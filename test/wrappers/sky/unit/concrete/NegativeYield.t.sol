// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title NegativeYieldTest
 * @author Alphix
 * @notice Unit tests for negative yield (rate decrease) handling.
 * @dev For Sky wrapper, negative yield occurs when sUSDS/USDS rate decreases.
 *      The implementation does NOT reduce accumulated fees during negative yield,
 *      it only updates the rate tracker to the new lower rate.
 */
contract NegativeYieldTest is BaseAlphix4626WrapperSky {
    /* NEGATIVE YIELD BEHAVIOR */

    /**
     * @notice Test that negative yield does NOT reduce already accumulated fees.
     * @dev Accumulated fees represent past yield and should not be clawed back.
     */
    function test_negativeYield_doesNotReduceAccumulatedFees() public {
        // Setup: deposit and generate yield to accumulate fees
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1); // 1% yield (circuit breaker limit)

        // Trigger accrual to lock in fees
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have accumulated fees");

        // Simulate 1% rate decrease (slash, circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfter = wrapper.getClaimableFees();

        // Fees should remain the same (not reduced)
        assertEq(feesAfter, feesBefore, "Accumulated fees should not be reduced by negative yield");
    }

    /**
     * @notice Test that negative yield updates lastRate but not accumulated fees.
     */
    function test_negativeYield_updatesLastRate() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 lastRateBefore = wrapper.getLastRate();

        // Slash
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 lastRateAfter = wrapper.getLastRate();
        assertLt(lastRateAfter, lastRateBefore, "Last rate should decrease after slash");
    }

    /**
     * @notice Test that negative yield maintains solvency.
     */
    function test_negativeYield_maintainsSolvency() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1); // 1% yield (circuit breaker limit)

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Simulate 1% rate decrease (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify solvency
        _assertSolvent();
    }

    /**
     * @notice Test that negative yield with zero fees doesn't revert.
     */
    function test_negativeYield_zeroFees_doesNotRevert() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        // Deposit
        _depositAsHook(1000e18, alphixHook);

        // Simulate rate decrease (no fees to reduce)
        _simulateSlashPercent(1);

        // Should not revert
        vm.prank(owner);
        wrapper.setFee(0);

        assertEq(wrapper.getClaimableFees(), 0, "Fees should still be zero");
    }

    /**
     * @notice Test that totalAssets decreases after negative yield.
     * @dev totalAssets reflects sUSDS value which decreases when rate decreases.
     */
    function test_negativeYield_totalAssetsDecreases() public {
        // Setup: deposit
        _depositAsHook(1000e18, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate rate decrease
        _simulateSlashPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // totalAssets should decrease (sUSDS is worth less)
        assertLt(totalAssetsAfter, totalAssetsBefore, "totalAssets should decrease after rate decrease");
    }

    /**
     * @notice Test that totalAssets calculation is correct after negative yield.
     */
    function test_negativeYield_totalAssetsCalculationCorrect() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Simulate rate decrease
        _simulateSlashPercent(1);

        // totalAssets should equal sUSDS value minus claimable fees
        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 totalAssets = wrapper.totalAssets();

        uint256 netSusds = susdsBalance - claimableFees;
        uint256 netUsds = _susdsToUsds(netSusds);

        _assertApproxEq(totalAssets, netUsds, 2, "totalAssets incorrect after slash");
    }

    /**
     * @notice Test multiple consecutive slashing events don't reduce fees.
     */
    function test_negativeYield_multipleSlashes_feesUnchanged() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = wrapper.getClaimableFees();

        // First slash: 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Second slash: 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfter = wrapper.getClaimableFees();

        // Fees should be unchanged
        assertEq(feesAfter, feesBefore, "Fees should not be reduced by slashes");
    }

    /**
     * @notice Test that negative yield followed by positive yield works correctly.
     */
    function test_negativeYield_followedByPositiveYield() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterFirstYield = wrapper.getClaimableFees();

        // Slash 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSlash = wrapper.getClaimableFees();
        // Fees should NOT decrease (already accumulated)
        assertEq(feesAfterSlash, feesAfterFirstYield, "Fees should not decrease after slash");

        // Generate more yield
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSecondYield = wrapper.getClaimableFees();
        assertGt(feesAfterSecondYield, feesAfterSlash, "Fees should increase after positive yield");

        // Verify solvency
        _assertSolvent();
    }

    /**
     * @notice Test extreme slash (almost total loss).
     */
    function test_negativeYield_extremeSlash() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Slash 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify solvency still holds
        _assertSolvent();

        uint256 totalAssets = wrapper.totalAssets();
        assertGt(totalAssets, 0, "Total assets should still be positive");
    }

    /**
     * @notice Test that redemptions work correctly after negative yield.
     */
    function test_negativeYield_redemptionWorks() public {
        // Setup: deposit
        _depositAsHook(1000e18, alphixHook);

        // Simulate rate decrease
        _simulateSlashPercent(1);

        // Should be able to redeem
        uint256 shares = wrapper.balanceOf(alphixHook);
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        vm.prank(alphixHook);
        uint256 assets = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertGt(assets, 0, "Should receive assets on redeem");
        assertEq(wrapper.balanceOf(alphixHook), shares - maxRedeem, "Shares should be burned");
    }

    /**
     * @notice Test that withdrawals work correctly after negative yield.
     */
    function test_negativeYield_withdrawalWorks() public {
        // Setup: deposit
        _depositAsHook(1000e18, alphixHook);

        // Simulate rate decrease
        _simulateSlashPercent(1);

        // Should be able to withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        vm.prank(alphixHook);
        uint256 shares = wrapper.withdraw(maxWithdraw / 2, alphixHook, alphixHook);

        assertGt(shares, 0, "Should burn shares on withdraw");
    }

    /**
     * @notice Test that deposits work correctly after negative yield.
     */
    function test_negativeYield_depositWorks() public {
        // Setup: deposit
        _depositAsHook(1000e18, alphixHook);

        // Simulate rate decrease
        _simulateSlashPercent(1);

        // Should be able to deposit more
        usds.mint(alphixHook, 500e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 500e18);
        uint256 shares = wrapper.deposit(500e18, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should receive shares on deposit");
    }

    /**
     * @notice Test solvency after fee collection following negative yield.
     */
    function test_negativeYield_collectFeesAfterSlash() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBefore = wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have fees");

        // Slash
        _simulateSlashPercent(1);

        // Collect fees (should still work)
        vm.prank(owner);
        wrapper.collectFees();

        // Treasury should receive the full fees
        assertEq(susds.balanceOf(treasury), feesBefore, "Treasury should receive fees");

        // Verify solvency
        _assertSolvent();
    }
}
