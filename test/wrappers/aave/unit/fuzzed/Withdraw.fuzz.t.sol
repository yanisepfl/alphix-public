// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title WithdrawFuzzTest
 * @author Alphix
 * @notice Fuzz tests for withdraw functionality in Alphix4626WrapperAave.
 */
contract WithdrawFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test: withdraw valid amounts.
     * @param depositAmount The deposit amount to fuzz.
     * @param withdrawPercent The percentage to withdraw (0-100).
     */
    function testFuzz_withdraw_validAmounts(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Calculate withdraw amount
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        // Withdraw
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertGt(sharesBurned, 0, "Should burn shares");
        assertEq(asset.balanceOf(alphixHook), withdrawAmount, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: withdraw after yield.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_withdraw_afterYield(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Withdraw half of max
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw / 2;
        if (withdrawAmount == 0) return;

        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), withdrawAmount, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: maxWithdraw returns valid amounts.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_maxWithdraw_valid(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        // maxWithdraw should be <= deposited (before yield)
        assertLe(maxWithdraw, depositAmount, "Max withdraw should not exceed deposit");
        assertGt(maxWithdraw, 0, "Max withdraw should be positive");
    }

    /**
     * @notice Fuzz test: withdraw exactly maxWithdraw.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_withdraw_exactMax(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        // Withdraw exactly max
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), maxWithdraw, "Should receive max assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: withdraw exceeds max reverts.
     * @param depositAmount The deposit amount.
     * @param excess The excess amount above max.
     */
    function testFuzz_withdraw_exceedsMax_reverts(uint256 depositAmount, uint256 excess) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        excess = bound(excess, 1, 1_000_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw + excess;

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.WithdrawExceedsMax.selector);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
    }

    /**
     * @notice Fuzz test: multiple withdrawals maintain solvency.
     * @param numWithdrawals Number of withdrawals.
     */
    function testFuzz_withdraw_multipleMaintainSolvency(uint8 numWithdrawals) public {
        numWithdrawals = uint8(bound(numWithdrawals, 1, 10));

        // Deposit a large amount
        _depositAsHook(1_000e6, alphixHook);

        vm.startPrank(alphixHook);
        for (uint8 i = 0; i < numWithdrawals; i++) {
            uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
            if (maxWithdraw == 0) break;

            uint256 withdrawAmount = maxWithdraw / (numWithdrawals - i);
            if (withdrawAmount == 0) withdrawAmount = 1;
            if (withdrawAmount > maxWithdraw) withdrawAmount = maxWithdraw;

            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }
        vm.stopPrank();

        _assertSolvent();
    }

    /**
     * @notice Fuzz test: shares burned is correct.
     * @param depositAmount The deposit amount.
     * @param withdrawAmount The withdraw amount.
     */
    function testFuzz_withdraw_sharesBurnedCorrect(uint256 depositAmount, uint256 withdrawAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        withdrawAmount = bound(withdrawAmount, 1, maxWithdraw);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 previewShares = wrapper.previewWithdraw(withdrawAmount);

        vm.prank(alphixHook);
        uint256 actualShares = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, actualShares, "Shares balance delta should match returned");
        // previewWithdraw should match actual (or be slightly more due to rounding)
        assertGe(previewShares, actualShares - 1, "Preview should match or exceed actual");
        assertLe(previewShares, actualShares + 1, "Preview should be close to actual");
    }

    /**
     * @notice Fuzz test: withdraw with various decimal tokens.
     * @param decimals Token decimals.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_withdraw_variousDecimals(uint8 decimals, uint256 depositAmount) public {
        decimals = uint8(bound(decimals, 6, 18));

        WrapperDeployment memory deployment = _createWrapperWithDecimals(decimals);

        // Scale deposit amount to decimals
        depositAmount = bound(depositAmount, 10 ** decimals, 1_000_000 * 10 ** decimals);

        // Deposit
        uint256 shares = _depositAsHookOnDeployment(deployment, depositAmount);

        // Withdraw half
        uint256 maxWithdraw = deployment.wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw / 2;
        if (withdrawAmount == 0) return;

        vm.prank(alphixHook);
        uint256 sharesBurned = deployment.wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertGt(sharesBurned, 0, "Should burn shares");
        assertLt(sharesBurned, shares, "Should not burn all shares");
    }

    /**
     * @notice Fuzz test: withdraw after negative yield.
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_withdraw_afterNegativeYield(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        slashPercent = bound(slashPercent, 1, 50); // Max 50% slash

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // maxWithdraw should be reduced
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        assertLt(maxWithdraw, depositAmount, "Max withdraw should be less after slash");

        // Withdraw should still work
        if (maxWithdraw > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

            assertEq(asset.balanceOf(alphixHook), maxWithdraw, "Should receive assets");
        }
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: unauthorized address maxWithdraw returns 0.
     * @param unauthorizedAddr Random unauthorized address.
     */
    function testFuzz_maxWithdraw_unauthorizedReturnsZero(address unauthorizedAddr) public view {
        vm.assume(unauthorizedAddr != alphixHook);
        vm.assume(unauthorizedAddr != owner);
        vm.assume(unauthorizedAddr != address(0));

        assertEq(wrapper.maxWithdraw(unauthorizedAddr), 0, "Unauthorized should have 0 maxWithdraw");
    }

    /**
     * @notice Fuzz test: withdraw to any receiver address.
     * @param depositAmount The deposit amount.
     * @param receiver The receiver address.
     * @param withdrawPercent The percentage to withdraw.
     */
    function testFuzz_withdraw_toAnyReceiver(uint256 depositAmount, address receiver, uint256 withdrawPercent) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(aavePool));
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Calculate withdraw amount
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 receiverBalanceBefore = asset.balanceOf(receiver);

        // Withdraw to any receiver
        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, receiver, alphixHook);

        uint256 receiverBalanceAfter = asset.balanceOf(receiver);
        assertEq(receiverBalanceAfter - receiverBalanceBefore, withdrawAmount, "Receiver should get assets");
        _assertSolvent();
    }
}
