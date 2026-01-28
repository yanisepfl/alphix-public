// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title CollectFeesFlowTest
 * @author Alphix
 * @notice Integration tests for fee collection flows.
 * @dev Sky-specific: fees are collected in sUSDS
 */
contract CollectFeesFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests complete fee collection flow.
     */
    function test_collectFeesFlow_complete() public {
        // Deposit
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Get claimable fees
        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have claimable fees");

        // Collect fees
        uint256 treasuryBefore = susds.balanceOf(treasury);
        vm.prank(owner);
        wrapper.collectFees();
        uint256 treasuryAfter = susds.balanceOf(treasury);

        // Treasury should receive fees in sUSDS
        assertEq(treasuryAfter - treasuryBefore, claimableFees, "Treasury should receive exact fees");

        // No more claimable fees
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero after collection");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection with multiple yield cycles.
     */
    function test_collectFeesFlow_multipleYieldCycles() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 totalFeesCollected;

        for (uint256 i = 0; i < 5; i++) {
            // Generate yield
            _simulateYieldPercent(1);

            // Get and record fees
            uint256 fees = wrapper.getClaimableFees();

            // Collect fees
            if (fees > 0) {
                vm.prank(owner);
                wrapper.collectFees();
                totalFeesCollected += fees;
            }
        }

        // Treasury should have accumulated all fees
        assertEq(susds.balanceOf(treasury), totalFeesCollected, "Treasury should have all fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection followed by user operations.
     */
    function test_collectFeesFlow_thenUserOperations() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // User can still deposit
        _depositAsHook(5_000e18, alphixHook);

        // User can still withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw / 2, alphixHook, alphixHook);

        // User can still redeem
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(maxRedeem / 2, alphixHook, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection with treasury change.
     */
    function test_collectFeesFlow_withTreasuryChange() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Trigger accrual to update lastRate before next yield (circuit breaker)
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 fees1 = wrapper.getClaimableFees();

        // Change treasury
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        wrapper.setYieldTreasury(newTreasury);

        // Generate more yield
        _simulateYieldPercent(1);

        uint256 fees2 = wrapper.getClaimableFees();
        assertGt(fees2, fees1, "Should have more fees");

        // Collect fees - should go to new treasury
        vm.prank(owner);
        wrapper.collectFees();

        // All fees should go to new treasury
        assertEq(susds.balanceOf(newTreasury), fees2, "New treasury should receive all fees");
        assertEq(susds.balanceOf(treasury), 0, "Old treasury should receive nothing");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection after negative yield.
     */
    function test_collectFeesFlow_afterNegativeYield() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield and lock in fees
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE); // Trigger accrual

        uint256 feesBeforeSlash = wrapper.getClaimableFees();
        assertGt(feesBeforeSlash, 0, "Should have fees");

        // Negative yield
        _simulateSlashPercent(1);

        // Fees should NOT be reduced (Sky behavior)
        uint256 feesAfterSlash = wrapper.getClaimableFees();
        assertEq(feesAfterSlash, feesBeforeSlash, "Fees should not be reduced");

        // Can still collect full fees
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), feesBeforeSlash, "Treasury should receive full fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection with partial withdrawals interspersed.
     */
    function test_collectFeesFlow_withInterspersedWithdrawals() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Verify fees accumulated
        assertGt(wrapper.getClaimableFees(), 0, "Should have fees after yield");

        // Partial withdrawal
        vm.prank(alphixHook);
        wrapper.withdraw(1_000e18, alphixHook, alphixHook);

        // Fees should still be claimable
        uint256 feesAfterWithdraw = wrapper.getClaimableFees();
        assertGt(feesAfterWithdraw, 0, "Should have fees after withdrawal");

        // More yield
        _simulateYieldPercent(1);

        // Collect all fees
        uint256 totalFees = wrapper.getClaimableFees();
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), totalFees, "Treasury should receive all fees");

        _assertSolvent();
    }

    /**
     * @notice Tests collecting zero fees reverts with ZeroAmount.
     */
    function test_collectFeesFlow_zeroFees_reverts() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // No yield generated, so no fees
        assertEq(wrapper.getClaimableFees(), 0, "Should have no fees");

        // Collecting zero fees should revert
        vm.prank(owner);
        vm.expectRevert();
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), 0, "Treasury should have received nothing");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection maintains accurate accounting.
     */
    function test_collectFeesFlow_accountingAccuracy() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Record state before collection
        uint256 susdsBalanceBefore = susds.balanceOf(address(wrapper));
        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // State after collection
        uint256 susdsBalanceAfter = susds.balanceOf(address(wrapper));
        uint256 totalAssetsAfter = wrapper.totalAssets();

        // sUSDS balance should decrease by exact fee amount
        assertEq(susdsBalanceBefore - susdsBalanceAfter, claimableFees, "sUSDS decreased by fee amount");

        // Total assets should remain approximately the same
        // (fees were already excluded from totalAssets calculation)
        _assertApproxEq(totalAssetsAfter, totalAssetsBefore, 2, "Total assets unchanged after fee collection");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection with multiple users.
     */
    function test_collectFeesFlow_multipleUsers() public {
        // Multiple users deposit
        _depositAsHook(5_000e18, alphixHook);

        address hook2 = makeAddr("hook2");
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        usds.mint(hook2, 5_000e18);
        vm.startPrank(hook2);
        usds.approve(address(wrapper), 5_000e18);
        wrapper.deposit(5_000e18, hook2);
        vm.stopPrank();

        // Generate yield
        _simulateYieldPercent(1);

        // Collect fees
        assertGt(wrapper.getClaimableFees(), 0, "Should have fees to collect");
        vm.prank(owner);
        wrapper.collectFees();

        // Both users can still operate
        uint256 hook1Max = wrapper.maxWithdraw(alphixHook);
        uint256 hook2Max = wrapper.maxWithdraw(hook2);

        assertGt(hook1Max, 0, "Hook1 can withdraw");
        assertGt(hook2Max, 0, "Hook2 can withdraw");

        // Withdraw for both
        vm.prank(alphixHook);
        wrapper.withdraw(hook1Max, alphixHook, alphixHook);

        vm.prank(hook2);
        wrapper.withdraw(hook2Max, hook2, hook2);

        _assertSolvent();
    }
}
