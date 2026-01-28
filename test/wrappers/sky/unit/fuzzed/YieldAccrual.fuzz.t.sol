// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title YieldAccrualFuzzTest
 * @author Alphix
 * @notice Fuzz tests for yield accrual in the Alphix4626WrapperSky.
 * @dev Tests that yield is correctly calculated based on rate changes.
 */
contract YieldAccrualFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test yield accrual with varying deposit and yield amounts.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage (1%, limited by circuit breaker).
     */
    function testFuzz_yieldAccrual_varyingAmounts(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should increase (yield minus fees)
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test that fees are correctly calculated on yield.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage (1%, limited by circuit breaker).
     * @param fee The fee rate (0 to MAX_FEE).
     */
    function testFuzz_yieldAccrual_feeCalculation(uint256 depositMultiplier, uint256 yieldPercent, uint24 fee) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        fee = _boundFee(fee);
        uint256 depositAmount = depositMultiplier * 1e18;

        // Set fee
        vm.prank(owner);
        wrapper.setFee(fee);

        _depositAsHook(depositAmount, alphixHook);

        uint256 claimableFeesBefore = wrapper.getClaimableFees();

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFeesAfter = wrapper.getClaimableFees();

        if (fee > 0) {
            assertGt(claimableFeesAfter, claimableFeesBefore, "Fees should increase with yield");
        } else {
            assertEq(claimableFeesAfter, 0, "No fees should accrue with 0% fee");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple yield accruals.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yields Array of yield percentages.
     */
    function testFuzz_yieldAccrual_multipleAccruals(uint256 depositMultiplier, uint8[5] memory yields) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsPrevious = wrapper.totalAssets();

        for (uint256 i = 0; i < yields.length; i++) {
            uint256 yieldPercent = bound(yields[i], 1, 20);
            _simulateYieldPercent(yieldPercent);

            uint256 totalAssetsNow = wrapper.totalAssets();
            assertGe(totalAssetsNow, totalAssetsPrevious, "Assets should not decrease with positive yield");
            totalAssetsPrevious = totalAssetsNow;
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test that zero fee results in all yield going to depositors.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage (1%, limited by circuit breaker).
     */
    function testFuzz_yieldAccrual_zeroFee(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // No fees should accumulate
        assertEq(wrapper.getClaimableFees(), 0, "No fees with 0% fee");

        // All yield goes to depositors
        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();

        // Total assets should equal the full sUSDS value
        uint256 expectedAssets = _susdsToUsds(susdsBalance);
        _assertApproxEq(totalAssets, expectedAssets, 2, "All yield should go to depositors");
    }

    /**
     * @notice Fuzz test that max fee results in all yield going to fees.
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage (1%, limited by circuit breaker).
     */
    function testFuzz_yieldAccrual_maxFee(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        // Set fee to max (100%)
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        _depositAsHook(depositAmount, alphixHook);
        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Total assets should remain approximately the same (all yield taken as fee)
        uint256 totalAssetsAfter = wrapper.totalAssets();
        _assertApproxEq(totalAssetsAfter, totalAssetsBefore, 1e15, "No yield to depositors with 100% fee");

        // Should have claimable fees
        assertGt(wrapper.getClaimableFees(), 0, "Should have claimable fees");
    }

    /**
     * @notice Fuzz test yield accrual triggered by deposit.
     * @param initialDeposit Initial deposit amount.
     * @param yieldPercent Yield percentage (1%, limited by circuit breaker).
     * @param secondDeposit Second deposit amount.
     */
    function testFuzz_yieldAccrual_triggeredByDeposit(
        uint256 initialDeposit,
        uint256 yieldPercent,
        uint256 secondDeposit
    ) public {
        initialDeposit = bound(initialDeposit, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        secondDeposit = bound(secondDeposit, 1, 100_000_000);

        uint256 amount1 = initialDeposit * 1e18;
        uint256 amount2 = secondDeposit * 1e18;

        // First deposit
        _depositAsHook(amount1, alphixHook);

        // Simulate yield (not yet accrued)
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFeesBefore = wrapper.getClaimableFees();

        // Second deposit triggers accrual
        usds.mint(alphixHook, amount2);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount2);
        wrapper.deposit(amount2, alphixHook);
        vm.stopPrank();

        // Fees should have been accrued during deposit
        uint256 claimableFeesAfter = wrapper.getClaimableFees();
        assertGe(claimableFeesAfter, claimableFeesBefore, "Fees should be accrued on deposit");
    }

    /**
     * @notice Fuzz test yield accrual with rate changes.
     * @param depositMultiplier Deposit amount.
     * @param rateMultiplier New rate as percentage of initial (110 = 1.1x, 200 = 2x).
     */
    function testFuzz_yieldAccrual_rateChanges(uint256 depositMultiplier, uint256 rateMultiplier) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        rateMultiplier = bound(rateMultiplier, 101, 101); // 1.01x (circuit breaker limits to 1%)
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 lastRateBefore = wrapper.getLastRate();

        // Set new rate
        uint256 newRate = INITIAL_RATE * rateMultiplier / 100;
        _setRate(newRate);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfter = wrapper.totalAssets();
        uint256 lastRateAfter = wrapper.getLastRate();

        assertGt(totalAssetsAfter, totalAssetsBefore, "Assets should increase with rate");
        assertGt(lastRateAfter, lastRateBefore, "Last rate should update");
        _assertSolvent();
    }
}
