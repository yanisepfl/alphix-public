// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title NegativeYieldFuzzTest
 * @author Alphix
 * @notice Fuzz tests for negative yield (rate decrease) scenarios.
 * @dev The implementation does NOT reduce accumulated fees during negative yield.
 */
contract NegativeYieldFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test that negative yield does not reduce accumulated fees.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Initial yield percentage.
     * @param slashPercent Slash percentage.
     */
    function testFuzz_negativeYield_feesNotReduced(
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual to lock in fees
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have accumulated fees");

        // Slash
        _simulateSlashPercent(slashPercent);

        // Trigger accrual for rate update
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfter = wrapper.getClaimableFees();

        // Fees should NOT be reduced
        assertEq(feesAfter, feesBefore, "Fees should not be reduced by slash");
    }

    /**
     * @notice Fuzz test that negative yield updates lastRate.
     * @param depositMultiplier Deposit amount.
     * @param slashPercent Slash percentage.
     */
    function testFuzz_negativeYield_updatesLastRate(uint256 depositMultiplier, uint256 slashPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();

        _simulateSlashPercent(slashPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 lastRateAfter = wrapper.getLastRate();
        assertLt(lastRateAfter, lastRateBefore, "Last rate should decrease");
    }

    /**
     * @notice Fuzz test that negative yield maintains solvency.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Initial yield percentage.
     * @param slashPercent Slash percentage.
     */
    function testFuzz_negativeYield_maintainsSolvency(
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 slashPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        _simulateSlashPercent(slashPercent);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        _assertSolvent();
    }

    /**
     * @notice Fuzz test negative yield followed by positive yield.
     * @param depositMultiplier Deposit amount.
     * @param slashPercent Slash percentage.
     * @param recoveryYieldPercent Recovery yield percentage.
     */
    function testFuzz_negativeYield_thenPositiveYield(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 recoveryYieldPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        recoveryYieldPercent = bound(recoveryYieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // First some yield (within circuit breaker limits)
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();

        // Slash
        _simulateSlashPercent(slashPercent);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Fees unchanged
        uint256 feesAfterSlash = wrapper.getClaimableFees();
        assertEq(feesAfterSlash, feesBeforeSlash, "Fees unchanged after slash");

        // Recovery yield
        _simulateYieldPercent(recoveryYieldPercent);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // More fees
        uint256 feesAfterRecovery = wrapper.getClaimableFees();
        assertGt(feesAfterRecovery, feesAfterSlash, "Fees increase after recovery");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit after negative yield.
     * @param depositMultiplier Initial deposit amount.
     * @param slashPercent Slash percentage.
     * @param secondDepositMultiplier Second deposit amount.
     */
    function testFuzz_negativeYield_depositAfterSlash(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 secondDepositMultiplier
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        secondDepositMultiplier = bound(secondDepositMultiplier, 1, 100_000_000);

        uint256 amount1 = depositMultiplier * 1e18;
        uint256 amount2 = secondDepositMultiplier * 1e18;

        _depositAsHook(amount1, alphixHook);

        // Slash
        _simulateSlashPercent(slashPercent);

        // Second deposit should work
        usds.mint(alphixHook, amount2);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount2);
        uint256 shares = wrapper.deposit(amount2, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem after negative yield.
     * @param depositMultiplier Deposit amount.
     * @param slashPercent Slash percentage.
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_negativeYield_redeemAfterSlash(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 redeemPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        redeemPercent = bound(redeemPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // Slash
        _simulateSlashPercent(slashPercent);

        // Redeem should work
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;

        if (redeemShares > 0) {
            vm.prank(alphixHook);
            uint256 assets = wrapper.redeem(redeemShares, alphixHook, alphixHook);

            assertGt(assets, 0, "Should receive assets");
            _assertSolvent();
        }
    }
}
