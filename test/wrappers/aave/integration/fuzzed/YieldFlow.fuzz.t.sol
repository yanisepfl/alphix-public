// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title YieldFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for yield flows.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract YieldFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test complete yield cycle.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param feeRate The fee rate.
     */
    function testFuzz_yieldFlow_completeCycle(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint24 feeRate
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);
        feeRate = _boundFee(feeRate);

        // Set fee
        vm.prank(owner);
        d.wrapper.setFee(feeRate);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 totalAssetsBefore = d.wrapper.totalAssets();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 totalAssetsAfter = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();

        // With fee < 100%, user assets should increase
        if (feeRate < MAX_FEE) {
            assertGt(totalAssetsAfter, totalAssetsBefore, "Assets should increase");
        }

        // Fees should be proportional to yield and fee rate
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        assertEq(totalAssetsAfter + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test multiple yield cycles.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercents Array of yield percentages.
     */
    function testFuzz_yieldFlow_multipleCycles(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256[5] memory yieldPercents
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 previousTotalAssets = d.wrapper.totalAssets();
        uint256 previousFees;

        for (uint256 i = 0; i < yieldPercents.length; i++) {
            yieldPercents[i] = bound(yieldPercents[i], 1, 20);

            // Generate yield
            _simulateYieldOnDeployment(d, yieldPercents[i]);

            // Trigger accrual
            vm.prank(owner);
            d.wrapper.setFee(DEFAULT_FEE);

            uint256 currentTotalAssets = d.wrapper.totalAssets();
            uint256 currentFees = d.wrapper.getClaimableFees();

            // Assets should increase with yield
            assertGe(currentTotalAssets, previousTotalAssets, "Assets should not decrease");
            // Fees should accumulate
            assertGe(currentFees, previousFees, "Fees should accumulate");

            previousTotalAssets = currentTotalAssets;
            previousFees = currentFees;

            // Solvency check
            uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
            assertEq(currentTotalAssets + currentFees, aTokenBalance, "Solvency maintained");
        }
    }

    /**
     * @notice Fuzz test yield with varying fee rates.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param feeRates Array of fee rates.
     * @param yieldPercent The yield percentage per cycle.
     */
    function testFuzz_yieldFlow_varyingFees(
        uint8 decimals,
        uint256 depositMultiplier,
        uint24[3] memory feeRates,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 5, 20);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        for (uint256 i = 0; i < feeRates.length; i++) {
            feeRates[i] = _boundFee(feeRates[i]);

            // Set new fee
            vm.prank(owner);
            d.wrapper.setFee(feeRates[i]);

            // Generate yield
            _simulateYieldOnDeployment(d, yieldPercent);

            // Verify solvency
            uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
            uint256 totalAssets = d.wrapper.totalAssets();
            uint256 claimableFees = d.wrapper.getClaimableFees();
            assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
        }
    }
}
