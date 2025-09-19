// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixHookCallsTest
 * @author Alphix
 * @notice Integration tests from the hook and user perspective covering initialize, liquidity, and swaps
 * @dev Leverages router and position manager for realistic flows
 */
contract AlphixHookCallsTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    /**
     * @notice Owner can initialize a new pool on Alphix Hook, config stored in Logic
     */
    function test_owner_can_initialize_new_pool_on_hook() public {
        // Make a brand-new pool bound to this hook, not configured on Alphix yet
        (PoolKey memory freshKey, PoolId freshId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        // Only owner should initialize the pool on Alphix
        vm.prank(owner);
        hook.initializePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Verify logic stored the configuration
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(freshId);
        assertEq(cfg.initialFee, INITIAL_FEE, "initial fee mismatch");
        assertEq(cfg.initialTargetRatio, INITIAL_TARGET_RATIO, "initial target ratio mismatch");
        assertEq(uint8(cfg.poolType), uint8(IAlphixLogic.PoolType.STANDARD), "pool type mismatch");
        assertTrue(cfg.isConfigured, "pool should be configured");
    }

    /**
     * @notice addLiquidity via positionManager succeeds on an active pool (hook routes into logic guards)
     */
    function test_user_add_liquidity_success_via_positionManager() public {
        // New configured pool (active)
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

        // Choose a full-range LP and compute required amounts
        int24 tl = TickMath.minUsableTick(kFresh.tickSpacing);
        int24 tu = TickMath.maxUsableTick(kFresh.tickSpacing);
        uint128 liquidityAmount = 50e18;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityAmount
        );

        // Note: BaseAlphixTest minted tokens to owner, user1, user2; this test uses user1's balance
        vm.startPrank(user1);

        // Approve Permit2 and downstream allowance to positionManager
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(permit2), amt1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        permit2.approve(Currency.unwrap(kFresh.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        // Mint a position (this triggers hook.before/afterAddLiquidity)
        (uint256 newTokenId,) = positionManager.mint(
            kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, user1, block.timestamp, Constants.ZERO_BYTES
        );
        assertTrue(newTokenId != 0, "position not minted");
        vm.stopPrank();

        // Verify pool active by calling a guarded path through the hook->logic
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(1e15)), salt: 0});
        vm.prank(address(hook));
        bytes4 sel = logic.beforeAddLiquidity(user1, kFresh, params, "");
        assertEq(sel, BaseHook.beforeAddLiquidity.selector, "selector mismatch");
    }

    /**
     * @notice addLiquidity reverts when pool deactivated via logic, observed through positionManager mint
     */
    function test_user_add_liquidity_reverts_when_pauseOrDeactivated() public {
        // New configured pool
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

        // Try minting liquidity, hook.beforeAddLiquidity should revert with PoolPaused
        int24 tl = TickMath.minUsableTick(kFresh.tickSpacing);
        int24 tu = TickMath.maxUsableTick(kFresh.tickSpacing);
        uint128 liquidityAmount = 1e18;
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityAmount
        );

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(permit2), amt1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        permit2.approve(Currency.unwrap(kFresh.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        // Pause logic proxy -> delegatecalls, toggles the paused state in proxy storage, and emits the event.
        AlphixLogic(address(logicProxy)).pause();

        // Expect revert on the exact next external call (because of PausableUpgradeable.EnforcedPause.selector)
        _expectRevertOnModifyLiquiditiesMint(kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, owner);

        vm.stopPrank();

        // Call the logic’s beforeAddLiquidity entrypoint and expect the EnforcedPause selector
        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        logic.beforeAddLiquidity(
            owner,
            kFresh,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(1e18)), salt: 0}),
            ""
        );

        // Unpause pool logic
        vm.startPrank(owner);
        AlphixLogic(address(logicProxy)).unpause();

        // Deactivate pool
        hook.deactivatePool(kFresh);

        // Expect revert on the exact next external call (because of IAlphixLogic.PoolPaused.selector)
        _expectRevertOnModifyLiquiditiesMint(kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, owner);
        vm.stopPrank();

        // Now call the logic’s beforeAddLiquidity entrypoint and expect the PoolPaused selector
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        logic.beforeAddLiquidity(
            owner,
            kFresh,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(1e18)), salt: 0}),
            ""
        );
    }

    /**
     * @notice removeLiquidity via positionManager succeeds on an active pool (after mint), and reverts when paused or deactivated
     */
    function test_user_remove_liquidity_success_and_reverts_when_pausedOrDeactivated() public {
        // Fresh configured pool and seed a position for this contract
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

        vm.startPrank(owner);

        // Seed the newly created pool with liquidity (full range == true)
        uint256 posId = seedLiquidity(kFresh, owner, true, UNIT, 10_000e18, 10_000e18);
        assertTrue(posId != 0, "failed to mint position");

        // Reduce some liquidity (active path)
        uint256 liqToRemove = 1e18;
        positionManager.decreaseLiquidity(
            posId, uint128(liqToRemove), 0, 0, owner, block.timestamp, Constants.ZERO_BYTES
        );

        // Pause logic at the proxy (all hook calls should revert)
        AlphixLogic(address(logicProxy)).pause();

        // Expect revert on the exact next external call (because of PausableUpgradeable.EnforcedPause.selector)
        _expectRevertOnModifyLiquiditiesDecrease(posId, liqToRemove, 0, 0, owner);
        vm.stopPrank();

        // Liquidity was seeded with full range so we can infer tick lower and upper:
        int24 tl = TickMath.minUsableTick(kFresh.tickSpacing);
        int24 tu = TickMath.maxUsableTick(kFresh.tickSpacing);
        // For the direct logic entrypoint, use selector-based expectRevert (no wrapper layering here)
        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        logic.beforeRemoveLiquidity(
            owner,
            kFresh,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(1e18)), salt: 0}),
            ""
        );

        vm.startPrank(owner);

        // Unpause logic at the proxy
        AlphixLogic(address(logicProxy)).unpause();

        // Deactivate pool
        hook.deactivatePool(kFresh);

        // Expect revert on the exact next external call (because of IAlphixLogic.PoolPaused.selector)
        _expectRevertOnModifyLiquiditiesDecrease(posId, liqToRemove, 0, 0, owner);

        vm.stopPrank();

        // For the direct logic entrypoint, use selector-based expectRevert (no wrapper layering here)
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        logic.beforeRemoveLiquidity(
            owner,
            kFresh,
            ModifyLiquidityParams({tickLower: tl, tickUpper: tu, liquidityDelta: int256(uint256(1e18)), salt: 0}),
            ""
        );
    }

    /**
     * @notice swap succeeds on an active pool and increments hook path; also reverts when deactivated or paused
     */
    function test_user_swaps_success_and_reverts_on_deactivate_or_pause() public {
        // Fresh configured pool
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

        vm.startPrank(owner);
        // Provide some liquidity so a swap can execute
        seedLiquidity(kFresh, owner, true, UNIT, 10_000e18, 10_000e18);

        // Prepare swap input approvals for this contract
        uint256 amountIn = 1e18;
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(swapRouter), amountIn);

        // Execute swap zeroForOne via swapRouter
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: kFresh,
            hookData: Constants.ZERO_BYTES,
            receiver: owner,
            deadline: block.timestamp + 1
        });

        // Validate spent token0 (negative delta for token0)
        assertEq(int256(swapDelta.amount0()), -int256(amountIn), "amount0 spent mismatch");
        assertTrue(int256(swapDelta.amount1()) > 0, "amount1 received mismatch");

        // Deactivate pool then expect swap to revert with PoolPaused
        hook.deactivatePool(kFresh);

        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(swapRouter), amountIn);

        // Expect revert on the exact next external call (because of IAlphixLogic.PoolPaused.selector)
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: kFresh,
            hookData: Constants.ZERO_BYTES,
            receiver: owner,
            deadline: block.timestamp + 1
        });

        vm.stopPrank();

        // For the direct logic entrypoint, use selector-based expectRevert (no wrapper layering here)
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        logic.beforeSwap(
            owner, kFresh, SwapParams({zeroForOne: true, amountSpecified: int256(amountIn), sqrtPriceLimitX96: 0}), ""
        );

        vm.startPrank(owner);
        // Re-activate, then pause the logic globally and expect enforced pause
        hook.activatePool(kFresh);

        AlphixLogic(address(logicProxy)).pause();

        // Expect revert on the exact next external call (because of PausableUpgradeable.EnforcedPause.selector)
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: kFresh,
            hookData: Constants.ZERO_BYTES,
            receiver: owner,
            deadline: block.timestamp + 1
        });

        vm.stopPrank();

        // For the direct logic entrypoint, use selector-based expectRevert (no wrapper layering here)
        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        logic.beforeSwap(
            owner, kFresh, SwapParams({zeroForOne: true, amountSpecified: int256(amountIn), sqrtPriceLimitX96: 0}), ""
        );
    }

    /**
     * @notice afterInitialize dynamic-fee requirement is enforced when called via hook
     */
    function test_afterInitialize_dynamic_fee_required() public {
        // Static-fee key on the same currencies
        PoolKey memory staticKey = PoolKey(currency0, currency1, 3000, defaultTickSpacing, IHooks(hook));
        vm.prank(address(hook));
        vm.expectRevert(BaseDynamicFee.NotDynamicFee.selector);
        logic.afterInitialize(user1, staticKey, Constants.SQRT_PRICE_1_1, 0);
    }
}
