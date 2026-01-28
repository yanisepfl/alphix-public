// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title WithdrawFlowTest
 * @author Alphix
 * @notice Integration tests for withdrawal flows in Alphix4626WrapperSky.
 * @dev Sky-specific: withdrawals swap sUSDS → USDS via PSM
 */
contract WithdrawFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests deposit then withdraw flow.
     */
    function test_flow_depositThenWithdraw() public {
        uint256 depositAmount = 100e18;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 assetsBefore = usds.balanceOf(alphixHook);

        // Withdraw half
        uint256 withdrawAmount = 50e18;
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 assetsAfter = usds.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, sharesBurned, "Shares burned mismatch");
        assertApproxEqAbs(assetsAfter - assetsBefore, withdrawAmount, 1, "Assets received mismatch");
        _assertSolvent();
    }

    /**
     * @notice Tests deposit, yield, then withdraw flow.
     */
    function test_flow_depositYieldThenWithdraw() public {
        uint256 depositAmount = 100e18;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        // Simulate 1% yield (rate increase, respects circuit breaker)
        _simulateYieldPercent(1);

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
        uint256 depositAmount = 100e18;

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
        _depositAsHook(50e18, alphixHook);
        _depositAsHook(30e18, alphixHook);
        _depositAsHook(20e18, alphixHook);

        uint256 totalDeposited = 100e18;

        // Single withdrawal of all
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        // Verify
        assertApproxEqAbs(usds.balanceOf(alphixHook), maxWithdraw, 1, "Should have received assets");
        assertLe(maxWithdraw, totalDeposited + 1, "Max withdraw should not exceed deposits");
        _assertSolvent();
    }

    /**
     * @notice Tests single deposit followed by multiple withdrawals.
     */
    function test_flow_singleDepositThenMultipleWithdraws() public {
        uint256 depositAmount = 100e18;
        _depositAsHook(depositAmount, alphixHook);

        // Multiple withdrawals
        vm.startPrank(alphixHook);
        wrapper.withdraw(30e18, alphixHook, alphixHook);
        wrapper.withdraw(30e18, alphixHook, alphixHook);
        wrapper.withdraw(30e18, alphixHook, alphixHook);
        vm.stopPrank();

        uint256 totalWithdrawn = 90e18;
        assertApproxEqAbs(usds.balanceOf(alphixHook), totalWithdrawn, 2, "Total withdrawn mismatch");
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw after fee collection.
     */
    function test_flow_withdrawAfterFeeCollection() public {
        uint256 depositAmount = 100e18;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        assertApproxEqAbs(usds.balanceOf(alphixHook), maxWithdraw, 1, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw after negative yield (rate decrease).
     */
    function test_flow_withdrawAfterNegativeYield() public {
        uint256 depositAmount = 100e18;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate 1% rate decrease (slashing)
        _simulateSlashPercent(1);

        // maxWithdraw should be less than deposited
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        assertLt(maxWithdraw, depositAmount, "Max withdraw should be reduced after slash");

        // Withdraw all available
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        assertApproxEqAbs(usds.balanceOf(alphixHook), maxWithdraw, 1, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests interleaved deposits and withdrawals.
     */
    function test_flow_interleavedDepositsAndWithdraws() public {
        // Deposit
        _depositAsHook(50e18, alphixHook);

        // Withdraw some
        vm.prank(alphixHook);
        wrapper.withdraw(20e18, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(30e18, alphixHook);

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Withdraw some
        vm.prank(alphixHook);
        wrapper.withdraw(25e18, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(40e18, alphixHook);

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
        _depositAsHook(100e18, alphixHook);

        usds.mint(hook2, 100e18);
        vm.startPrank(hook2);
        usds.approve(address(wrapper), 100e18);
        wrapper.deposit(100e18, hook2);
        vm.stopPrank();

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

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
        uint256 depositAmount = 100e18;

        // Owner deposits
        _depositAsOwner(depositAmount, owner);

        uint256 ownerShares = wrapper.balanceOf(owner);
        assertGt(ownerShares, 0, "Owner should have shares");

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Owner withdraws
        uint256 maxWithdraw = wrapper.maxWithdraw(owner);
        vm.prank(owner);
        wrapper.withdraw(maxWithdraw, owner, owner);

        assertApproxEqAbs(usds.balanceOf(owner), maxWithdraw, 1, "Owner should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw to different receiver.
     */
    function test_flow_withdrawToDifferentReceiver() public {
        uint256 depositAmount = 100e18;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        address receiver = makeAddr("externalReceiver");
        uint256 withdrawAmount = 50e18;

        uint256 hookSharesBefore = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        // Withdraw to different receiver
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, receiver, alphixHook);

        uint256 hookSharesAfter = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceAfter = usds.balanceOf(receiver);

        assertEq(hookSharesBefore - hookSharesAfter, sharesBurned, "Shares burned mismatch");
        assertApproxEqAbs(receiverBalanceAfter - receiverBalanceBefore, withdrawAmount, 1, "Receiver should get assets");
        assertEq(usds.balanceOf(alphixHook), 0, "Hook should not receive assets");
        _assertSolvent();
    }

    /**
     * @notice Tests that yield accrues before withdrawal.
     */
    function test_flow_yieldAccruesBeforeWithdraw() public {
        _depositAsHook(100e18, alphixHook);

        // Record fees before yield
        uint256 feesBeforeYield = wrapper.getClaimableFees();

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // getClaimableFees calculates pending fees in view (includes unrealized yield)
        uint256 feesAfterYield = wrapper.getClaimableFees();
        assertGt(feesAfterYield, feesBeforeYield, "Claimable fees should include pending yield fees");

        // Withdraw triggers actual accrual to state
        vm.prank(alphixHook);
        wrapper.withdraw(10e18, alphixHook, alphixHook);

        // Fees should still be positive
        uint256 feesAfterWithdraw = wrapper.getClaimableFees();
        assertGt(feesAfterWithdraw, 0, "Fees should be accumulated after withdraw");
    }
}
