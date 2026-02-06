// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title RedeemTest
 * @author Alphix
 * @notice Unit tests for the redeem function.
 */
contract RedeemTest is BaseAlphix4626WrapperSky {
    function setUp() public override {
        super.setUp();
        // Make initial deposit for redeem tests
        _depositAsHook(1000e18, alphixHook);
    }

    /* ACCESS CONTROL */

    /**
     * @notice Test that hook can redeem own shares.
     */
    function test_redeem_asHook_succeeds() public {
        uint256 shares = 100e18;

        vm.prank(alphixHook);
        uint256 assets = wrapper.redeem(shares, alphixHook, alphixHook);

        assertGt(assets, 0, "Should receive assets");
    }

    /**
     * @notice Test that owner can redeem own shares.
     */
    function test_redeem_asOwner_succeeds() public {
        // Owner has seed shares
        uint256 ownerShares = wrapper.balanceOf(owner);

        vm.prank(owner);
        uint256 assets = wrapper.redeem(ownerShares / 2, owner, owner);

        assertGt(assets, 0, "Should receive assets");
    }

    /**
     * @notice Test that unauthorized caller cannot redeem.
     */
    function test_redeem_asUnauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.redeem(100e18, unauthorized, unauthorized);
    }

    /* OWNER CONSTRAINT */

    /**
     * @notice Test that redeem reverts if owner_ != msg.sender.
     */
    function test_redeem_fromOther_reverts() public {
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.CallerNotOwner.selector);
        wrapper.redeem(100e18, alphixHook, alice); // Try to redeem alice's shares
    }

    /* RECEIVER FLEXIBILITY */

    /**
     * @notice Test that hook can redeem to any receiver.
     */
    function test_redeem_toAnyReceiver_succeeds() public {
        uint256 shares = 100e18;
        uint256 expectedAssets = wrapper.previewRedeem(shares);
        uint256 aliceBalanceBefore = usds.balanceOf(alice);

        vm.prank(alphixHook);
        wrapper.redeem(shares, alice, alphixHook);

        assertApproxEqAbs(usds.balanceOf(alice), aliceBalanceBefore + expectedAssets, 1, "Alice should receive USDS");
    }

    /* ASSET CALCULATIONS */

    /**
     * @notice Test that assets received match preview.
     */
    function test_redeem_assetsMatchPreview() public {
        uint256 shares = 100e18;
        uint256 expectedAssets = wrapper.previewRedeem(shares);

        vm.prank(alphixHook);
        uint256 assets = wrapper.redeem(shares, alphixHook, alphixHook);

        assertEq(assets, expectedAssets, "Assets should match preview");
    }

    /**
     * @notice Test redeem after yield gives more assets.
     */
    function test_redeem_afterYield_receivesMoreAssets() public {
        uint256 shares = 100e18;
        uint256 assetsBefore = wrapper.previewRedeem(shares);

        // Simulate yield
        _simulateYieldPercent(1);

        uint256 assetsAfter = wrapper.previewRedeem(shares);
        assertGt(assetsAfter, assetsBefore, "Should receive more assets after yield");
    }

    /* STATE CHANGES */

    /**
     * @notice Test that redeem burns exact shares.
     */
    function test_redeem_burnsExactShares() public {
        uint256 shares = 100e18;
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);

        assertEq(wrapper.balanceOf(alphixHook), sharesBefore - shares, "Exact shares not burned");
    }

    /**
     * @notice Test that redeem transfers USDS to receiver.
     */
    function test_redeem_transfersUsdsToReceiver() public {
        uint256 shares = 100e18;
        uint256 expectedAssets = wrapper.previewRedeem(shares);
        uint256 balanceBefore = usds.balanceOf(alphixHook);

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);

        assertApproxEqAbs(usds.balanceOf(alphixHook), balanceBefore + expectedAssets, 1, "USDS not transferred");
    }

    /**
     * @notice Test that redeem swaps sUSDS to USDS via PSM.
     */
    function test_redeem_swapsFromSusds() public {
        uint256 shares = 100e18;
        uint256 susdsBalanceBefore = susds.balanceOf(address(wrapper));

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);

        uint256 susdsBalanceAfter = susds.balanceOf(address(wrapper));
        assertLt(susdsBalanceAfter, susdsBalanceBefore, "Wrapper should have less sUSDS");
    }

    /**
     * @notice Test that redeem decreases totalAssets.
     */
    function test_redeem_decreasesTotalAssets() public {
        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 shares = 100e18;
        uint256 expectedAssets = wrapper.previewRedeem(shares);

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);

        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore - expectedAssets, 0.01e18, "Total assets should decrease");
    }

    /**
     * @notice Test that redeem decreases totalSupply.
     */
    function test_redeem_decreasesTotalSupply() public {
        uint256 totalSupplyBefore = wrapper.totalSupply();
        uint256 shares = 100e18;

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);

        assertEq(wrapper.totalSupply(), totalSupplyBefore - shares, "Total supply should decrease");
    }

    /* EVENTS */

    /**
     * @notice Test that redeem emits Withdraw event.
     */
    function test_redeem_emitsEvent() public {
        uint256 shares = 100e18;
        uint256 expectedAssets = wrapper.previewRedeem(shares);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alphixHook, alphixHook, alphixHook, expectedAssets, shares);

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);
    }

    /* EDGE CASES */

    /**
     * @notice Test that redeem with zero assets reverts.
     */
    function test_redeem_zeroAssets_reverts() public {
        // Set rate very high so 1 share = ~0 assets (edge case)
        // Actually, at normal rates, need very small share amount
        // For this test, we use a share amount that rounds to 0 assets
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.ZeroAssets.selector);
        wrapper.redeem(0, alphixHook, alphixHook);
    }

    /**
     * @notice Test that redeem exceeding max reverts.
     */
    function test_redeem_exceedsMax_reverts() public {
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.RedeemExceedsMax.selector);
        wrapper.redeem(maxRedeem + 1, alphixHook, alphixHook);
    }

    /**
     * @notice Test that redeem reverts when paused.
     */
    function test_redeem_whenPaused_reverts() public {
        vm.prank(owner);
        wrapper.pause();

        vm.prank(alphixHook);
        vm.expectRevert(); // EnforcedPause
        wrapper.redeem(100e18, alphixHook, alphixHook);
    }

    /* SOLVENCY */

    /**
     * @notice Test that wrapper remains solvent after redeem.
     */
    function test_redeem_maintainsSolvency() public {
        vm.prank(alphixHook);
        wrapper.redeem(100e18, alphixHook, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Test full redeem maintains solvency.
     */
    function test_redeem_fullRedeem_maintainsSolvency() public {
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        vm.prank(alphixHook);
        wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        _assertSolvent();
        assertEq(wrapper.balanceOf(alphixHook), 0, "All shares should be burned");
    }

    /* EMPTY VAULT EDGE CASES */

    /**
     * @notice Test conversion functions after ALL shares are redeemed (including seed liquidity).
     * @dev This tests the branches at lines 344 and 364:
     *      - `_convertToShares`: `if (supply == 0) return assets`
     *      - `_convertToAssets`: `if (supply == 0) return shares`
     *
     *      After redeeming all shares, the vault is empty and conversions should return 1:1.
     */
    function test_conversionFunctions_afterAllSharesRedeemed() public {
        // First, redeem all hook's shares
        uint256 hookShares = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(hookShares, alphixHook, alphixHook);

        // Then, owner redeems all their seed liquidity shares
        uint256 ownerShares = wrapper.maxRedeem(owner);
        vm.prank(owner);
        wrapper.redeem(ownerShares, owner, owner);

        // Verify vault is empty
        assertEq(wrapper.totalSupply(), 0, "Total supply should be 0");

        // Test conversion functions return 1:1 when supply is 0
        // These hit the `if (supply == 0)` branches
        uint256 testAmount = 1000e18;
        assertEq(wrapper.convertToShares(testAmount), testAmount, "convertToShares should return 1:1 when empty");
        assertEq(wrapper.convertToAssets(testAmount), testAmount, "convertToAssets should return 1:1 when empty");

        // Also verify previewDeposit and previewRedeem use the same logic
        assertEq(wrapper.previewDeposit(testAmount), testAmount, "previewDeposit should return 1:1 when empty");
        assertEq(wrapper.previewRedeem(testAmount), testAmount, "previewRedeem should return 1:1 when empty");
    }

    /**
     * @notice Test that totalAssets returns 0 after all shares are redeemed.
     * @dev This tests the branch at line 307: `if (netSusds == 0) return 0`
     *      and line 322: `if (totalSusds == 0) return 0` in _getNetSusds.
     */
    function test_totalAssets_afterAllSharesRedeemed() public {
        // Redeem all hook's shares
        uint256 hookShares = wrapper.maxRedeem(alphixHook);
        vm.prank(alphixHook);
        wrapper.redeem(hookShares, alphixHook, alphixHook);

        // Owner redeems all seed liquidity
        uint256 ownerShares = wrapper.maxRedeem(owner);
        vm.prank(owner);
        wrapper.redeem(ownerShares, owner, owner);

        // Verify totalAssets is 0 (or very close due to rounding)
        assertLe(wrapper.totalAssets(), 1, "Total assets should be ~0 after full redemption");
    }
}
