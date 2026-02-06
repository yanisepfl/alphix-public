// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title RedeemFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for redeem flow integration scenarios.
 */
contract RedeemFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test redeem varying percentages of shares.
     */
    function testFuzz_redeemFlow_varyingAmounts(uint256 depositMultiplier, uint256 redeemPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        redeemPercent = bound(redeemPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemAmount = maxRedeem * redeemPercent / 100;

        if (redeemAmount > 0) {
            uint256 sharesBefore = wrapper.balanceOf(alphixHook);

            vm.prank(alphixHook);
            wrapper.redeem(redeemAmount, alphixHook, alphixHook);

            assertEq(wrapper.balanceOf(alphixHook), sharesBefore - redeemAmount, "Shares should decrease");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem after yield.
     */
    function testFuzz_redeemFlow_afterYield(uint256 depositMultiplier, uint256 yieldPercent, uint256 redeemPercent)
        public
    {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        redeemPercent = bound(redeemPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemAmount = maxRedeem * redeemPercent / 100;

        if (redeemAmount > 0) {
            vm.prank(alphixHook);
            uint256 assetsReceived = wrapper.redeem(redeemAmount, alphixHook, alphixHook);

            assertGt(assetsReceived, 0, "Should receive assets");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple redeems.
     */
    function testFuzz_redeemFlow_multiple(uint256 depositMultiplier, uint8[3] memory redeemPercents) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        for (uint256 i = 0; i < redeemPercents.length; i++) {
            uint256 percent = bound(redeemPercents[i], 1, 30); // Max 30% each
            uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
            uint256 redeemAmount = maxRedeem * percent / 100;

            if (redeemAmount > 0) {
                vm.prank(alphixHook);
                wrapper.redeem(redeemAmount, alphixHook, alphixHook);
            }
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem after negative yield.
     */
    function testFuzz_redeemFlow_afterNegativeYield(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 redeemPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        redeemPercent = bound(redeemPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Negative yield
        _simulateSlashPercent(slashPercent);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemAmount = maxRedeem * redeemPercent / 100;

        if (redeemAmount > 0) {
            vm.prank(alphixHook);
            uint256 assetsReceived = wrapper.redeem(redeemAmount, alphixHook, alphixHook);

            // After slash, should receive less assets per share
            assertLt(assetsReceived, depositAmount * redeemPercent / 100, "Should receive less after slash");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem to different receiver.
     */
    function testFuzz_redeemFlow_toDifferentReceiver(uint256 depositMultiplier, address receiver) public {
        vm.assume(receiver != address(0) && receiver != address(wrapper) && receiver != address(psm));
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemAmount = maxRedeem / 2;

        if (redeemAmount > 0) {
            uint256 receiverBefore = usds.balanceOf(receiver);

            vm.prank(alphixHook);
            uint256 assetsReceived = wrapper.redeem(redeemAmount, receiver, alphixHook);

            assertApproxEqAbs(
                usds.balanceOf(receiver), receiverBefore + assetsReceived, 1, "Receiver should get assets"
            );
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem matches preview.
     */
    function testFuzz_redeemFlow_matchesPreview(uint256 depositMultiplier, uint256 redeemPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        redeemPercent = bound(redeemPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemAmount = maxRedeem * redeemPercent / 100;

        if (redeemAmount > 0) {
            uint256 previewedAssets = wrapper.previewRedeem(redeemAmount);

            vm.prank(alphixHook);
            uint256 actualAssets = wrapper.redeem(redeemAmount, alphixHook, alphixHook);

            assertEq(actualAssets, previewedAssets, "Actual should match preview");
        }

        _assertSolvent();
    }
}
