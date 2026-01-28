// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PausableTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky pausable functionality.
 */
contract PausableTest is BaseAlphix4626WrapperSky {
    /* EVENTS - Redeclared from OZ Pausable for testing */

    event Paused(address account);
    event Unpaused(address account);

    /* PAUSE TESTS */

    /**
     * @notice Tests that owner can pause the contract.
     */
    function test_pause_succeeds() public {
        vm.prank(owner);
        wrapper.pause();

        assertTrue(wrapper.paused(), "Contract should be paused");
    }

    /**
     * @notice Tests that pause emits Paused event.
     */
    function test_pause_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        wrapper.pause();
    }

    /**
     * @notice Tests that non-owner cannot pause.
     */
    function test_pause_revertsIfNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        wrapper.pause();
    }

    /**
     * @notice Tests that pause reverts if already paused.
     */
    function test_pause_revertsIfAlreadyPaused() public {
        vm.startPrank(owner);
        wrapper.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.pause();
        vm.stopPrank();
    }

    /* UNPAUSE TESTS */

    /**
     * @notice Tests that owner can unpause the contract.
     */
    function test_unpause_succeeds() public {
        vm.startPrank(owner);
        wrapper.pause();
        assertTrue(wrapper.paused(), "Should be paused");

        wrapper.unpause();
        assertFalse(wrapper.paused(), "Contract should be unpaused");
        vm.stopPrank();
    }

    /**
     * @notice Tests that unpause emits Unpaused event.
     */
    function test_unpause_emitsEvent() public {
        vm.startPrank(owner);
        wrapper.pause();

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        wrapper.unpause();
        vm.stopPrank();
    }

    /**
     * @notice Tests that non-owner cannot unpause.
     */
    function test_unpause_revertsIfNotOwner() public {
        vm.prank(owner);
        wrapper.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        wrapper.unpause();
    }

    /**
     * @notice Tests that unpause reverts if not paused.
     */
    function test_unpause_revertsIfNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        wrapper.unpause();
    }

    /* DEPOSIT WHEN PAUSED TESTS */

    /**
     * @notice Tests that deposit reverts when paused.
     */
    function test_deposit_revertsWhenPaused() public {
        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Try to deposit as hook
        uint256 depositAmount = 1000e18;
        usds.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), depositAmount);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit works after unpause.
     */
    function test_deposit_succeedsAfterUnpause() public {
        // Pause and unpause
        vm.startPrank(owner);
        wrapper.pause();
        wrapper.unpause();
        vm.stopPrank();

        // Deposit should work
        uint256 depositAmount = 1000e18;
        usds.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares after unpause");
    }

    /**
     * @notice Tests that owner deposit also reverts when paused.
     */
    function test_deposit_ownerRevertsWhenPaused() public {
        vm.prank(owner);
        wrapper.pause();

        uint256 depositAmount = 1000e18;
        usds.mint(owner, depositAmount);

        vm.startPrank(owner);
        usds.approve(address(wrapper), depositAmount);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.deposit(depositAmount, owner);
        vm.stopPrank();
    }

    /* WITHDRAW WHEN PAUSED TESTS */

    /**
     * @notice Tests that withdraw reverts when paused.
     */
    function test_withdraw_revertsWhenPaused() public {
        // First deposit some assets
        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Try to withdraw
        vm.prank(alphixHook);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.withdraw(500e18, alphixHook, alphixHook);
    }

    /**
     * @notice Tests that withdraw works after unpause.
     */
    function test_withdraw_succeedsAfterUnpause() public {
        // First deposit some assets
        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        // Pause and unpause
        vm.startPrank(owner);
        wrapper.pause();
        wrapper.unpause();
        vm.stopPrank();

        // Withdraw should work
        uint256 assetsBefore = usds.balanceOf(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(500e18, alphixHook, alphixHook);

        assertEq(usds.balanceOf(alphixHook), assetsBefore + 500e18, "Should receive assets after unpause");
    }

    /**
     * @notice Tests that owner withdraw also reverts when paused.
     */
    function test_withdraw_ownerRevertsWhenPaused() public {
        // First deposit as owner
        _depositAsOwner(1000e18, owner);

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Owner tries to withdraw - should also revert
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.withdraw(500e18, owner, owner);
    }

    /* REDEEM WHEN PAUSED TESTS */

    /**
     * @notice Tests that redeem reverts when paused.
     */
    function test_redeem_revertsWhenPaused() public {
        // First deposit some assets
        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Try to redeem
        uint256 shares = wrapper.balanceOf(alphixHook) / 2;
        vm.prank(alphixHook);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.redeem(shares, alphixHook, alphixHook);
    }

    /**
     * @notice Tests that redeem works after unpause.
     */
    function test_redeem_succeedsAfterUnpause() public {
        // First deposit some assets
        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        // Pause and unpause
        vm.startPrank(owner);
        wrapper.pause();
        wrapper.unpause();
        vm.stopPrank();

        // Redeem should work
        uint256 shares = wrapper.balanceOf(alphixHook) / 2;
        uint256 assetsBefore = usds.balanceOf(alphixHook);
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(shares, alphixHook, alphixHook);

        assertEq(usds.balanceOf(alphixHook), assetsBefore + assetsReceived, "Should receive assets after unpause");
    }

    /**
     * @notice Tests that owner redeem also reverts when paused.
     */
    function test_redeem_ownerRevertsWhenPaused() public {
        // First deposit as owner
        _depositAsOwner(1000e18, owner);

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Owner tries to redeem - should also revert
        uint256 shares = wrapper.balanceOf(owner) / 2;
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.redeem(shares, owner, owner);
    }

    /* ADMIN FUNCTIONS WHEN PAUSED TESTS */

    /**
     * @notice Tests that setFee works when paused.
     */
    function test_setFee_succeedsWhenPaused() public {
        vm.startPrank(owner);
        wrapper.pause();

        // setFee should still work
        wrapper.setFee(200_000); // 20%
        assertEq(wrapper.getFee(), 200_000, "Fee should be updated while paused");
        vm.stopPrank();
    }

    /**
     * @notice Tests that setYieldTreasury works when paused.
     */
    function test_setYieldTreasury_succeedsWhenPaused() public {
        address newTreasury = makeAddr("newTreasury");

        vm.startPrank(owner);
        wrapper.pause();

        // setYieldTreasury should still work
        wrapper.setYieldTreasury(newTreasury);
        assertEq(wrapper.getYieldTreasury(), newTreasury, "Treasury should be updated while paused");
        vm.stopPrank();
    }

    /**
     * @notice Tests that collectFees works when paused.
     */
    function test_collectFees_succeedsWhenPaused() public {
        // Deposit and generate yield first
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        vm.startPrank(owner);
        wrapper.pause();

        // collectFees should still work
        uint256 feesBefore = wrapper.getClaimableFees();
        assertGt(feesBefore, 0, "Should have fees to collect");

        wrapper.collectFees();
        vm.stopPrank();

        // Fees should be collected
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be collected while paused");
    }

    /**
     * @notice Tests that addAlphixHook works when paused.
     */
    function test_addAlphixHook_succeedsWhenPaused() public {
        address newHook = makeAddr("newHook");

        vm.startPrank(owner);
        wrapper.pause();

        // addAlphixHook should still work
        wrapper.addAlphixHook(newHook);
        assertTrue(wrapper.isAlphixHook(newHook), "Hook should be added while paused");
        vm.stopPrank();
    }

    /**
     * @notice Tests that removeAlphixHook works when paused.
     */
    function test_removeAlphixHook_succeedsWhenPaused() public {
        address newHook = makeAddr("newHook");

        vm.startPrank(owner);
        wrapper.addAlphixHook(newHook);
        wrapper.pause();

        // removeAlphixHook should still work
        wrapper.removeAlphixHook(newHook);
        assertFalse(wrapper.isAlphixHook(newHook), "Hook should be removed while paused");
        vm.stopPrank();
    }

    /**
     * @notice Tests that rescueTokens works when paused.
     * @dev Token rescue should not be affected by pause state.
     */
    function test_rescueTokens_succeedsWhenPaused() public {
        // Send some tokens to the wrapper
        usds.mint(address(wrapper), 50e18);

        vm.startPrank(owner);
        wrapper.pause();

        // rescueTokens should still work
        uint256 treasuryBefore = usds.balanceOf(treasury);
        wrapper.rescueTokens(address(usds), 50e18);
        vm.stopPrank();

        assertEq(usds.balanceOf(treasury) - treasuryBefore, 50e18, "Should rescue tokens while paused");
    }

    /* VIEW FUNCTIONS WHEN PAUSED TESTS */

    /**
     * @notice Tests that view functions work when paused.
     * @dev Note: maxDeposit, maxWithdraw, maxRedeem all return 0 when paused
     *      (no deposits/withdrawals/redeems allowed).
     */
    function test_viewFunctions_workWhenPaused() public {
        // Deposit first
        _depositAsHook(1000e18, alphixHook);

        vm.prank(owner);
        wrapper.pause();

        // All view functions should work (not revert)
        assertGt(wrapper.totalAssets(), 0, "totalAssets should work");
        assertGt(wrapper.balanceOf(alphixHook), 0, "balanceOf should work");
        assertEq(wrapper.getFee(), DEFAULT_FEE, "getFee should work");
        assertEq(wrapper.getYieldTreasury(), treasury, "getYieldTreasury should work");
        assertTrue(wrapper.isAlphixHook(alphixHook), "isAlphixHook should work");
        // All max functions return 0 when paused - no operations allowed
        assertEq(wrapper.maxDeposit(alphixHook), 0, "maxDeposit should return 0 when paused");
        assertEq(wrapper.maxWithdraw(alphixHook), 0, "maxWithdraw should return 0 when paused");
        assertEq(wrapper.maxRedeem(alphixHook), 0, "maxRedeem should return 0 when paused");
    }

    /* INITIAL STATE TEST */

    /**
     * @notice Tests that contract is not paused initially.
     */
    function test_initialState_notPaused() public view {
        assertFalse(wrapper.paused(), "Contract should not be paused initially");
    }
}
