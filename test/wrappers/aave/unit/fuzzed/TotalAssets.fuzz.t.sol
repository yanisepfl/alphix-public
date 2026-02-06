// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title TotalAssetsFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave totalAssets function.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract TotalAssetsFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that totalAssets increases after deposit.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     */
    function testFuzz_totalAssets_increasesAfterDeposit(uint8 decimals, uint256 depositMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        uint256 totalAssetsBefore = d.wrapper.totalAssets();

        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 totalAssetsAfter = d.wrapper.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore + depositAmount, "Total assets should increase by deposit");
    }

    /**
     * @notice Fuzz test that totalAssets equals aToken minus fees.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_totalAssets_equalsATokenMinusFees(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 0, 100);

        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        if (yieldPercent > 0) {
            _simulateYieldOnDeployment(d, yieldPercent);
        }

        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 claimableFees = d.wrapper.getClaimableFees();
        uint256 totalAssets = d.wrapper.totalAssets();

        assertEq(totalAssets, aTokenBalance - claimableFees, "totalAssets should equal aToken - fees");
    }

    /**
     * @notice Fuzz test that totalAssets reflects correct net yield based on fee.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param feeRate The fee rate.
     */
    function testFuzz_totalAssets_netYieldCorrect(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint24 feeRate
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 50);
        feeRate = _boundFee(feeRate);

        vm.prank(owner);
        d.wrapper.setFee(feeRate);

        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 totalAssetsBefore = d.wrapper.totalAssets();

        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 totalAssetsAfter = d.wrapper.totalAssets();

        // With higher fee, less yield goes to totalAssets
        if (feeRate == MAX_FEE) {
            assertEq(totalAssetsAfter, totalAssetsBefore, "No yield with max fee");
        } else {
            assertGt(totalAssetsAfter, totalAssetsBefore, "Should have positive yield with fee < 100%");
        }
    }

    /**
     * @notice Fuzz test totalAssets with multiple deposits.
     * @param decimals The asset decimals (6-18).
     * @param depositMultipliers Array of deposit amount multipliers.
     */
    function testFuzz_totalAssets_multipleDeposits(uint8 decimals, uint256[5] memory depositMultipliers) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 expectedTotal = d.seedLiquidity;

        for (uint256 i = 0; i < depositMultipliers.length; i++) {
            depositMultipliers[i] = bound(depositMultipliers[i], 1, 100_000_000);
            uint256 depositAmount = depositMultipliers[i] * 10 ** d.decimals;
            expectedTotal += depositAmount;

            d.asset.mint(alphixHook, depositAmount);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), depositAmount);
            d.wrapper.deposit(depositAmount, alphixHook);
            vm.stopPrank();
        }

        assertEq(d.wrapper.totalAssets(), expectedTotal, "Total should match sum of deposits");
    }
}
