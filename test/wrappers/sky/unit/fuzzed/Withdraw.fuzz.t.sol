// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title WithdrawFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperSky withdraw function.
 */
contract WithdrawFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test for withdraw with varying amounts.
     * @param depositMultiplier The deposit amount multiplier.
     * @param withdrawPercent Percentage of max to withdraw (1-100).
     */
    function testFuzz_withdraw_varyingAmounts(uint256 depositMultiplier, uint256 withdrawPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            uint256 shares = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

            assertGt(shares, 0, "Should burn non-zero shares");
            _assertSolvent();
        }
    }

    /**
     * @notice Fuzz test that unauthorized callers always revert.
     * @param caller Random caller address.
     */
    function testFuzz_withdraw_unauthorizedCaller_reverts(address caller) public {
        vm.assume(caller != alphixHook && caller != owner && caller != address(0));

        _depositAsHook(1000e18, alphixHook);

        vm.prank(caller);
        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.withdraw(100e18, caller, caller);
    }

    /**
     * @notice Fuzz test that withdraw from different owner reverts.
     * @param otherOwner Random address to try withdrawing from.
     */
    function testFuzz_withdraw_fromOther_reverts(address otherOwner) public {
        vm.assume(otherOwner != alphixHook && otherOwner != address(0));

        _depositAsHook(1000e18, alphixHook);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.CallerNotOwner.selector);
        wrapper.withdraw(100e18, alphixHook, otherOwner);
    }

    /**
     * @notice Fuzz test that withdraw maintains solvency.
     * @param depositMultiplier The deposit amount multiplier.
     * @param withdrawPercent Percentage of max to withdraw.
     */
    function testFuzz_withdraw_maintainsSolvency(uint256 depositMultiplier, uint256 withdrawPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

            _assertSolvent();
        }
    }

    /**
     * @notice Fuzz test that previewWithdraw matches actual withdraw.
     * @param depositMultiplier The deposit amount multiplier.
     * @param withdrawPercent Percentage of max to withdraw.
     */
    function testFuzz_withdraw_matchesPreview(uint256 depositMultiplier, uint256 withdrawPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            uint256 previewedShares = wrapper.previewWithdraw(withdrawAmount);

            vm.prank(alphixHook);
            uint256 actualShares = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

            assertEq(actualShares, previewedShares, "Actual shares should match preview");
        }
    }

    /**
     * @notice Fuzz test withdraw to any receiver.
     * @param depositMultiplier The deposit amount multiplier.
     * @param receiver Random receiver address.
     */
    function testFuzz_withdraw_toAnyReceiver(uint256 depositMultiplier, address receiver) public {
        vm.assume(receiver != address(0) && receiver != address(wrapper) && receiver != address(psm));
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 withdrawAmount = wrapper.maxWithdraw(alphixHook) / 2;
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, receiver, alphixHook);

        assertApproxEqAbs(
            usds.balanceOf(receiver), receiverBalanceBefore + withdrawAmount, 1, "Receiver should get assets"
        );
    }

    /**
     * @notice Fuzz test withdraw after yield.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent Yield percentage (1-100).
     * @param withdrawPercent Percentage of max to withdraw.
     */
    function testFuzz_withdraw_afterYield(uint256 depositMultiplier, uint256 yieldPercent, uint256 withdrawPercent)
        public
    {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        withdrawPercent = bound(withdrawPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

            _assertSolvent();
        }
    }

    /**
     * @notice Fuzz test multiple sequential withdraws.
     * @param depositMultiplier The deposit amount multiplier.
     * @param withdrawPercents Array of withdraw percentages.
     */
    function testFuzz_withdraw_multipleWithdraws(uint256 depositMultiplier, uint8[3] memory withdrawPercents) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        for (uint256 i = 0; i < withdrawPercents.length; i++) {
            uint256 percent = bound(withdrawPercents[i], 1, 30); // Max 30% each
            uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
            uint256 withdrawAmount = maxWithdraw * percent / 100;

            if (withdrawAmount > 0) {
                vm.prank(alphixHook);
                wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
            }
        }

        _assertSolvent();
    }
}
