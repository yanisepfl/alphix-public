// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixInvariantHandler
 * @author Alphix
 * @notice Production-ready handler for invariant testing with full swap and liquidity operations
 * @dev Guides the fuzzer through valid state transitions while performing real protocol interactions
 */
contract AlphixInvariantHandler is CommonBase, StdCheats, StdUtils {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;

    // Core contracts
    Alphix public hook;
    IAlphixLogic public logic;
    IPoolManager public poolManager;
    IPositionManager public positionManager;
    IUniswapV4Router04 public swapRouter;
    IPermit2 public permit2;

    // Test actors
    address public owner;
    address public user1;
    address public user2;
    address[] public actors;

    // Test currencies
    Currency public currency0;
    Currency public currency1;

    // Call counters for statistics
    uint256 public callCountpoke;
    uint256 public callCountpokeFailed; // Track failed poke attempts for cooldown validation
    uint256 public callCountswap;
    uint256 public callCountaddLiquidity;
    uint256 public callCountremoveLiquidity;
    uint256 public callCounttimeWarp;
    uint256 public callCountpause;
    uint256 public callCountunpause;

    // Ghost variables for tracking state
    uint256 public ghostsumOfFees;
    uint256 public ghostsumOfTargetRatios;
    uint256 public ghostmaxFeeObserved;
    uint256 public ghostminFeeObserved = type(uint256).max;
    uint256 public ghosttotalSwapVolume;
    uint256 public ghosttotalLiquidityAdded;
    uint256 public ghosttotalLiquidityRemoved;

    // Pool tracking
    PoolKey[] public pools;
    mapping(PoolId => uint256) public poolIndex;
    mapping(PoolId => bool) public poolExists;
    mapping(PoolId => mapping(address => uint256[])) public userPositions; // poolId => user => tokenIds

    // Track liquidity amount for each position (tokenId => liquidityAmount)
    mapping(uint256 => uint128) public positionLiquidity;

    constructor(
        Alphix _hook,
        IAlphixLogic _logic,
        address _owner,
        address _user1,
        address _user2,
        IPoolManager _poolManager,
        IPositionManager _positionManager,
        IUniswapV4Router04 _swapRouter,
        IPermit2 _permit2,
        Currency _currency0,
        Currency _currency1
    ) {
        hook = _hook;
        logic = _logic;
        owner = _owner;
        user1 = _user1;
        user2 = _user2;
        poolManager = _poolManager;
        positionManager = _positionManager;
        swapRouter = _swapRouter;
        permit2 = _permit2;
        currency0 = _currency0;
        currency1 = _currency1;

        // Setup actors
        actors.push(owner);
        actors.push(user1);
        actors.push(user2);
    }

    /* ========================================================================== */
    /*                           HANDLER FUNCTIONS                                */
    /* ========================================================================== */

    /**
     * @notice Poke a pool with a fuzzed current ratio
     * @dev Bounded to valid ratio range with cooldown handling
     */
    function poke(uint256 poolSeed, uint256 ratioSeed) public {
        // Select a pool
        if (pools.length == 0) return;
        PoolKey memory poolKey = pools[poolSeed % pools.length];
        PoolId poolId = poolKey.toId();

        // Check if pool is configured
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        if (!config.isConfigured) return;

        // Conditionally warp time to test cooldown enforcement
        // 50% chance to warp past cooldown, 50% chance to test same-block/cooldown rejection
        if (ratioSeed % 2 == 0) {
            // Warp past cooldown to allow poke
            vm.warp(block.timestamp + 1 days + 1);
        }
        // else: don't warp, test cooldown enforcement

        // Bound current ratio to valid range
        uint256 currentRatio = bound(ratioSeed, 1, AlphixGlobalConstants.MAX_CURRENT_RATIO);

        // Poke as owner
        vm.prank(owner);
        try hook.poke(poolKey, currentRatio) {
            callCountpoke++;

            // Update ghost variables
            uint24 newFee = hook.getFee(poolKey);
            ghostsumOfFees += newFee;
            if (newFee > ghostmaxFeeObserved) ghostmaxFeeObserved = newFee;
            if (newFee < ghostminFeeObserved) ghostminFeeObserved = newFee;

            config = logic.getPoolConfig(poolId);
            ghostsumOfTargetRatios += config.initialTargetRatio;
        } catch {
            // Poke can fail for various valid reasons (cooldown, paused, zero ratio, etc.)
            callCountpokeFailed++;
        }
    }

    /**
     * @notice Perform a swap with real router
     * @dev Bounded swap amounts with proper token minting and approval
     */
    function swap(uint256 poolSeed, uint256 amountSeed, bool zeroForOne) public {
        if (pools.length == 0) return;
        PoolKey memory poolKey = pools[poolSeed % pools.length];
        PoolId poolId = poolKey.toId();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        if (!config.isConfigured) return;

        // Bound swap amount (0.01 to 100 tokens)
        uint256 swapAmount = bound(amountSeed, 1e16, 100e18);

        // Select random actor
        address actor = actors[amountSeed % actors.length];

        // Mint and approve tokens
        Currency inputCurrency = zeroForOne ? currency0 : currency1;
        MockERC20(Currency.unwrap(inputCurrency)).mint(actor, swapAmount);

        vm.startPrank(actor);
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), swapAmount);

        // Perform swap
        try swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: actor,
            deadline: block.timestamp + 100
        }) returns (BalanceDelta) {
            callCountswap++;
            ghosttotalSwapVolume += swapAmount;
            // Note: Delta can legitimately be zero in edge cases (extreme slippage)
            // Ghost variables track successful swaps for invariant validation
        } catch {
            // Swap can fail for various reasons (slippage, liquidity, paused, etc.)
            // This is expected behavior
        }
        vm.stopPrank();
    }

    /**
     * @notice Add liquidity to a pool using position manager
     * @dev Full-range liquidity with bounded amounts
     */
    function addLiquidity(uint256 poolSeed, uint128 liquiditySeed) public {
        if (pools.length == 0) return;
        PoolKey memory poolKey = pools[poolSeed % pools.length];
        PoolId poolId = poolKey.toId();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        if (!config.isConfigured) return;

        // Bound liquidity (1 to 1000 units)
        uint128 liquidityAmount = uint128(bound(uint256(liquiditySeed), 1e18, 1000e18));

        // Full range liquidity
        int24 tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        // Calculate required amounts
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // Select random actor
        address actor = actors[poolSeed % actors.length];

        // Mint tokens with buffer
        uint256 buffer = 1e18;
        MockERC20(Currency.unwrap(currency0)).mint(actor, amount0 + buffer);
        MockERC20(Currency.unwrap(currency1)).mint(actor, amount1 + buffer);

        vm.startPrank(actor);

        // Approve tokens to permit2
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amount0 + buffer);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amount1 + buffer);

        // Approve permit2 to spend on behalf of position manager
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amount0 + buffer), expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amount1 + buffer), expiry);

        // Use EasyPosm library for minting
        // Note: EasyPosm library calls are internal wrappers, so try-catch would require external wrapper
        // Instead, we let failures bubble up - fuzzer will handle gracefully via fail_on_revert = false
        (uint256 tokenId,) = positionManager.mint(
            poolKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0 + buffer,
            amount1 + buffer,
            actor,
            block.timestamp + 100,
            Constants.ZERO_BYTES
        );

        vm.stopPrank();

        callCountaddLiquidity++;
        ghosttotalLiquidityAdded += liquidityAmount;

        // Track position and its liquidity amount
        userPositions[poolId][actor].push(tokenId);
        positionLiquidity[tokenId] = liquidityAmount;
    }

    /**
     * @notice Remove liquidity from a pool using position manager
     * @dev Removes from existing positions (burns entire position)
     */
    function removeLiquidity(uint256 poolSeed, uint256 positionSeed) public {
        if (pools.length == 0) return;
        PoolKey memory poolKey = pools[poolSeed % pools.length];
        PoolId poolId = poolKey.toId();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        if (!config.isConfigured) return;

        // Select random actor
        address actor = actors[poolSeed % actors.length];

        // Check if actor has positions
        if (userPositions[poolId][actor].length == 0) return;

        // Select a position
        uint256 positionIdx = positionSeed % userPositions[poolId][actor].length;
        uint256 tokenId = userPositions[poolId][actor][positionIdx];

        vm.startPrank(actor);

        // Get liquidity amount before burning
        uint128 liquidityAmount = positionLiquidity[tokenId];

        // Use EasyPosm library for burning
        // Note: EasyPosm library calls are internal wrappers, so try-catch would require external wrapper
        // Instead, we let failures bubble up - fuzzer will handle gracefully via fail_on_revert = false
        positionManager.burn(
            tokenId,
            0, // amount0Min
            0, // amount1Min
            actor,
            block.timestamp + 100,
            Constants.ZERO_BYTES
        );

        vm.stopPrank();

        callCountremoveLiquidity++;
        // Track actual liquidity amount removed (not just operation count)
        ghosttotalLiquidityRemoved += liquidityAmount;

        // Clean up position tracking
        delete positionLiquidity[tokenId];

        // Remove tokenId from userPositions array (swap with last and pop)
        uint256 lastIdx = userPositions[poolId][actor].length - 1;
        if (positionIdx != lastIdx) {
            userPositions[poolId][actor][positionIdx] = userPositions[poolId][actor][lastIdx];
        }
        userPositions[poolId][actor].pop();
    }

    /**
     * @notice Warp time forward to test cooldowns and time-based behavior
     * @dev Bounded time warp (1 hour to 30 days)
     */
    function warpTime(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 1 hours, 30 days);
        vm.warp(block.timestamp + timeDelta);
        callCounttimeWarp++;
    }

    /**
     * @notice Pause the contract (only owner can do this)
     */
    function pauseContract() public {
        vm.prank(owner);
        try hook.pause() {
            callCountpause++;
        } catch {
            // Already paused or other error
        }
    }

    /**
     * @notice Unpause the contract (only owner can do this)
     */
    function unpauseContract() public {
        vm.prank(owner);
        try hook.unpause() {
            callCountunpause++;
        } catch {
            // Already unpaused or other error
        }
    }

    /**
     * @notice Add a pool to the handler's tracking
     * @dev Called during setup and registers pool with test contract for invariant tracking
     */
    function addPool(PoolKey memory poolKey) external {
        PoolId poolId = poolKey.toId();
        if (!poolExists[poolId]) {
            pools.push(poolKey);
            poolIndex[poolId] = pools.length - 1;
            poolExists[poolId] = true;

            // Register pool with test contract for invariant tracking
            // When called from test contract (setUp or fuzzing), msg.sender is AlphixInvariantsTest
            // The low-level call allows graceful handling if called from other contexts
            (bool success,) =
                msg.sender.call(abi.encodeWithSignature("trackPool((address,address,uint24,int24,address))", poolKey));
            // Ignore return value - failure only occurs if called from non-test context
            success; // Suppress unused variable warning
        }
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    function getGhostVariables() external view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            ghostsumOfFees,
            ghostsumOfTargetRatios,
            ghostmaxFeeObserved,
            ghostminFeeObserved,
            ghosttotalSwapVolume,
            ghosttotalLiquidityAdded,
            ghosttotalLiquidityRemoved
        );
    }

    function getUserPositionCount(PoolId poolId, address user) external view returns (uint256) {
        return userPositions[poolId][user].length;
    }

    function getUserPosition(PoolId poolId, address user, uint256 index) external view returns (uint256) {
        return userPositions[poolId][user][index];
    }
}
