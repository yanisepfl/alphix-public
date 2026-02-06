// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title CollectFeesFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for fee collection scenarios.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract CollectFeesFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test complete fee collection flow.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFeesFlow_completeCollection(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent
    ) public {
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

        uint256 totalAssetsBefore = d.wrapper.totalAssets();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // Check claimable fees
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees to claim");

        // Collect fees
        vm.prank(owner);
        d.wrapper.collectFees();

        // Verify treasury received fees
        assertEq(d.aToken.balanceOf(treasury), claimableFees, "Treasury should receive fees");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssetsAfter = d.wrapper.totalAssets();
        assertEq(totalAssetsAfter, aTokenBalance, "All balance should be user assets after collection");
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssets should increase from yield");

        // Fees should be zero
        assertEq(d.wrapper.getClaimableFees(), 0, "No more fees to claim");
    }

    /**
     * @notice Fuzz test periodic fee collection.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yields Array of yield percentages for each period.
     */
    function testFuzz_collectFeesFlow_periodicCollection(
        uint8 decimals,
        uint256 depositMultiplier,
        uint8[3] memory yields
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

        uint256 totalCollected;

        // Simulate multiple periods of yield and collection
        for (uint256 i = 0; i < yields.length; i++) {
            uint256 yieldPercent = bound(yields[i], 5, 30);

            // Generate yield
            _simulateYieldOnDeployment(d, yieldPercent);

            uint256 claimableFees = d.wrapper.getClaimableFees();

            // Collect fees
            vm.prank(owner);
            d.wrapper.collectFees();

            totalCollected += claimableFees;
        }

        // Verify all fees collected
        assertEq(d.aToken.balanceOf(treasury), totalCollected, "Should collect all periodic fees");

        // Verify wrapper state
        assertEq(d.wrapper.getClaimableFees(), 0, "No pending fees");

        // Solvency check
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All balance should be user assets");
    }

    /**
     * @notice Fuzz test fee collection with varying fee rates.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param lowFee Low fee rate.
     * @param highFee High fee rate.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFeesFlow_varyingFeeRates(
        uint8 decimals,
        uint256 depositMultiplier,
        uint24 lowFee,
        uint24 highFee,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        lowFee = uint24(bound(lowFee, 50_000, 150_000)); // 5-15%
        highFee = uint24(bound(highFee, 400_000, 600_000)); // 40-60%
        yieldPercent = bound(yieldPercent, 5, 30);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Period 1: Low fee
        vm.prank(owner);
        d.wrapper.setFee(lowFee);

        _simulateYieldOnDeployment(d, yieldPercent);
        vm.prank(owner);
        d.wrapper.collectFees();

        uint256 feesAtLowRate = d.aToken.balanceOf(treasury);

        // Period 2: High fee
        vm.prank(owner);
        d.wrapper.setFee(highFee);

        _simulateYieldOnDeployment(d, yieldPercent);
        vm.prank(owner);
        d.wrapper.collectFees();

        uint256 feesAtHighRate = d.aToken.balanceOf(treasury) - feesAtLowRate;

        // Higher fee should collect more (given similar yield and TVL)
        assertGt(feesAtHighRate, feesAtLowRate, "Higher fee should collect more");
    }

    /**
     * @notice Fuzz test fee collection after negative yield.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_collectFeesFlow_afterSlash(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 20, 60);
        slashPercent = bound(slashPercent, 10, 50);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = d.wrapper.getClaimableFees();

        // Slash
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);

        // Fees should be reduced
        uint256 feesAfterSlash = d.wrapper.getClaimableFees();
        assertLt(feesAfterSlash, feesBeforeSlash, "Fees reduced by slash");

        // Collect reduced fees
        vm.prank(owner);
        d.wrapper.collectFees();

        assertEq(d.aToken.balanceOf(treasury), feesAfterSlash, "Should collect reduced fees");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All balance is user assets after collection");
    }

    /**
     * @notice Fuzz test fee collection interleaved with deposits.
     * @param decimals The asset decimals (6-18).
     * @param deposit1Multiplier First deposit amount multiplier.
     * @param deposit2Multiplier Second deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFeesFlow_interleavedWithDeposits(
        uint8 decimals,
        uint256 deposit1Multiplier,
        uint256 deposit2Multiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        deposit1Multiplier = bound(deposit1Multiplier, 1, 500_000_000);
        deposit2Multiplier = bound(deposit2Multiplier, 1, 500_000_000);
        vm.assume(deposit2Multiplier > deposit1Multiplier); // Ensure second deposit is larger
        uint256 deposit1 = deposit1Multiplier * 10 ** d.decimals;
        uint256 deposit2 = deposit2Multiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 5, 30);

        // First deposit
        d.asset.mint(alphixHook, deposit1);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), deposit1);
        d.wrapper.deposit(deposit1, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Collect first fees
        vm.prank(owner);
        d.wrapper.collectFees();

        uint256 firstCollection = d.aToken.balanceOf(treasury);

        // Second deposit (larger)
        d.asset.mint(alphixHook, deposit2);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), deposit2);
        d.wrapper.deposit(deposit2, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Collect second fees
        vm.prank(owner);
        d.wrapper.collectFees();

        uint256 secondCollection = d.aToken.balanceOf(treasury) - firstCollection;

        // Second collection should be larger (more TVL)
        assertGt(secondCollection, firstCollection, "More TVL should generate more fees");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test complete lifecycle.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_collectFeesFlow_completeLifecycle(uint8 decimals, uint256 depositMultiplier, uint256 slashPercent)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        slashPercent = bound(slashPercent, 10, 30);

        // Phase 1: Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Phase 2: First yield cycle
        _simulateYieldOnDeployment(d, 15);
        vm.prank(owner);
        d.wrapper.collectFees();
        uint256 collection1 = d.aToken.balanceOf(treasury);

        // Phase 3: Slashing event
        uint256 balance = d.aToken.balanceOf(address(d.wrapper));
        d.aToken.simulateSlash(address(d.wrapper), balance * slashPercent / 100);
        // Trigger accrual to process negative yield
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        // Phase 4: Recovery yield
        _simulateYieldOnDeployment(d, 20);
        vm.prank(owner);
        d.wrapper.collectFees();
        uint256 collection2 = d.aToken.balanceOf(treasury) - collection1;

        // Phase 5: Additional deposit
        uint256 additionalDeposit = depositAmount / 2;
        d.asset.mint(alphixHook, additionalDeposit);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), additionalDeposit);
        d.wrapper.deposit(additionalDeposit, alphixHook);
        vm.stopPrank();

        // Phase 6: Third yield cycle
        _simulateYieldOnDeployment(d, 10);
        vm.prank(owner);
        d.wrapper.collectFees();
        uint256 collection3 = d.aToken.balanceOf(treasury) - collection1 - collection2;

        // All collections should be positive
        assertGt(collection1, 0, "First collection positive");
        assertGt(collection2, 0, "Second collection positive");
        assertGt(collection3, 0, "Third collection positive");

        // Final solvency check
        uint256 finalATokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 finalTotalAssets = d.wrapper.totalAssets();
        uint256 finalFees = d.wrapper.getClaimableFees();

        assertEq(finalFees, 0, "All fees collected");
        assertEq(finalTotalAssets, finalATokenBalance, "All balance is user assets");
    }

    /**
     * @notice Fuzz test zero fee setting reverts on collect.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFeesFlow_zeroFee(uint8 decimals, uint256 depositMultiplier, uint256 yieldPercent) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 10, 100);

        // Set fee to 0
        vm.prank(owner);
        d.wrapper.setFee(0);

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Generate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // No fees should accumulate
        assertEq(d.wrapper.getClaimableFees(), 0, "No fees with 0% fee");

        // Collect should revert with ZeroAmount since no fees
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroAmount.selector);
        d.wrapper.collectFees();

        // All yield goes to depositors
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All yield goes to depositors");
    }
}
