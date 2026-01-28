// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title WithdrawTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave withdraw functionality.
 * @dev Note: withdraw requires owner_ == msg.sender. Receiver can be any address.
 */
contract WithdrawTest is BaseAlphix4626WrapperAave {
    /* SETUP */

    function setUp() public override {
        super.setUp();
        // Give hook some shares to withdraw
        _depositAsHookToSelf(100e6);
    }

    /* HELPER */

    /**
     * @notice Helper to deposit as hook to self (respecting new receiver constraint).
     */
    function _depositAsHookToSelf(uint256 amount) internal returns (uint256 shares) {
        asset.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Helper to deposit as owner to self.
     */
    function _depositAsOwnerToSelf(uint256 amount) internal returns (uint256 shares) {
        asset.mint(owner, amount);
        vm.startPrank(owner);
        asset.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, owner);
        vm.stopPrank();
    }

    /* WITHDRAW TESTS */

    /**
     * @notice Tests that the hook can withdraw to itself successfully.
     */
    function test_withdraw_asHook_toSelf_succeeds() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 assetsBefore = asset.balanceOf(alphixHook);

        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 assetsAfter = asset.balanceOf(alphixHook);

        assertGt(sharesBurned, 0, "No shares burned");
        assertEq(sharesBefore - sharesAfter, sharesBurned, "Share balance mismatch");
        assertEq(assetsAfter - assetsBefore, withdrawAmount, "Asset balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that the owner can withdraw to itself successfully.
     */
    function test_withdraw_asOwner_toSelf_succeeds() public {
        // First deposit as owner
        _depositAsOwnerToSelf(100e6);

        uint256 withdrawAmount = 50e6;

        vm.startPrank(owner);
        uint256 sharesBefore = wrapper.balanceOf(owner);
        uint256 assetsBefore = asset.balanceOf(owner);

        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, owner, owner);

        uint256 sharesAfter = wrapper.balanceOf(owner);
        uint256 assetsAfter = asset.balanceOf(owner);

        assertGt(sharesBurned, 0, "No shares burned");
        assertEq(sharesBefore - sharesAfter, sharesBurned, "Share balance mismatch");
        assertEq(assetsAfter - assetsBefore, withdrawAmount, "Asset balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that unauthorized callers cannot withdraw.
     */
    function test_withdraw_unauthorizedCaller_reverts() public {
        vm.startPrank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.withdraw(50e6, unauthorized, unauthorized);
        vm.stopPrank();
    }

    /**
     * @notice Tests that alice (not hook or owner) cannot withdraw.
     */
    function test_withdraw_asAlice_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.withdraw(50e6, alice, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that hook can withdraw to a different receiver.
     */
    function test_withdraw_toDifferentReceiver_succeeds() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alice, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 aliceAssetsAfter = asset.balanceOf(alice);

        assertGt(sharesBurned, 0, "No shares burned");
        assertEq(sharesBefore - sharesAfter, sharesBurned, "Share balance mismatch");
        assertEq(aliceAssetsAfter - aliceAssetsBefore, withdrawAmount, "Alice should receive assets");
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw reverts when owner != msg.sender.
     */
    function test_withdraw_ownerNotCaller_reverts() public {
        // First deposit as owner
        _depositAsOwnerToSelf(100e6);

        // Hook tries to withdraw owner's shares
        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.CallerNotOwner.selector);
        wrapper.withdraw(50e6, owner, owner);
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw reverts when trying to withdraw more than maxWithdraw.
     */
    function test_withdraw_exceedsMax_reverts() public {
        uint256 maxAmount = wrapper.maxWithdraw(alphixHook);

        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.WithdrawExceedsMax.selector);
        wrapper.withdraw(maxAmount + 1, alphixHook, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw emits the correct event.
     */
    function test_withdraw_emitsEvent() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        uint256 expectedShares = wrapper.previewWithdraw(withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alphixHook, alphixHook, alphixHook, withdrawAmount, expectedShares);

        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw to different receiver emits correct event.
     */
    function test_withdraw_toDifferentReceiver_emitsEvent() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        uint256 expectedShares = wrapper.previewWithdraw(withdrawAmount);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alphixHook, alice, alphixHook, withdrawAmount, expectedShares);

        wrapper.withdraw(withdrawAmount, alice, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw transfers assets correctly.
     */
    function test_withdraw_transfersAssets() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        uint256 hookAssetsBefore = asset.balanceOf(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        uint256 hookAssetsAfter = asset.balanceOf(alphixHook);

        assertEq(hookAssetsAfter - hookAssetsBefore, withdrawAmount, "Assets not transferred correctly");
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw burns shares correctly.
     */
    function test_withdraw_burnsShares() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, sharesBurned, "Shares not burned correctly");
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw updates lastWrapperBalance.
     */
    function test_withdraw_updatesLastWrapperBalance() public {
        uint256 withdrawAmount = 50e6;

        vm.startPrank(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        uint256 expectedBalance = aToken.balanceOf(address(wrapper));
        assertEq(wrapper.getLastWrapperBalance(), expectedBalance, "lastWrapperBalance not updated");
        vm.stopPrank();
    }

    /**
     * @notice Tests full withdrawal of all shares.
     */
    function test_withdraw_fullWithdrawal_succeeds() public {
        vm.startPrank(alphixHook);
        uint256 maxWithdrawable = wrapper.maxWithdraw(alphixHook);

        uint256 sharesBurned = wrapper.withdraw(maxWithdrawable, alphixHook, alphixHook);

        assertGt(sharesBurned, 0, "No shares burned");
        // Note: May have dust remaining due to rounding
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw maintains solvency.
     */
    function test_withdraw_maintainsSolvency() public {
        uint256 withdrawAmount = 50e6;

        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests withdraw after yield accrual.
     */
    function test_withdraw_afterYieldAccrual_succeeds() public {
        // Simulate 10% yield
        _simulateYieldPercent(10);

        vm.startPrank(alphixHook);
        uint256 maxWithdrawable = wrapper.maxWithdraw(alphixHook);
        // Should be able to withdraw more than deposited due to yield
        assertGt(maxWithdrawable, 0, "Max withdraw should be positive");

        uint256 withdrawAmount = maxWithdrawable / 2;
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertGt(sharesBurned, 0, "No shares burned");
        vm.stopPrank();
    }

    /* MAX WITHDRAW TESTS */

    /**
     * @notice Tests that maxWithdraw returns correct value for hook.
     */
    function test_maxWithdraw_returnsCorrectValueForHook() public view {
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 hookBalance = wrapper.balanceOf(alphixHook);
        uint256 convertedAssets = wrapper.convertToAssets(hookBalance);

        // maxWithdraw should be min of Aave liquidity and converted assets
        assertLe(maxWithdraw, convertedAssets, "maxWithdraw should not exceed converted assets");
        assertGt(maxWithdraw, 0, "maxWithdraw should be positive");
    }

    /**
     * @notice Tests that maxWithdraw returns correct value for owner.
     */
    function test_maxWithdraw_returnsCorrectValueForOwner() public {
        // Deposit as owner first
        _depositAsOwnerToSelf(100e6);

        uint256 maxWithdraw = wrapper.maxWithdraw(owner);
        assertGt(maxWithdraw, 0, "maxWithdraw should be positive for owner");
    }

    /**
     * @notice Tests that maxWithdraw returns 0 for unauthorized address.
     */
    function test_maxWithdraw_returnsZeroForUnauthorized() public view {
        assertEq(wrapper.maxWithdraw(alice), 0, "maxWithdraw should be 0 for unauthorized");
        assertEq(wrapper.maxWithdraw(bob), 0, "maxWithdraw should be 0 for unauthorized");
        assertEq(wrapper.maxWithdraw(unauthorized), 0, "maxWithdraw should be 0 for unauthorized");
    }

    /**
     * @notice Tests that maxWithdraw returns 0 for address(0).
     */
    function test_maxWithdraw_returnsZeroForZeroAddress() public view {
        assertEq(wrapper.maxWithdraw(address(0)), 0, "maxWithdraw should be 0 for zero address");
    }

    /**
     * @notice Tests that a second hook can withdraw.
     */
    function test_withdraw_secondHook_succeeds() public {
        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Deposit as hook2
        asset.mint(hook2, 100e6);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), 100e6);
        wrapper.deposit(100e6, hook2);

        // Withdraw as hook2
        uint256 withdrawAmount = 50e6;
        uint256 assetsBefore = asset.balanceOf(hook2);
        wrapper.withdraw(withdrawAmount, hook2, hook2);
        uint256 assetsAfter = asset.balanceOf(hook2);

        assertEq(assetsAfter - assetsBefore, withdrawAmount, "Assets not received");
        vm.stopPrank();
    }

    /**
     * @notice Tests that a removed hook cannot withdraw.
     */
    function test_withdraw_removedHook_reverts() public {
        address hook2 = makeAddr("hook2");

        // Add hook2 and deposit
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        asset.mint(hook2, 100e6);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), 100e6);
        wrapper.deposit(100e6, hook2);
        vm.stopPrank();

        // Remove hook2
        vm.prank(owner);
        wrapper.removeAlphixHook(hook2);

        // Try to withdraw - should fail
        vm.startPrank(hook2);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.withdraw(50e6, hook2, hook2);
        vm.stopPrank();
    }

    /**
     * @notice Tests multiple sequential withdrawals.
     */
    function test_withdraw_multipleWithdrawals_succeeds() public {
        vm.startPrank(alphixHook);

        uint256 withdraw1 = 20e6;
        uint256 withdraw2 = 30e6;

        uint256 assetsBefore = asset.balanceOf(alphixHook);

        wrapper.withdraw(withdraw1, alphixHook, alphixHook);
        wrapper.withdraw(withdraw2, alphixHook, alphixHook);

        uint256 assetsAfter = asset.balanceOf(alphixHook);

        assertEq(assetsAfter - assetsBefore, withdraw1 + withdraw2, "Total withdrawal mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that withdraw with zero amount reverts.
     */
    function test_withdraw_zeroAmount_reverts() public {
        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroShares.selector);
        wrapper.withdraw(0, alphixHook, alphixHook);
        vm.stopPrank();
    }

    /* RESERVE STATUS TESTS */

    /**
     * @notice Tests that maxWithdraw returns 0 when reserve is inactive.
     */
    function test_maxWithdraw_returnsZeroWhenReserveInactive() public {
        // Set reserve as inactive
        aavePool.setReserveConfig(false, false, false, 0);

        assertEq(wrapper.maxWithdraw(alphixHook), 0, "maxWithdraw should be 0 when reserve inactive");
    }

    /**
     * @notice Tests that maxWithdraw returns 0 when reserve is paused.
     */
    function test_maxWithdraw_returnsZeroWhenReservePaused() public {
        // Set reserve as paused (active but paused)
        aavePool.setReserveConfig(true, false, true, 0);

        assertEq(wrapper.maxWithdraw(alphixHook), 0, "maxWithdraw should be 0 when reserve paused");
    }
}
