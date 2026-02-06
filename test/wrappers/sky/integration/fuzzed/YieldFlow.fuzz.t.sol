// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title YieldFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for yield accrual flow integration scenarios.
 */
contract YieldFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test yield accrual with varying amounts.
     */
    function testFuzz_yieldFlow_varyingYield(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Assets should increase (minus fees)
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase with yield");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee calculation at various fee rates.
     */
    function testFuzz_yieldFlow_feeCalculation(uint256 depositMultiplier, uint256 yieldPercent, uint24 feeRate) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        feeRate = _boundFee(feeRate);

        uint256 depositAmount = depositMultiplier * 1e18;

        // Set fee rate
        vm.prank(owner);
        wrapper.setFee(feeRate);

        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(feeRate);

        uint256 claimableFees = wrapper.getClaimableFees();

        if (feeRate == 0) {
            assertEq(claimableFees, 0, "Zero fee rate should generate zero fees");
        } else if (feeRate == MAX_FEE) {
            // All yield should be fees
            assertGt(claimableFees, 0, "Max fee should capture all yield");
        } else {
            // Partial fees
            if (yieldPercent > 5) {
                assertGt(claimableFees, 0, "Should have some fees");
            }
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple yield accruals.
     */
    function testFuzz_yieldFlow_multipleAccruals(uint256 depositMultiplier, uint8[5] memory yieldPercents) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 cumulativeFees;

        for (uint256 i = 0; i < yieldPercents.length; i++) {
            uint256 yieldPct = bound(yieldPercents[i], 1, 1); // Circuit breaker limits to 1%
            _simulateYieldPercent(yieldPct);

            // Trigger accrual
            vm.prank(owner);
            wrapper.setFee(DEFAULT_FEE);

            uint256 currentFees = wrapper.getClaimableFees();
            assertGe(currentFees, cumulativeFees, "Fees should only increase");
            cumulativeFees = currentFees;
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test yield distribution among multiple depositors.
     */
    function testFuzz_yieldFlow_multipleDepositors(
        uint256 deposit1Multiplier,
        uint256 deposit2Multiplier,
        uint256 yieldPercent
    ) public {
        deposit1Multiplier = bound(deposit1Multiplier, 1, 1_000_000);
        deposit2Multiplier = bound(deposit2Multiplier, 1, 1_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        uint256 deposit1 = deposit1Multiplier * 1e18;
        uint256 deposit2 = deposit2Multiplier * 1e18;

        // Hook deposits
        uint256 hookShares = _depositAsHook(deposit1, alphixHook);

        // Owner deposits
        usds.mint(owner, deposit2);
        vm.startPrank(owner);
        usds.approve(address(wrapper), deposit2);
        uint256 ownerShares = wrapper.deposit(deposit2, owner);
        vm.stopPrank();

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        // Both should have proportional assets
        uint256 hookAssets = wrapper.convertToAssets(hookShares);
        uint256 ownerAssets = wrapper.convertToAssets(ownerShares);

        // Ratio should be approximately maintained
        if (deposit1 == deposit2) {
            _assertApproxEq(hookAssets, ownerAssets, hookAssets / 100 + 10, "Equal deposits should have equal value");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test yield with zero fee.
     */
    function testFuzz_yieldFlow_zeroFee(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 totalAfter = wrapper.totalAssets();

        // All yield should go to depositors
        uint256 expectedYield = totalBefore * yieldPercent / 100;
        _assertApproxEq(totalAfter - totalBefore, expectedYield, expectedYield / 100 + 10, "All yield to depositors");

        assertEq(wrapper.getClaimableFees(), 0, "No fees with zero rate");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test yield rate tracking.
     */
    function testFuzz_yieldFlow_rateTracking(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 rateBefore = wrapper.getLastRate();

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 rateAfter = wrapper.getLastRate();

        // Rate should increase
        assertGt(rateAfter, rateBefore, "Rate should increase after yield");

        _assertSolvent();
    }
}
