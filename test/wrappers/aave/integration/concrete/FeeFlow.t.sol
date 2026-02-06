// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title FeeFlowTest
 * @author Alphix
 * @notice Integration tests for fee management flows.
 */
contract FeeFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests fee change flow with yield accrual.
     */
    function test_feeFlow_changeFeeMidStream() public {
        // Deposit
        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        // Simulate yield at 10% fee
        _simulateYieldPercent(10);

        uint256 feesAt10Percent = wrapper.getClaimableFees();

        // Change fee to 50%
        vm.prank(owner);
        wrapper.setFee(500_000);

        // Fees from first yield should be locked in
        uint256 feesAfterChange = wrapper.getClaimableFees();
        assertEq(feesAfterChange, feesAt10Percent, "Fees should be preserved after fee change");

        // Simulate more yield at 50% fee
        _simulateYieldPercent(10);

        uint256 feesAfterSecondYield = wrapper.getClaimableFees();
        uint256 secondYieldFees = feesAfterSecondYield - feesAfterChange;

        // Second yield should have higher fee percentage
        assertGt(secondYieldFees, feesAt10Percent, "Higher fee should generate more fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee reduction flow.
     */
    function test_feeFlow_reduceFee() public {
        // Start at 50% fee
        vm.prank(owner);
        wrapper.setFee(500_000);

        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        _simulateYieldPercent(10);
        uint256 feesAt50Percent = wrapper.getClaimableFees();

        // Reduce fee to 10%
        vm.prank(owner);
        wrapper.setFee(100_000);

        _simulateYieldPercent(10);
        uint256 totalFees = wrapper.getClaimableFees();
        uint256 feesAt10Percent = totalFees - feesAt50Percent;

        // Fees at lower rate should be smaller
        assertLt(feesAt10Percent, feesAt50Percent, "Lower fee rate should generate fewer fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee to zero flow.
     * @dev When fee rate is 0%, no fees are taken from USER yield. However,
     *      the fee-owned aTokens still earn yield which goes 100% to treasury.
     */
    function test_feeFlow_setFeeToZero() public {
        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        // Generate some fees
        _simulateYieldPercent(10);
        uint256 feesBefore = wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have fees before");

        // Set fee to zero
        vm.prank(owner);
        wrapper.setFee(0);

        // Existing fees preserved
        assertEq(wrapper.getClaimableFees(), feesBefore, "Existing fees preserved");

        // New yield: fee-owned portion still earns yield for treasury (100% of its yield)
        // but no new fees from user-owned portion
        _simulateYieldPercent(10);
        uint256 feesAfter = wrapper.getClaimableFees();

        // Fees should increase only by the yield on the fee-owned portion
        // feesBefore earns 10% yield, all of which goes to fees
        uint256 expectedFeeYield = feesBefore * 10 / 100;
        _assertApproxEq(feesAfter - feesBefore, expectedFeeYield, 1, "Fee portion still earns yield for treasury");

        _assertSolvent();
    }

    /**
     * @notice Tests fee from zero flow.
     */
    function test_feeFlow_setFeeFromZero() public {
        // Start at zero fee
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        _simulateYieldPercent(10);
        assertEq(wrapper.getClaimableFees(), 0, "No fees at zero rate");

        // Enable fee
        vm.prank(owner);
        wrapper.setFee(100_000);

        // Still no fees (yield already generated)
        // The yield was already recorded at _lastWrapperBalance
        assertEq(wrapper.getClaimableFees(), 0, "Previous yield not retroactively charged");

        // New yield generates fees
        _simulateYieldPercent(10);
        assertGt(wrapper.getClaimableFees(), 0, "New yield generates fees");

        _assertSolvent();
    }

    /**
     * @notice Tests fee at max flow.
     */
    function test_feeFlow_maxFeeImpact() public {
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        uint256 deposit = 10_000e6;
        _depositAsHook(deposit, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        _simulateYieldPercent(50);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should not change (all yield goes to fees)
        assertEq(totalAssetsAfter, totalAssetsBefore, "No asset growth at max fee");

        // All yield should be fees
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + deposit) * 50 / 100;
        _assertApproxEq(wrapper.getClaimableFees(), expectedYield, 1, "All yield is fees");

        _assertSolvent();
    }
}
