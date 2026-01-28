// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title RedeemTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave redeem functionality.
 * @dev Note: redeem requires owner_ == msg.sender. Receiver can be any address.
 */
contract RedeemTest is BaseAlphix4626WrapperAave {
    /* SETUP */

    function setUp() public override {
        super.setUp();
        // Give hook some shares to redeem
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

    /* REDEEM TESTS */

    /**
     * @notice Tests that the hook can redeem to itself successfully.
     */
    function test_redeem_asHook_toSelf_succeeds() public {
        vm.startPrank(alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 assetsBefore = asset.balanceOf(alphixHook);

        uint256 redeemShares = sharesBefore / 2;
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 assetsAfter = asset.balanceOf(alphixHook);

        assertGt(assetsReceived, 0, "No assets received");
        assertEq(sharesBefore - sharesAfter, redeemShares, "Share balance mismatch");
        assertEq(assetsAfter - assetsBefore, assetsReceived, "Asset balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that the owner can redeem to itself successfully.
     */
    function test_redeem_asOwner_toSelf_succeeds() public {
        // First deposit as owner
        _depositAsOwnerToSelf(100e6);

        vm.startPrank(owner);
        uint256 sharesBefore = wrapper.balanceOf(owner);
        uint256 assetsBefore = asset.balanceOf(owner);

        uint256 redeemShares = sharesBefore / 2;
        uint256 assetsReceived = wrapper.redeem(redeemShares, owner, owner);

        uint256 sharesAfter = wrapper.balanceOf(owner);
        uint256 assetsAfter = asset.balanceOf(owner);

        assertGt(assetsReceived, 0, "No assets received");
        assertEq(sharesBefore - sharesAfter, redeemShares, "Share balance mismatch");
        assertEq(assetsAfter - assetsBefore, assetsReceived, "Asset balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that unauthorized callers cannot redeem.
     */
    function test_redeem_unauthorizedCaller_reverts() public {
        vm.startPrank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.redeem(50e6, unauthorized, unauthorized);
        vm.stopPrank();
    }

    /**
     * @notice Tests that alice (not hook or owner) cannot redeem.
     */
    function test_redeem_asAlice_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.redeem(50e6, alice, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that hook can redeem to a different receiver.
     */
    function test_redeem_toDifferentReceiver_succeeds() public {
        vm.startPrank(alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        uint256 redeemShares = sharesBefore / 2;
        uint256 assetsReceived = wrapper.redeem(redeemShares, alice, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);
        uint256 aliceAssetsAfter = asset.balanceOf(alice);

        assertGt(assetsReceived, 0, "No assets received");
        assertEq(sharesBefore - sharesAfter, redeemShares, "Share balance mismatch");
        assertEq(aliceAssetsAfter - aliceAssetsBefore, assetsReceived, "Alice should receive assets");
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem reverts when owner != msg.sender.
     */
    function test_redeem_ownerNotCaller_reverts() public {
        // First deposit as owner
        _depositAsOwnerToSelf(100e6);

        // Hook tries to redeem owner's shares
        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.CallerNotOwner.selector);
        wrapper.redeem(50e6, owner, owner);
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem reverts when trying to redeem more than maxRedeem.
     */
    function test_redeem_exceedsMax_reverts() public {
        uint256 maxAmount = wrapper.maxRedeem(alphixHook);

        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.RedeemExceedsMax.selector);
        wrapper.redeem(maxAmount + 1, alphixHook, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem emits the correct event.
     */
    function test_redeem_emitsEvent() public {
        vm.startPrank(alphixHook);
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;
        uint256 expectedAssets = wrapper.previewRedeem(redeemShares);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alphixHook, alphixHook, alphixHook, expectedAssets, redeemShares);

        wrapper.redeem(redeemShares, alphixHook, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem to different receiver emits correct event.
     */
    function test_redeem_toDifferentReceiver_emitsEvent() public {
        vm.startPrank(alphixHook);
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;
        uint256 expectedAssets = wrapper.previewRedeem(redeemShares);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alphixHook, alice, alphixHook, expectedAssets, redeemShares);

        wrapper.redeem(redeemShares, alice, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem transfers assets correctly.
     */
    function test_redeem_transfersAssets() public {
        vm.startPrank(alphixHook);
        uint256 hookAssetsBefore = asset.balanceOf(alphixHook);
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;

        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);
        uint256 hookAssetsAfter = asset.balanceOf(alphixHook);

        assertEq(hookAssetsAfter - hookAssetsBefore, assetsReceived, "Assets not transferred correctly");
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem burns shares correctly.
     */
    function test_redeem_burnsShares() public {
        vm.startPrank(alphixHook);
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 redeemShares = sharesBefore / 2;

        wrapper.redeem(redeemShares, alphixHook, alphixHook);
        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, redeemShares, "Shares not burned correctly");
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem updates lastWrapperBalance.
     */
    function test_redeem_updatesLastWrapperBalance() public {
        vm.startPrank(alphixHook);
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;
        wrapper.redeem(redeemShares, alphixHook, alphixHook);

        uint256 expectedBalance = aToken.balanceOf(address(wrapper));
        assertEq(wrapper.getLastWrapperBalance(), expectedBalance, "lastWrapperBalance not updated");
        vm.stopPrank();
    }

    /**
     * @notice Tests full redemption of all shares.
     */
    function test_redeem_fullRedemption_succeeds() public {
        vm.startPrank(alphixHook);
        uint256 maxRedeemable = wrapper.maxRedeem(alphixHook);

        uint256 assetsReceived = wrapper.redeem(maxRedeemable, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "No assets received");
        // Note: May have dust remaining due to rounding
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem maintains solvency.
     */
    function test_redeem_maintainsSolvency() public {
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;

        vm.prank(alphixHook);
        wrapper.redeem(redeemShares, alphixHook, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests redeem after yield accrual.
     */
    function test_redeem_afterYieldAccrual_succeeds() public {
        // Simulate 10% yield
        _simulateYieldPercent(10);

        vm.startPrank(alphixHook);
        uint256 maxRedeemable = wrapper.maxRedeem(alphixHook);
        // Should be able to get more assets than deposited due to yield
        assertGt(maxRedeemable, 0, "Max redeem should be positive");

        uint256 redeemShares = maxRedeemable / 2;
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "No assets received");
        vm.stopPrank();
    }

    /* MAX REDEEM TESTS */

    /**
     * @notice Tests that maxRedeem returns correct value for hook.
     */
    function test_maxRedeem_returnsCorrectValueForHook() public view {
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 hookBalance = wrapper.balanceOf(alphixHook);

        // maxRedeem should be min of Aave liquidity (in shares) and hook's shares
        assertLe(maxRedeem, hookBalance, "maxRedeem should not exceed share balance");
        assertGt(maxRedeem, 0, "maxRedeem should be positive");
    }

    /**
     * @notice Tests that maxRedeem returns correct value for owner.
     */
    function test_maxRedeem_returnsCorrectValueForOwner() public {
        // Deposit as owner first
        _depositAsOwnerToSelf(100e6);

        uint256 maxRedeem = wrapper.maxRedeem(owner);
        assertGt(maxRedeem, 0, "maxRedeem should be positive for owner");
    }

    /**
     * @notice Tests that maxRedeem returns 0 for unauthorized address.
     */
    function test_maxRedeem_returnsZeroForUnauthorized() public view {
        assertEq(wrapper.maxRedeem(alice), 0, "maxRedeem should be 0 for unauthorized");
        assertEq(wrapper.maxRedeem(bob), 0, "maxRedeem should be 0 for unauthorized");
        assertEq(wrapper.maxRedeem(unauthorized), 0, "maxRedeem should be 0 for unauthorized");
    }

    /**
     * @notice Tests that maxRedeem returns 0 for address(0).
     */
    function test_maxRedeem_returnsZeroForZeroAddress() public view {
        assertEq(wrapper.maxRedeem(address(0)), 0, "maxRedeem should be 0 for zero address");
    }

    /**
     * @notice Tests that a second hook can redeem.
     */
    function test_redeem_secondHook_succeeds() public {
        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Deposit as hook2
        asset.mint(hook2, 100e6);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), 100e6);
        uint256 shares = wrapper.deposit(100e6, hook2);

        // Redeem as hook2
        uint256 redeemShares = shares / 2;
        uint256 assetsBefore = asset.balanceOf(hook2);
        uint256 assetsReceived = wrapper.redeem(redeemShares, hook2, hook2);
        uint256 assetsAfter = asset.balanceOf(hook2);

        assertEq(assetsAfter - assetsBefore, assetsReceived, "Assets not received");
        vm.stopPrank();
    }

    /**
     * @notice Tests that a removed hook cannot redeem.
     */
    function test_redeem_removedHook_reverts() public {
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

        // Try to redeem - should fail
        vm.startPrank(hook2);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.redeem(50e6, hook2, hook2);
        vm.stopPrank();
    }

    /**
     * @notice Tests multiple sequential redemptions.
     */
    function test_redeem_multipleRedemptions_succeeds() public {
        vm.startPrank(alphixHook);

        uint256 totalShares = wrapper.balanceOf(alphixHook);
        uint256 redeem1 = totalShares / 4;
        uint256 redeem2 = totalShares / 4;

        uint256 assetsBefore = asset.balanceOf(alphixHook);

        uint256 assets1 = wrapper.redeem(redeem1, alphixHook, alphixHook);
        uint256 assets2 = wrapper.redeem(redeem2, alphixHook, alphixHook);

        uint256 assetsAfter = asset.balanceOf(alphixHook);

        assertEq(assetsAfter - assetsBefore, assets1 + assets2, "Total redemption mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that redeem with zero shares reverts with ZeroAssets.
     * @dev When shares == 0, _convertToAssets returns 0, triggering ZeroAssets error.
     */
    function test_redeem_zeroShares_reverts() public {
        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroAssets.selector);
        wrapper.redeem(0, alphixHook, alphixHook);
        vm.stopPrank();
    }

    /* PREVIEW REDEEM TESTS */

    /**
     * @notice Tests that previewRedeem returns expected assets.
     */
    function test_previewRedeem_returnsExpectedAssets() public view {
        uint256 shares = wrapper.balanceOf(alphixHook);
        uint256 previewedAssets = wrapper.previewRedeem(shares);

        // Preview should return the expected assets for given shares
        assertGt(previewedAssets, 0, "Preview should return positive value");
    }

    /**
     * @notice Tests that actual redeem matches preview.
     */
    function test_redeem_matchesPreview() public {
        vm.startPrank(alphixHook);
        uint256 redeemShares = wrapper.balanceOf(alphixHook) / 2;
        uint256 previewedAssets = wrapper.previewRedeem(redeemShares);

        uint256 actualAssets = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        // Due to rounding, actual should be close to preview
        assertGe(actualAssets, previewedAssets - 1, "Actual should match or exceed preview - 1");
        assertLe(actualAssets, previewedAssets + 1, "Actual should be close to preview");
        vm.stopPrank();
    }

    /* RESERVE STATUS TESTS */

    /**
     * @notice Tests that maxRedeem returns 0 when reserve is inactive.
     */
    function test_maxRedeem_returnsZeroWhenReserveInactive() public {
        // Set reserve as inactive
        aavePool.setReserveConfig(false, false, false, 0);

        assertEq(wrapper.maxRedeem(alphixHook), 0, "maxRedeem should be 0 when reserve inactive");
    }

    /**
     * @notice Tests that maxRedeem returns 0 when reserve is paused.
     */
    function test_maxRedeem_returnsZeroWhenReservePaused() public {
        // Set reserve as paused (active but paused)
        aavePool.setReserveConfig(true, false, true, 0);

        assertEq(wrapper.maxRedeem(alphixHook), 0, "maxRedeem should be 0 when reserve paused");
    }
}
