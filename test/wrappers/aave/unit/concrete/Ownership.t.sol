// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title OwnershipTest
 * @author Alphix
 * @notice Unit tests for Alphix4626WrapperAave ownership behavior.
 * @dev Tests Ownable2Step migration and renounceOwnership override.
 */
contract OwnershipTest is BaseAlphix4626WrapperAave {
    /* RENOUNCE OWNERSHIP TESTS */

    /**
     * @notice Test that renounceOwnership reverts with RenounceDisabled error.
     */
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.RenounceDisabled.selector);
        wrapper.renounceOwnership();
    }

    /**
     * @notice Test that renounceOwnership reverts even from non-owner.
     * @dev The function reverts with RenounceDisabled, not Unauthorized.
     */
    function test_renounceOwnership_reverts_fromNonOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperAave.RenounceDisabled.selector);
        wrapper.renounceOwnership();
    }

    /* OWNABLE2STEP TESTS */

    /**
     * @notice Test that transferOwnership sets pending owner.
     */
    function test_transferOwnership_setsPendingOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        // Pending owner should be set
        assertEq(wrapper.pendingOwner(), newOwner);
        // Current owner should still be the original owner
        assertEq(wrapper.owner(), owner);
    }

    /**
     * @notice Test that acceptOwnership completes the transfer.
     */
    function test_acceptOwnership_completesTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: Transfer ownership
        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        // Step 2: Accept ownership
        vm.prank(newOwner);
        wrapper.acceptOwnership();

        // New owner should now be the owner
        assertEq(wrapper.owner(), newOwner);
        // Pending owner should be cleared
        assertEq(wrapper.pendingOwner(), address(0));
    }

    /**
     * @notice Test that only pending owner can accept ownership.
     */
    function test_acceptOwnership_reverts_fromNonPendingOwner() public {
        address newOwner = makeAddr("newOwner");
        address attacker = makeAddr("attacker");

        // Step 1: Transfer ownership
        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        // Step 2: Attacker tries to accept
        vm.prank(attacker);
        vm.expectRevert();
        wrapper.acceptOwnership();

        // Owner should still be original
        assertEq(wrapper.owner(), owner);
    }

    /**
     * @notice Test that transferOwnership reverts from non-owner.
     */
    function test_transferOwnership_reverts_fromNonOwner() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(unauthorized);
        vm.expectRevert();
        wrapper.transferOwnership(newOwner);
    }

    /**
     * @notice Test that owner can cancel pending transfer by setting new pending owner.
     */
    function test_transferOwnership_canCancelPendingTransfer() public {
        address pendingOwner1 = makeAddr("pendingOwner1");
        address pendingOwner2 = makeAddr("pendingOwner2");

        // Set first pending owner
        vm.prank(owner);
        wrapper.transferOwnership(pendingOwner1);
        assertEq(wrapper.pendingOwner(), pendingOwner1);

        // Set second pending owner (overrides first)
        vm.prank(owner);
        wrapper.transferOwnership(pendingOwner2);
        assertEq(wrapper.pendingOwner(), pendingOwner2);

        // First pending owner can no longer accept
        vm.prank(pendingOwner1);
        vm.expectRevert();
        wrapper.acceptOwnership();

        // Second pending owner can accept
        vm.prank(pendingOwner2);
        wrapper.acceptOwnership();
        assertEq(wrapper.owner(), pendingOwner2);
    }

    /**
     * @notice Test that new owner has full admin capabilities.
     */
    function test_newOwner_hasFullAdminCapabilities() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        vm.prank(owner);
        wrapper.transferOwnership(newOwner);
        vm.prank(newOwner);
        wrapper.acceptOwnership();

        // New owner can set fee
        vm.prank(newOwner);
        wrapper.setFee(200_000); // 20%
        assertEq(wrapper.getFee(), 200_000);

        // New owner can add hooks
        address newHook = makeAddr("newHook");
        vm.prank(newOwner);
        wrapper.addAlphixHook(newHook);
        assertTrue(wrapper.isAlphixHook(newHook));

        // New owner can pause
        vm.prank(newOwner);
        wrapper.pause();
        assertTrue(wrapper.paused());

        // New owner can unpause
        vm.prank(newOwner);
        wrapper.unpause();
        assertFalse(wrapper.paused());
    }

    /**
     * @notice Test that old owner loses admin capabilities after transfer.
     */
    function test_oldOwner_losesAdminCapabilities() public {
        address newOwner = makeAddr("newOwner");

        // Transfer ownership
        vm.prank(owner);
        wrapper.transferOwnership(newOwner);
        vm.prank(newOwner);
        wrapper.acceptOwnership();

        // Old owner can no longer set fee
        vm.prank(owner);
        vm.expectRevert();
        wrapper.setFee(200_000);

        // Old owner can no longer add hooks
        vm.prank(owner);
        vm.expectRevert();
        wrapper.addAlphixHook(makeAddr("someHook"));

        // Old owner can no longer pause
        vm.prank(owner);
        vm.expectRevert();
        wrapper.pause();
    }
}
