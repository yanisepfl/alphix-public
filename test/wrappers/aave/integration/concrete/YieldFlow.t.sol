// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title YieldFlowTest
 * @author Alphix
 * @notice Integration tests for yield accrual flows.
 */
contract YieldFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests complete yield flow with deposits and fee calculations.
     */
    function test_yieldFlow_completeScenario() public {
        // Initial deposit
        uint256 deposit1 = 10_000e6;
        _depositAsHook(deposit1, alphixHook);

        uint256 totalAfterDeposit = wrapper.totalAssets();
        assertEq(totalAfterDeposit, DEFAULT_SEED_LIQUIDITY + deposit1, "Total should be seed + deposit");

        // Simulate 20% yield
        _simulateYieldPercent(20);

        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit1) * 20 / 100;

        // Yield generated but not yet accrued
        assertGt(aTokenBalance, totalAfterDeposit, "aToken balance should increase");

        // Check claimable fees (calculated on-the-fly)
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 expectedFees = expectedYield * DEFAULT_FEE / MAX_FEE;

        _assertApproxEq(claimableFees, expectedFees, 1, "Claimable fees should match expected");

        // Total assets should reflect net yield
        uint256 expectedTotalAssets = aTokenBalance - claimableFees;
        assertEq(wrapper.totalAssets(), expectedTotalAssets, "Total assets should be aToken - fees");

        // Trigger accrual via deposit
        _depositAsHook(1_000e6, alphixHook);

        // Fees should still be accumulated
        assertGt(wrapper.getClaimableFees(), 0, "Fees should be accumulated after accrual");

        _assertSolvent();
    }

    /**
     * @notice Tests yield distribution between depositors.
     */
    function test_yieldFlow_multipleDepositors() public {
        // First depositor (hook) deposits
        uint256 hookDeposit = 10_000e6;
        uint256 hookShares = _depositAsHook(hookDeposit, alphixHook);

        // Second depositor (owner) deposits
        uint256 ownerDeposit = 10_000e6;
        asset.mint(owner, ownerDeposit);
        vm.startPrank(owner);
        asset.approve(address(wrapper), ownerDeposit);
        uint256 ownerShares = wrapper.deposit(ownerDeposit, owner);
        vm.stopPrank();

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Check each depositor's share of assets
        uint256 hookAssets = wrapper.convertToAssets(hookShares);
        uint256 ownerAssets = wrapper.convertToAssets(ownerShares);

        // Both should have increased proportionally (accounting for seed deposit)
        assertGt(hookAssets, hookDeposit * 99 / 100, "Hook assets should have grown");
        assertGt(ownerAssets, ownerDeposit * 99 / 100, "Owner assets should have grown");

        _assertSolvent();
    }

    /**
     * @notice Tests yield flow with zero fee.
     */
    function test_yieldFlow_zeroFee() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 totalAfter = wrapper.totalAssets();
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit) * 10 / 100;

        // All yield should go to depositors
        _assertApproxEq(totalAfter - totalBefore, expectedYield, 1, "All yield should go to depositors");
        assertEq(wrapper.getClaimableFees(), 0, "No fees with zero fee rate");

        _assertSolvent();
    }

    /**
     * @notice Tests yield flow with max fee.
     */
    function test_yieldFlow_maxFee() public {
        // Set fee to 100%
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 totalAfter = wrapper.totalAssets();

        // No yield should go to depositors
        assertEq(totalAfter, totalBefore, "No yield with max fee");

        // All yield should be fees
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit) * 10 / 100;
        _assertApproxEq(wrapper.getClaimableFees(), expectedYield, 1, "All yield should be fees");

        _assertSolvent();
    }

    /**
     * @notice Tests multiple yield accruals.
     */
    function test_yieldFlow_multipleAccruals() public {
        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        uint256 cumulativeFees;

        // Multiple yield cycles
        for (uint256 i = 0; i < 5; i++) {
            _simulateYieldPercent(5);

            // Trigger accrual with small deposit
            _depositAsHook(100e6, alphixHook);

            uint256 currentFees = wrapper.getClaimableFees();
            assertGt(currentFees, cumulativeFees, "Fees should accumulate");
            cumulativeFees = currentFees;
        }

        _assertSolvent();
    }
}
