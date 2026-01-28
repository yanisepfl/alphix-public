// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title AlphixHooksTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave hook management functions.
 * @dev Tests addAlphixHook, removeAlphixHook, isAlphixHook, and getAllAlphixHooks.
 */
contract AlphixHooksTest is BaseAlphix4626WrapperAave {
    /* ADD ALPHIX HOOK TESTS */

    /**
     * @notice Tests that owner can add a new hook.
     */
    function test_addAlphixHook_succeeds() public {
        address newHook = makeAddr("newHook");

        vm.prank(owner);
        wrapper.addAlphixHook(newHook);

        assertTrue(wrapper.isAlphixHook(newHook), "Hook should be added");
    }

    /**
     * @notice Tests that addAlphixHook emits the correct event.
     */
    function test_addAlphixHook_emitsEvent() public {
        address newHook = makeAddr("newHook");

        vm.expectEmit(true, false, false, false);
        emit IAlphix4626WrapperAave.AlphixHookAdded(newHook);

        vm.prank(owner);
        wrapper.addAlphixHook(newHook);
    }

    /**
     * @notice Tests that non-owner cannot add a hook.
     */
    function test_addAlphixHook_revertsIfNotOwner() public {
        address newHook = makeAddr("newHook");

        vm.prank(alice);
        vm.expectRevert();
        wrapper.addAlphixHook(newHook);
    }

    /**
     * @notice Tests that adding zero address reverts.
     */
    function test_addAlphixHook_revertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.InvalidAddress.selector);
        wrapper.addAlphixHook(address(0));
    }

    /**
     * @notice Tests that adding an already existing hook reverts.
     */
    function test_addAlphixHook_revertsIfAlreadyExists() public {
        // alphixHook is already added in setUp
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.HookAlreadyExists.selector);
        wrapper.addAlphixHook(alphixHook);
    }

    /**
     * @notice Tests that multiple hooks can be added.
     */
    function test_addAlphixHook_multipleHooks() public {
        address hook2 = makeAddr("hook2");
        address hook3 = makeAddr("hook3");
        address hook4 = makeAddr("hook4");

        vm.startPrank(owner);
        wrapper.addAlphixHook(hook2);
        wrapper.addAlphixHook(hook3);
        wrapper.addAlphixHook(hook4);
        vm.stopPrank();

        assertTrue(wrapper.isAlphixHook(alphixHook), "Hook1 should exist");
        assertTrue(wrapper.isAlphixHook(hook2), "Hook2 should exist");
        assertTrue(wrapper.isAlphixHook(hook3), "Hook3 should exist");
        assertTrue(wrapper.isAlphixHook(hook4), "Hook4 should exist");
    }

    /* REMOVE ALPHIX HOOK TESTS */

    /**
     * @notice Tests that owner can remove a hook.
     */
    function test_removeAlphixHook_succeeds() public {
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        assertFalse(wrapper.isAlphixHook(alphixHook), "Hook should be removed");
    }

    /**
     * @notice Tests that removeAlphixHook emits the correct event.
     */
    function test_removeAlphixHook_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit IAlphix4626WrapperAave.AlphixHookRemoved(alphixHook);

        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);
    }

    /**
     * @notice Tests that non-owner cannot remove a hook.
     */
    function test_removeAlphixHook_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        wrapper.removeAlphixHook(alphixHook);
    }

    /**
     * @notice Tests that removing a non-existent hook reverts.
     */
    function test_removeAlphixHook_revertsIfNotExists() public {
        address nonExistent = makeAddr("nonExistent");

        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.HookDoesNotExist.selector);
        wrapper.removeAlphixHook(nonExistent);
    }

    /**
     * @notice Tests that a removed hook can no longer deposit.
     */
    function test_removeAlphixHook_hookCanNoLongerDeposit() public {
        // First verify hook can deposit
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount * 2);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(depositAmount, alphixHook); // Should work
        vm.stopPrank();

        // Remove the hook
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        // Now hook cannot deposit
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.deposit(depositAmount, alphixHook);
    }

    /**
     * @notice Tests that removing a hook doesn't affect its existing shares.
     */
    function test_removeAlphixHook_doesNotAffectExistingShares() public {
        // Deposit as hook
        uint256 depositAmount = 100e6;
        uint256 shares = _depositAsHook(depositAmount, alphixHook);

        // Remove the hook
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        // Shares should still exist
        assertEq(wrapper.balanceOf(alphixHook), shares, "Shares should remain");
    }

    /**
     * @notice Tests that a removed hook can be re-added.
     */
    function test_removeAlphixHook_canBeReAdded() public {
        // Remove hook
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);
        assertFalse(wrapper.isAlphixHook(alphixHook), "Hook should be removed");

        // Re-add hook
        vm.prank(owner);
        wrapper.addAlphixHook(alphixHook);
        assertTrue(wrapper.isAlphixHook(alphixHook), "Hook should be re-added");
    }

    /* IS ALPHIX HOOK TESTS */

    /**
     * @notice Tests isAlphixHook returns true for an added hook.
     */
    function test_isAlphixHook_returnsTrueForHook() public view {
        assertTrue(wrapper.isAlphixHook(alphixHook), "Should return true for hook");
    }

    /**
     * @notice Tests isAlphixHook returns false for non-hook address.
     */
    function test_isAlphixHook_returnsFalseForNonHook() public view {
        assertFalse(wrapper.isAlphixHook(alice), "Should return false for non-hook");
    }

    /**
     * @notice Tests isAlphixHook returns false for owner (owner is not a hook).
     */
    function test_isAlphixHook_returnsFalseForOwner() public view {
        assertFalse(wrapper.isAlphixHook(owner), "Should return false for owner");
    }

    /**
     * @notice Tests isAlphixHook returns false after removal.
     */
    function test_isAlphixHook_returnsFalseAfterRemoval() public {
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        assertFalse(wrapper.isAlphixHook(alphixHook), "Should return false after removal");
    }

    /* GET ALL ALPHIX HOOKS TESTS */

    /**
     * @notice Tests getAllAlphixHooks returns all hooks.
     */
    function test_getAllAlphixHooks_returnsAllHooks() public {
        address hook2 = makeAddr("hook2");
        address hook3 = makeAddr("hook3");

        vm.startPrank(owner);
        wrapper.addAlphixHook(hook2);
        wrapper.addAlphixHook(hook3);
        vm.stopPrank();

        address[] memory hooks = wrapper.getAllAlphixHooks();

        assertEq(hooks.length, 3, "Should have 3 hooks");
        // Note: Order is not guaranteed with EnumerableSet
        bool foundHook1;
        bool foundHook2;
        bool foundHook3;
        for (uint256 i = 0; i < hooks.length; i++) {
            if (hooks[i] == alphixHook) foundHook1 = true;
            if (hooks[i] == hook2) foundHook2 = true;
            if (hooks[i] == hook3) foundHook3 = true;
        }
        assertTrue(foundHook1 && foundHook2 && foundHook3, "All hooks should be present");
    }

    /**
     * @notice Tests getAllAlphixHooks returns empty array when all hooks removed.
     */
    function test_getAllAlphixHooks_emptyAfterAllRemoved() public {
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        address[] memory hooks = wrapper.getAllAlphixHooks();
        assertEq(hooks.length, 0, "Should be empty");
    }

    /**
     * @notice Tests getAllAlphixHooks updates after add/remove operations.
     */
    function test_getAllAlphixHooks_updatesAfterOperations() public {
        // Initial state: 1 hook
        assertEq(wrapper.getAllAlphixHooks().length, 1, "Should have 1 hook initially");

        // Add hook
        address hook2 = makeAddr("hook2");
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);
        assertEq(wrapper.getAllAlphixHooks().length, 2, "Should have 2 hooks");

        // Remove original hook
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);
        assertEq(wrapper.getAllAlphixHooks().length, 1, "Should have 1 hook");
        assertEq(wrapper.getAllAlphixHooks()[0], hook2, "Remaining hook should be hook2");
    }

    /* MAX DEPOSIT TESTS */

    /**
     * @notice Tests maxDeposit returns 0 for non-hook/non-owner.
     */
    function test_maxDeposit_returnsZeroForNonHook() public view {
        assertEq(wrapper.maxDeposit(alice), 0, "Should return 0 for non-hook");
    }

    /**
     * @notice Tests maxDeposit returns max for hook.
     */
    function test_maxDeposit_returnsMaxForHook() public view {
        assertEq(wrapper.maxDeposit(alphixHook), type(uint256).max, "Should return max for hook");
    }

    /**
     * @notice Tests maxDeposit returns max for owner.
     */
    function test_maxDeposit_returnsMaxForOwner() public view {
        assertEq(wrapper.maxDeposit(owner), type(uint256).max, "Should return max for owner");
    }

    /**
     * @notice Tests maxDeposit returns 0 after hook removal.
     */
    function test_maxDeposit_returnsZeroAfterRemoval() public {
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        assertEq(wrapper.maxDeposit(alphixHook), 0, "Should return 0 after removal");
    }

    /* NO HOOKS SCENARIO */

    /**
     * @notice Tests that only owner can deposit when no hooks are added.
     */
    function test_deposit_onlyOwnerWhenNoHooks() public {
        // Remove the only hook
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        // Owner can still deposit to themselves
        uint256 depositAmount = 100e6;
        asset.mint(owner, depositAmount);

        vm.startPrank(owner);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, owner);
        vm.stopPrank();

        assertGt(shares, 0, "Owner should be able to deposit");
    }
}
