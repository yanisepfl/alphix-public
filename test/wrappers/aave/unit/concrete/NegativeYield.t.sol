// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title NegativeYieldTest
 * @author Alphix
 * @notice Unit tests for negative yield (slashing) handling.
 */
contract NegativeYieldTest is BaseAlphix4626WrapperAave {
    /* NEGATIVE YIELD ACCRUAL */

    /**
     * @notice Test that negative yield reduces fees proportionally.
     */
    function test_negativeYield_reducesFeeProportionally() public {
        // Setup: deposit and generate yield to accumulate fees
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20); // 20% yield

        // Trigger accrual to lock in fees
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = wrapper.getClaimableFees();
        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        assertGt(feesBefore, 0, "Should have accumulated fees");

        // Simulate 10% slashing
        uint256 slashAmount = balanceBefore * 10 / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfter = wrapper.getClaimableFees();
        uint256 expectedFeesAfter = feesBefore * 90 / 100; // 10% reduction

        // Allow for rounding
        _assertApproxEq(feesAfter, expectedFeesAfter, 1, "Fees should be reduced proportionally");
    }

    /**
     * @notice Test that negative yield emits NegativeYield event.
     */
    function test_negativeYield_emitsEvent() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = balanceBefore * 10 / 100;

        // Simulate slashing
        aToken.simulateSlash(address(wrapper), slashAmount);

        uint256 balanceAfter = aToken.balanceOf(address(wrapper));
        uint256 feesBefore = wrapper.getClaimableFees();
        uint256 expectedFeesReduced = feesBefore - (feesBefore * 90 / 100);

        // Expect NegativeYield event
        vm.expectEmit(true, true, true, false);
        emit IAlphix4626WrapperAave.NegativeYield(slashAmount, expectedFeesReduced, balanceAfter);

        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);
    }

    /**
     * @notice Test that negative yield maintains solvency.
     */
    function test_negativeYield_maintainsSolvency() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(50); // Large yield

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Simulate 30% slashing
        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balanceBefore * 30 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify solvency
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Test that negative yield with zero fees doesn't revert.
     */
    function test_negativeYield_zeroFees_doesNotRevert() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        // Deposit
        _depositAsHook(100e6, alphixHook);

        // Simulate slashing (no fees to reduce)
        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balanceBefore * 10 / 100);

        // Should not revert
        vm.prank(owner);
        wrapper.setFee(0);

        assertEq(wrapper.getClaimableFees(), 0, "Fees should still be zero");
    }

    /**
     * @notice Test that negative yield is correctly reflected in getClaimableFees view.
     */
    function test_negativeYield_correctlyReflectedInView() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();

        // Simulate slashing WITHOUT triggering accrual
        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balanceBefore * 10 / 100);

        // View should reflect reduced fees immediately
        uint256 feesAfterSlash = wrapper.getClaimableFees();
        uint256 expectedFees = feesBeforeSlash * 90 / 100;

        _assertApproxEq(feesAfterSlash, expectedFees, 1, "View should reflect negative yield");
    }

    /**
     * @notice Test that totalAssets is correct after negative yield.
     */
    function test_negativeYield_totalAssetsCorrect() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Simulate slashing
        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balanceBefore * 10 / 100);

        // totalAssets should equal aToken balance minus claimable fees
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 totalAssets = wrapper.totalAssets();

        assertEq(totalAssets, aTokenBalance - claimableFees, "totalAssets incorrect after slash");
    }

    /**
     * @notice Test multiple consecutive slashing events.
     */
    function test_negativeYield_multipleSlashes() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(50);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = wrapper.getClaimableFees();

        // First slash: 10%
        uint256 balance1 = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance1 * 10 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Second slash: 10%
        uint256 balance2 = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance2 * 10 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfter = wrapper.getClaimableFees();

        // Fees should be roughly 81% of original (0.9 * 0.9 = 0.81)
        uint256 expectedFees = feesBefore * 81 / 100;
        _assertApproxEq(feesAfter, expectedFees, 2, "Fees incorrect after multiple slashes");
    }

    /**
     * @notice Test that negative yield followed by positive yield works correctly.
     */
    function test_negativeYield_followedByPositiveYield() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterFirstYield = wrapper.getClaimableFees();

        // Slash 10%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 10 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSlash = wrapper.getClaimableFees();
        assertLt(feesAfterSlash, feesAfterFirstYield, "Fees should decrease after slash");

        // Generate more yield
        _simulateYieldPercent(10);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSecondYield = wrapper.getClaimableFees();
        assertGt(feesAfterSecondYield, feesAfterSlash, "Fees should increase after positive yield");

        // Verify solvency
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Test extreme slash (almost total loss).
     */
    function test_negativeYield_extremeSlash() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Slash 90%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 90 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify solvency still holds
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated after extreme slash");
        assertGt(totalAssets, 0, "Total assets should still be positive");
    }
}
