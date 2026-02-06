// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title FeeFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for fee management flows.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract FeeFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test fee change mid-stream.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param initialFee Initial fee rate.
     * @param newFee New fee rate.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_feeFlow_changeFeeMidStream(
        uint8 decimals,
        uint256 depositMultiplier,
        uint24 initialFee,
        uint24 newFee,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        initialFee = _boundFee(initialFee);
        newFee = _boundFee(newFee);
        yieldPercent = bound(yieldPercent, 1, 50);

        // Set initial fee
        vm.prank(owner);
        d.wrapper.setFee(initialFee);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Simulate yield at initial fee
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 feesAtInitialRate = d.wrapper.getClaimableFees();

        // Change fee
        vm.prank(owner);
        d.wrapper.setFee(newFee);

        // Fees from first yield should be preserved
        uint256 feesAfterChange = d.wrapper.getClaimableFees();
        assertEq(feesAfterChange, feesAtInitialRate, "Fees should be preserved after fee change");

        // Simulate more yield at new fee
        _simulateYieldOnDeployment(d, yieldPercent);

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test fee reduction flow.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param highFee High fee rate.
     * @param lowFee Low fee rate.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_feeFlow_reduceFee(
        uint8 decimals,
        uint256 depositMultiplier,
        uint24 highFee,
        uint24 lowFee,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        highFee = uint24(bound(highFee, 300_000, MAX_FEE)); // 30-100%
        lowFee = uint24(bound(lowFee, 10_000, 200_000)); // 1-20%
        yieldPercent = bound(yieldPercent, 5, 50);

        // Start at high fee
        vm.prank(owner);
        d.wrapper.setFee(highFee);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);
        uint256 feesAtHighRate = d.wrapper.getClaimableFees();

        // Reduce fee
        vm.prank(owner);
        d.wrapper.setFee(lowFee);

        _simulateYieldOnDeployment(d, yieldPercent);
        uint256 totalFees = d.wrapper.getClaimableFees();

        // Note: We removed the assertLt because with fee-owned aToken yield attribution,
        // the fee portion compounds at 100% regardless of fee rate. When lowFee period starts,
        // the accumulated fee portion from highFee period earns yield at 100% + lowFee% on user portion.
        // This can result in higher absolute fees at lower rate when fee base is larger.
        // The key invariant is that fees always increase (totalFees > feesAtHighRate).
        assertGt(totalFees, feesAtHighRate, "Total fees should increase after more yield");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test set fee to zero flow.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_feeFlow_setFeeToZero(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 5, 50);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate some fees
        _simulateYieldOnDeployment(d, yieldPercent);
        uint256 feesBefore = d.wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have fees before");

        // Set fee to zero
        vm.prank(owner);
        d.wrapper.setFee(0);

        // Existing fees preserved
        assertEq(d.wrapper.getClaimableFees(), feesBefore, "Existing fees preserved");

        // New yield: fee portion still earns yield even at 0% user fee rate
        // (fee-owned aTokens compound 100% to fees)
        _simulateYieldOnDeployment(d, yieldPercent);
        assertGe(d.wrapper.getClaimableFees(), feesBefore, "Fee portion earns yield even at zero rate");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test set fee from zero flow.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param newFee New fee rate.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_feeFlow_setFeeFromZero(
        uint8 decimals,
        uint256 depositMultiplier,
        uint24 newFee,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        newFee = uint24(bound(newFee, 100, MAX_FEE)); // Ensure newFee >= 0.01% to avoid precision loss
        yieldPercent = bound(yieldPercent, 5, 50);

        // Start at zero fee
        vm.prank(owner);
        d.wrapper.setFee(0);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);
        assertEq(d.wrapper.getClaimableFees(), 0, "No fees at zero rate");

        // Enable fee
        vm.prank(owner);
        d.wrapper.setFee(newFee);

        // Still no fees (yield already generated)
        assertEq(d.wrapper.getClaimableFees(), 0, "Previous yield not retroactively charged");

        // New yield generates fees
        _simulateYieldOnDeployment(d, yieldPercent);
        assertGt(d.wrapper.getClaimableFees(), 0, "New yield generates fees");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test max fee impact.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_feeFlow_maxFeeImpact(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 10, 100);

        vm.prank(owner);
        d.wrapper.setFee(MAX_FEE);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 totalAssetsBefore = d.wrapper.totalAssets();

        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 totalAssetsAfter = d.wrapper.totalAssets();

        // Total assets should not change (all yield goes to fees)
        assertEq(totalAssetsAfter, totalAssetsBefore, "No asset growth at max fee");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssetsAfter + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test multiple fee changes.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param fees Array of fee rates to cycle through.
     */
    function testFuzz_feeFlow_multipleFeeChanges(uint8 decimals, uint256 depositMultiplier, uint24[4] memory fees)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        for (uint256 i = 0; i < fees.length; i++) {
            fees[i] = _boundFee(fees[i]);

            vm.prank(owner);
            d.wrapper.setFee(fees[i]);

            // Generate yield at this fee rate
            _simulateYieldOnDeployment(d, 10);

            // Verify solvency after each change
            uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
            uint256 totalAssets = d.wrapper.totalAssets();
            uint256 claimableFees = d.wrapper.getClaimableFees();
            assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
        }
    }
}
