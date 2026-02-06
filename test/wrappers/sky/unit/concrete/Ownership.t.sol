// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title OwnershipTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky ownership functions.
 * @dev Tests Ownable2Step functionality including two-step transferOwnership and renounceOwnership.
 */
contract OwnershipTest is BaseAlphix4626WrapperSky {
    /* EVENTS - Redeclared from OZ Ownable2Step for testing */

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /* INITIAL STATE */

    /**
     * @notice Tests that owner is correctly set after deployment.
     */
    function test_owner_initialState() public view {
        assertEq(wrapper.owner(), owner, "Owner should be set correctly");
    }

    /* TRANSFER OWNERSHIP TESTS (Ownable2Step - two-step process) */

    /**
     * @notice Tests that owner can initiate ownership transfer.
     */
    function test_transferOwnership_initiatesTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        // Owner should still be the original owner until accepted
        assertEq(wrapper.owner(), owner, "Ownership should not transfer until accepted");
        assertEq(wrapper.pendingOwner(), newOwner, "Pending owner should be set");
    }

    /**
     * @notice Tests that new owner can accept ownership.
     */
    function test_acceptOwnership_succeeds() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        vm.prank(newOwner);
        wrapper.acceptOwnership();

        assertEq(wrapper.owner(), newOwner, "Ownership should be transferred after acceptance");
        assertEq(wrapper.pendingOwner(), address(0), "Pending owner should be cleared");
    }

    /**
     * @notice Tests that transferOwnership emits OwnershipTransferStarted event.
     */
    function test_transferOwnership_emitsStartedEvent() public {
        address newOwner = makeAddr("newOwner");

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferStarted(owner, newOwner);

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);
    }

    /**
     * @notice Tests that acceptOwnership emits OwnershipTransferred event.
     */
    function test_acceptOwnership_emitsTransferredEvent() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        vm.expectEmit(true, true, false, false);
        emit OwnershipTransferred(owner, newOwner);

        vm.prank(newOwner);
        wrapper.acceptOwnership();
    }

    /**
     * @notice Tests that non-owner cannot transfer ownership.
     */
    function test_transferOwnership_nonOwner_reverts() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wrapper.transferOwnership(newOwner);
    }

    /**
     * @notice Tests that non-pending owner cannot accept ownership.
     */
    function test_acceptOwnership_nonPendingOwner_reverts() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        // Alice (not the pending owner) cannot accept
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wrapper.acceptOwnership();
    }

    /**
     * @notice Tests that transferring to zero address sets pending owner to zero.
     * @dev Ownable2Step allows setting pendingOwner to zero (effectively cancels pending transfer).
     */
    function test_transferOwnership_toZeroAddress_setsPendingToZero() public {
        address newOwner = makeAddr("newOwner");

        // Start a transfer to newOwner
        vm.prank(owner);
        wrapper.transferOwnership(newOwner);
        assertEq(wrapper.pendingOwner(), newOwner, "Pending owner should be set");

        // Transfer to zero effectively cancels the pending transfer
        vm.prank(owner);
        wrapper.transferOwnership(address(0));
        assertEq(wrapper.pendingOwner(), address(0), "Pending owner should be zero");

        // Owner remains unchanged
        assertEq(wrapper.owner(), owner, "Owner should remain unchanged");
    }

    /**
     * @notice Tests that new owner has all privileges after accepting.
     */
    function test_transferOwnership_newOwnerHasPrivileges() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        vm.prank(newOwner);
        wrapper.acceptOwnership();

        // New owner should be able to set fee
        vm.prank(newOwner);
        wrapper.setFee(200_000);

        assertEq(wrapper.getFee(), 200_000, "New owner should be able to set fee");
    }

    /**
     * @notice Tests that old owner loses privileges after transfer is accepted.
     */
    function test_transferOwnership_oldOwnerLosesPrivileges() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        vm.prank(newOwner);
        wrapper.acceptOwnership();

        // Old owner should not be able to set fee
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        wrapper.setFee(200_000);
    }

    /**
     * @notice Tests that pending owner has no privileges until they accept.
     */
    function test_transferOwnership_pendingOwnerNoPrivilegesUntilAccept() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        // Pending owner should not yet be able to set fee
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        wrapper.setFee(200_000);
    }

    /* RENOUNCE OWNERSHIP TESTS */

    /**
     * @notice Tests that renounceOwnership is disabled.
     */
    function test_renounceOwnership_reverts() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.RenounceDisabled.selector);
        wrapper.renounceOwnership();
    }

    /**
     * @notice Tests that renounceOwnership is disabled for all callers including non-owners.
     * @dev The RenounceDisabled check happens before the owner check.
     */
    function test_renounceOwnership_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IAlphix4626WrapperSky.RenounceDisabled.selector);
        wrapper.renounceOwnership();
    }

    /* OWNER CAN STILL DEPOSIT */

    /**
     * @notice Tests that owner can deposit to themselves.
     */
    function test_owner_canDeposit() public {
        uint256 depositAmount = 1000e18;
        usds.mint(owner, depositAmount);

        vm.startPrank(owner);
        usds.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, owner);
        vm.stopPrank();

        assertGt(shares, 0, "Owner should be able to deposit");
    }

    /**
     * @notice Tests that new owner can deposit after accepting ownership transfer.
     */
    function test_transferOwnership_newOwnerCanDeposit() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        wrapper.transferOwnership(newOwner);

        vm.prank(newOwner);
        wrapper.acceptOwnership();

        uint256 depositAmount = 1000e18;
        usds.mint(newOwner, depositAmount);

        vm.startPrank(newOwner);
        usds.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, newOwner);
        vm.stopPrank();

        assertGt(shares, 0, "New owner should be able to deposit");
    }

    /**
     * @notice Tests that owner can cancel pending transfer by setting new pending owner.
     */
    function test_transferOwnership_canCancelPendingTransfer() public {
        address newOwner1 = makeAddr("newOwner1");
        address newOwner2 = makeAddr("newOwner2");

        // Start transfer to newOwner1
        vm.prank(owner);
        wrapper.transferOwnership(newOwner1);
        assertEq(wrapper.pendingOwner(), newOwner1, "Pending owner should be newOwner1");

        // Owner changes mind, starts transfer to newOwner2
        vm.prank(owner);
        wrapper.transferOwnership(newOwner2);
        assertEq(wrapper.pendingOwner(), newOwner2, "Pending owner should be newOwner2");

        // newOwner1 can no longer accept
        vm.prank(newOwner1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner1));
        wrapper.acceptOwnership();

        // newOwner2 can accept
        vm.prank(newOwner2);
        wrapper.acceptOwnership();
        assertEq(wrapper.owner(), newOwner2, "newOwner2 should be owner");
    }
}
