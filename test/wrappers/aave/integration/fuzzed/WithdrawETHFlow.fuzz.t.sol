// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";

/**
 * @title WithdrawETHFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for ETH withdraw flows.
 */
contract WithdrawETHFlowFuzzTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Fuzz test: deposit-yield-withdraw flow.
     * @param depositAmount Deposit amount.
     * @param yieldPercent Yield percentage.
     * @param withdrawPercent Percentage to withdraw.
     */
    function testFuzz_withdrawETHFlow_depositYieldWithdraw(
        uint256 depositAmount,
        uint256 yieldPercent,
        uint256 withdrawPercent
    ) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        yieldPercent = bound(yieldPercent, 0, 50);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit
        _depositETHAsHook(depositAmount);

        // Simulate yield
        if (yieldPercent > 0) {
            _simulateYieldPercent(yieldPercent);
        }

        // Withdraw
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBefore + withdrawAmount, "Should receive correct ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: deposit-slash-withdraw flow.
     * @param depositAmount Deposit amount.
     * @param slashPercent Slash percentage.
     * @param withdrawPercent Percentage to withdraw.
     */
    function testFuzz_withdrawETHFlow_depositSlashWithdraw(
        uint256 depositAmount,
        uint256 slashPercent,
        uint256 withdrawPercent
    ) public {
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        slashPercent = bound(slashPercent, 1, 50);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit
        _depositETHAsHook(depositAmount);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wethWrapper), slashAmount);

        // Withdraw
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) return;

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBefore + withdrawAmount, "Should receive correct ETH");

        // Max withdraw should be less than original deposit
        assertLt(maxWithdraw, depositAmount, "Max withdraw should be less after slash");
    }

    /**
     * @notice Fuzz test: multiple deposits then partial withdraw.
     * @param deposits Array of deposit amounts.
     * @param withdrawPercent Percentage to withdraw.
     */
    function testFuzz_withdrawETHFlow_multipleDepositsThenWithdraw(uint256[3] memory deposits, uint256 withdrawPercent)
        public
    {
        withdrawPercent = bound(withdrawPercent, 1, 100);

        uint256 totalDeposited;

        // Multiple deposits
        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] = bound(deposits[i], 0.1 ether, 10 ether);
            vm.deal(alphixHook, deposits[i]);
            vm.prank(alphixHook);
            wethWrapper.depositETH{value: deposits[i]}(alphixHook);
            totalDeposited += deposits[i];
        }

        // Withdraw percentage
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBefore + withdrawAmount, "Should receive correct ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: withdraw to random receiver.
     * @param depositAmount Deposit amount.
     * @param receiver Receiver address.
     * @param withdrawPercent Percentage to withdraw.
     */
    function testFuzz_withdrawETHFlow_toRandomReceiver(uint256 depositAmount, address receiver, uint256 withdrawPercent)
        public
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wethWrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(weth));
        // Ensure receiver can accept ETH (exclude contracts and precompiles 0x01-0x09)
        vm.assume(receiver.code.length == 0);
        vm.assume(uint160(receiver) > 10);
        // Exclude Foundry's console.log precompile which cannot receive ETH
        vm.assume(receiver != 0x000000000000000000636F6e736F6c652e6c6f67);

        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit
        _depositETHAsHook(depositAmount);

        // Withdraw to receiver
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 receiverBefore = receiver.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, receiver, alphixHook);

        assertEq(receiver.balance, receiverBefore + withdrawAmount, "Receiver should get ETH");
    }

    /**
     * @notice Fuzz test: interleaved deposits and withdrawals.
     * @param operations Array of operation amounts (positive = deposit, use mod for withdraw decision).
     */
    function testFuzz_withdrawETHFlow_interleavedOperations(uint256[6] memory operations) public {
        // Initial deposit to have something to work with
        _depositETHAsHook(10 ether);

        for (uint256 i = 0; i < operations.length; i++) {
            bool isDeposit = (operations[i] % 2) == 0;
            uint256 amount = bound(operations[i], 0.01 ether, 5 ether);

            if (isDeposit) {
                vm.deal(alphixHook, amount);
                vm.prank(alphixHook);
                wethWrapper.depositETH{value: amount}(alphixHook);
            } else {
                uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
                if (maxWithdraw == 0) continue;

                uint256 withdrawAmount = amount > maxWithdraw ? maxWithdraw : amount;
                vm.prank(alphixHook);
                wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);
            }
        }

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }
}
