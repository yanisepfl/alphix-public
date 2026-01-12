// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";

/**
 * @title AlphixLogicHookCallsTest
 * @author Alphix
 * @notice Tests for hook entrypoints on AlphixLogic: before/after initialize, liquidity, and swap calls
 * @dev Uses fresh pools for activation-dependent paths; asserts onlyHook and pause semantics
 */
contract AlphixLogicHookCallsTest is BaseAlphixTest {
    /* NOTE:
       - Default pool from BaseAlphixTest is already initialized on Alphix.
       - For tests requiring activation/inactivation transitions, fresh pools are created to avoid state coupling.
    */

    /* beforeInitialize */

    function test_beforeInitialize_success() public {
        vm.prank(address(hook));
        bytes4 result = logic.beforeInitialize(user1, key, Constants.SQRT_PRICE_1_1);
        assertEq(result, BaseHook.beforeInitialize.selector, "selector mismatch");
    }

    function test_beforeInitialize_revertsOnNonHook() public {
        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.beforeInitialize(user1, key, Constants.SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsWhenPaused() public {
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        logic.beforeInitialize(user1, key, Constants.SQRT_PRICE_1_1);
    }

    /* afterInitialize */

    function test_afterInitialize_success() public {
        // key has dynamic fee flag (LPFeeLibrary.DYNAMIC_FEE_FLAG), so this should succeed
        vm.prank(address(hook));
        bytes4 result = logic.afterInitialize(user1, key, Constants.SQRT_PRICE_1_1, 0);
        assertEq(result, BaseHook.afterInitialize.selector, "selector mismatch");
    }

    function test_afterInitialize_revertsOnStaticFee() public {
        // Create a PoolKey with a static fee (e.g., 3000)
        // forge-lint: disable-next-line(named-struct-fields)
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, defaultTickSpacing, IHooks(hook));

        vm.prank(address(hook));
        vm.expectRevert(BaseDynamicFee.NotDynamicFee.selector);
        logic.afterInitialize(user1, staticKey, Constants.SQRT_PRICE_1_1, 0);
    }

    function test_afterInitialize_revertsOnNonHook() public {
        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.afterInitialize(user1, key, Constants.SQRT_PRICE_1_1, 0);
    }

    function test_afterInitialize_revertsWhenPaused() public {
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        logic.afterInitialize(user1, key, Constants.SQRT_PRICE_1_1, 0);
    }

    /* before/after Add/Remove Liquidity */

    function test_beforeAddLiquidity_success_onFreshConfiguredPool() public {
        // Deploy fresh hook + logic stack for this test (single-pool-per-hook architecture)
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        int24 lower = -int24(3 * defaultTickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(3 * defaultTickSpacing);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000, salt: 0});

        vm.prank(address(freshHook));
        bytes4 result = freshLogic.beforeAddLiquidity(user1, kFresh, params, "");
        assertEq(result, BaseHook.beforeAddLiquidity.selector, "selector mismatch");
    }

    function test_beforeAddLiquidity_revertsOnInactivePool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook then deactivate
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.prank(address(freshHook));
        freshLogic.deactivatePool();

        int24 lower = -int24(3 * defaultTickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(3 * defaultTickSpacing);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000, salt: 0});

        vm.prank(address(freshHook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        freshLogic.beforeAddLiquidity(user1, kFresh, params, "");
    }

    function test_beforeRemoveLiquidity_success_onFreshConfiguredPool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        int24 lower = -int24(3 * defaultTickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(3 * defaultTickSpacing);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000, salt: 0});

        vm.prank(address(freshHook));
        bytes4 result = freshLogic.beforeRemoveLiquidity(user1, kFresh, params, "");
        assertEq(result, BaseHook.beforeRemoveLiquidity.selector, "selector mismatch");
    }

    function test_afterAddLiquidity_success_onFreshConfiguredPool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        int24 lower = -int24(3 * defaultTickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(3 * defaultTickSpacing);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000, salt: 0});

        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.prank(address(freshHook));
        (bytes4 selector, BalanceDelta hookDelta) = freshLogic.afterAddLiquidity(user1, kFresh, params, zero, zero, "");
        assertEq(selector, BaseHook.afterAddLiquidity.selector, "selector mismatch");
        assertEq(BalanceDelta.unwrap(hookDelta), 0, "hook delta should be zero");
    }

    function test_afterRemoveLiquidity_success_onFreshConfiguredPool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        int24 lower = -int24(3 * defaultTickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(3 * defaultTickSpacing);
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000, salt: 0});

        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.prank(address(freshHook));
        (bytes4 selector, BalanceDelta hookDelta) =
            freshLogic.afterRemoveLiquidity(user1, kFresh, params, zero, zero, "");
        assertEq(selector, BaseHook.afterRemoveLiquidity.selector, "selector mismatch");
        assertEq(BalanceDelta.unwrap(hookDelta), 0, "hook delta should be zero");
    }

    /* before/after Swap */

    function test_beforeSwap_success_onFreshConfiguredPool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.prank(address(freshHook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee,) = freshLogic.beforeSwap(user1, kFresh, params, "");
        assertEq(selector, BaseHook.beforeSwap.selector, "selector mismatch");
        assertEq(BeforeSwapDelta.unwrap(delta), 0, "delta should be zero");
        assertEq(fee, 0, "fee override should be zero");
    }

    function test_beforeSwap_revertsOnInactivePool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook then deactivate
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.prank(address(freshHook));
        freshLogic.deactivatePool();

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        vm.prank(address(freshHook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        freshLogic.beforeSwap(user1, kFresh, params, "");
    }

    function test_afterSwap_success_onFreshConfiguredPool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.prank(address(freshHook));
        (bytes4 selector, int128 hookDelta,) = freshLogic.afterSwap(user1, kFresh, params, zero, "");
        assertEq(selector, BaseHook.afterSwap.selector, "selector mismatch");
        assertEq(hookDelta, 0, "hook delta should be zero");
    }

    function test_afterSwap_revertsOnInactivePool() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook then deactivate
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.prank(address(freshHook));
        freshLogic.deactivatePool();

        SwapParams memory params =
            SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.prank(address(freshHook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        freshLogic.afterSwap(user1, kFresh, params, zero, "");
    }

    /* All onlyHook entrypoints revert on non-hook */

    function test_allHookCalls_revertOnNonHook() public {
        // Deploy fresh hook + logic stack for this test
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create and initialize a pool on the fresh hook
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        int24 lower = -int24(3 * defaultTickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 upper = int24(3 * defaultTickSpacing);
        ModifyLiquidityParams memory lpParams =
            ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1000, salt: 0});

        SwapParams memory swapParams =
            SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1});

        BalanceDelta zero = BalanceDelta.wrap(0);

        vm.startPrank(user1);

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.beforeInitialize(user1, kFresh, Constants.SQRT_PRICE_1_1);

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.afterInitialize(user1, kFresh, Constants.SQRT_PRICE_1_1, 0);

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.beforeAddLiquidity(user1, kFresh, lpParams, "");

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.beforeRemoveLiquidity(user1, kFresh, lpParams, "");

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.afterAddLiquidity(user1, kFresh, lpParams, zero, zero, "");

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.afterRemoveLiquidity(user1, kFresh, lpParams, zero, zero, "");

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.beforeSwap(user1, kFresh, swapParams, "");

        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        freshLogic.afterSwap(user1, kFresh, swapParams, zero, "");

        vm.stopPrank();
    }
}
