// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title WithdrawFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for withdrawal flow scenarios.
 */
contract WithdrawFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test deposit then partial withdraw flow.
     * @param depositAmount The deposit amount.
     * @param withdrawPercent The percentage to withdraw (1-99).
     */
    function testFuzz_flow_depositThenPartialWithdraw(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 99);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);

        // Withdraw
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, sharesBurned, "Shares burned mismatch");
        assertEq(asset.balanceOf(alphixHook), withdrawAmount, "Assets received mismatch");
        assertGt(sharesAfter, 0, "Should have remaining shares after partial withdraw");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit, yield, then withdraw flow.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     * @param withdrawPercent The percentage of max to withdraw.
     */
    function testFuzz_flow_depositYieldWithdraw(uint256 depositAmount, uint256 yieldPercent, uint256 withdrawPercent)
        public
    {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        yieldPercent = bound(yieldPercent, 1, 100);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Calculate withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        // Withdraw
        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), withdrawAmount, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple deposits then single withdraw.
     * @param deposit1 First deposit amount.
     * @param deposit2 Second deposit amount.
     * @param deposit3 Third deposit amount.
     */
    function testFuzz_flow_multipleDepositsSingleWithdraw(uint256 deposit1, uint256 deposit2, uint256 deposit3) public {
        deposit1 = bound(deposit1, 1e6, 100_000e6);
        deposit2 = bound(deposit2, 1e6, 100_000e6);
        deposit3 = bound(deposit3, 1e6, 100_000e6);

        // Multiple deposits
        _depositAsHook(deposit1, alphixHook);
        _depositAsHook(deposit2, alphixHook);
        _depositAsHook(deposit3, alphixHook);

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
     * @notice Fuzz test single deposit then multiple withdrawals.
     * @param depositAmount The deposit amount.
     * @param numWithdrawals Number of withdrawals (1-5).
     */
    function testFuzz_flow_singleDepositMultipleWithdraws(uint256 depositAmount, uint8 numWithdrawals) public {
        depositAmount = bound(depositAmount, 10e6, 1_000_000e6);
        numWithdrawals = uint8(bound(numWithdrawals, 1, 5));

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalWithdrawn;

        // Multiple withdrawals
        vm.startPrank(alphixHook);
        for (uint8 i = 0; i < numWithdrawals; i++) {
            uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
            if (maxWithdraw == 0) break;

            uint256 withdrawAmount = maxWithdraw / (numWithdrawals - i);
            if (withdrawAmount == 0) withdrawAmount = 1;
            if (withdrawAmount > maxWithdraw) withdrawAmount = maxWithdraw;

            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
            totalWithdrawn += withdrawAmount;
        }
        vm.stopPrank();

        assertEq(asset.balanceOf(alphixHook), totalWithdrawn, "Total withdrawn mismatch");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test interleaved deposits and withdrawals.
     * @param amounts Array of amounts for operations.
     */
    function testFuzz_flow_interleavedOperations(uint256[6] memory amounts) public {
        // Bound all amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1e6, 100_000e6);
        }

        // Deposit
        _depositAsHook(amounts[0], alphixHook);

        // Withdraw some (up to max)
        uint256 max1 = wrapper.maxWithdraw(alphixHook);
        uint256 withdraw1 = amounts[1] > max1 ? max1 / 2 : amounts[1] / 2;
        if (withdraw1 > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdraw1, alphixHook, alphixHook);
        }

        // Deposit more
        _depositAsHook(amounts[2], alphixHook);

        // Simulate yield
        _simulateYieldPercent(5);

        // Withdraw some
        uint256 max2 = wrapper.maxWithdraw(alphixHook);
        uint256 withdraw2 = amounts[3] > max2 ? max2 / 2 : amounts[3] / 2;
        if (withdraw2 > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdraw2, alphixHook, alphixHook);
        }

        // Deposit more
        _depositAsHook(amounts[4], alphixHook);

        // Final withdraw
        uint256 max3 = wrapper.maxWithdraw(alphixHook);
        uint256 withdraw3 = amounts[5] > max3 ? max3 / 2 : amounts[5] / 2;
        if (withdraw3 > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdraw3, alphixHook, alphixHook);
        }

        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have shares");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test withdraw after negative yield.
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage (1-50).
     */
    function testFuzz_flow_withdrawAfterSlash(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 10e6, 1_000_000e6);
        slashPercent = bound(slashPercent, 1, 50);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // Withdraw max
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        if (maxWithdraw > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

            assertEq(asset.balanceOf(alphixHook), maxWithdraw, "Should receive max assets");
        }
        _assertSolvent();
    }

    /**
     * @notice Fuzz test multi-user withdraw flow.
     * @param hook1Deposit Hook1's deposit amount.
     * @param hook2Deposit Hook2's deposit amount.
     * @param withdrawPercent Percentage each withdraws.
     */
    function testFuzz_flow_multiUserWithdraw(uint256 hook1Deposit, uint256 hook2Deposit, uint256 withdrawPercent)
        public
    {
        hook1Deposit = bound(hook1Deposit, 1e6, 100_000e6);
        hook2Deposit = bound(hook2Deposit, 1e6, 100_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Both deposit
        _depositAsHook(hook1Deposit, alphixHook);

        asset.mint(hook2, hook2Deposit);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), hook2Deposit);
        wrapper.deposit(hook2Deposit, hook2);
        vm.stopPrank();

        // Simulate yield
        _simulateYieldPercent(10);

        // Both withdraw
        uint256 hook1Max = wrapper.maxWithdraw(alphixHook);
        uint256 hook1Withdraw = hook1Max * withdrawPercent / 100;
        if (hook1Withdraw > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(hook1Withdraw, alphixHook, alphixHook);
        }

        uint256 hook2Max = wrapper.maxWithdraw(hook2);
        uint256 hook2Withdraw = hook2Max * withdrawPercent / 100;
        if (hook2Withdraw > 0) {
            vm.prank(hook2);
            wrapper.withdraw(hook2Withdraw, hook2, hook2);
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test withdraw with various decimals.
     * @param decimals Token decimals.
     * @param depositMultiplier Deposit amount in tokens.
     * @param withdrawPercent Percentage to withdraw.
     */
    function testFuzz_flow_withdrawVariousDecimals(uint8 decimals, uint256 depositMultiplier, uint256 withdrawPercent)
        public
    {
        decimals = uint8(bound(decimals, 6, 18));
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Deposit
        _depositAsHookOnDeployment(d, depositAmount);

        // Calculate withdraw
        uint256 maxWithdraw = d.wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) return;

        // Withdraw
        vm.prank(alphixHook);
        d.wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertEq(d.asset.balanceOf(alphixHook), withdrawAmount, "Should receive assets");
    }
}
