// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "../../utils/libraries/EasyPosm.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AlphixLVRFee} from "../../../src/AlphixLVRFee.sol";
import {BaseAlphixLVRFeeTest} from "../BaseAlphixLVRFee.t.sol";

/**
 * @title AlphixLVRFee_FullCycle
 * @notice End-to-end lifecycle: deploy, init, poke, set hook fee, swap, collect.
 */
contract AlphixLVRFee_FullCycle is BaseAlphixLVRFeeTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    int24 constant TICK_LOWER = -600;
    int24 constant TICK_UPPER = 600;
    uint128 constant LIQUIDITY = 10_000_000e18;

    function test_fullCycle_deployInitPokeSwapCollect() public {
        // 1. Initialize pool
        _initializePool();

        // 2. Verify initial LP fee is 0
        (,,, uint24 initialFee) = poolManager.getSlot0(poolKey.toId());
        assertEq(initialFee, 0, "Initial LP fee should be 0");

        // 3. Add liquidity
        _seedLiquidity();

        // 4. Poke LP fee
        vm.prank(feePoker);
        hook.poke(poolKey, 3000); // 0.3%

        (,,, uint24 fee) = poolManager.getSlot0(poolKey.toId());
        assertEq(fee, 3000, "LP fee should be 3000");

        // 5. Set hook fee
        hook.setHookFee(poolKey, 50_000); // 5%
        assertEq(hook.getHookFee(poolKey.toId()), 50_000);

        // 6. Swap
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(received > 0, "Should receive output");

        // 7. Verify hook has claims
        uint256 hookClaims = poolManager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookClaims > 0, "Hook should have accumulated claims");

        // 8. Verify treasury is set
        assertEq(hook.treasury(), treasury);
    }

    function test_fullCycle_pauseAndResume() public {
        _initializePool();
        _seedLiquidity();

        // Poke and set hook fee
        vm.prank(feePoker);
        hook.poke(poolKey, 1000);
        hook.setHookFee(poolKey, 10_000);

        // Pause
        vm.prank(admin);
        hook.pause();

        // Poke fails while paused
        vm.prank(feePoker);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.poke(poolKey, 2000);

        // setHookFee also fails while paused
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.setHookFee(poolKey, 20_000);

        // But swaps still work (hook has afterSwap but no blocking logic)
        _performSwap(0.1e18, true);

        // Unpause
        vm.prank(admin);
        hook.unpause();

        // Both work again
        vm.prank(feePoker);
        hook.poke(poolKey, 3000);
        hook.setHookFee(poolKey, 30_000);

        assertEq(hook.getFee(poolKey.toId()), 3000);
        assertEq(hook.getHookFee(poolKey.toId()), 30_000);
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
        permit2.approve(
            Currency.unwrap(currency0), address(positionManager), uint160(a0 + 1), uint48(block.timestamp + 100)
        );
        permit2.approve(
            Currency.unwrap(currency1), address(positionManager), uint160(a1 + 1), uint48(block.timestamp + 100)
        );
        positionManager.mint(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            LIQUIDITY,
            a0 + 1,
            a1 + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
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
}
