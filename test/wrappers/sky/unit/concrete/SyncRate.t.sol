// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SyncRateTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky syncRate functionality.
 * @dev Tests the circuit breaker recovery mechanism that syncs _lastRate to current rate.
 */
contract SyncRateTest is BaseAlphix4626WrapperSky {
    /* EVENTS - Redeclared for testing */
    event RateSynced(uint256 indexed oldRate, uint256 indexed newRate, uint256 targetRate);

    /* BASIC FUNCTIONALITY */

    /**
     * @notice Test that syncRate succeeds when rate increased beyond 1%.
     */
    function test_syncRate_succeeds_whenRateIncreased() public {
        // Deposit first to have meaningful state
        _depositAsHook(1000e18, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();

        // Simulate 10% rate increase (beyond 1% circuit breaker)
        _simulateYieldPercent(10);

        uint256 currentRate = rateProvider.getConversionRate();

        // Verify deposit would fail due to circuit breaker
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();

        // Sync rate as owner
        vm.prank(owner);
        wrapper.syncRate();

        uint256 lastRateAfter = wrapper.getLastRate();

        // Rate should now equal current rate (single call sync)
        assertEq(lastRateAfter, currentRate, "Rate should sync to current rate");
        assertGt(lastRateAfter, lastRateBefore, "Rate should have increased");
    }

    /**
     * @notice Test that syncRate succeeds when rate decreased beyond 1%.
     */
    function test_syncRate_succeeds_whenRateDecreased() public {
        // Deposit first
        _depositAsHook(1000e18, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();

        // Simulate 5% rate decrease (slash, beyond 1% circuit breaker)
        _simulateSlashPercent(5);

        uint256 currentRate = rateProvider.getConversionRate();

        // Verify deposit would fail due to circuit breaker
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();

        // Sync rate as owner
        vm.prank(owner);
        wrapper.syncRate();

        uint256 lastRateAfter = wrapper.getLastRate();

        // Rate should now equal current rate (single call sync)
        assertEq(lastRateAfter, currentRate, "Rate should sync to current rate");
        assertLt(lastRateAfter, lastRateBefore, "Rate should have decreased");
    }

    /**
     * @notice Test that syncRate reverts when no change is needed.
     */
    function test_syncRate_reverts_whenNoChangeNeeded() public {
        // Deposit to initialize state
        _depositAsHook(1000e18, alphixHook);

        // No rate change - should revert
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.NoSyncNeeded.selector);
        wrapper.syncRate();
    }

    /**
     * @notice Test that syncRate reverts when not called by owner.
     */
    function test_syncRate_reverts_whenNotOwner() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(10);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wrapper.syncRate();

        vm.prank(alphixHook);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alphixHook));
        wrapper.syncRate();
    }

    /* UNBLOCKING OPERATIONS */

    /**
     * @notice Test that syncRate unblocks deposit after large rate jump.
     */
    function test_syncRate_unblocks_deposit_afterLargeRateJump() public {
        _depositAsHook(1000e18, alphixHook);

        // 10% rate increase (beyond 1% threshold)
        _simulateYieldPercent(10);

        // Deposit fails before sync
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();

        // Single sync should unblock
        vm.prank(owner);
        wrapper.syncRate();

        // Now deposit should succeed
        vm.prank(alphixHook);
        uint256 shares = wrapper.deposit(100e18, alphixHook);
        assertGt(shares, 0, "Deposit should succeed after sync");
    }

    /**
     * @notice Test that syncRate unblocks withdraw after large rate jump.
     */
    function test_syncRate_unblocks_withdraw_afterLargeRateJump() public {
        _depositAsHook(1000e18, alphixHook);

        // 5% rate increase (beyond 1% threshold)
        _simulateYieldPercent(5);

        // Withdraw fails before sync
        vm.prank(alphixHook);
        vm.expectRevert();
        wrapper.withdraw(100e18, alphixHook, alphixHook);

        // Single sync should unblock
        vm.prank(owner);
        wrapper.syncRate();

        // Now withdraw should succeed
        vm.prank(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(100e18, alphixHook, alphixHook);
        assertGt(sharesBurned, 0, "Withdraw should succeed after sync");
    }

    /**
     * @notice Test that second syncRate call reverts (already synced).
     */
    function test_syncRate_secondCallReverts() public {
        _depositAsHook(1000e18, alphixHook);

        // 10% rate increase (beyond 1% threshold)
        _simulateYieldPercent(10);

        // First sync succeeds
        vm.prank(owner);
        wrapper.syncRate();

        // Second call should revert - already at current rate
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.NoSyncNeeded.selector);
        wrapper.syncRate();
    }

    /**
     * @notice Test that syncRate emits the correct event.
     */
    function test_syncRate_emitsEvent() public {
        _depositAsHook(1000e18, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();
        _simulateYieldPercent(10);
        uint256 currentRate = rateProvider.getConversionRate();

        vm.expectEmit(true, true, false, true);
        emit RateSynced(lastRateBefore, currentRate, currentRate);

        vm.prank(owner);
        wrapper.syncRate();
    }

    /* EDGE CASES */

    /**
     * @notice Test sync when rate increase exceeds 1% threshold.
     */
    function test_syncRate_smallRateIncrease_syncsToExactRate() public {
        _depositAsHook(1000e18, alphixHook);

        // 3% rate increase (beyond 1% threshold) - should sync to exact rate in one call
        _simulateYieldPercent(3);

        uint256 targetRate = rateProvider.getConversionRate();

        vm.prank(owner);
        wrapper.syncRate();

        uint256 finalRate = wrapper.getLastRate();
        assertEq(finalRate, targetRate, "Should sync to exact rate");

        // Should revert on next call
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.NoSyncNeeded.selector);
        wrapper.syncRate();
    }

    /**
     * @notice Test that syncRate accrues yield and fees properly.
     * @dev syncRate should accrue yield (and fees) while bypassing circuit breaker.
     */
    function test_syncRate_accruesYield() public {
        _depositAsHook(1000e18, alphixHook);

        // Simulate yield (beyond 1% threshold)
        _simulateYieldPercent(10);

        // Get fees before sync (should be 0 since no accrual yet)
        // Note: getClaimableFees() includes pending, so we need to check after sync
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 totalSupplyBefore = wrapper.totalSupply();

        // Sync to catch up to rate - this should accrue yield
        vm.prank(owner);
        wrapper.syncRate();

        // Shares should NOT change from sync alone (no minting/burning)
        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        assertEq(sharesBefore, sharesAfter, "syncRate should not change share balance");

        // totalSupply should also remain unchanged from sync
        uint256 totalSupplyAfter = wrapper.totalSupply();
        assertEq(totalSupplyBefore, totalSupplyAfter, "totalSupply should not change from sync");

        // Fees should have been accrued (assuming non-zero fee)
        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "syncRate should accrue fees from yield");
    }

    /**
     * @notice Test sync then normal operations resume yield accrual.
     */
    function test_syncRate_thenDeposit_accruedYieldCorrectly() public {
        _depositAsHook(1000e18, alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);

        // 5% rate increase (beyond 1% threshold)
        _simulateYieldPercent(5);

        // Sync fully (single call)
        vm.prank(owner);
        wrapper.syncRate();

        // Now deposit - this should work and accrue any remaining yield
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        assertGt(sharesAfter, sharesBefore, "Should have more shares after deposit");

        // Total assets should reflect the rate increase
        uint256 totalAssets = wrapper.totalAssets();
        assertGt(totalAssets, 1000e18, "Total assets should increase with rate");
    }
}
