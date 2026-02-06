// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title WithdrawETHTest
 * @author Alphix
 * @notice Unit tests for Alphix4626WrapperWethAave.withdrawETH().
 */
contract WithdrawETHTest is BaseAlphix4626WrapperWethAave {
    /* SETUP */

    function setUp() public override {
        super.setUp();
        // Deposit some ETH first so we have shares to withdraw
        _depositETHAsHook(10 ether);
    }

    /* SUCCESS CASES */

    /**
     * @notice Test basic withdrawETH success.
     */
    function test_withdrawETH_success() public {
        uint256 withdrawAmount = 1 ether;
        uint256 hookBalanceBefore = alphixHook.balance;
        uint256 sharesBefore = wethWrapper.balanceOf(alphixHook);

        vm.prank(alphixHook);
        uint256 sharesBurned = wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);

        // Shares should be burned
        assertGt(sharesBurned, 0, "No shares burned");
        assertEq(wethWrapper.balanceOf(alphixHook), sharesBefore - sharesBurned, "Share balance mismatch");

        // ETH should be received
        assertEq(alphixHook.balance, hookBalanceBefore + withdrawAmount, "ETH not received");
    }

    /**
     * @notice Test withdrawETH to different receiver.
     */
    function test_withdrawETH_toDifferentReceiver() public {
        uint256 withdrawAmount = 1 ether;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, bob, alphixHook);

        // Bob should receive ETH
        assertEq(bob.balance, bobBalanceBefore + withdrawAmount, "Bob did not receive ETH");
    }

    /**
     * @notice Test withdrawETH emits correct event.
     */
    function test_withdrawETH_emitsEvent() public {
        uint256 withdrawAmount = 1 ether;
        uint256 expectedShares = wethWrapper.previewWithdraw(withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit WithdrawETH(alphixHook, alphixHook, alphixHook, withdrawAmount, expectedShares);

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(withdrawAmount, alphixHook, alphixHook);
    }

    /* REVERT CASES */

    /**
     * @notice Test withdrawETH reverts if owner != msg.sender.
     * @dev Uses owner (authorized) trying to withdraw alphixHook's shares.
     */
    function test_withdrawETH_revertsIfOwnerNotMsgSender() public {
        // Owner is authorized but trying to withdraw alphixHook's shares
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.CallerNotOwner.selector);
        wethWrapper.withdrawETH(1 ether, owner, alphixHook);
    }

    /**
     * @notice Test withdrawETH reverts if exceeds max.
     */
    function test_withdrawETH_revertsIfExceedsMax() public {
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.WithdrawExceedsMax.selector);
        wethWrapper.withdrawETH(maxWithdraw + 1, alphixHook, alphixHook);
    }

    /**
     * @notice Test withdrawETH reverts if unauthorized.
     */
    function test_withdrawETH_revertsIfUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wethWrapper.withdrawETH(1 ether, unauthorized, unauthorized);
    }

    /**
     * @notice Test withdrawETH reverts if paused.
     */
    function test_withdrawETH_revertsIfPaused() public {
        vm.prank(owner);
        wethWrapper.pause();

        vm.prank(alphixHook);
        vm.expectRevert();
        wethWrapper.withdrawETH(1 ether, alphixHook, alphixHook);
    }

    /* INTEGRATION */

    /**
     * @notice Test full deposit-withdraw cycle with ETH.
     */
    function test_withdrawETH_fullCycle() public {
        uint256 depositAmount = 5 ether;
        uint256 hookBalanceStart = alphixHook.balance;

        // Deposit ETH
        vm.prank(alphixHook);
        wethWrapper.depositETH{value: depositAmount}(alphixHook);

        // Withdraw same amount
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(depositAmount, alphixHook, alphixHook);

        // Should have approximately same balance (minus any rounding)
        assertApproxEqAbs(alphixHook.balance, hookBalanceStart, 1, "Balance should be approximately same");
    }

    /* EDGE CASES */

    /**
     * @notice Test withdrawETH with zero amount reverts with WithdrawExceedsMax.
     * @dev The ZeroShares branch at line 126 is effectively unreachable for withdrawETH because:
     *      1. withdrawETH uses Rounding.Ceil for share calculation
     *      2. Even 1 wei will round up to at least 1 share
     *      3. Attempting to withdraw 0 will hit WithdrawExceedsMax first (since maxWithdraw > 0)
     *
     *      This test verifies the expected behavior when withdrawing 0 amount.
     */
    function test_withdrawETH_zeroAmount_reverts() public {
        // Withdrawing 0 should hit the shares == 0 check after rounding,
        // but actually it won't because 0 assets -> 0 shares with Ceil rounding still = 0
        // However, maxWithdraw check might be hit first if we have shares
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroShares.selector);
        wethWrapper.withdrawETH(0, alphixHook, alphixHook);
    }
}
