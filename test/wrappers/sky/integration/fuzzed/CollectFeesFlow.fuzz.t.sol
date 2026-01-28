// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title CollectFeesFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for fee collection flow integration scenarios.
 */
contract CollectFeesFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test fee collection with varying yields.
     */
    function testFuzz_collectFeesFlow_varyingYield(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFees = wrapper.getClaimableFees();

        if (claimableFees > 0) {
            uint256 treasuryBefore = susds.balanceOf(treasury);

            vm.prank(owner);
            wrapper.collectFees();

            assertEq(susds.balanceOf(treasury) - treasuryBefore, claimableFees, "Treasury should receive exact fees");
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple fee collection cycles.
     */
    function testFuzz_collectFeesFlow_multipleCycles(uint256 depositMultiplier, uint8[5] memory yieldPercents) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalFeesCollected;

        for (uint256 i = 0; i < yieldPercents.length; i++) {
            uint256 yieldPct = bound(yieldPercents[i], 1, 1); // Circuit breaker limits to 1%
            _simulateYieldPercent(yieldPct);

            uint256 fees = wrapper.getClaimableFees();
            if (fees > 0) {
                vm.prank(owner);
                wrapper.collectFees();
                totalFeesCollected += fees;
            }
        }

        assertEq(susds.balanceOf(treasury), totalFeesCollected, "Treasury should have total fees");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection maintains accounting.
     */
    function testFuzz_collectFeesFlow_maintainsAccounting(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        if (claimableFees > 0) {
            vm.prank(owner);
            wrapper.collectFees();
        }

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should remain approximately the same
        // (fees were already excluded from totalAssets calculation)
        _assertApproxEq(totalAssetsAfter, totalAssetsBefore, 2, "Total assets unchanged");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection with multiple users.
     */
    function testFuzz_collectFeesFlow_multipleUsers(
        uint256 deposit1Multiplier,
        uint256 deposit2Multiplier,
        uint256 yieldPercent
    ) public {
        deposit1Multiplier = bound(deposit1Multiplier, 1, 1_000_000);
        deposit2Multiplier = bound(deposit2Multiplier, 1, 1_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        // Multiple users deposit
        _depositAsHook(deposit1Multiplier * 1e18, alphixHook);

        usds.mint(owner, deposit2Multiplier * 1e18);
        vm.startPrank(owner);
        usds.approve(address(wrapper), deposit2Multiplier * 1e18);
        wrapper.deposit(deposit2Multiplier * 1e18, owner);
        vm.stopPrank();

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 fees = wrapper.getClaimableFees();
        if (fees > 0) {
            vm.prank(owner);
            wrapper.collectFees();
        }

        // Both users should still be able to withdraw
        uint256 hookMax = wrapper.maxWithdraw(alphixHook);
        uint256 ownerMax = wrapper.maxWithdraw(owner);

        assertGt(hookMax, 0, "Hook should have withdrawable");
        assertGt(ownerMax, 0, "Owner should have withdrawable");

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection after partial withdrawals.
     */
    function testFuzz_collectFeesFlow_afterWithdrawal(
        uint256 depositMultiplier,
        uint256 withdrawPercent,
        uint256 yieldPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 50);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        // Partial withdrawal
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
}
