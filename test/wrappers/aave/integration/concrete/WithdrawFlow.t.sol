// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title WithdrawFlowTest
 * @author Alphix
 * @notice Integration tests for withdrawal flows in Alphix4626WrapperAave.
 */
contract WithdrawFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests deposit then withdraw flow.
     */
    function test_flow_depositThenWithdraw() public {
        uint256 depositAmount = 100e6;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 assetsBefore = asset.balanceOf(alphixHook);

        // Withdraw half
        uint256 withdrawAmount = 50e6;
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 assetsAfter = asset.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, sharesBurned, "Shares burned mismatch");
        assertEq(assetsAfter - assetsBefore, withdrawAmount, "Assets received mismatch");
        _assertSolvent();
    }

    /**
     * @notice Tests deposit, yield, then withdraw flow.
     */
    function test_flow_depositYieldThenWithdraw() public {
        uint256 depositAmount = 100e6;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 maxWithdrawable = wrapper.maxWithdraw(alphixHook);
        // Should be able to withdraw more than deposited (minus fees)
        assertGt(maxWithdrawable, depositAmount * 90 / 100, "Should have earned yield");

        // Withdraw original deposit amount
        vm.prank(alphixHook);
        wrapper.withdraw(depositAmount, alphixHook, alphixHook);

        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares from yield");
        _assertSolvent();
    }

    /**
     * @notice Tests full deposit and withdraw cycle.
     */
    function test_flow_fullDepositWithdrawCycle() public {
        uint256 depositAmount = 100e6;

        // Deposit
        _depositAsHook(depositAmount, alphixHook);
        uint256 sharesReceived = wrapper.balanceOf(alphixHook);

        // Get max withdrawable
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        // Withdraw all
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        // Check shares (may have dust due to rounding)
        uint256 remainingShares = wrapper.balanceOf(alphixHook);
        assertLt(remainingShares, sharesReceived / 1000, "Should have withdrawn almost all");
        _assertSolvent();
    }

    /**
     * @notice Tests multiple deposits followed by single withdrawal.
     */
    function test_flow_multipleDepositsThenSingleWithdraw() public {
        // Multiple deposits
        _depositAsHook(50e6, alphixHook);
        _depositAsHook(30e6, alphixHook);
        _depositAsHook(20e6, alphixHook);

        uint256 totalDeposited = 100e6;

        // Single withdrawal of all
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        // Verify
        assertEq(asset.balanceOf(alphixHook), maxWithdraw, "Should have received assets");
        assertLe(maxWithdraw, totalDeposited, "Max withdraw should not exceed deposits");
        _assertSolvent();
    }

    /**
     * @notice Tests single deposit followed by multiple withdrawals.
     */
    function test_flow_singleDepositThenMultipleWithdraws() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        // Multiple withdrawals
        vm.startPrank(alphixHook);
        wrapper.withdraw(30e6, alphixHook, alphixHook);
        wrapper.withdraw(30e6, alphixHook, alphixHook);
        wrapper.withdraw(30e6, alphixHook, alphixHook);
        vm.stopPrank();

        uint256 totalWithdrawn = 90e6;
        assertEq(asset.balanceOf(alphixHook), totalWithdrawn, "Total withdrawn mismatch");
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw after fee collection.
     */
    function test_flow_withdrawAfterFeeCollection() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), maxWithdraw, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw after negative yield.
     */
    function test_flow_withdrawAfterNegativeYield() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate 5% negative yield (slashing)
        uint256 currentBalance = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = currentBalance * 5 / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // maxWithdraw should be less than deposited
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        assertLt(maxWithdraw, depositAmount, "Max withdraw should be reduced after slash");

        // Withdraw all available
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), maxWithdraw, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests interleaved deposits and withdrawals.
     */
    function test_flow_interleavedDepositsAndWithdraws() public {
        // Deposit
        _depositAsHook(50e6, alphixHook);

        // Withdraw some
        vm.prank(alphixHook);
        wrapper.withdraw(20e6, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(30e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(5);

        // Withdraw some
        vm.prank(alphixHook);
        wrapper.withdraw(25e6, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(40e6, alphixHook);

        // Final state check
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have shares");
        assertGt(wrapper.totalAssets(), 0, "Should have assets");
        _assertSolvent();
    }

    /**
     * @notice Tests multi-user deposit and withdraw flow.
     */
    function test_flow_multiUserDepositWithdraw() public {
        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Both hooks deposit
        _depositAsHook(100e6, alphixHook);

        asset.mint(hook2, 100e6);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), 100e6);
        wrapper.deposit(100e6, hook2);
        vm.stopPrank();

        // Simulate yield
        _simulateYieldPercent(10);

        // Hook1 withdraws
        uint256 hook1MaxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(hook1MaxWithdraw / 2, alphixHook, alphixHook);

        // Hook2 withdraws
        uint256 hook2MaxWithdraw = wrapper.maxWithdraw(hook2);
        vm.prank(hook2);
        wrapper.withdraw(hook2MaxWithdraw / 2, hook2, hook2);

        // Both should still have shares
        assertGt(wrapper.balanceOf(alphixHook), 0, "Hook1 should have shares");
        assertGt(wrapper.balanceOf(hook2), 0, "Hook2 should have shares");
        _assertSolvent();
    }

    /**
     * @notice Tests owner deposit and withdraw flow.
     */
    function test_flow_ownerDepositWithdraw() public {
        uint256 depositAmount = 100e6;

        // Owner deposits
        _depositAsOwner(depositAmount, owner);

        uint256 ownerShares = wrapper.balanceOf(owner);
        assertGt(ownerShares, 0, "Owner should have shares");

        // Simulate yield
        _simulateYieldPercent(5);

        // Owner withdraws
        uint256 maxWithdraw = wrapper.maxWithdraw(owner);
        vm.prank(owner);
        wrapper.withdraw(maxWithdraw, owner, owner);

        assertEq(asset.balanceOf(owner), maxWithdraw, "Owner should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw updates lastWrapperBalance correctly across operations.
     */
    function test_flow_lastWrapperBalanceUpdatesOnWithdraw() public {
        _depositAsHook(100e6, alphixHook);

        uint256 balanceBefore = wrapper.getLastWrapperBalance();

        // Withdraw
        vm.prank(alphixHook);
        wrapper.withdraw(50e6, alphixHook, alphixHook);

        uint256 balanceAfter = wrapper.getLastWrapperBalance();
        uint256 actualATokenBalance = aToken.balanceOf(address(wrapper));

        assertLt(balanceAfter, balanceBefore, "Balance should decrease after withdraw");
        assertEq(balanceAfter, actualATokenBalance, "lastWrapperBalance should match actual");
    }

    /**
     * @notice Tests that yield accrues before withdrawal.
     * @dev getClaimableFees() is a view function that calculates pending fees without modifying state.
     *      The accrual happens when withdraw is called, but the view function already shows pending fees.
     */
    function test_flow_yieldAccruesBeforeWithdraw() public {
        _depositAsHook(100e6, alphixHook);

        // Record fees before yield
        uint256 feesBeforeYield = wrapper.getClaimableFees();

        // Simulate yield
        _simulateYieldPercent(10);

        // getClaimableFees calculates pending fees in view (includes unrealized yield)
        uint256 feesAfterYield = wrapper.getClaimableFees();
        assertGt(feesAfterYield, feesBeforeYield, "Claimable fees should include pending yield fees");

        // Withdraw triggers actual accrual to state
        vm.prank(alphixHook);
        wrapper.withdraw(10e6, alphixHook, alphixHook);

        // Fees should still be positive
        uint256 feesAfterWithdraw = wrapper.getClaimableFees();
        assertGt(feesAfterWithdraw, 0, "Fees should be accumulated after withdraw");
    }

    /**
     * @notice Tests hook can withdraw to a different receiver address.
     */
    function test_flow_withdrawToDifferentReceiver() public {
        uint256 depositAmount = 100e6;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        address receiver = makeAddr("externalReceiver");
        uint256 withdrawAmount = 50e6;

        uint256 hookSharesBefore = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceBefore = asset.balanceOf(receiver);

        // Withdraw to different receiver
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, receiver, alphixHook);

        uint256 hookSharesAfter = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceAfter = asset.balanceOf(receiver);

        assertEq(hookSharesBefore - hookSharesAfter, sharesBurned, "Shares burned mismatch");
        assertEq(receiverBalanceAfter - receiverBalanceBefore, withdrawAmount, "Receiver should get assets");
        assertEq(asset.balanceOf(alphixHook), 0, "Hook should not receive assets");
        _assertSolvent();
    }
}
