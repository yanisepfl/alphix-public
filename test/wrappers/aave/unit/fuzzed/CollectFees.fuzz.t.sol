// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollectFeesFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the collectFees function.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract CollectFeesFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that collectFees transfers correct amount.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param feeRate The fee rate.
     */
    function testFuzz_collectFees_transfersCorrectAmount(
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

        // Ensure fee rate > 0 to generate fees
        vm.assume(feeRate > 0);

        vm.prank(owner);
        d.wrapper.setFee(feeRate);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 claimableFees = d.wrapper.getClaimableFees();

        // Skip if no fees accrued (can happen with very small amounts due to rounding)
        vm.assume(claimableFees > 0);

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        assertEq(d.aToken.balanceOf(treasury), claimableFees, "Should transfer claimable fees");
    }

    /**
     * @notice Fuzz test that non-owner cannot collect.
     * @param decimals The asset decimals (6-18).
     * @param caller Random caller address.
     */
    function testFuzz_collectFees_nonOwner_reverts(uint8 decimals, address caller) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.assume(caller != owner && caller != address(0));

        // Setup fees
        uint256 depositAmount = 100 * 10 ** d.decimals;
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, 10);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        d.wrapper.collectFees();
    }

    /**
     * @notice Fuzz test that fees reset to zero after collection.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFees_resetsFees(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit and generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        assertEq(d.wrapper.getClaimableFees(), 0, "Fees should be zero after collection");
    }

    /**
     * @notice Fuzz test that totalAssets unchanged after collection.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFees_totalAssetsUnchanged(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);

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

        uint256 totalAssetsBefore = d.wrapper.totalAssets();

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        uint256 totalAssetsAfter = d.wrapper.totalAssets();

        assertEq(totalAssetsAfter, totalAssetsBefore, "totalAssets should not change");
    }

    /**
     * @notice Fuzz test solvency after collection.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFees_maintainsSolvency(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100); // Must be > 0 to generate fees

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();

        assertEq(claimableFees, 0, "Fees should be zero");
        assertEq(totalAssets, aTokenBalance, "All balance should be user assets");
    }

    /**
     * @notice Fuzz test multiple collections.
     * @param decimals The asset decimals (6-18).
     * @param depositMultipliers Array of deposit multipliers.
     * @param yields Array of yield percentages.
     */
    function testFuzz_collectFees_multiple(
        uint8 decimals,
        uint256[3] memory depositMultipliers,
        uint256[3] memory yields
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 totalCollected;

        for (uint256 i = 0; i < 3; i++) {
            depositMultipliers[i] = bound(depositMultipliers[i], 1, 100_000_000);
            uint256 depositAmount = depositMultipliers[i] * 10 ** d.decimals;
            yields[i] = bound(yields[i], 1, 30);

            // Deposit
            d.asset.mint(alphixHook, depositAmount);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), depositAmount);
            d.wrapper.deposit(depositAmount, alphixHook);
            vm.stopPrank();

            // Generate yield
            _simulateYieldOnDeployment(d, yields[i]);

            uint256 claimableFees = d.wrapper.getClaimableFees();

            // Collect
            vm.prank(owner);
            d.wrapper.collectFees();

            totalCollected += claimableFees;
        }

        assertEq(d.aToken.balanceOf(treasury), totalCollected, "Should collect all fees");
    }

    /**
     * @notice Fuzz test collection after slash.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_collectFees_afterSlash(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 10, 100);
        slashPercent = bound(slashPercent, 1, 80);

        // Deposit and generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

        // Get fees after slash
        uint256 feesAfterSlash = d.wrapper.getClaimableFees();

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        assertEq(d.aToken.balanceOf(treasury), feesAfterSlash, "Should collect reduced fees");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test setYieldTreasury with various addresses.
     * @param decimals The asset decimals (6-18).
     * @param newTreasury Random treasury address.
     */
    function testFuzz_setYieldTreasury_toVariousAddresses(uint8 decimals, address newTreasury) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.assume(newTreasury != address(0));
        vm.assume(newTreasury != address(d.wrapper));

        // Setup fees
        uint256 depositAmount = 100 * 10 ** d.decimals;
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, 20);

        // Change treasury
        vm.prank(owner);
        d.wrapper.setYieldTreasury(newTreasury);

        uint256 claimableFees = d.wrapper.getClaimableFees();

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        assertEq(d.aToken.balanceOf(newTreasury), claimableFees, "New treasury should get fees");
    }

    /**
     * @notice Fuzz test lastWrapperBalance update after collection.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFees_updatesLastWrapperBalance(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit and generate yield
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Collect
        vm.prank(owner);
        d.wrapper.collectFees();

        // lastWrapperBalance should equal aToken balance
        uint256 lastBalance = d.wrapper.getLastWrapperBalance();
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));

        assertEq(lastBalance, aTokenBalance, "lastWrapperBalance should be updated");
    }
}
