// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title RedeemFlowTest
 * @author Alphix
 * @notice Integration tests for redeem flows in Alphix4626WrapperAave.
 */
contract RedeemFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests deposit then redeem flow.
     */
    function test_flow_depositThenRedeem() public {
        uint256 depositAmount = 100e6;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 assetsBefore = asset.balanceOf(alphixHook);

        // Redeem half the shares
        uint256 redeemShares = sharesBefore / 2;
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 assetsAfter = asset.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, redeemShares, "Shares burned mismatch");
        assertEq(assetsAfter - assetsBefore, assetsReceived, "Assets received mismatch");
        _assertSolvent();
    }

    /**
     * @notice Tests deposit, yield, then redeem flow.
     */
    function test_flow_depositYieldThenRedeem() public {
        uint256 depositAmount = 100e6;

        // Deposit as hook
        uint256 sharesReceived = _depositAsHook(depositAmount, alphixHook);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Redeem all shares
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        // Should receive more than deposited (minus fees) due to yield
        assertGt(assetsReceived, depositAmount * 90 / 100, "Should have earned yield");
        assertLe(wrapper.balanceOf(alphixHook), sharesReceived - maxRedeem + 1, "Should have burned shares");
        _assertSolvent();
    }

    /**
     * @notice Tests full deposit and redeem cycle.
     */
    function test_flow_fullDepositRedeemCycle() public {
        uint256 depositAmount = 100e6;

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Get max redeemable
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        // Redeem all
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "Should receive assets");
        // Check shares (may have dust due to rounding)
        uint256 remainingShares = wrapper.balanceOf(alphixHook);
        assertLe(remainingShares, 1, "Should have redeemed almost all");
        _assertSolvent();
    }

    /**
     * @notice Tests multiple deposits followed by single redeem.
     */
    function test_flow_multipleDepositsThenSingleRedeem() public {
        // Multiple deposits
        _depositAsHook(50e6, alphixHook);
        _depositAsHook(30e6, alphixHook);
        _depositAsHook(20e6, alphixHook);

        uint256 totalShares = wrapper.balanceOf(alphixHook);

        // Single redeem of all
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        // Verify
        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should have received assets");
        assertLe(wrapper.balanceOf(alphixHook), totalShares - maxRedeem + 1, "Should have burned shares");
        _assertSolvent();
    }

    /**
     * @notice Tests single deposit followed by multiple redemptions.
     */
    function test_flow_singleDepositThenMultipleRedeems() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalShares = wrapper.balanceOf(alphixHook);
        uint256 redeemPerOp = totalShares / 4;

        // Multiple redemptions
        vm.startPrank(alphixHook);
        uint256 assets1 = wrapper.redeem(redeemPerOp, alphixHook, alphixHook);
        uint256 assets2 = wrapper.redeem(redeemPerOp, alphixHook, alphixHook);
        uint256 assets3 = wrapper.redeem(redeemPerOp, alphixHook, alphixHook);
        vm.stopPrank();

        uint256 totalAssetsReceived = assets1 + assets2 + assets3;
        assertEq(asset.balanceOf(alphixHook), totalAssetsReceived, "Total assets received mismatch");
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem after fee collection.
     */
    function test_flow_redeemAfterFeeCollection() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Redeem
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem after negative yield.
     */
    function test_flow_redeemAfterNegativeYield() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate 5% negative yield (slashing)
        uint256 currentBalance = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = currentBalance * 5 / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // Redeem all available
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        // Should receive less than deposited due to slash
        assertLt(assetsReceived, depositAmount, "Should receive less after slash");
        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests interleaved deposits and redemptions.
     */
    function test_flow_interleavedDepositsAndRedeems() public {
        // Deposit
        _depositAsHook(50e6, alphixHook);

        // Redeem some
        uint256 shares1 = wrapper.balanceOf(alphixHook) / 3;
        vm.prank(alphixHook);
        wrapper.redeem(shares1, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(30e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(5);

        // Redeem some
        uint256 shares2 = wrapper.balanceOf(alphixHook) / 3;
        vm.prank(alphixHook);
        wrapper.redeem(shares2, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(40e6, alphixHook);

        // Final state check
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have shares");
        assertGt(wrapper.totalAssets(), 0, "Should have assets");
        _assertSolvent();
    }

    /**
     * @notice Tests multi-user deposit and redeem flow.
     */
    function test_flow_multiUserDepositRedeem() public {
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

        // Hook1 redeems half
        uint256 hook1Shares = wrapper.balanceOf(alphixHook) / 2;
        vm.prank(alphixHook);
        wrapper.redeem(hook1Shares, alphixHook, alphixHook);

        // Hook2 redeems half
        uint256 hook2Shares = wrapper.balanceOf(hook2) / 2;
        vm.prank(hook2);
        wrapper.redeem(hook2Shares, hook2, hook2);

        // Both should still have shares
        assertGt(wrapper.balanceOf(alphixHook), 0, "Hook1 should have shares");
        assertGt(wrapper.balanceOf(hook2), 0, "Hook2 should have shares");
        _assertSolvent();
    }

    /**
     * @notice Tests owner deposit and redeem flow.
     */
    function test_flow_ownerDepositRedeem() public {
        uint256 depositAmount = 100e6;

        // Owner deposits
        _depositAsOwner(depositAmount, owner);

        uint256 ownerShares = wrapper.balanceOf(owner);
        assertGt(ownerShares, 0, "Owner should have shares");

        // Simulate yield
        _simulateYieldPercent(5);

        // Owner redeems all
        uint256 maxRedeem = wrapper.maxRedeem(owner);
        vm.prank(owner);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, owner, owner);

        assertEq(asset.balanceOf(owner), assetsReceived, "Owner should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem updates lastWrapperBalance correctly across operations.
     */
    function test_flow_lastWrapperBalanceUpdatesOnRedeem() public {
        _depositAsHook(100e6, alphixHook);

        uint256 balanceBefore = wrapper.getLastWrapperBalance();

        // Redeem half
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;
        vm.prank(alphixHook);
        wrapper.redeem(redeemShares, alphixHook, alphixHook);

        uint256 balanceAfter = wrapper.getLastWrapperBalance();
        uint256 actualATokenBalance = aToken.balanceOf(address(wrapper));

        assertLt(balanceAfter, balanceBefore, "Balance should decrease after redeem");
        assertEq(balanceAfter, actualATokenBalance, "lastWrapperBalance should match actual");
    }

    /**
     * @notice Tests that yield accrues before redemption.
     */
    function test_flow_yieldAccruesBeforeRedeem() public {
        _depositAsHook(100e6, alphixHook);

        // Record fees before yield
        uint256 feesBeforeYield = wrapper.getClaimableFees();

        // Simulate yield
        _simulateYieldPercent(10);

        // getClaimableFees calculates pending fees in view
        uint256 feesAfterYield = wrapper.getClaimableFees();
        assertGt(feesAfterYield, feesBeforeYield, "Claimable fees should include pending yield fees");

        // Redeem triggers actual accrual to state
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 4;
        vm.prank(alphixHook);
        wrapper.redeem(redeemShares, alphixHook, alphixHook);

        // Fees should still be positive
        uint256 feesAfterRedeem = wrapper.getClaimableFees();
        assertGt(feesAfterRedeem, 0, "Fees should be accumulated after redeem");
    }

    /**
     * @notice Tests hook can redeem to a different receiver address.
     */
    function test_flow_redeemToDifferentReceiver() public {
        uint256 depositAmount = 100e6;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        address receiver = makeAddr("externalReceiver");
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;

        uint256 hookSharesBefore = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceBefore = asset.balanceOf(receiver);

        // Redeem to different receiver
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, receiver, alphixHook);

        uint256 hookSharesAfter = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceAfter = asset.balanceOf(receiver);

        assertEq(hookSharesBefore - hookSharesAfter, redeemShares, "Shares burned mismatch");
        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsReceived, "Receiver should get assets");
        assertEq(asset.balanceOf(alphixHook), 0, "Hook should not receive assets");
        _assertSolvent();
    }

    /**
     * @notice Tests withdraw vs redeem equivalence for same value.
     */
    function test_flow_withdrawVsRedeemEquivalence() public {
        // Two separate deposits
        _depositAsHook(100e6, alphixHook);

        address hook2 = makeAddr("hook2");
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        asset.mint(hook2, 100e6);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), 100e6);
        wrapper.deposit(100e6, hook2);
        vm.stopPrank();

        // Get comparable amounts
        uint256 withdrawAmount = 50e6;
        uint256 sharesForWithdraw = wrapper.previewWithdraw(withdrawAmount);

        // Hook1 withdraws by asset amount
        vm.prank(alphixHook);
        uint256 sharesBurnedWithdraw = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        // Hook2 redeems same number of shares
        vm.prank(hook2);
        uint256 assetsFromRedeem = wrapper.redeem(sharesForWithdraw, hook2, hook2);

        // Results should be very close
        assertLe(sharesBurnedWithdraw, sharesForWithdraw + 1, "Shares burned should be similar");
        assertGe(sharesBurnedWithdraw + 1, sharesForWithdraw, "Shares burned should be similar");
        // Assets from redeem should be close to withdraw amount (same shares = similar assets)
        assertGe(assetsFromRedeem, withdrawAmount - 1, "Assets from redeem should be close to withdraw amount");
        assertLe(assetsFromRedeem, withdrawAmount + 1, "Assets from redeem should be close to withdraw amount");
        assertEq(asset.balanceOf(hook2), assetsFromRedeem, "Hook2 should receive assets from redeem");
        _assertSolvent();
    }

    /**
     * @notice Tests mixed withdraw and redeem operations.
     */
    function test_flow_mixedWithdrawAndRedeem() public {
        _depositAsHook(200e6, alphixHook);

        // Withdraw by asset amount
        vm.prank(alphixHook);
        wrapper.withdraw(50e6, alphixHook, alphixHook);

        // Redeem by share amount
        uint256 sharesToRedeem = wrapper.balanceOf(alphixHook) / 4;
        vm.prank(alphixHook);
        wrapper.redeem(sharesToRedeem, alphixHook, alphixHook);

        // Simulate yield
        _simulateYieldPercent(5);

        // Withdraw again
        vm.prank(alphixHook);
        wrapper.withdraw(30e6, alphixHook, alphixHook);

        // Redeem again
        sharesToRedeem = wrapper.balanceOf(alphixHook) / 2;
        vm.prank(alphixHook);
        wrapper.redeem(sharesToRedeem, alphixHook, alphixHook);

        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares");
        _assertSolvent();
    }
}
