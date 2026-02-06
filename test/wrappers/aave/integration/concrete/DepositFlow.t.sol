// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title DepositFlowTest
 * @author Alphix
 * @notice Integration tests for complete deposit user flows.
 */
contract DepositFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests a complete deposit flow from hook.
     */
    function test_depositFlow_hookDepositAndCheckBalances() public {
        uint256 depositAmount = 1_000e6;

        // Initial state
        uint256 initialTotalAssets = wrapper.totalAssets();
        uint256 initialTotalSupply = wrapper.totalSupply();
        uint256 initialHookShares = wrapper.balanceOf(alphixHook);
        uint256 initialHookAssets = asset.balanceOf(alphixHook);

        // Hook deposits
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Verify state changes
        assertEq(wrapper.totalAssets(), initialTotalAssets + depositAmount, "Total assets should increase");
        assertEq(wrapper.totalSupply(), initialTotalSupply + shares, "Total supply should increase");
        assertEq(wrapper.balanceOf(alphixHook), initialHookShares + shares, "Hook shares should increase");
        assertEq(asset.balanceOf(alphixHook), initialHookAssets, "Hook asset balance unchanged (minted amount used)");

        // Verify aToken balance
        assertEq(aToken.balanceOf(address(wrapper)), initialTotalAssets + depositAmount, "aToken balance should match");

        // Verify solvency
        _assertSolvent();
    }

    /**
     * @notice Tests deposit flow with yield accrual between deposits.
     */
    function test_depositFlow_multipleDepositsWithYield() public {
        // First deposit
        uint256 deposit1 = 1_000e6;
        uint256 shares1 = _depositAsHook(deposit1, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Second deposit (should get fewer shares due to yield)
        uint256 deposit2 = 1_000e6;
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
        uint256 deposit1 = 1_000e6;
        _depositAsHook(deposit1, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Change fee to 50%
        vm.prank(owner);
        wrapper.setFee(500_000);

        // Second deposit
        uint256 deposit2 = 1_000e6;
        _depositAsHook(deposit2, alphixHook);

        // Verify fee was applied to first yield
        assertGt(wrapper.getClaimableFees(), 0, "Fees should have been accrued");

        _assertSolvent();
    }

    /**
     * @notice Tests deposit flow from owner.
     */
    function test_depositFlow_ownerDeposit() public {
        uint256 depositAmount = 500e6;

        asset.mint(owner, depositAmount);

        vm.startPrank(owner);
        asset.approve(address(wrapper), depositAmount);

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
     * @dev Cross-deposit is no longer allowed (receiver must equal msg.sender).
     */
    function test_depositFlow_hookAndOwnerEachDepositToSelf() public {
        uint256 depositAmount = 1_000e6;

        // Hook deposits to self
        uint256 hookSharesBefore = wrapper.balanceOf(alphixHook);
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 hookShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(alphixHook), hookSharesBefore + hookShares, "Hook should receive shares");

        // Owner deposits to self
        uint256 ownerSharesBefore = wrapper.balanceOf(owner);
        asset.mint(owner, depositAmount);
        vm.startPrank(owner);
        asset.approve(address(wrapper), depositAmount);
        uint256 ownerShares = wrapper.deposit(depositAmount, owner);
        vm.stopPrank();
        assertEq(wrapper.balanceOf(owner), ownerSharesBefore + ownerShares, "Owner should receive shares");

        _assertSolvent();
    }
}
