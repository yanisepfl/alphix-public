// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";
import {AlphixLVR} from "../../../../src/AlphixLVR.sol";
import {BaseAlphixLVRTest} from "../../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_Swap
 * @notice Integration tests verifying dynamic fee is applied during actual swaps.
 */
contract AlphixLVR_Swap is BaseAlphixLVRTest {
    using PoolIdLibrary for *;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    int24 constant TICK_LOWER = -120;
    int24 constant TICK_UPPER = 120;
    uint128 constant LIQUIDITY = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        _initializePool();
        _seedLiquidity();
    }

    function _seedLiquidity() internal {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            LIQUIDITY
        );

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amount0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amount1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amount0 + 1), expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amount1 + 1), expiry);

        positionManager.mint(
            poolKey,
            TICK_LOWER,
            TICK_UPPER,
            LIQUIDITY,
            amount0 + 1,
            amount1 + 1,
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

    function test_swap_usesDefaultZeroFee() public {
        // No poke yet — default fee is 0
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(received > 0, "Swap should produce output with zero fee");
    }

    function test_swap_appliesPokedFee() public {
        // Snapshot state to ensure identical pool conditions for both swaps
        uint256 snapshotId = vm.snapshot();

        // Poke a high fee and swap
        vm.prank(feePoker);
        hook.poke(poolKey, 100_000); // 10%

        uint256 balBefore0 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 received0 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore0;

        // Revert to snapshot so pool state is identical for next swap
        vm.revertTo(snapshotId);

        // Poke a lower fee and swap against same pool state
        vm.prank(feePoker);
        hook.poke(poolKey, 100); // 0.01%

        uint256 balBefore1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 received1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore1;

        // Lower fee should give more output
        assertTrue(received1 > received0, "Lower fee should produce more output");
    }

    function test_swap_feeChangesMidSession() public {
        // Start with low fee
        vm.prank(feePoker);
        hook.poke(poolKey, 100);

        _performSwap(0.1e18, true);

        // Increase fee
        vm.prank(feePoker);
        hook.poke(poolKey, 50_000);

        // Swap still works with new fee
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(0.1e18, true);
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(received > 0, "Swap should work after fee change");
    }

    function test_swap_bothDirectionsWork() public {
        vm.prank(feePoker);
        hook.poke(poolKey, 3000);

        // zeroForOne
        _performSwap(0.5e18, true);

        // oneForZero
        _performSwap(0.5e18, false);
    }

    function test_swap_worksWithMaxFee() public {
        vm.prank(feePoker);
        hook.poke(poolKey, LPFeeLibrary.MAX_LP_FEE);

        // Swap should still execute (100% fee means 0 output, but no revert)
        _performSwap(0.1e18, true);
    }
}
