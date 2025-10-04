// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";
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
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
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
    uint256 public callCount_poke;
    uint256 public callCount_swap;
    uint256 public callCount_addLiquidity;
    uint256 public callCount_removeLiquidity;
    uint256 public callCount_timeWarp;
    uint256 public callCount_pause;
    uint256 public callCount_unpause;

    // Ghost variables for tracking state
    uint256 public ghost_sumOfFees;
    uint256 public ghost_sumOfTargetRatios;
    uint256 public ghost_maxFeeObserved;
    uint256 public ghost_minFeeObserved = type(uint256).max;
    uint256 public ghost_totalSwapVolume;
    uint256 public ghost_totalLiquidityAdded;
    uint256 public ghost_totalLiquidityRemoved;

    // Pool tracking
    PoolKey[] public pools;
    mapping(PoolId => uint256) public poolIndex;
    mapping(PoolId => bool) public poolExists;
    mapping(PoolId => mapping(address => uint256[])) public userPositions; // poolId => user => tokenIds

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

        // Warp time forward to ensure cooldown passes
        vm.warp(block.timestamp + 1 days + 1);

        // Bound current ratio to valid range
        uint256 currentRatio = bound(ratioSeed, 1, AlphixGlobalConstants.MAX_CURRENT_RATIO);

        // Poke as owner
        vm.prank(owner);
        try hook.poke(poolKey, currentRatio) {
            callCount_poke++;

            // Update ghost variables
            uint24 newFee = hook.getFee(poolKey);
            ghost_sumOfFees += newFee;
            if (newFee > ghost_maxFeeObserved) ghost_maxFeeObserved = newFee;
            if (newFee < ghost_minFeeObserved) ghost_minFeeObserved = newFee;

            config = logic.getPoolConfig(poolId);
            ghost_sumOfTargetRatios += config.initialTargetRatio;
        } catch {
            // Poke can fail for various valid reasons (paused, etc.)
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
        }) returns (BalanceDelta delta) {
            callCount_swap++;
            ghost_totalSwapVolume += swapAmount;

            // Successful swap - delta should be non-zero
            assert(delta.amount0() != 0 || delta.amount1() != 0);
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

        callCount_addLiquidity++;
        ghost_totalLiquidityAdded += liquidityAmount;

        // Track position
        userPositions[poolId][actor].push(tokenId);

        vm.stopPrank();
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

        // Use EasyPosm library for burning (burns entire position)
        positionManager.burn(
            tokenId,
            0, // amount0Min
            0, // amount1Min
            actor,
            block.timestamp + 100,
            Constants.ZERO_BYTES
        );

        callCount_removeLiquidity++;
        // Note: We don't track exact liquidity amount in burn since EasyPosm burns entire position
        ghost_totalLiquidityRemoved += 1; // Just count the operation

        vm.stopPrank();
    }

    /**
     * @notice Warp time forward to test cooldowns and time-based behavior
     * @dev Bounded time warp (1 hour to 30 days)
     */
    function warpTime(uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 1 hours, 30 days);
        vm.warp(block.timestamp + timeDelta);
        callCount_timeWarp++;
    }

    /**
     * @notice Pause the contract (only owner can do this)
     */
    function pauseContract() public {
        vm.prank(owner);
        try hook.pause() {
            callCount_pause++;
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
            callCount_unpause++;
        } catch {
            // Already unpaused or other error
        }
    }

    /**
     * @notice Add a pool to the handler's tracking
     * @dev Called during setup
     */
    function addPool(PoolKey memory poolKey) external {
        PoolId poolId = poolKey.toId();
        if (!poolExists[poolId]) {
            pools.push(poolKey);
            poolIndex[poolId] = pools.length - 1;
            poolExists[poolId] = true;
        }
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    function getPoolCount() external view returns (uint256) {
        return pools.length;
    }

    function getGhostVariables()
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (
            ghost_sumOfFees,
            ghost_sumOfTargetRatios,
            ghost_maxFeeObserved,
            ghost_minFeeObserved,
            ghost_totalSwapVolume,
            ghost_totalLiquidityAdded,
            ghost_totalLiquidityRemoved
        );
    }

    function getUserPositionCount(PoolId poolId, address user) external view returns (uint256) {
        return userPositions[poolId][user].length;
    }

    function getUserPosition(PoolId poolId, address user, uint256 index) external view returns (uint256) {
        return userPositions[poolId][user][index];
    }
}
