// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title YieldAccrualFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave yield accrual mechanism.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract YieldAccrualFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that yield accrual maintains solvency.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_yieldAccrual_maintainsSolvency(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 0, 1000); // Up to 1000% yield

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Simulate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();

        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test that fees are calculated correctly.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param feeRate The fee rate.
     */
    function testFuzz_yieldAccrual_feesCorrect(
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

        uint256 balanceBefore = d.aToken.balanceOf(address(d.wrapper));

        // Simulate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 balanceAfter = d.aToken.balanceOf(address(d.wrapper));
        uint256 actualYield = balanceAfter - balanceBefore;

        // Check claimable fees
        uint256 claimableFees = d.wrapper.getClaimableFees();
        uint256 expectedFees = actualYield * feeRate / MAX_FEE;

        _assertApproxEq(claimableFees, expectedFees, 1, "Fees should match expected");
    }

    /**
     * @notice Fuzz test that totalAssets reflects correct net yield.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param feeRate The fee rate.
     */
    function testFuzz_yieldAccrual_totalAssetsCorrect(
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

        // Simulate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 totalAssetsAfter = d.wrapper.totalAssets();

        // Total assets should increase by yield minus fees
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 claimableFees = d.wrapper.getClaimableFees();

        assertEq(totalAssetsAfter, aTokenBalance - claimableFees, "totalAssets should equal aToken - fees");
        assertGe(totalAssetsAfter, totalAssetsBefore, "totalAssets should not decrease");
    }

    /**
     * @notice Fuzz test multiple yield accruals.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercents Array of yield percentages.
     */
    function testFuzz_yieldAccrual_multiple(uint8 decimals, uint256 depositMultiplier, uint256[5] memory yieldPercents)
        public
    {
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

        for (uint256 i = 0; i < yieldPercents.length; i++) {
            yieldPercents[i] = bound(yieldPercents[i], 0, 20);

            if (yieldPercents[i] > 0) {
                _simulateYieldOnDeployment(d, yieldPercents[i]);
            }

            // Trigger accrual with small deposit
            uint256 smallDeposit = 10 ** d.decimals;
            d.asset.mint(alphixHook, smallDeposit);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), smallDeposit);
            d.wrapper.deposit(smallDeposit, alphixHook);
            vm.stopPrank();

            uint256 currentTotalAssets = d.wrapper.totalAssets();
            assertGe(currentTotalAssets, previousTotalAssets, "totalAssets should not decrease");
            previousTotalAssets = currentTotalAssets;

            // Verify solvency
            uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
            uint256 totalAssets = d.wrapper.totalAssets();
            uint256 claimableFees = d.wrapper.getClaimableFees();
            assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
        }
    }
}
