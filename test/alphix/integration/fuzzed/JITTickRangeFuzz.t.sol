// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title JITTickRangeFuzzTest
 * @notice Fuzz tests for JIT liquidity behavior across different tick range configurations
 * @dev Tests verify that:
 *      1. Swaps never revert regardless of JIT tick range configuration
 *      2. JIT participation is correctly determined by tick position
 *      3. Yield sources change only when JIT participates
 *
 *      Since tick range is immutable (set at pool initialization), each fuzz test
 *      deploys a fresh hook with the fuzzed tick range.
 */
contract JITTickRangeFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    /**
     * @notice Struct to hold infrastructure deployed for fuzz tests
     */
    struct FuzzInfrastructure {
        Alphix freshHook;
        AccessManager freshAm;
        PoolKey testKey;
        Currency testCurrency0;
        Currency testCurrency1;
        MockYieldVault testVault0;
        MockYieldVault testVault1;
        int24 jitTickLower;
        int24 jitTickUpper;
    }

    address public yieldManager;
    address public alice;
    address public bob;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /**
     * @notice Fuzz test: JIT behavior with various tick ranges
     * @dev Verifies swaps never revert and JIT participation matches tick position.
     *      Deploys a fresh hook per fuzz run with the tick range set at initialization.
     * @param jitTickLowerSeed Used to derive JIT tick lower bound
     * @param jitTickUpperSeed Used to derive JIT tick upper bound
     * @param swapAmount Amount to swap (bounded to reasonable range)
     * @param zeroForOne Swap direction
     */
    function testFuzz_jitBehaviorVsTickRange(
        int24 jitTickLowerSeed,
        int24 jitTickUpperSeed,
        uint256 swapAmount,
        bool zeroForOne
    ) public {
        // Bound swap amount to reasonable range (0.01 to 100 tokens)
        swapAmount = bound(swapAmount, 0.01e18, 100e18);

        FuzzInfrastructure memory infra;

        // Derive valid tick range from seeds
        int24 minTick = TickMath.minUsableTick(defaultTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(defaultTickSpacing);

        // Bound the seeds to valid tick range
        int24 rawLower = int24(bound(int256(jitTickLowerSeed), int256(minTick), int256(maxTick - defaultTickSpacing)));
        int24 rawUpper = int24(bound(int256(jitTickUpperSeed), int256(rawLower + defaultTickSpacing), int256(maxTick)));

        // Align to tick spacing
        infra.jitTickLower = (rawLower / defaultTickSpacing) * defaultTickSpacing;
        infra.jitTickUpper = (rawUpper / defaultTickSpacing) * defaultTickSpacing;

        // Ensure valid range
        if (infra.jitTickUpper <= infra.jitTickLower) {
            infra.jitTickUpper = infra.jitTickLower + defaultTickSpacing;
        }

        // Deploy fresh hook with tick range set at initialization
        _deployFreshInfrastructureWithTickRange(infra);

        // Add base liquidity
        _addRegularLpToPool(infra.testKey, infra.testCurrency0, infra.testCurrency1, 10000e18);

        // Configure yield sources
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, infra.freshAm, address(infra.freshHook));
        vm.stopPrank();

        vm.startPrank(yieldManager);
        infra.freshHook.setYieldSource(infra.testCurrency0, address(infra.testVault0));
        infra.freshHook.setYieldSource(infra.testCurrency1, address(infra.testVault1));
        vm.stopPrank();

        // Add rehypo liquidity
        _addReHypoLiquidityToPool(infra.freshHook, infra.testCurrency0, infra.testCurrency1, alice, 100e18);

        // Get current tick from the fresh pool
        (, int24 currentTick,,) = poolManager.getSlot0(infra.testKey.toId());

        // Record state before
        uint256 yieldSource0Before = infra.freshHook.getAmountInYieldSource(infra.testCurrency0);
        uint256 yieldSource1Before = infra.freshHook.getAmountInYieldSource(infra.testCurrency1);

        // Determine if current tick is in range BEFORE the swap
        bool wasInRange = currentTick >= infra.jitTickLower && currentTick < infra.jitTickUpper;

        // Execute swap - THIS SHOULD NEVER REVERT
        vm.startPrank(bob);
        if (zeroForOne) {
            MockERC20(Currency.unwrap(infra.testCurrency0)).approve(address(swapRouter), swapAmount);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: infra.testKey,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
        } else {
            MockERC20(Currency.unwrap(infra.testCurrency1)).approve(address(swapRouter), swapAmount);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: false,
                poolKey: infra.testKey,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
        }
        vm.stopPrank();

        // Record state after
        uint256 yieldSource0After = infra.freshHook.getAmountInYieldSource(infra.testCurrency0);
        uint256 yieldSource1After = infra.freshHook.getAmountInYieldSource(infra.testCurrency1);

        bool yieldSourcesChanged =
            (yieldSource0After != yieldSource0Before) || (yieldSource1After != yieldSource1Before);

        // If we started in range, JIT should have participated (yield sources should change)
        // If we started out of range, JIT should NOT have participated (unless swap moved us into range)
        if (wasInRange) {
            assertTrue(yieldSourcesChanged, "JIT should participate when tick starts in range");
        }
        // Note: We can't assert !yieldSourcesChanged for out-of-range because the swap
        // might move the price INTO the range during execution
    }

    /**
     * @notice Fuzz test: Swaps never revert with extreme tick range configurations
     * @dev Tests edge cases like very narrow ranges, ranges at extremes, etc.
     *      Deploys a fresh hook per fuzz run with the tick range set at initialization.
     */
    function testFuzz_swapsNeverRevert_extremeRanges(uint256 rangeType, uint256 swapAmount, bool zeroForOne) public {
        // Bound swap amount
        swapAmount = bound(swapAmount, 0.01e18, 50e18);

        FuzzInfrastructure memory infra;

        int24 minTick = TickMath.minUsableTick(defaultTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(defaultTickSpacing);

        // Choose range type based on rangeType seed
        // Note: We use tick 0 as "current tick" reference since we initialize at SQRT_PRICE_1_1
        uint256 rangeChoice = rangeType % 6;
        int24 referenceTick = 0; // At SQRT_PRICE_1_1, current tick is 0

        if (rangeChoice == 0) {
            // Full range
            infra.jitTickLower = minTick;
            infra.jitTickUpper = maxTick;
        } else if (rangeChoice == 1) {
            // Single tick spacing (minimum valid range) around reference
            infra.jitTickLower = (referenceTick / defaultTickSpacing) * defaultTickSpacing;
            infra.jitTickUpper = infra.jitTickLower + defaultTickSpacing;
        } else if (rangeChoice == 2) {
            // Range far below reference tick
            infra.jitTickLower = minTick;
            infra.jitTickUpper = minTick + defaultTickSpacing * 10;
        } else if (rangeChoice == 3) {
            // Range far above reference tick
            infra.jitTickLower = maxTick - defaultTickSpacing * 10;
            infra.jitTickUpper = maxTick;
        } else if (rangeChoice == 4) {
            // Range around reference tick (likely in range)
            infra.jitTickLower = ((referenceTick - 1000) / defaultTickSpacing) * defaultTickSpacing;
            infra.jitTickUpper = ((referenceTick + 1000) / defaultTickSpacing) * defaultTickSpacing;
            if (infra.jitTickUpper <= infra.jitTickLower) {
                infra.jitTickUpper = infra.jitTickLower + defaultTickSpacing;
            }
        } else {
            // Asymmetric range
            infra.jitTickLower = ((referenceTick - 500) / defaultTickSpacing) * defaultTickSpacing;
            infra.jitTickUpper = ((referenceTick + 2000) / defaultTickSpacing) * defaultTickSpacing;
            if (infra.jitTickUpper <= infra.jitTickLower) {
                infra.jitTickUpper = infra.jitTickLower + defaultTickSpacing;
            }
        }

        // Deploy fresh hook with tick range set at initialization
        _deployFreshInfrastructureWithTickRange(infra);

        // Add base liquidity
        _addRegularLpToPool(infra.testKey, infra.testCurrency0, infra.testCurrency1, 10000e18);

        // Configure yield sources
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, infra.freshAm, address(infra.freshHook));
        vm.stopPrank();

        vm.startPrank(yieldManager);
        infra.freshHook.setYieldSource(infra.testCurrency0, address(infra.testVault0));
        infra.freshHook.setYieldSource(infra.testCurrency1, address(infra.testVault1));
        vm.stopPrank();

        _addReHypoLiquidityToPool(infra.freshHook, infra.testCurrency0, infra.testCurrency1, alice, 100e18);

        // Execute swap - THIS SHOULD NEVER REVERT regardless of range configuration
        vm.startPrank(bob);
        if (zeroForOne) {
            MockERC20(Currency.unwrap(infra.testCurrency0)).approve(address(swapRouter), swapAmount);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: infra.testKey,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
        } else {
            MockERC20(Currency.unwrap(infra.testCurrency1)).approve(address(swapRouter), swapAmount);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: false,
                poolKey: infra.testKey,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
        }
        vm.stopPrank();

        // If we reach here, swap succeeded (which is the main assertion)
        assertTrue(true, "Swap completed without revert");
    }

    // NOTE: testFuzz_consecutiveSwapsWithRangeChanges was DELETED because it tested
    // changing tick range multiple times, which is no longer supported since tick range
    // is now immutable (set at pool initialization time).

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Deploys a fresh Alphix infrastructure with a specific tick range
     * @param infra The infrastructure struct to populate (must have jitTickLower and jitTickUpper set)
     */
    function _deployFreshInfrastructureWithTickRange(FuzzInfrastructure memory infra) internal {
        // Deploy fresh Alphix stack
        (infra.freshHook, infra.freshAm) = _deployFreshAlphixStackFull();

        // Initialize pool with the specified tick range
        (infra.testKey,) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            infra.freshHook,
            infra.jitTickLower,
            infra.jitTickUpper
        );

        infra.testCurrency0 = infra.testKey.currency0;
        infra.testCurrency1 = infra.testKey.currency1;

        // Fund test users generously
        uint256 fundAmount = INITIAL_TOKEN_AMOUNT * 100;
        MockERC20(Currency.unwrap(infra.testCurrency0)).mint(alice, fundAmount);
        MockERC20(Currency.unwrap(infra.testCurrency1)).mint(alice, fundAmount);
        MockERC20(Currency.unwrap(infra.testCurrency0)).mint(bob, fundAmount);
        MockERC20(Currency.unwrap(infra.testCurrency1)).mint(bob, fundAmount);

        // Deploy yield vaults
        infra.testVault0 = new MockYieldVault(IERC20(Currency.unwrap(infra.testCurrency0)));
        infra.testVault1 = new MockYieldVault(IERC20(Currency.unwrap(infra.testCurrency1)));
    }

    /**
     * @notice Adds regular LP liquidity to a pool
     * @param _key Pool key
     * @param _currency0 Currency0
     * @param _currency1 Currency1
     * @param amount Liquidity amount
     */
    function _addRegularLpToPool(PoolKey memory _key, Currency _currency0, Currency _currency1, uint256 amount)
        internal
    {
        vm.startPrank(owner);

        int24 _fullRangeLower = TickMath.minUsableTick(_key.tickSpacing);
        int24 _fullRangeUpper = TickMath.maxUsableTick(_key.tickSpacing);

        // Mint tokens if needed
        uint256 mintAmount = amount * 2;
        MockERC20(Currency.unwrap(_currency0)).mint(owner, mintAmount);
        MockERC20(Currency.unwrap(_currency1)).mint(owner, mintAmount);

        MockERC20(Currency.unwrap(_currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(_currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(_currency0), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );
        permit2.approve(
            Currency.unwrap(_currency1), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );

        positionManager.mint(
            _key,
            _fullRangeLower,
            _fullRangeUpper,
            amount,
            amount,
            amount * 2,
            owner,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }

    /**
     * @notice Adds rehypothecated liquidity to a pool
     * @param _hook The Alphix hook
     * @param _currency0 Currency0
     * @param _currency1 Currency1
     * @param user The user adding liquidity
     * @param shares Number of shares to mint
     */
    function _addReHypoLiquidityToPool(
        Alphix _hook,
        Currency _currency0,
        Currency _currency1,
        address user,
        uint256 shares
    ) internal {
        (uint256 amount0, uint256 amount1) = _hook.previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(_currency0)).approve(address(_hook), amount0 + 1);
        MockERC20(Currency.unwrap(_currency1)).approve(address(_hook), amount1 + 1);
        _hook.addReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();
    }
}
