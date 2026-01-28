// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title WithdrawTest
 * @author Alphix
 * @notice Unit tests for the withdraw function.
 */
contract WithdrawTest is BaseAlphix4626WrapperSky {
    function setUp() public override {
        super.setUp();
        // Make initial deposit for withdrawal tests
        _depositAsHook(1000e18, alphixHook);
    }

    /* ACCESS CONTROL */

    /**
     * @notice Test that hook can withdraw own shares.
     */
    function test_withdraw_asHook_succeeds() public {
        uint256 assets = 100e18;

        vm.prank(alphixHook);
        uint256 shares = wrapper.withdraw(assets, alphixHook, alphixHook);

        assertGt(shares, 0, "Should burn shares");
    }

    /**
     * @notice Test that owner can withdraw own shares.
     */
    function test_withdraw_asOwner_succeeds() public {
        // Owner has seed shares
        uint256 ownerShares = wrapper.balanceOf(owner);
        uint256 assets = wrapper.convertToAssets(ownerShares / 2);

        vm.prank(owner);
        uint256 shares = wrapper.withdraw(assets, owner, owner);

        assertGt(shares, 0, "Should burn shares");
    }

    /**
     * @notice Test that unauthorized caller cannot withdraw.
     */
    function test_withdraw_asUnauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.withdraw(100e18, unauthorized, unauthorized);
    }

    /* OWNER CONSTRAINT */

    /**
     * @notice Test that withdraw reverts if owner_ != msg.sender.
     */
    function test_withdraw_fromOther_reverts() public {
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.CallerNotOwner.selector);
        wrapper.withdraw(100e18, alphixHook, alice); // Try to withdraw alice's shares
    }

    /* RECEIVER FLEXIBILITY */

    /**
     * @notice Test that hook can withdraw to any receiver.
     */
    function test_withdraw_toAnyReceiver_succeeds() public {
        uint256 assets = 100e18;
        uint256 aliceBalanceBefore = usds.balanceOf(alice);

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alice, alphixHook);

        assertApproxEqAbs(usds.balanceOf(alice), aliceBalanceBefore + assets, 1, "Alice should receive USDS");
    }

    /* ASSET CALCULATIONS */

    /**
     * @notice Test that shares burned match preview.
     */
    function test_withdraw_sharesBurnedMatchPreview() public {
        uint256 assets = 100e18;
        uint256 expectedShares = wrapper.previewWithdraw(assets);

        vm.prank(alphixHook);
        uint256 shares = wrapper.withdraw(assets, alphixHook, alphixHook);

        assertEq(shares, expectedShares, "Shares should match preview");
    }

    /**
     * @notice Test withdraw after yield gives correct assets.
     */
    function test_withdraw_afterYield_receivesCorrectAssets() public {
        // Simulate yield
        _simulateYieldPercent(1);

        uint256 assets = 100e18;
        uint256 usdsBalanceBefore = usds.balanceOf(alphixHook);

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alphixHook, alphixHook);

        uint256 received = usds.balanceOf(alphixHook) - usdsBalanceBefore;
        assertApproxEqAbs(received, assets, 1, "Should receive requested assets");
    }

    /* STATE CHANGES */

    /**
     * @notice Test that withdraw burns shares.
     */
    function test_withdraw_burnsShares() public {
        uint256 assets = 100e18;
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 expectedShares = wrapper.previewWithdraw(assets);

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alphixHook, alphixHook);

        assertEq(wrapper.balanceOf(alphixHook), sharesBefore - expectedShares, "Shares not burned");
    }

    /**
     * @notice Test that withdraw transfers USDS to receiver.
     */
    function test_withdraw_transfersUsdsToReceiver() public {
        uint256 assets = 100e18;
        uint256 balanceBefore = usds.balanceOf(alphixHook);

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alphixHook, alphixHook);

        assertApproxEqAbs(usds.balanceOf(alphixHook), balanceBefore + assets, 1, "USDS not transferred");
    }

    /**
     * @notice Test that withdraw swaps sUSDS to USDS via PSM.
     */
    function test_withdraw_swapsFromSusds() public {
        uint256 assets = 100e18;
        uint256 susdsBalanceBefore = susds.balanceOf(address(wrapper));

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alphixHook, alphixHook);

        uint256 susdsBalanceAfter = susds.balanceOf(address(wrapper));
        assertLt(susdsBalanceAfter, susdsBalanceBefore, "Wrapper should have less sUSDS");
    }

    /**
     * @notice Test that withdraw decreases totalAssets.
     */
    function test_withdraw_decreasesTotalAssets() public {
        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 assets = 100e18;

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alphixHook, alphixHook);

        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore - assets, 0.01e18, "Total assets should decrease");
    }

    /**
     * @notice Test that withdraw decreases totalSupply.
     */
    function test_withdraw_decreasesTotalSupply() public {
        uint256 totalSupplyBefore = wrapper.totalSupply();

        vm.prank(alphixHook);
        uint256 shares = wrapper.withdraw(100e18, alphixHook, alphixHook);

        assertEq(wrapper.totalSupply(), totalSupplyBefore - shares, "Total supply should decrease");
    }

    /* EVENTS */

    /**
     * @notice Test that withdraw emits Withdraw event.
     */
    function test_withdraw_emitsEvent() public {
        uint256 assets = 100e18;
        uint256 expectedShares = wrapper.previewWithdraw(assets);

        vm.expectEmit(true, true, true, true);
        emit Withdraw(alphixHook, alphixHook, alphixHook, assets, expectedShares);

        vm.prank(alphixHook);
        wrapper.withdraw(assets, alphixHook, alphixHook);
    }

    /* EDGE CASES */

    /**
     * @notice Test that zero withdraw reverts.
     */
    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.ZeroShares.selector);
        wrapper.withdraw(0, alphixHook, alphixHook);
    }

    /**
     * @notice Test that withdraw exceeding max reverts.
     */
    function test_withdraw_exceedsMax_reverts() public {
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.WithdrawExceedsMax.selector);
        wrapper.withdraw(maxWithdraw + 1, alphixHook, alphixHook);
    }

    /**
     * @notice Test that withdraw reverts when paused.
     */
    function test_withdraw_whenPaused_reverts() public {
        vm.prank(owner);
        wrapper.pause();

        vm.prank(alphixHook);
        vm.expectRevert(); // EnforcedPause
        wrapper.withdraw(100e18, alphixHook, alphixHook);
    }

    /* SOLVENCY */

    /**
     * @notice Test that wrapper remains solvent after withdraw.
     */
    function test_withdraw_maintainsSolvency() public {
        vm.prank(alphixHook);
        wrapper.withdraw(100e18, alphixHook, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Test full withdrawal maintains solvency.
     */
    function test_withdraw_fullWithdrawal_maintainsSolvency() public {
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);

        vm.prank(alphixHook);
        wrapper.withdraw(maxWithdraw, alphixHook, alphixHook);

        _assertSolvent();
        assertEq(wrapper.balanceOf(alphixHook), 0, "All shares should be burned");
    }
}
