// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title DepositFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for deposit flow integration scenarios.
 */
contract DepositFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test deposit flow with varying amounts.
     */
    function testFuzz_depositFlow_varyingAmounts(uint256 depositMultiplier) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        uint256 initialTotalAssets = wrapper.totalAssets();
        uint256 initialShares = wrapper.balanceOf(alphixHook);

        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapper.balanceOf(alphixHook), initialShares + shares, "Shares should increase");
        assertApproxEqAbs(wrapper.totalAssets(), initialTotalAssets + depositAmount, 2, "Total assets should increase");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple deposits with yield between.
     */
    function testFuzz_depositFlow_multipleWithYield(
        uint256 deposit1Multiplier,
        uint256 deposit2Multiplier,
        uint256 yieldPercent
    ) public {
        deposit1Multiplier = bound(deposit1Multiplier, 1, 10_000_000);
        deposit2Multiplier = bound(deposit2Multiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1);

        uint256 deposit1 = deposit1Multiplier * 1e18;
        uint256 deposit2 = deposit2Multiplier * 1e18;

        // First deposit
        uint256 shares1 = _depositAsHook(deposit1, alphixHook);

        // Yield
        _simulateYieldPercent(yieldPercent);

        // Second deposit should get fewer shares
        uint256 shares2 = _depositAsHook(deposit2, alphixHook);

        // Same amount should get fewer shares after yield
        if (deposit1 == deposit2) {
            assertLt(shares2, shares1, "Same deposit should get fewer shares after yield");
        }

        assertEq(wrapper.balanceOf(alphixHook), shares1 + shares2, "Total shares mismatch");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit maintains solvency at various rates.
     */
    function testFuzz_depositFlow_atVaryingRates(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 0, 1);

        uint256 depositAmount = depositMultiplier * 1e18;

        // Set initial rate (via yield, respects circuit breaker - max 1%)
        if (yieldPercent > 0) {
            _depositAsHook(100e18, alphixHook); // Initial deposit to generate yield on
            _simulateYieldPercent(yieldPercent);
        }

        // New deposit
        _depositAsHook(depositAmount, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit and immediate withdrawal.
     */
    function testFuzz_depositFlow_depositThenWithdraw(uint256 depositMultiplier, uint256 withdrawPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test sequential deposits.
     */
    function testFuzz_depositFlow_sequential(uint256[3] memory depositsMultiplier) public {
        uint256 totalShares;

        for (uint256 i = 0; i < depositsMultiplier.length; i++) {
            uint256 multiplier = bound(depositsMultiplier[i], 1, 1_000_000);
            uint256 amount = multiplier * 1e18;

            uint256 shares = _depositAsHook(amount, alphixHook);
            totalShares += shares;
        }

        assertEq(wrapper.balanceOf(alphixHook), totalShares, "Total shares mismatch");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit after fee change.
     */
    function testFuzz_depositFlow_afterFeeChange(uint256 depositMultiplier, uint24 newFee) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        newFee = _boundFee(newFee);

        uint256 depositAmount = depositMultiplier * 1e18;

        // Initial deposit
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Change fee
        vm.prank(owner);
        wrapper.setFee(newFee);

        // Another deposit
        _depositAsHook(depositAmount, alphixHook);

        _assertSolvent();
    }
}
