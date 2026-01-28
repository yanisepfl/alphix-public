// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title DepositFlowTest
 * @author Alphix
 * @notice Integration tests for complete deposit user flows.
 * @dev Sky-specific: deposits swap USDS → sUSDS via PSM
 */
contract DepositFlowTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests a complete deposit flow from hook.
     */
    function test_depositFlow_hookDepositAndCheckBalances() public {
        uint256 depositAmount = 1_000e18;

        // Initial state
        uint256 initialTotalAssets = wrapper.totalAssets();
        uint256 initialTotalSupply = wrapper.totalSupply();
        uint256 initialHookShares = wrapper.balanceOf(alphixHook);
        uint256 initialSusdsBalance = susds.balanceOf(address(wrapper));

        // Hook deposits
        usds.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Verify state changes
        assertApproxEqAbs(wrapper.totalAssets(), initialTotalAssets + depositAmount, 2, "Total assets should increase");
        assertEq(wrapper.totalSupply(), initialTotalSupply + shares, "Total supply should increase");
        assertEq(wrapper.balanceOf(alphixHook), initialHookShares + shares, "Hook shares should increase");

        // Verify sUSDS balance increased (deposit swaps USDS → sUSDS)
        uint256 expectedSusds = _usdsToSusds(depositAmount);
        assertApproxEqAbs(
            susds.balanceOf(address(wrapper)), initialSusdsBalance + expectedSusds, 2, "sUSDS balance should match"
        );

        // Verify solvency
        _assertSolvent();
    }

    /**
     * @notice Tests deposit flow with yield accrual between deposits.
     */
    function test_depositFlow_multipleDepositsWithYield() public {
        // First deposit
        uint256 deposit1 = 1_000e18;
        uint256 shares1 = _depositAsHook(deposit1, alphixHook);

        // Simulate yield (rate increase, 1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Second deposit (should get fewer shares due to yield)
        uint256 deposit2 = 1_000e18;
        uint256 shares2 = _depositAsHook(deposit2, alphixHook);

        // After yield, the share price is higher, so same deposit gets fewer shares
        assertLt(shares2, shares1, "Second deposit should get fewer shares after yield");

        // Total shares
        assertEq(wrapper.balanceOf(alphixHook), shares1 + shares2, "Total shares should be sum");

        _assertSolvent();
    }

    /**
     * @notice Tests deposit flow with fee change.
     */
    function test_depositFlow_depositAfterFeeChange() public {
        // First deposit at default fee
        uint256 deposit1 = 1_000e18;
        _depositAsHook(deposit1, alphixHook);

        // Simulate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Change fee to 50%
        vm.prank(owner);
        wrapper.setFee(500_000);

        // Second deposit
        uint256 deposit2 = 1_000e18;
        _depositAsHook(deposit2, alphixHook);

        // Verify fee was applied to first yield
        assertGt(wrapper.getClaimableFees(), 0, "Fees should have been accrued");

        _assertSolvent();
    }

    /**
     * @notice Tests deposit flow from owner.
     */
    function test_depositFlow_ownerDeposit() public {
        uint256 depositAmount = 500e18;

        usds.mint(owner, depositAmount);

        vm.startPrank(owner);
        usds.approve(address(wrapper), depositAmount);

        uint256 sharesBefore = wrapper.balanceOf(owner);
        uint256 shares = wrapper.deposit(depositAmount, owner);
        uint256 sharesAfter = wrapper.balanceOf(owner);
        vm.stopPrank();

        // Owner already has shares from seed deposit
        assertGt(sharesBefore, 0, "Owner should have seed shares");
        assertEq(sharesAfter, sharesBefore + shares, "Owner shares should increase");

        _assertSolvent();
    }

    /**
     * @notice Tests deposit flow - hook and owner each deposit to themselves.
     */
    function test_depositFlow_hookAndOwnerEachDepositToSelf() public {
        uint256 depositAmount = 1_000e18;

        // Hook deposits to self
        uint256 hookSharesBefore = wrapper.balanceOf(alphixHook);
        usds.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), depositAmount);
        uint256 hookShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(alphixHook), hookSharesBefore + hookShares, "Hook should receive shares");

        // Owner deposits to self
        uint256 ownerSharesBefore = wrapper.balanceOf(owner);
        usds.mint(owner, depositAmount);
        vm.startPrank(owner);
        usds.approve(address(wrapper), depositAmount);
        uint256 ownerShares = wrapper.deposit(depositAmount, owner);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(owner), ownerSharesBefore + ownerShares, "Owner should receive shares");

        _assertSolvent();
    }

    /**
     * @notice Tests deposit at various rate levels.
     */
    function test_depositFlow_atDifferentRates() public {
        // Deposit at 1:1 rate
        uint256 deposit1 = 1_000e18;
        uint256 shares1 = _depositAsHook(deposit1, alphixHook);

        // Simulate 1% rate increase (respects circuit breaker)
        _simulateYieldPercent(1);

        // Deposit at higher rate
        uint256 deposit2 = 1_000e18;
        uint256 shares2 = _depositAsHook(deposit2, alphixHook);

        // Second deposit should get fewer shares due to rate increase
        // (sUSDS is now worth more)
        assertLt(shares2, shares1, "Should get fewer shares at higher rate");

        // Both deposits should be able to withdraw their proportional share
        uint256 totalAssets = wrapper.maxWithdraw(alphixHook);

        // Total assets should be close to deposits minus fees
        assertGt(totalAssets, deposit1 + deposit2 - (deposit1 + deposit2) / 10, "Should have most assets");
        // Verify shares were minted
        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have shares");

        _assertSolvent();
    }

    /**
     * @notice Tests deposit after multiple yield cycles.
     */
    function test_depositFlow_afterMultipleYieldCycles() public {
        uint256 depositAmount = 1_000e18;

        // Initial deposit
        uint256 initialShares = _depositAsHook(depositAmount, alphixHook);

        // Multiple yield cycles (1% each) with accrual between each
        // Circuit breaker checks per-accrual, so we must trigger accrual between yield changes
        for (uint256 i = 0; i < 5; i++) {
            _simulateYieldPercent(1);
            // Trigger accrual to update lastRate before next yield
            vm.prank(owner);
            wrapper.setFee(DEFAULT_FEE);
        }

        // New deposit of same amount after all yield
        uint256 newShares = _depositAsHook(depositAmount, alphixHook);

        // Should receive fewer shares due to accumulated yield (rate has increased)
        assertLt(newShares, initialShares, "Should get fewer shares after yield");

        _assertSolvent();
    }
}
