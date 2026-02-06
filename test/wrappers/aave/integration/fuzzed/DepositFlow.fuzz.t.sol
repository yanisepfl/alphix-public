// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title DepositFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for deposit flows.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract DepositFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test complete deposit flow with various parameters.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     */
    function testFuzz_depositFlow_complete(uint8 decimals, uint256 depositMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Record initial state
        uint256 initialTotalAssets = d.wrapper.totalAssets();
        uint256 initialSupply = d.wrapper.totalSupply();

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        uint256 shares = d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Verify deposit results
        assertGt(shares, 0, "Should receive shares");
        assertEq(d.wrapper.balanceOf(alphixHook), shares, "Balance should equal shares");
        assertEq(d.wrapper.totalAssets(), initialTotalAssets + depositAmount, "Total assets should increase");
        assertEq(d.wrapper.totalSupply(), initialSupply + shares, "Total supply should increase");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test multiple deposits.
     * @param decimals The asset decimals (6-18).
     * @param depositMultipliers Array of deposit amounts.
     */
    function testFuzz_depositFlow_multiple(uint8 decimals, uint256[5] memory depositMultipliers) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 totalDeposited = d.seedLiquidity;
        uint256 totalShares = d.seedLiquidity; // Initial shares = seed liquidity

        for (uint256 i = 0; i < depositMultipliers.length; i++) {
            depositMultipliers[i] = bound(depositMultipliers[i], 1, 100_000_000);
            uint256 depositAmount = depositMultipliers[i] * 10 ** d.decimals;

            d.asset.mint(alphixHook, depositAmount);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), depositAmount);
            uint256 shares = d.wrapper.deposit(depositAmount, alphixHook);
            vm.stopPrank();

            totalDeposited += depositAmount;
            totalShares += shares;

            // Verify state after each deposit
            assertEq(d.wrapper.totalAssets(), totalDeposited, "Total assets incorrect");
        }

        // Final solvency check
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Final solvency check");
    }

    /**
     * @notice Fuzz test deposit with yield generation in between.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier1 First deposit multiplier.
     * @param yieldPercent Yield percentage.
     * @param depositMultiplier2 Second deposit multiplier.
     */
    function testFuzz_depositFlow_withYield(
        uint8 decimals,
        uint256 depositMultiplier1,
        uint256 yieldPercent,
        uint256 depositMultiplier2
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier1 = bound(depositMultiplier1, 1, 100_000_000);
        depositMultiplier2 = bound(depositMultiplier2, 1, 100_000_000);
        uint256 deposit1 = depositMultiplier1 * 10 ** d.decimals;
        uint256 deposit2 = depositMultiplier2 * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 50);

        // First deposit
        d.asset.mint(alphixHook, deposit1);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), deposit1);
        uint256 shares1 = d.wrapper.deposit(deposit1, alphixHook);
        vm.stopPrank();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // Second deposit - should get fewer shares per asset due to yield
        d.asset.mint(alphixHook, deposit2);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), deposit2);
        uint256 shares2 = d.wrapper.deposit(deposit2, alphixHook);
        vm.stopPrank();

        // Shares per asset should decrease with yield
        uint256 sharesPerAsset1 = shares1 * 1e18 / deposit1;
        uint256 sharesPerAsset2 = shares2 * 1e18 / deposit2;
        assertLe(sharesPerAsset2, sharesPerAsset1, "Shares per asset should decrease after yield");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }
}
