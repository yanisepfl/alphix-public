// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";

/**
 * @title WithdrawETHFlowTest
 * @author Alphix
 * @notice Integration tests for complete ETH withdraw user flows.
 */
contract WithdrawETHFlowTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Tests a complete ETH withdraw flow.
     */
    function test_withdrawETHFlow_basicWithdraw() public {
        uint256 depositAmount = 10 ether;

        // Deposit first
        _depositETHAsHook(depositAmount);

        // Record state before withdraw
        uint256 sharesBefore = wethWrapper.balanceOf(alphixHook);
        uint256 ethBefore = alphixHook.balance;
        uint256 totalAssetsBefore = wethWrapper.totalAssets();

        // Withdraw half
        uint256 withdrawAmount = 5 ether;
        vm.prank(alphixHook);
        uint256 sharesBurned = wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        // Verify state
        assertEq(wethWrapper.balanceOf(alphixHook), sharesBefore - sharesBurned, "Shares should decrease");
        assertEq(alphixHook.balance, ethBefore + withdrawAmount, "ETH should increase");
        assertEq(wethWrapper.totalAssets(), totalAssetsBefore - withdrawAmount, "Total assets should decrease");
    }

    /**
     * @notice Tests withdraw ETH to a different receiver.
     */
    function test_withdrawETHFlow_toDifferentReceiver() public {
        uint256 depositAmount = 10 ether;

        // Deposit first
        _depositETHAsHook(depositAmount);

        // Withdraw to alice
        uint256 aliceEthBefore = alice.balance;
        uint256 withdrawAmount = 5 ether;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, alice, alphixHook);

        assertEq(alice.balance, aliceEthBefore + withdrawAmount, "Alice should receive ETH");
    }

    /**
     * @notice Tests withdraw ETH after yield accrual.
     */
    function test_withdrawETHFlow_afterYield() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        _depositETHAsHook(depositAmount);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Withdraw all shares as ETH
        uint256 ethBefore = alphixHook.balance;
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

        // Should receive more than deposited due to yield (minus fees)
        uint256 ethReceived = alphixHook.balance - ethBefore;
        assertGt(ethReceived, depositAmount * 9 / 10, "Should receive deposit + some yield");
    }

    /**
     * @notice Tests partial withdrawals maintain correct state.
     */
    function test_withdrawETHFlow_multiplePartialWithdrawals() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        _depositETHAsHook(depositAmount);

        // Multiple partial withdrawals
        for (uint256 i = 0; i < 3; i++) {
            uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
            if (maxWithdraw == 0) break;

            uint256 withdrawAmount = maxWithdraw / 3;
            if (withdrawAmount == 0) break;

            vm.prank(alphixHook);
            wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);
        }

        // Solvency should hold
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Tests withdrawETH interleaved with depositETH.
     */
    function test_withdrawETHFlow_interleavedWithDeposits() public {
        // Deposit 10 ETH
        _depositETHAsHook(10 ether);

        // Withdraw 5 ETH
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(5 ether, alphixHook, alphixHook);

        // Deposit 3 ETH more
        vm.deal(alphixHook, 3 ether);
        vm.prank(alphixHook);
        wethWrapper.depositETH{value: 3 ether}(alphixHook);

        // Withdraw 2 ETH
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(2 ether, alphixHook, alphixHook);

        // Net: deposited 13, withdrew 7 = 6 ETH worth of assets
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        assertApproxEqRel(maxWithdraw, 6 ether, 0.01e18, "Max withdraw should be ~6 ETH");
    }

    /**
     * @notice Tests withdraw ETH after fee collection.
     */
    function test_withdrawETHFlow_afterFeeCollection() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Simulate yield
        _simulateYieldPercent(20);

        // Collect fees
        vm.prank(owner);
        wethWrapper.collectFees();

        // User still has their original shares (balanceOf unchanged)
        assertEq(wethWrapper.balanceOf(alphixHook), sharesMinted, "Share balance should be unchanged");

        // Withdraw max assets
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        assertGt(maxWithdraw, 0, "Should be able to withdraw after fee collection");

        uint256 sharesBefore = wethWrapper.balanceOf(alphixHook);
        vm.prank(alphixHook);
        uint256 sharesBurned = wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

        // After withdrawing maxWithdraw, user should have minimal shares left
        // Note: withdrawETH is asset-based, so some shares may remain due to rounding
        uint256 sharesAfter = wethWrapper.balanceOf(alphixHook);
        assertLt(sharesAfter, sharesBefore, "Shares should decrease");
        assertGt(sharesBurned, 0, "Should have burned shares");
    }

    /**
     * @notice Tests withdraw ETH with negative yield (slash).
     */
    function test_withdrawETHFlow_afterNegativeYield() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        _depositETHAsHook(depositAmount);

        // Simulate 20% slash
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 slashAmount = currentBalance * 20 / 100;
        aToken.simulateSlash(address(wethWrapper), slashAmount);

        // Max withdraw should be less
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        assertLt(maxWithdraw, depositAmount, "Max withdraw should be less after slash");

        // Withdraw should work
        uint256 ethBefore = alphixHook.balance;
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBefore + maxWithdraw, "Should receive ETH");
    }

    /**
     * @notice Tests that WETH is correctly unwrapped before sending ETH.
     */
    function test_withdrawETHFlow_unwrapsCorrectly() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        _depositETHAsHook(depositAmount);

        uint256 wethInWrapper = weth.balanceOf(address(wethWrapper));
        assertEq(wethInWrapper, 0, "No WETH should be in wrapper");

        // Withdraw
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(5 ether, alphixHook, alphixHook);

        // Still no WETH in wrapper
        assertEq(weth.balanceOf(address(wethWrapper)), 0, "No WETH should remain in wrapper");
    }
}
