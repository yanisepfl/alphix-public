// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title RedeemFlowTest
 * @author Alphix
 * @notice Integration tests for redemption flows in Alphix4626WrapperSky.
 * @dev Sky-specific: redemptions swap sUSDS → USDS via PSM
 */
contract RedeemFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests deposit then redeem flow.
     */
    function test_flow_depositThenRedeem() public {
        uint256 depositAmount = 100e18;

        // Deposit as hook
        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 assetsBefore = usds.balanceOf(alphixHook);

        // Redeem half of shares
        uint256 redeemShares = shares / 2;
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 assetsAfter = usds.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, redeemShares, "Shares burned mismatch");
        assertApproxEqAbs(assetsAfter - assetsBefore, assetsReceived, 1, "Assets received mismatch");
        _assertSolvent();
    }

    /**
     * @notice Tests deposit, yield, then redeem flow.
     */
    function test_flow_depositYieldThenRedeem() public {
        uint256 depositAmount = 100e18;

        // Deposit as hook
        _depositAsHook(depositAmount, alphixHook);

        // Simulate 1% yield (respects circuit breaker)
        _simulateYieldPercent(1);

        // Redeem all shares
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        // Should receive more than deposited (minus fees)
        assertGt(assetsReceived, depositAmount * 90 / 100, "Should have earned yield");
        _assertSolvent();
    }

    /**
     * @notice Tests full deposit and redeem cycle.
     */
    function test_flow_fullDepositRedeemCycle() public {
        uint256 depositAmount = 100e18;

        // Deposit
        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        // Redeem all
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        // Check shares (may have dust)
        uint256 remainingShares = wrapper.balanceOf(alphixHook);
        assertLt(remainingShares, shares / 1000, "Should have redeemed almost all");
        _assertSolvent();
    }

    /**
     * @notice Tests multiple deposits followed by single redeem.
     */
    function test_flow_multipleDepositsThenSingleRedeem() public {
        // Multiple deposits
        uint256 shares1 = _depositAsHook(50e18, alphixHook);
        uint256 shares2 = _depositAsHook(30e18, alphixHook);
        uint256 shares3 = _depositAsHook(20e18, alphixHook);

        uint256 totalShares = shares1 + shares2 + shares3;

        // Single redeem of all
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        // Verify
        assertLt(wrapper.balanceOf(alphixHook), totalShares / 1000, "Should have redeemed almost all");
        _assertSolvent();
    }

    /**
     * @notice Tests single deposit followed by multiple redeems.
     */
    function test_flow_singleDepositThenMultipleRedeems() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        // Multiple redeems
        uint256 redeemAmount = shares / 4;
        vm.startPrank(alphixHook);
        wrapper.redeem(redeemAmount, alphixHook, alphixHook);
        wrapper.redeem(redeemAmount, alphixHook, alphixHook);
        wrapper.redeem(redeemAmount, alphixHook, alphixHook);
        vm.stopPrank();

        assertGt(usds.balanceOf(alphixHook), 0, "Should have received assets");
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem after fee collection.
     */
    function test_flow_redeemAfterFeeCollection() public {
        uint256 depositAmount = 100e18;
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Redeem
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertGt(usds.balanceOf(alphixHook), 0, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem after negative yield (rate decrease).
     */
    function test_flow_redeemAfterNegativeYield() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        // Simulate 1% rate decrease
        _simulateSlashPercent(1);

        // previewRedeem should show less than deposited
        uint256 assetsExpected = wrapper.previewRedeem(shares);
        assertLt(assetsExpected, depositAmount, "Preview should be less than deposited");

        // Redeem all
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertLt(assetsReceived, depositAmount, "Should receive less after slash");
        _assertSolvent();
    }

    /**
     * @notice Tests interleaved deposits and redeems.
     */
    function test_flow_interleavedDepositsAndRedeems() public {
        // Deposit
        uint256 shares1 = _depositAsHook(50e18, alphixHook);

        // Redeem some
        vm.prank(alphixHook);
        wrapper.redeem(shares1 / 4, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(30e18, alphixHook);

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Redeem some
        uint256 currentShares = wrapper.balanceOf(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(currentShares / 3, alphixHook, alphixHook);

        // Deposit more
        _depositAsHook(40e18, alphixHook);

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
        uint256 hook1Shares = _depositAsHook(100e18, alphixHook);

        usds.mint(hook2, 100e18);
        vm.startPrank(hook2);
        usds.approve(address(wrapper), 100e18);
        uint256 hook2Shares = wrapper.deposit(100e18, hook2);
        vm.stopPrank();

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Hook1 redeems half
        vm.prank(alphixHook);
        wrapper.redeem(hook1Shares / 2, alphixHook, alphixHook);

        // Hook2 redeems half
        vm.prank(hook2);
        wrapper.redeem(hook2Shares / 2, hook2, hook2);

        // Both should still have shares
        assertGt(wrapper.balanceOf(alphixHook), 0, "Hook1 should have shares");
        assertGt(wrapper.balanceOf(hook2), 0, "Hook2 should have shares");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem to different receiver.
     */
    function test_flow_redeemToDifferentReceiver() public {
        uint256 depositAmount = 100e18;
        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        address receiver = makeAddr("externalReceiver");
        uint256 redeemShares = shares / 2;

        uint256 hookSharesBefore = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceBefore = usds.balanceOf(receiver);

        // Redeem to different receiver
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, receiver, alphixHook);

        uint256 hookSharesAfter = wrapper.balanceOf(alphixHook);
        uint256 receiverBalanceAfter = usds.balanceOf(receiver);

        assertEq(hookSharesBefore - hookSharesAfter, redeemShares, "Shares burned mismatch");
        assertApproxEqAbs(receiverBalanceAfter - receiverBalanceBefore, assetsReceived, 1, "Receiver should get assets");
        assertEq(usds.balanceOf(alphixHook), 0, "Hook should not receive assets");
        _assertSolvent();
    }

    /**
     * @notice Tests redeem vs withdraw yields same results for equivalent values.
     */
    function test_flow_redeemVsWithdrawEquivalence() public {
        // Deposit for hook
        _depositAsHook(200e18, alphixHook);

        uint256 shares = wrapper.balanceOf(alphixHook);

        // Get expected assets from redeeming half shares
        uint256 redeemShares = shares / 2;
        uint256 expectedAssets = wrapper.previewRedeem(redeemShares);

        // Redeem half shares
        vm.prank(alphixHook);
        uint256 redeemAssets = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        // Withdraw equivalent assets (will burn approximately same shares)
        vm.prank(alphixHook);
        uint256 withdrawShares = wrapper.withdraw(expectedAssets, alphixHook, alphixHook);

        // Should be approximately equal (within rounding)
        _assertApproxEq(redeemAssets, expectedAssets, 2, "Redeem should give expected assets");
        _assertApproxEq(withdrawShares, redeemShares, 2, "Withdraw should burn similar shares");
        _assertSolvent();
    }
}
