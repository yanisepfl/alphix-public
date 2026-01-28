// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title NegativeYieldFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for negative yield (slashing) flows.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract NegativeYieldFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test complete slash and recovery cycle.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent Initial yield percentage.
     * @param slashPercent Slash percentage.
     * @param recoveryPercent Recovery yield percentage.
     */
    function testFuzz_negativeYieldFlow_slashAndRecover(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent,
        uint256 recoveryPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 10, 50);
        slashPercent = bound(slashPercent, 10, 70);
        recoveryPercent = bound(recoveryPercent, 10, 50);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate initial yield
        _simulateYieldOnDeployment(d, yieldPercent);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = d.wrapper.getClaimableFees();
        assertGt(feesBeforeSlash, 0, "Should have fees before slash");

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSlash = d.wrapper.getClaimableFees();
        assertLt(feesAfterSlash, feesBeforeSlash, "Fees should be reduced by slash");

        uint256 totalAssetsAfterSlash = d.wrapper.totalAssets();

        // Recovery
        _simulateYieldOnDeployment(d, recoveryPercent);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterRecovery = d.wrapper.totalAssets();
        assertGt(totalAssetsAfterRecovery, totalAssetsAfterSlash, "Should recover with yield");

        // Final solvency check
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test multiple slash events.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param slashPercents Array of slash percentages.
     */
    function testFuzz_negativeYieldFlow_multipleSlashes(
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

        for (uint256 i = 0; i < slashPercents.length; i++) {
            uint256 slashPercent = bound(slashPercents[i], 5, 25);
            uint256 balance = d.aToken.balanceOf(address(d.wrapper));

            if (balance > 0) {
                d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);
                vm.prank(owner);
                d.wrapper.setFee(DEFAULT_FEE);

                // Verify solvency after each slash
                uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
                uint256 totalAssets = d.wrapper.totalAssets();
                uint256 claimableFees = d.wrapper.getClaimableFees();
                assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency after slash");
            }
        }
    }

    /**
     * @notice Fuzz test slash with fee collection.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent Yield percentage.
     * @param slashPercent Slash percentage.
     */
    function testFuzz_negativeYieldFlow_slashWithFeeCollection(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 10, 50);
        slashPercent = bound(slashPercent, 10, 60);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

        // Get reduced fees
        uint256 feesAfterSlash = d.wrapper.getClaimableFees();

        // Collect fees
        vm.prank(owner);
        d.wrapper.collectFees();

        // Verify collection
        assertEq(d.aToken.balanceOf(treasury), feesAfterSlash, "Should collect reduced fees");
        assertEq(d.wrapper.getClaimableFees(), 0, "Fees should be zero");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All balance is user assets");
    }
}
