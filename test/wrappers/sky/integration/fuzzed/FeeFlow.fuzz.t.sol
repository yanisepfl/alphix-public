// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title FeeFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for fee management flow integration scenarios.
 */
contract FeeFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test fee changes.
     */
    function testFuzz_feeFlow_feeChanges(uint256 depositMultiplier, uint24 newFee) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        newFee = _boundFee(newFee);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        uint256 feesBefore = wrapper.getClaimableFees();

        // Change fee
        vm.prank(owner);
        wrapper.setFee(newFee);

        // Existing fees preserved
        assertEq(wrapper.getClaimableFees(), feesBefore, "Existing fees should be preserved");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection at varying amounts.
     */
    function testFuzz_feeFlow_collection(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield (respects circuit breaker - max 1%)
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFees = wrapper.getClaimableFees();

        if (claimableFees > 0) {
            uint256 treasuryBefore = susds.balanceOf(treasury);

            vm.prank(owner);
            wrapper.collectFees();

            assertEq(susds.balanceOf(treasury), treasuryBefore + claimableFees, "Treasury should receive fees");
            assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero after collection");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple fee collections.
     */
    function testFuzz_feeFlow_multipleCollections(uint256 depositMultiplier, uint8[3] memory yieldPercents) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalCollected;

        for (uint256 i = 0; i < yieldPercents.length; i++) {
            uint256 yieldPct = bound(yieldPercents[i], 1, 1);
            _simulateYieldPercent(yieldPct);

            uint256 fees = wrapper.getClaimableFees();
            if (fees > 0) {
                vm.prank(owner);
                wrapper.collectFees();
                totalCollected += fees;
            }
        }

        assertEq(susds.balanceOf(treasury), totalCollected, "Treasury should have all collected fees");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection after operations.
     */
    function testFuzz_feeFlow_afterOperations(uint256 depositMultiplier, uint256 withdrawPercent, uint256 yieldPercent)
        public
    {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 50);
        yieldPercent = bound(yieldPercent, 1, 1);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        // Partial withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        // Should still have fees
        uint256 fees = wrapper.getClaimableFees();
        if (fees > 0) {
            vm.prank(owner);
            wrapper.collectFees();

            assertEq(susds.balanceOf(treasury), fees, "Treasury should receive fees");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee with varying fee rates.
     */
    function testFuzz_feeFlow_varyingRates(uint256 depositMultiplier, uint24 feeRate, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        feeRate = _boundFee(feeRate);
        yieldPercent = bound(yieldPercent, 1, 1);

        // Set initial fee rate
        vm.prank(owner);
        wrapper.setFee(feeRate);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield (respects circuit breaker - max 1%)
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(feeRate);

        uint256 fees = wrapper.getClaimableFees();

        if (feeRate == 0) {
            assertEq(fees, 0, "Zero fee should give zero claimable");
        } else {
            assertGt(fees, 0, "Non-zero fee should give non-zero claimable");
        }

        _assertSolvent();
    }
}
