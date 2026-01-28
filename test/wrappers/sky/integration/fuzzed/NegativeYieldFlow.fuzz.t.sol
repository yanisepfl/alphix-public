// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title NegativeYieldFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for negative yield (rate decrease) flow integration scenarios.
 * @dev Key Sky difference: fees are NOT reduced during negative yield.
 */
contract NegativeYieldFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test negative yield with varying slash amounts.
     */
    function testFuzz_negativeYieldFlow_varyingSlash(uint256 depositMultiplier, uint256 slashPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        slashPercent = bound(slashPercent, 1, 1);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Negative yield
        _simulateSlashPercent(slashPercent);

        uint256 totalAfter = wrapper.totalAssets();

        // Total assets should decrease
        assertLt(totalAfter, totalBefore, "Total assets should decrease");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test that fees are not reduced by negative yield.
     */
    function testFuzz_negativeYieldFlow_feesNotReduced(
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        yieldPercent = bound(yieldPercent, 1, 1);
        slashPercent = bound(slashPercent, 1, 1);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield and lock in fees
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();
        assertGt(feesBeforeSlash, 0, "Should have fees before slash");

        // Negative yield
        _simulateSlashPercent(slashPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSlash = wrapper.getClaimableFees();

        // Fees should NOT be reduced (Sky behavior)
        assertEq(feesAfterSlash, feesBeforeSlash, "Fees should NOT be reduced by slash");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test recovery after negative yield.
     */
    function testFuzz_negativeYieldFlow_recovery(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 recoveryPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        slashPercent = bound(slashPercent, 1, 1);
        recoveryPercent = bound(recoveryPercent, 1, 5);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalBefore = wrapper.totalAssets();

        // Negative yield
        _simulateSlashPercent(slashPercent);

        uint256 totalAfterSlash = wrapper.totalAssets();
        assertLt(totalAfterSlash, totalBefore, "Should decrease after slash");

        // Recovery yield
        _simulateYieldPercent(recoveryPercent);

        uint256 totalAfterRecovery = wrapper.totalAssets();
        assertGt(totalAfterRecovery, totalAfterSlash, "Should recover with new yield");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test operations after negative yield.
     */
    function testFuzz_negativeYieldFlow_operationsAfterSlash(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 withdrawPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        slashPercent = bound(slashPercent, 1, 1);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Negative yield
        _simulateSlashPercent(slashPercent);

        // Should still be able to withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        // Should still be able to deposit
        _depositAsHook(depositAmount / 2, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple slashes.
     */
    function testFuzz_negativeYieldFlow_multipleSlashes(uint256 depositMultiplier, uint8[3] memory slashPercents)
        public
    {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // Generate initial yield and fees (1% respects circuit breaker)
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlashes = wrapper.getClaimableFees();

        // Multiple slashes
        for (uint256 i = 0; i < slashPercents.length; i++) {
            uint256 slashPct = bound(slashPercents[i], 1, 1);
            _simulateSlashPercent(slashPct);

            vm.prank(owner);
            wrapper.setFee(DEFAULT_FEE);
        }

        // Fees should remain unchanged
        assertEq(wrapper.getClaimableFees(), feesBeforeSlashes, "Fees should not change after slashes");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection after slash.
     */
    function testFuzz_negativeYieldFlow_collectFeesAfterSlash(
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        yieldPercent = bound(yieldPercent, 1, 1);
        slashPercent = bound(slashPercent, 1, 1);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();
        assertGt(feesBeforeSlash, 0, "Should have fees");

        // Slash
        _simulateSlashPercent(slashPercent);

        // Collect fees (should get full amount, not reduced)
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), feesBeforeSlash, "Treasury should receive full fees");

        _assertSolvent();
    }
}
