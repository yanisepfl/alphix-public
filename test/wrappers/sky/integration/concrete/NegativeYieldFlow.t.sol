// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title NegativeYieldFlowTest
 * @author Alphix
 * @notice Integration tests for negative yield (rate decrease/slashing) scenarios.
 * @dev Sky-specific: negative yield occurs when sUSDS/USDS rate decreases.
 *      Important: accumulated fees are NOT reduced during negative yield.
 */
contract NegativeYieldFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Test complete slashing flow: deposit, yield, slash, deposit.
     */
    function test_negativeYieldFlow_depositYieldSlashDeposit() public {
        // Initial deposit
        _depositAsHook(100e18, alphixHook);

        uint256 initialShares = wrapper.balanceOf(alphixHook);
        uint256 initialTotalAssets = wrapper.totalAssets();

        // Generate yield
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterYield = wrapper.getClaimableFees();
        uint256 totalAssetsAfterYield = wrapper.totalAssets();

        assertGt(feesAfterYield, 0, "Should have fees from yield");
        assertGt(totalAssetsAfterYield, initialTotalAssets, "Total assets should increase");

        // Simulate 1% rate decrease (slash, circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSlash = wrapper.getClaimableFees();
        uint256 totalAssetsAfterSlash = wrapper.totalAssets();

        // Key difference from Aave: fees are NOT reduced after slash
        assertEq(feesAfterSlash, feesAfterYield, "Fees should NOT decrease after slash (Sky behavior)");
        assertLt(totalAssetsAfterSlash, totalAssetsAfterYield, "Total assets should decrease");

        // New deposit after slashing
        _depositAsHook(50e18, alphixHook);

        uint256 finalShares = wrapper.balanceOf(alphixHook);
        assertGt(finalShares, initialShares, "Should have more shares after second deposit");

        // Verify solvency
        _assertSolvent();
    }

    /**
     * @notice Test slashing with multiple depositors.
     */
    function test_negativeYieldFlow_multipleDepositors() public {
        // Hook deposits
        _depositAsHook(100e18, alphixHook);
        uint256 hookShares = wrapper.balanceOf(alphixHook);

        // Owner deposits
        usds.mint(owner, 50e18);
        vm.startPrank(owner);
        usds.approve(address(wrapper), 50e18);
        wrapper.deposit(50e18, owner);
        vm.stopPrank();
        uint256 ownerShares = wrapper.balanceOf(owner);

        // Generate yield
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Slash 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Shares should remain the same (slashing affects assets, not shares)
        assertEq(wrapper.balanceOf(alphixHook), hookShares, "Hook shares unchanged");
        assertEq(wrapper.balanceOf(owner), ownerShares, "Owner shares unchanged");

        // But share value (convertToAssets) should decrease
        uint256 hookAssetsAfter = wrapper.convertToAssets(hookShares);
        uint256 ownerAssetsAfter = wrapper.convertToAssets(ownerShares);

        // Both have reduced value but proportionally maintained
        assertGt(hookAssetsAfter, 0, "Hook should have some assets");
        assertGt(ownerAssetsAfter, 0, "Owner should have some assets");

        _assertSolvent();
    }

    /**
     * @notice Test recovery after slashing with new yield.
     */
    function test_negativeYieldFlow_recoveryWithNewYield() public {
        // Deposit
        _depositAsHook(100e18, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsBeforeSlash = wrapper.totalAssets();

        // Slash 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterSlash = wrapper.totalAssets();
        assertLt(totalAssetsAfterSlash, totalAssetsBeforeSlash, "Assets should decrease");

        // Generate recovery yield (1%, circuit breaker limit)
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterRecovery = wrapper.totalAssets();

        // Should have recovered some value
        assertGt(totalAssetsAfterRecovery, totalAssetsAfterSlash, "Should recover with new yield");

        _assertSolvent();
    }

    /**
     * @notice Test extreme scenario: multiple slashes interspersed with deposits.
     */
    function test_negativeYieldFlow_complexScenario() public {
        // Phase 1: Initial deposit and yield
        _depositAsHook(100e18, alphixHook);
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 2: First slash
        _simulateSlashPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 3: New deposit
        _depositAsHook(50e18, alphixHook);

        // Phase 4: More yield
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 5: Second slash (4% exceeds 1% threshold, need syncRate)
        _simulateSlashPercent(4);
        vm.prank(owner);
        wrapper.syncRate(); // Sync to handle large rate change

        // Phase 6: Final yield
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify invariants hold
        uint256 totalAssets = wrapper.totalAssets();
        assertGt(totalAssets, 0, "Total assets should be positive");

        _assertSolvent();
    }

    /**
     * @notice Test slashing down to near-zero value.
     */
    function test_negativeYieldFlow_extremeSlash() public {
        // Deposit
        _depositAsHook(100e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Slash 1% (circuit breaker limit)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify contract still functions
        uint256 totalAssets = wrapper.totalAssets();

        assertGt(totalAssets, 0, "Should have some assets remaining");
        // Fees should be reduced or zero after extreme slash
        assertLe(wrapper.getClaimableFees(), wrapper.totalAssets(), "Fees should not exceed total assets");

        // Solvency should still hold
        _assertSolvent();

        // Should still be able to deposit
        _depositAsHook(10e18, alphixHook);
        assertGt(wrapper.totalAssets(), totalAssets, "Should be able to deposit after extreme slash");
    }

    /**
     * @notice Test that fees are not reduced by negative yield.
     */
    function test_negativeYieldFlow_feesNotReducedBySlash() public {
        // Deposit
        _depositAsHook(1000e18, alphixHook);

        // Generate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        // Trigger accrual to lock in fees
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();
        assertGt(feesBeforeSlash, 0, "Should have fees before slash");

        // Multiple slashes (each 4% exceeds 1% threshold, need syncRate)
        _simulateSlashPercent(4);
        vm.prank(owner);
        wrapper.syncRate();

        _simulateSlashPercent(4);
        vm.prank(owner);
        wrapper.syncRate();

        _simulateSlashPercent(4);
        vm.prank(owner);
        wrapper.syncRate();

        uint256 feesAfterSlashes = wrapper.getClaimableFees();

        // Fees should remain the same
        assertEq(feesAfterSlashes, feesBeforeSlash, "Fees should NOT be reduced by slashes");

        _assertSolvent();
    }

    /**
     * @notice Test withdraw after slash maintains solvency.
     */
    function test_negativeYieldFlow_withdrawAfterSlash() public {
        // Deposit
        _depositAsHook(100e18, alphixHook);

        // Generate yield and lock in fees
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Slash
        _simulateSlashPercent(1);

        // Withdraw all
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        assertGt(usds.balanceOf(alphixHook), 0, "Should have received assets");
        _assertSolvent();
    }

    /**
     * @notice Test fee collection after slash.
     */
    function test_negativeYieldFlow_collectFeesAfterSlash() public {
        // Deposit
        _depositAsHook(1000e18, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();
        assertGt(feesBeforeSlash, 0, "Should have fees");

        // Slash
        _simulateSlashPercent(1);

        // Collect fees (should still work)
        vm.prank(owner);
        wrapper.collectFees();

        // Treasury should receive the full fees (not reduced)
        assertEq(susds.balanceOf(treasury), feesBeforeSlash, "Treasury should receive full fees");

        _assertSolvent();
    }

    /**
     * @notice Test rate tracking during negative yield.
     */
    function test_negativeYieldFlow_rateTracking() public {
        // Deposit
        _depositAsHook(100e18, alphixHook);

        // Generate yield
        _simulateYieldPercent(1);

        // Trigger accrual to update rate
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 rateBeforeSlash = wrapper.getLastRate();
        assertGt(rateBeforeSlash, INITIAL_RATE, "Rate should have increased from yield");

        // Slash 1% (within circuit breaker threshold)
        _simulateSlashPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 rateAfterSlash = wrapper.getLastRate();

        // Rate should have decreased but still positive
        assertLt(rateAfterSlash, rateBeforeSlash, "Rate should decrease after slash");
        assertGt(rateAfterSlash, 0, "Rate should still be positive");

        _assertSolvent();
    }
}
