// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "../../utils/libraries/EasyPosm.sol";
import {AlphixLVR} from "../../../src/AlphixLVR.sol";
import {BaseAlphixLVRTest} from "../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_FullCycle
 * @notice End-to-end lifecycle test: deploy, init, add liquidity, poke fees, swap, verify.
 */
contract AlphixLVR_FullCycle is BaseAlphixLVRTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    uint128 constant LIQUIDITY = 10_000_000e18;

    function test_fullCycle_deployInitPokeSwap() public {
        // 1. Initialize pool
        _initializePool();

        // 2. Verify initial fee is 0
        (,,, uint24 initialFee) = poolManager.getSlot0(poolKey.toId());
        assertEq(initialFee, 0, "Initial fee should be 0");

        // 3. Add liquidity
        _seedLiquidity();

        // 4. Poke fee to 500 (0.05%)
        vm.prank(feePoker);
        hook.poke(poolKey, 500);

        (,,, uint24 fee1) = poolManager.getSlot0(poolKey.toId());
        assertEq(fee1, 500, "Fee should be 500 after poke");

        // 5. Swap zeroForOne
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 receivedLowFee = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(receivedLowFee > 0, "Should receive output");

        // 6. Increase fee to 50000 (5%)
        vm.prank(feePoker);
        hook.poke(poolKey, 50_000);

        (,,, uint24 fee2) = poolManager.getSlot0(poolKey.toId());
        assertEq(fee2, 50_000, "Fee should be 50000 after second poke");

        // 7. Swap again — should receive less due to higher fee
        balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 receivedHighFee = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(receivedHighFee > 0, "Should still receive output");
        assertTrue(receivedHighFee < receivedLowFee, "Higher fee should give less output");

        // 8. Reduce fee back to low
        vm.prank(feePoker);
        hook.poke(poolKey, 100);

        (,,, uint24 fee3) = poolManager.getSlot0(poolKey.toId());
        assertEq(fee3, 100, "Fee should be 100 after third poke");
    }

    function test_fullCycle_pauseAndResume() public {
        _initializePool();
        _seedLiquidity();

        // Poke works
        vm.prank(feePoker);
        hook.poke(poolKey, 1000);

        // Pause
        vm.prank(admin);
        hook.pause();

        // Poke fails while paused
        vm.prank(feePoker);
        vm.expectRevert();
        hook.poke(poolKey, 2000);

        // But swaps still work (hook has no beforeSwap/afterSwap)
        _performSwap(0.1e18, true);

        // Unpause
        vm.prank(admin);
        hook.unpause();

        // Poke works again
        vm.prank(feePoker);
        hook.poke(poolKey, 3000);
        assertEq(hook.getFee(poolKey.toId()), 3000);
    }

    function test_fullCycle_multiPoolLifecycle() public {
        // Pool 1
        _initializePool();
        _seedLiquidity();

        // Pool 2 with different tokens
        (Currency c2, Currency c3) = deployCurrencyPair();
        PoolKey memory key2 = PoolKey({
            currency0: c2,
            currency1: c3,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });
        poolManager.initialize(key2, TickMath.getSqrtPriceAtTick(0));

        // Seed pool 2
        _seedLiquidityForPool(key2, c2, c3);

        // Poke different fees
        vm.startPrank(feePoker);
        hook.poke(poolKey, 200);
        hook.poke(key2, 8000);
        vm.stopPrank();

        assertEq(hook.getFee(poolKey.toId()), 200);
        assertEq(hook.getFee(key2.toId()), 8000);

        // Swap on both
        _performSwap(0.5e18, true);
        _performSwapOnPool(key2, c2, 0.5e18, true);
    }

    /* ---- HELPERS ---- */

    function _seedLiquidity() internal {
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            LIQUIDITY
        );
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), a0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), a1 + 1);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(a0 + 1), uint48(block.timestamp + 100));
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(a1 + 1), uint48(block.timestamp + 100));
        positionManager.mint(poolKey, TICK_LOWER, TICK_UPPER, LIQUIDITY, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES);
    }

    function _seedLiquidityForPool(PoolKey memory key, Currency c0, Currency c1) internal {
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(-100),
            TickMath.getSqrtPriceAtTick(100),
            1_000_000e18
        );
        MockERC20(Currency.unwrap(c0)).approve(address(permit2), a0 + 1);
        MockERC20(Currency.unwrap(c1)).approve(address(permit2), a1 + 1);
        permit2.approve(Currency.unwrap(c0), address(positionManager), uint160(a0 + 1), uint48(block.timestamp + 100));
        permit2.approve(Currency.unwrap(c1), address(positionManager), uint160(a1 + 1), uint48(block.timestamp + 100));
        positionManager.mint(key, -100, 100, 1_000_000e18, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES);
    }

    function _performSwap(uint256 amount, bool zeroForOne) internal {
        Currency inputCurrency = zeroForOne ? currency0 : currency1;
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amount);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 100
        });
    }

    function _performSwapOnPool(PoolKey memory key, Currency inputCurrency, uint256 amount, bool zeroForOne) internal {
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amount);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 100
        });
    }
}
