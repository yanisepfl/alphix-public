// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title NegativeYieldFuzzTest
 * @author Alphix
 * @notice Fuzz tests for negative yield (slashing) handling.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract NegativeYieldFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that fees are reduced proportionally to slash.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_negativeYield_feesReducedProportionally(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);
        slashPercent = bound(slashPercent, 1, 90); // Max 90% slash

        // Deposit and generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = d.wrapper.getClaimableFees();

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        uint256 slashAmount = balance * slashPercent / 100;
        d.aToken.simulateSlash(address(d.wrapper), slashAmount);

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfter = d.wrapper.getClaimableFees();
        uint256 expectedFees = feesBefore * (100 - slashPercent) / 100;

        // Allow for rounding
        _assertApproxEq(feesAfter, expectedFees, 2, "Fees should be reduced proportionally");
    }

    /**
     * @notice Fuzz test that solvency is maintained after slash.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_negativeYield_maintainsSolvency(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 0, 100);
        slashPercent = bound(slashPercent, 1, 95);

        // Deposit and optionally generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        if (yieldPercent > 0) {
            _simulateYieldOnDeployment(d, yieldPercent);
        }

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

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
     * @notice Fuzz test that totalAssets is correct after slash.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_negativeYield_totalAssetsCorrect(uint8 decimals, uint256 depositMultiplier, uint256 slashPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        slashPercent = bound(slashPercent, 1, 90);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate yield to have fees
        _simulateYieldOnDeployment(d, 20);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

        // totalAssets should equal aToken - fees
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 claimableFees = d.wrapper.getClaimableFees();
        uint256 totalAssets = d.wrapper.totalAssets();

        assertEq(totalAssets, aTokenBalance - claimableFees, "totalAssets incorrect");
    }

    /**
     * @notice Fuzz test multiple slashes.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param slashPercents Array of slash percentages.
     */
    function testFuzz_negativeYield_multipleSlashes(
        uint8 decimals,
        uint256 depositMultiplier,
        uint8[3] memory slashPercents
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate initial yield
        _simulateYieldOnDeployment(d, 50);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        for (uint256 i = 0; i < 3; i++) {
            uint256 slashPercent = bound(slashPercents[i], 1, 30);
            uint256 balance = d.aToken.balanceOf(address(d.wrapper));

            if (balance > 0) {
                d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);
                vm.prank(owner);
                d.wrapper.setFee(DEFAULT_FEE);
            }
        }

        // Verify solvency after multiple slashes
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();

        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated after multiple slashes");
    }

    /**
     * @notice Fuzz test slash followed by yield recovery.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param slashPercent The slash percentage.
     * @param recoveryYield The recovery yield percentage.
     */
    function testFuzz_negativeYield_recovery(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 recoveryYield
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        slashPercent = bound(slashPercent, 10, 80);
        recoveryYield = bound(recoveryYield, 1, 100);

        // Deposit and generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, 20);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterSlash = d.wrapper.totalAssets();

        // Recovery yield
        _simulateYieldOnDeployment(d, recoveryYield);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterRecovery = d.wrapper.totalAssets();

        assertGt(totalAssetsAfterRecovery, totalAssetsAfterSlash, "Should recover with new yield");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(d.wrapper.totalAssets() + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test that view function matches state after accrual.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_negativeYield_viewMatchesState(uint8 decimals, uint256 depositMultiplier, uint256 slashPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        slashPercent = bound(slashPercent, 1, 90);

        // Deposit and generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, 30);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

        // View should reflect pending slash
        uint256 viewFeesBefore = d.wrapper.getClaimableFees();

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterAccrual = d.wrapper.getClaimableFees();

        // View before should match state after
        assertEq(viewFeesBefore, feesAfterAccrual, "View should match state after accrual");
    }
}
