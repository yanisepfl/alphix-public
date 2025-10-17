// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";

/**
 * @title AlphixLogicHookCallsFuzzTest
 * @author Alphix
 * @notice Fuzz tests for AlphixLogic hook callback access control and state validation
 * @dev Tests hook callbacks with fuzzed callers and pool states
 */
contract AlphixLogicHookCallsFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    /* ========================================================================== */
    /*                        CALLER AUTHORIZATION TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that non-hook callers are rejected for hook callbacks
     * @dev Tests all hook callbacks reject unauthorized callers
     * @param callerSeed Seed for unauthorized caller address
     */
    function testFuzz_hook_callbacks_reject_non_hook_callers(uint256 callerSeed) public {
        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        vm.assume(caller != address(hook));

        // afterInitialize rejects non-hook
        vm.prank(caller);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.afterInitialize(user1, key, Constants.SQRT_PRICE_1_1, 0);

        // beforeAddLiquidity rejects non-hook
        vm.prank(caller);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.beforeAddLiquidity(
            user1, key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
        );

        // beforeRemoveLiquidity rejects non-hook
        vm.prank(caller);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.beforeRemoveLiquidity(
            user1, key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0}), ""
        );

        // beforeSwap rejects non-hook
        vm.prank(caller);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.beforeSwap(user1, key, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), "");
    }

    /* ========================================================================== */
    /*                         STATIC FEE REJECTION TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that afterInitialize rejects static fee pools
     * @dev Tests with various static fee values
     * @param staticFee Static fee value to test
     */
    function testFuzz_afterInitialize_rejects_static_fee(uint24 staticFee) public {
        // Bound to valid static fee range (exclude dynamic fee flag)
        staticFee = uint24(bound(staticFee, 1, LPFeeLibrary.MAX_LP_FEE));
        vm.assume(!LPFeeLibrary.isDynamicFee(staticFee));

        // Create static fee key
        // forge-lint: disable-next-line(named-struct-fields)
        PoolKey memory staticKey = PoolKey(currency0, currency1, staticFee, defaultTickSpacing, IHooks(hook));

        // Should revert with NotDynamicFee
        vm.prank(address(hook));
        vm.expectRevert(BaseDynamicFee.NotDynamicFee.selector);
        logic.afterInitialize(user1, staticKey, Constants.SQRT_PRICE_1_1, 0);
    }

    /* ========================================================================== */
    /*                        POOL STATE VALIDATION TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that operations succeed on active pools with various tick ranges
     * @dev Tests liquidity operations with fuzzed tick ranges
     * @param tickSpacingMultiplier Multiplier for tick spacing (1-10)
     * @param liquidityDelta Liquidity delta amount
     */
    function testFuzz_beforeAddLiquidity_succeeds_with_various_ticks(
        uint8 tickSpacingMultiplier,
        int256 liquidityDelta
    ) public {
        // Bound parameters
        tickSpacingMultiplier = uint8(bound(tickSpacingMultiplier, 1, 10));
        liquidityDelta = int256(bound(liquidityDelta, 1, 1e24));

        // Create fresh configured pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Calculate ticks based on multiplier
        int24 lower = -int24(uint24(tickSpacingMultiplier) * uint24(defaultTickSpacing));
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(uint24(tickSpacingMultiplier) * uint24(defaultTickSpacing));

        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: liquidityDelta, salt: 0});

        // Should succeed from hook
        vm.prank(address(hook));
        bytes4 result = logic.beforeAddLiquidity(user1, kFresh, params, "");
        assertEq(result, BaseHook.beforeAddLiquidity.selector, "selector mismatch");
    }

    /**
     * @notice Fuzz test that operations fail on deactivated pools
     * @dev Tests that deactivated pools reject all operations
     * @param operationType Operation type (0=add liq, 1=remove liq, 2=swap)
     */
    function testFuzz_operations_fail_on_deactivated_pool(uint8 operationType) public {
        // Bound operation type
        operationType = uint8(bound(operationType, 0, 2));

        // Create and deactivate pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
        );

        vm.prank(address(hook));
        logic.deactivatePool(kFresh);

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);

        if (operationType == 0) {
            // Add liquidity
            logic.beforeAddLiquidity(
                user1, kFresh, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
            );
        } else if (operationType == 1) {
            // Remove liquidity
            logic.beforeRemoveLiquidity(
                user1,
                kFresh,
                ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0}),
                ""
            );
        } else {
            // Swap
            logic.beforeSwap(
                user1, kFresh, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
            );
        }
    }

    /**
     * @notice Fuzz test that swap direction doesn't affect access control
     * @dev Tests beforeSwap with both swap directions and amounts
     * @param zeroForOne Swap direction
     * @param amountSpecified Swap amount (can be positive or negative)
     */
    function testFuzz_beforeSwap_works_with_any_direction(bool zeroForOne, int256 amountSpecified) public {
        // Bound amount (avoid zero and handle type(int256).min edge case)
        if (amountSpecified >= 0) {
            amountSpecified = int256(bound(uint256(amountSpecified), 1, 1e24));
        } else {
            // Avoid type(int256).min which cannot be negated
            vm.assume(amountSpecified != type(int256).min);
            uint256 absAmount = uint256(-amountSpecified);
            amountSpecified = -int256(bound(absAmount, 1, 1e24));
        }

        // Create fresh pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Swap should succeed from hook
        vm.prank(address(hook));
        (bytes4 result,,) = logic.beforeSwap(
            user1,
            kFresh,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0}),
            ""
        );
        assertEq(result, BaseHook.beforeSwap.selector, "selector mismatch");
    }

    /* ========================================================================== */
    /*                          PAUSE STATE TESTS                                */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that all callbacks fail when paused
     * @dev Tests that global pause affects all hook callbacks
     * @param callbackType Callback type to test (0-3)
     */
    function testFuzz_all_callbacks_fail_when_paused(uint8 callbackType) public {
        // Bound callback type
        callbackType = uint8(bound(callbackType, 0, 3));

        // Pause logic
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);

        if (callbackType == 0) {
            logic.beforeInitialize(user1, key, Constants.SQRT_PRICE_1_1);
        } else if (callbackType == 1) {
            logic.afterInitialize(user1, key, Constants.SQRT_PRICE_1_1, 0);
        } else if (callbackType == 2) {
            logic.beforeAddLiquidity(
                user1, key, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
            );
        } else {
            logic.beforeSwap(
                user1, key, SwapParams({zeroForOne: true, amountSpecified: 1e18, sqrtPriceLimitX96: 0}), ""
            );
        }
    }

    /**
     * @notice Fuzz test that callbacks work after unpause
     * @dev Verifies pause/unpause cycle works correctly
     * @param shouldPause Whether to test pause cycle
     */
    function testFuzz_callbacks_work_after_unpause(bool shouldPause) public {
        if (shouldPause) {
            // Pause and unpause
            vm.startPrank(owner);
            AlphixLogic(address(logicProxy)).pause();
            AlphixLogic(address(logicProxy)).unpause();
            vm.stopPrank();
        }

        // afterInitialize should work
        vm.prank(address(hook));
        bytes4 result = logic.afterInitialize(user1, key, Constants.SQRT_PRICE_1_1, 0);
        assertEq(result, BaseHook.afterInitialize.selector, "should work after unpause");
    }

    /* ========================================================================== */
    /*                     POOL ACTIVATION/DEACTIVATION TESTS                    */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that pools can be activated and deactivated multiple times
     * @dev Tests activation state transitions
     * @param cycles Number of activation/deactivation cycles (1-5)
     */
    function testFuzz_pool_activation_deactivation_cycles(uint8 cycles) public {
        // Bound cycles
        cycles = uint8(bound(cycles, 1, 5));

        // Create pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
        );

        for (uint256 i = 0; i < cycles; i++) {
            // Deactivate
            vm.prank(address(hook));
            logic.deactivatePool(kFresh);

            // Try to add liquidity - should fail when deactivated
            vm.prank(address(hook));
            vm.expectRevert(IAlphixLogic.PoolPaused.selector);
            logic.beforeAddLiquidity(
                user1, kFresh, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
            );

            // Reactivate
            vm.prank(address(hook));
            logic.activatePool(kFresh);

            // Add liquidity should now work
            vm.prank(address(hook));
            bytes4 result = logic.beforeAddLiquidity(
                user1, kFresh, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
            );
            assertEq(result, BaseHook.beforeAddLiquidity.selector, "should work when activated");
        }
    }
}
