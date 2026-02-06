// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title RedeemFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperSky redeem function.
 */
contract RedeemFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test for redeem with varying amounts.
     * @param depositMultiplier The deposit amount multiplier.
     * @param redeemPercent Percentage of shares to redeem (1-100).
     */
    function testFuzz_redeem_varyingAmounts(uint256 depositMultiplier, uint256 redeemPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        redeemPercent = bound(redeemPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;

        if (redeemShares > 0) {
            vm.prank(alphixHook);
            uint256 assets = wrapper.redeem(redeemShares, alphixHook, alphixHook);

            assertGt(assets, 0, "Should receive non-zero assets");
            _assertSolvent();
        }
    }

    /**
     * @notice Fuzz test that unauthorized callers always revert.
     * @param caller Random caller address.
     */
    function testFuzz_redeem_unauthorizedCaller_reverts(address caller) public {
        vm.assume(caller != alphixHook && caller != owner && caller != address(0));

        _depositAsHook(1000e18, alphixHook);

        vm.prank(caller);
        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.redeem(100e18, caller, caller);
    }

    /**
     * @notice Fuzz test that redeem from different owner reverts.
     * @param otherOwner Random address to try redeeming from.
     */
    function testFuzz_redeem_fromOther_reverts(address otherOwner) public {
        vm.assume(otherOwner != alphixHook && otherOwner != address(0));

        _depositAsHook(1000e18, alphixHook);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.CallerNotOwner.selector);
        wrapper.redeem(100e18, alphixHook, otherOwner);
    }

    /**
     * @notice Fuzz test that redeem maintains solvency.
     * @param depositMultiplier The deposit amount multiplier.
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_redeem_maintainsSolvency(uint256 depositMultiplier, uint256 redeemPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        redeemPercent = bound(redeemPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;

        if (redeemShares > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(redeemShares, alphixHook, alphixHook);

            _assertSolvent();
        }
    }

    /**
     * @notice Fuzz test that previewRedeem matches actual redeem.
     * @param depositMultiplier The deposit amount multiplier.
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_redeem_matchesPreview(uint256 depositMultiplier, uint256 redeemPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        redeemPercent = bound(redeemPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;

        if (redeemShares > 0) {
            uint256 previewedAssets = wrapper.previewRedeem(redeemShares);

            vm.prank(alphixHook);
            uint256 actualAssets = wrapper.redeem(redeemShares, alphixHook, alphixHook);

            assertEq(actualAssets, previewedAssets, "Actual assets should match preview");
        }
    }

    /**
     * @notice Fuzz test redeem to any receiver.
     * @param depositMultiplier The deposit amount multiplier.
     * @param receiver Random receiver address.
     */
    function testFuzz_redeem_toAnyReceiver(uint256 depositMultiplier, address receiver) public {
        vm.assume(receiver != address(0) && receiver != address(wrapper) && receiver != address(psm));
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 redeemShares = wrapper.maxRedeem(alphixHook) / 2;
        uint256 previewedAssets = wrapper.previewRedeem(redeemShares);
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        vm.prank(alphixHook);
        wrapper.redeem(redeemShares, receiver, alphixHook);

        assertApproxEqAbs(
            usds.balanceOf(receiver), receiverBalanceBefore + previewedAssets, 1, "Receiver should get assets"
        );
    }

    /**
     * @notice Fuzz test redeem after yield.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent Yield percentage (1%, limited by circuit breaker).
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_redeem_afterYield(uint256 depositMultiplier, uint256 yieldPercent, uint256 redeemPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        redeemPercent = bound(redeemPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;

        if (redeemShares > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(redeemShares, alphixHook, alphixHook);

            _assertSolvent();
        }
    }

    /**
     * @notice Fuzz test full redeem.
     * @param depositMultiplier The deposit amount multiplier.
     */
    function testFuzz_redeem_fullRedeem(uint256 depositMultiplier) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        vm.prank(alphixHook);
        wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertEq(wrapper.balanceOf(alphixHook), 0, "All shares should be redeemed");
        _assertSolvent();
    }
}
