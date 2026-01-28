// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title YieldFlowTest
 * @author Alphix
 * @notice Integration tests for yield accrual flows.
 * @dev Sky-specific: yield comes from sUSDS rate appreciation (via rate provider)
 */
contract YieldFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests complete yield flow with deposits and fee calculations.
     */
    function test_yieldFlow_completeScenario() public {
        // Initial deposit
        uint256 deposit1 = 10_000e18;
        _depositAsHook(deposit1, alphixHook);

        uint256 totalAfterDeposit = wrapper.totalAssets();
        assertApproxEqAbs(totalAfterDeposit, DEFAULT_SEED_LIQUIDITY + deposit1, 2, "Total should be seed + deposit");

        // Simulate 1% yield (rate increase, respects circuit breaker)
        _simulateYieldPercent(1);

        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit1) * 1 / 100;

        // Yield generated: sUSDS is now worth 1% more in USDS terms
        uint256 valueInUsds = _susdsToUsds(susdsBalance);
        assertGt(valueInUsds, totalAfterDeposit, "sUSDS value should increase");

        // Check claimable fees (calculated on-the-fly)
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 expectedFees = expectedYield * DEFAULT_FEE / MAX_FEE;

        _assertApproxEq(claimableFees, _usdsToSusds(expectedFees), 2, "Claimable fees should match expected");

        // Total assets should reflect net yield
        uint256 expectedTotalAssets = _susdsToUsds(susdsBalance - claimableFees);
        _assertApproxEq(wrapper.totalAssets(), expectedTotalAssets, 2, "Total assets should be sUSDS value - fees");

        // Trigger accrual via deposit
        _depositAsHook(1_000e18, alphixHook);

        // Fees should still be accumulated
        assertGt(wrapper.getClaimableFees(), 0, "Fees should be accumulated after accrual");

        _assertSolvent();
    }

    /**
     * @notice Tests yield distribution between depositors.
     */
    function test_yieldFlow_multipleDepositors() public {
        // First depositor (hook) deposits
        uint256 hookDeposit = 10_000e18;
        uint256 hookShares = _depositAsHook(hookDeposit, alphixHook);

        // Second depositor (owner) deposits
        uint256 ownerDeposit = 10_000e18;
        usds.mint(owner, ownerDeposit);
        vm.startPrank(owner);
        usds.approve(address(wrapper), ownerDeposit);
        uint256 ownerShares = wrapper.deposit(ownerDeposit, owner);
        vm.stopPrank();

        // Simulate 1% yield (respects circuit breaker)
        _simulateYieldPercent(1);

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

        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Simulate 1% yield (respects circuit breaker)
        _simulateYieldPercent(1);

        uint256 totalAfter = wrapper.totalAssets();
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit) * 1 / 100;

        // All yield should go to depositors
        _assertApproxEq(totalAfter - totalBefore, expectedYield, 2, "All yield should go to depositors");
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

        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Simulate 1% yield (respects circuit breaker)
        _simulateYieldPercent(1);

        uint256 totalAfter = wrapper.totalAssets();

        // No yield should go to depositors
        _assertApproxEq(totalAfter, totalBefore, 2, "No yield with max fee");

        // All yield should be fees
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit) * 1 / 100;
        _assertApproxEq(_susdsToUsds(wrapper.getClaimableFees()), expectedYield, 2, "All yield should be fees");

        _assertSolvent();
    }

    /**
     * @notice Tests multiple yield accruals.
     */
    function test_yieldFlow_multipleAccruals() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 cumulativeFees;

        // Multiple yield cycles
        for (uint256 i = 0; i < 5; i++) {
            _simulateYieldPercent(1);

            // Trigger accrual with small deposit
            _depositAsHook(100e18, alphixHook);

            uint256 currentFees = wrapper.getClaimableFees();
            assertGt(currentFees, cumulativeFees, "Fees should accumulate");
            cumulativeFees = currentFees;
        }

        _assertSolvent();
    }

    /**
     * @notice Tests yield tracking via rate changes.
     */
    function test_yieldFlow_rateTracking() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 initialRate = wrapper.getLastRate();
        assertEq(initialRate, INITIAL_RATE, "Initial rate should be 1:1");

        // Simulate 1% yield (respects circuit breaker)
        _simulateYieldPercent(1);

        // Rate should update after accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE); // Trigger accrual

        uint256 newRate = wrapper.getLastRate();
        assertGt(newRate, initialRate, "Rate should increase after yield");
        assertEq(newRate, INITIAL_RATE * 101 / 100, "Rate should be 1.01x");

        _assertSolvent();
    }

    /**
     * @notice Tests compound yield over multiple periods.
     */
    function test_yieldFlow_compoundYield() public {
        uint256 deposit = 10_000e18;
        _depositAsHook(deposit, alphixHook);

        uint256 totalBeforeYield = wrapper.totalAssets();

        // Multiple small yield periods
        for (uint256 i = 0; i < 10; i++) {
            _simulateYieldPercent(1); // 1% each time
        }

        uint256 totalAfterYield = wrapper.totalAssets();

        // Should have accumulated compound yield (minus fees)
        uint256 yieldReceived = totalAfterYield - totalBeforeYield;
        assertGt(yieldReceived, 0, "Should have compound yield");

        // Compound 1% x 10 is about 10.46%, so net yield after 10% fee is about 9.4%
        uint256 minExpectedYield = totalBeforeYield * 8 / 100; // Conservative estimate
        assertGt(yieldReceived, minExpectedYield, "Compound yield should be significant");

        _assertSolvent();
    }

    /**
     * @notice Tests yield with deposit mid-period.
     */
    function test_yieldFlow_depositMidPeriod() public {
        // First deposit
        uint256 deposit1 = 5_000e18;
        _depositAsHook(deposit1, alphixHook);

        // Partial yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Second deposit (joins mid-yield-period)
        uint256 deposit2 = 5_000e18;
        uint256 shares2 = _depositAsHook(deposit2, alphixHook);

        // More yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Second depositor should get less yield per share
        uint256 valueOfShares2 = wrapper.convertToAssets(shares2);

        // Should be close to deposit2 + 1% yield (second period only)
        // minus fees
        assertLt(valueOfShares2, deposit2 * 110 / 100, "Should have accumulated yield");
        assertGt(valueOfShares2, deposit2, "Should have some yield");

        _assertSolvent();
    }
}
