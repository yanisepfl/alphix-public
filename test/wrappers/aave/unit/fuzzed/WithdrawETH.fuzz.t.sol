// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title WithdrawETHFuzzTest
 * @author Alphix
 * @notice Fuzz tests for withdrawETH functionality in Alphix4626WrapperWethAave.
 */
contract WithdrawETHFuzzTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Fuzz test: withdrawETH valid amounts.
     * @param depositAmount The deposit amount to fuzz.
     * @param withdrawPercent The percentage to withdraw (1-100).
     */
    function testFuzz_withdrawETH_validAmounts(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deal ETH and deposit
        vm.deal(alphixHook, depositAmount);
        _depositETHAsHook(depositAmount);

        // Calculate withdraw amount
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 ethBalanceBefore = alphixHook.balance;

        // Withdraw ETH
        vm.prank(alphixHook);
        uint256 sharesBurned = wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        assertGt(sharesBurned, 0, "Should burn shares");
        assertEq(alphixHook.balance, ethBalanceBefore + withdrawAmount, "Should receive ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: withdrawETH after yield.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_withdrawETH_afterYield(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Withdraw half of max
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw / 2;
        if (withdrawAmount == 0) return;

        uint256 ethBalanceBefore = alphixHook.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBalanceBefore + withdrawAmount, "Should receive ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: maxWithdraw returns valid amounts.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_maxWithdraw_valid(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);

        // Deal ETH and deposit
        vm.deal(alphixHook, depositAmount);
        _depositETHAsHook(depositAmount);

        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);

        // maxWithdraw should be <= deposited (before yield)
        assertLe(maxWithdraw, depositAmount, "Max withdraw should not exceed deposit");
        assertGt(maxWithdraw, 0, "Max withdraw should be positive");
    }

    /**
     * @notice Fuzz test: withdrawETH exactly maxWithdraw.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_withdrawETH_exactMax(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 ethBalanceBefore = alphixHook.balance;

        // Withdraw exactly max
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBalanceBefore + maxWithdraw, "Should receive max ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: withdrawETH exceeds max reverts.
     * @param depositAmount The deposit amount.
     * @param excess The excess amount above max.
     */
    function testFuzz_withdrawETH_exceedsMax_reverts(uint256 depositAmount, uint256 excess) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        excess = bound(excess, 1, 1000 ether);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw + excess;

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.WithdrawExceedsMax.selector);
        wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);
    }

    /**
     * @notice Fuzz test: multiple withdrawals maintain solvency.
     * @param numWithdrawals Number of withdrawals.
     */
    function testFuzz_withdrawETH_multipleMaintainSolvency(uint8 numWithdrawals) public {
        numWithdrawals = uint8(bound(numWithdrawals, 1, 10));

        // Deposit a large amount
        _depositETHAsHook(100 ether);

        vm.startPrank(alphixHook);
        for (uint8 i = 0; i < numWithdrawals; i++) {
            uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
            if (maxWithdraw == 0) break;

            uint256 withdrawAmount = maxWithdraw / (numWithdrawals - i);
            if (withdrawAmount == 0) withdrawAmount = 1;
            if (withdrawAmount > maxWithdraw) withdrawAmount = maxWithdraw;

            wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);
        }
        vm.stopPrank();

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: withdrawETH to any receiver address.
     * @param depositAmount The deposit amount.
     * @param receiver The receiver address.
     * @param withdrawPercent The percentage to withdraw.
     */
    function testFuzz_withdrawETH_toAnyReceiver(uint256 depositAmount, address receiver, uint256 withdrawPercent)
        public
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wethWrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(aavePool));
        vm.assume(receiver != address(weth));
        // Ensure receiver can accept ETH (exclude contracts and precompiles 0x01-0x09)
        vm.assume(receiver.code.length == 0);
        vm.assume(uint160(receiver) > 10);
        // Exclude Foundry's console.log precompile which cannot receive ETH
        vm.assume(receiver != 0x000000000000000000636F6e736F6c652e6c6f67);

        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        // Calculate withdraw amount
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        uint256 receiverBalanceBefore = receiver.balance;

        // Withdraw ETH to any receiver
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, receiver, alphixHook);

        assertEq(receiver.balance, receiverBalanceBefore + withdrawAmount, "Receiver should get ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: unauthorized address maxWithdraw returns 0.
     * @param unauthorizedAddr Random unauthorized address.
     */
    function testFuzz_maxWithdraw_unauthorizedReturnsZero(address unauthorizedAddr) public view {
        vm.assume(unauthorizedAddr != alphixHook);
        vm.assume(unauthorizedAddr != owner);
        vm.assume(unauthorizedAddr != address(0));

        assertEq(wethWrapper.maxWithdraw(unauthorizedAddr), 0, "Unauthorized should have 0 maxWithdraw");
    }

    /**
     * @notice Fuzz test: withdrawETH after negative yield (slash).
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_withdrawETH_afterNegativeYield(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        slashPercent = bound(slashPercent, 1, 50); // Max 50% slash

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wethWrapper), slashAmount);

        // maxWithdraw should be reduced
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        assertLt(maxWithdraw, depositAmount, "Max withdraw should be less after slash");

        // Withdraw should still work
        if (maxWithdraw > 0) {
            uint256 ethBalanceBefore = alphixHook.balance;

            vm.prank(alphixHook);
            wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

            assertEq(alphixHook.balance, ethBalanceBefore + maxWithdraw, "Should receive ETH");
        }

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }
}
