// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title SyncRateFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperSky syncRate functionality.
 */
contract SyncRateFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test: syncRate works for any yield percentage.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage (2-100, > 1% to trigger circuit breaker).
     */
    function testFuzz_syncRate_anyYieldPercent(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 100e18, 10_000_000e18);
        yieldPercent = bound(yieldPercent, 2, 100); // > 1% to trigger circuit breaker

        _depositAsHook(depositAmount, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        uint256 currentRate = rateProvider.getConversionRate();

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        uint256 lastRateAfter = wrapper.getLastRate();

        // Rate should now equal current rate
        assertEq(lastRateAfter, currentRate, "Rate should sync to current rate");
        assertGt(lastRateAfter, lastRateBefore, "Rate should have increased");
    }

    /**
     * @notice Fuzz test: syncRate works for any slash percentage.
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage (2-50, > 1% to trigger circuit breaker).
     */
    function testFuzz_syncRate_anySlashPercent(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 100e18, 10_000_000e18);
        slashPercent = bound(slashPercent, 2, 50); // > 1% to trigger circuit breaker

        _depositAsHook(depositAmount, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();

        // Simulate slash
        _simulateSlashPercent(slashPercent);

        uint256 currentRate = rateProvider.getConversionRate();

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        uint256 lastRateAfter = wrapper.getLastRate();

        // Rate should now equal current rate
        assertEq(lastRateAfter, currentRate, "Rate should sync to current rate");
        assertLt(lastRateAfter, lastRateBefore, "Rate should have decreased");
    }

    /**
     * @notice Fuzz test: syncRate unblocks deposit for any blocked rate.
     * @param depositAmount The initial deposit amount.
     * @param secondDepositAmount The second deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_syncRate_unblocksDeposit(uint256 depositAmount, uint256 secondDepositAmount, uint256 yieldPercent)
        public
    {
        depositAmount = bound(depositAmount, 100e18, 1_000_000e18);
        secondDepositAmount = bound(secondDepositAmount, 1e18, 100_000e18);
        yieldPercent = bound(yieldPercent, 2, 100);

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield beyond circuit breaker
        _simulateYieldPercent(yieldPercent);

        // Deposit should fail
        usds.mint(alphixHook, secondDepositAmount);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), secondDepositAmount);
        vm.expectRevert();
        wrapper.deposit(secondDepositAmount, alphixHook);
        vm.stopPrank();

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        // Now deposit should succeed
        vm.prank(alphixHook);
        uint256 shares = wrapper.deposit(secondDepositAmount, alphixHook);
        assertGt(shares, 0, "Deposit should succeed after sync");
    }

    /**
     * @notice Fuzz test: syncRate unblocks withdraw for any blocked rate.
     * @param depositAmount The deposit amount.
     * @param withdrawAmount The withdraw amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_syncRate_unblocksWithdraw(uint256 depositAmount, uint256 withdrawAmount, uint256 yieldPercent)
        public
    {
        depositAmount = bound(depositAmount, 100e18, 1_000_000e18);
        yieldPercent = bound(yieldPercent, 2, 100);

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield beyond circuit breaker
        _simulateYieldPercent(yieldPercent);

        // Withdraw should fail
        vm.prank(alphixHook);
        vm.expectRevert();
        wrapper.withdraw(depositAmount / 2, alphixHook, alphixHook);

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        // Now get actual maxWithdraw and withdraw within bounds
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        withdrawAmount = bound(withdrawAmount, 1, maxWithdraw);

        // Now withdraw should succeed
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        assertGt(sharesBurned, 0, "Withdraw should succeed after sync");
    }

    /**
     * @notice Fuzz test: syncRate does not change share balances.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_syncRate_preservesShareBalances(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 100e18, 10_000_000e18);
        yieldPercent = bound(yieldPercent, 2, 100);

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Record balances before sync
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 totalSupplyBefore = wrapper.totalSupply();

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        // Verify balances unchanged
        assertEq(wrapper.balanceOf(alphixHook), sharesBefore, "Share balance should not change");
        assertEq(wrapper.totalSupply(), totalSupplyBefore, "Total supply should not change");
    }

    /**
     * @notice Fuzz test: second syncRate call always reverts.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_syncRate_secondCallReverts(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 100e18, 10_000_000e18);
        yieldPercent = bound(yieldPercent, 2, 100);

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        // First sync succeeds
        vm.prank(owner);
        wrapper.syncRate();

        // Second sync reverts
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.NoSyncNeeded.selector);
        wrapper.syncRate();
    }

    /**
     * @notice Fuzz test: syncRate followed by deposit maintains solvency.
     * @param depositAmount The initial deposit.
     * @param secondDeposit The second deposit.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_syncRate_thenDeposit_maintainsSolvency(
        uint256 depositAmount,
        uint256 secondDeposit,
        uint256 yieldPercent
    ) public {
        depositAmount = bound(depositAmount, 100e18, 1_000_000e18);
        secondDeposit = bound(secondDeposit, 1e18, 100_000e18);
        yieldPercent = bound(yieldPercent, 2, 100);

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        // Deposit
        usds.mint(alphixHook, secondDeposit);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), secondDeposit);
        wrapper.deposit(secondDeposit, alphixHook);
        vm.stopPrank();

        // Check solvency: totalAssets should be positive
        uint256 totalAssets = wrapper.totalAssets();
        assertGt(totalAssets, 0, "Total assets should be positive");

        // Total supply should match shares minted
        uint256 totalSupply = wrapper.totalSupply();
        assertGt(totalSupply, 0, "Total supply should be positive");
    }

    /**
     * @notice Fuzz test: syncRate followed by withdraw maintains solvency.
     * @param depositAmount The deposit amount.
     * @param withdrawPercent The percentage to withdraw (1-99).
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_syncRate_thenWithdraw_maintainsSolvency(
        uint256 depositAmount,
        uint256 withdrawPercent,
        uint256 yieldPercent
    ) public {
        depositAmount = bound(depositAmount, 100e18, 1_000_000e18);
        withdrawPercent = bound(withdrawPercent, 1, 99); // Not 100% to leave some balance
        yieldPercent = bound(yieldPercent, 2, 100);

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        // Sync rate
        vm.prank(owner);
        wrapper.syncRate();

        // Withdraw percentage of max
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = (maxWithdraw * withdrawPercent) / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        // Check solvency: remaining shares should have positive value
        uint256 remainingShares = wrapper.balanceOf(alphixHook);
        if (remainingShares > 0) {
            uint256 remainingAssets = wrapper.maxWithdraw(alphixHook);
            assertGt(remainingAssets, 0, "Remaining shares should have value");
        }
    }
}
