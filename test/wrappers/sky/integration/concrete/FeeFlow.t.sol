// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title FeeFlowTest
 * @author Alphix
 * @notice Integration tests for fee management flows.
 * @dev Sky-specific: fees are collected in sUSDS terms
 */
contract FeeFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests fee change flow with yield accrual.
     */
    function test_feeFlow_changeFeeMidStream() public {
        // Deposit
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Simulate yield at 10% fee
        _simulateYieldPercent(1);

        uint256 feesAt10Percent = wrapper.getClaimableFees();

        // Change fee to 50%
        vm.prank(owner);
        wrapper.setFee(500_000);

        // Fees from first yield should be locked in
        uint256 feesAfterChange = wrapper.getClaimableFees();
        assertEq(feesAfterChange, feesAt10Percent, "Fees should be preserved after fee change");

        // Simulate more yield at 50% fee
        _simulateYieldPercent(1);

        uint256 feesAfterSecondYield = wrapper.getClaimableFees();
        uint256 secondYieldFees = feesAfterSecondYield - feesAfterChange;

        // Second yield should have higher fee percentage
        assertGt(secondYieldFees, feesAt10Percent, "Higher fee should generate more fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee reduction flow.
     */
    function test_feeFlow_reduceFee() public {
        // Start at 50% fee
        vm.prank(owner);
        wrapper.setFee(500_000);

        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        _simulateYieldPercent(1);
        uint256 feesAt50Percent = wrapper.getClaimableFees();

        // Reduce fee to 10%
        vm.prank(owner);
        wrapper.setFee(100_000);

        _simulateYieldPercent(1);
        uint256 totalFees = wrapper.getClaimableFees();
        uint256 feesAt10Percent = totalFees - feesAt50Percent;

        // Fees at lower rate should be smaller
        assertLt(feesAt10Percent, feesAt50Percent, "Lower fee rate should generate fewer fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee to zero flow.
     */
    function test_feeFlow_setFeeToZero() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate some fees
        _simulateYieldPercent(1);
        uint256 feesBefore = wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have fees before");

        // Set fee to zero
        vm.prank(owner);
        wrapper.setFee(0);

        // Existing fees preserved
        assertEq(wrapper.getClaimableFees(), feesBefore, "Existing fees preserved");

        // New yield generates no fees
        _simulateYieldPercent(1);
        assertEq(wrapper.getClaimableFees(), feesBefore, "No new fees with zero rate");

        _assertSolvent();
    }

    /**
     * @notice Tests fee from zero flow.
     */
    function test_feeFlow_setFeeFromZero() public {
        // Start at zero fee
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        _simulateYieldPercent(1);
        assertEq(wrapper.getClaimableFees(), 0, "No fees at zero rate");

        // Enable fee
        vm.prank(owner);
        wrapper.setFee(100_000);

        // Still no fees (yield already generated - rate was updated)
        assertEq(wrapper.getClaimableFees(), 0, "Previous yield not retroactively charged");

        // New yield generates fees
        _simulateYieldPercent(1);
        assertGt(wrapper.getClaimableFees(), 0, "New yield generates fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee at max flow.
     */
    function test_feeFlow_maxFeeImpact() public {
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        _simulateYieldPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should not change (all yield goes to fees)
        _assertApproxEq(totalAssetsAfter, totalAssetsBefore, 2, "No asset growth at max fee");

        // All yield should be fees (in sUSDS) - 1% yield with circuit breaker
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit) * 1 / 100;
        _assertApproxEq(_susdsToUsds(wrapper.getClaimableFees()), expectedYield, 2, "All yield is fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection and withdrawal flow.
     */
    function test_feeFlow_collectAndWithdraw() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Get claimable fees
        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have claimable fees");

        // Collect fees
        uint256 treasuryBalanceBefore = susds.balanceOf(treasury);
        vm.prank(owner);
        wrapper.collectFees();
        uint256 treasuryBalanceAfter = susds.balanceOf(treasury);

        // Treasury should receive fees in sUSDS
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, claimableFees, "Treasury should receive fees");

        // No more claimable fees
        assertEq(wrapper.getClaimableFees(), 0, "No fees after collection");

        // User can still withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests multiple fee collection cycles.
     */
    function test_feeFlow_multipleFeeCollections() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 totalFeesCollected;

        for (uint256 i = 0; i < 3; i++) {
            // Generate yield
            _simulateYieldPercent(1);

            // Get and collect fees
            uint256 fees = wrapper.getClaimableFees();
            if (fees > 0) {
                vm.prank(owner);
                wrapper.collectFees();
                totalFeesCollected += fees;
            }
        }

        // Treasury should have all fees
        assertEq(susds.balanceOf(treasury), totalFeesCollected, "Treasury should have all collected fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection after partial withdrawals.
     */
    function test_feeFlow_feeCollectionAfterPartialWithdrawals() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Partial withdrawal
        vm.prank(alphixHook);
        wrapper.withdraw(2_000e18, alphixHook, alphixHook);

        // Should still have fees
        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees after partial withdrawal");

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), claimableFees, "Treasury should receive fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee accrual across multiple users.
     */
    function test_feeFlow_feeAcrossMultipleUsers() public {
        address hook2 = makeAddr("hook2");
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Both hooks deposit
        _depositAsHook(5_000e18, alphixHook);

        usds.mint(hook2, 5_000e18);
        vm.startPrank(hook2);
        usds.approve(address(wrapper), 5_000e18);
        wrapper.deposit(5_000e18, hook2);
        vm.stopPrank();

        // Generate yield
        _simulateYieldPercent(1);

        // Fees should be based on total yield
        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees from total yield");

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Both users can still withdraw proportionally
        uint256 hook1Withdraw = wrapper.maxWithdraw(alphixHook);
        uint256 hook2Withdraw = wrapper.maxWithdraw(hook2);

        _assertApproxEq(hook1Withdraw, hook2Withdraw, 10, "Equal depositors should have equal withdrawable");

        _assertSolvent();
    }
}
