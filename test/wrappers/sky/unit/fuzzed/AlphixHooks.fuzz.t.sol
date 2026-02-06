// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AlphixHooksFuzzTest
 * @author Alphix
 * @notice Fuzz tests for Alphix Hook management.
 */
contract AlphixHooksFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test adding hooks with random addresses.
     * @param newHook Random hook address.
     */
    function testFuzz_addAlphixHook_randomAddresses(address newHook) public {
        vm.assume(newHook != address(0) && newHook != alphixHook);

        vm.prank(owner);
        wrapper.addAlphixHook(newHook);

        assertTrue(wrapper.isAlphixHook(newHook), "Hook should be added");
    }

    /**
     * @notice Fuzz test adding hook reverts for non-owner.
     * @param caller Random caller.
     * @param newHook Random hook address.
     */
    function testFuzz_addAlphixHook_nonOwner_reverts(address caller, address newHook) public {
        vm.assume(caller != owner && caller != address(0));
        vm.assume(newHook != address(0) && newHook != alphixHook);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        wrapper.addAlphixHook(newHook);
    }

    /**
     * @notice Fuzz test removing hooks.
     * @param hooks Array of hook addresses to add and remove.
     */
    function testFuzz_removeAlphixHook_multipleHooks(address[3] memory hooks) public {
        // Filter and add hooks
        for (uint256 i = 0; i < hooks.length; i++) {
            vm.assume(hooks[i] != address(0) && hooks[i] != alphixHook);
            // Make addresses unique
            for (uint256 j = 0; j < i; j++) {
                vm.assume(hooks[i] != hooks[j]);
            }

            vm.prank(owner);
            wrapper.addAlphixHook(hooks[i]);
        }

        // Remove hooks
        for (uint256 i = 0; i < hooks.length; i++) {
            vm.prank(owner);
            wrapper.removeAlphixHook(hooks[i]);

            assertFalse(wrapper.isAlphixHook(hooks[i]), "Hook should be removed");
        }
    }

    /**
     * @notice Fuzz test maxDeposit returns correct values.
     * @param caller Random address.
     */
    function testFuzz_maxDeposit_correctValues(address caller) public view {
        uint256 maxDeposit = wrapper.maxDeposit(caller);

        if (caller == alphixHook || caller == owner) {
            assertEq(maxDeposit, type(uint256).max, "Authorized should have max deposit");
        } else {
            assertEq(maxDeposit, 0, "Unauthorized should have 0 deposit");
        }
    }

    /**
     * @notice Fuzz test hook can deposit after being added.
     * @param newHook Random hook address.
     * @param depositMultiplier Deposit amount.
     */
    function testFuzz_hook_canDepositAfterAdd(address newHook, uint256 depositMultiplier) public {
        vm.assume(newHook != address(0) && newHook != alphixHook && newHook != owner);
        vm.assume(newHook != address(wrapper) && newHook != address(usds) && newHook != address(susds));
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        uint256 amount = depositMultiplier * 1e18;

        // Add hook
        vm.prank(owner);
        wrapper.addAlphixHook(newHook);

        // Deposit as new hook
        usds.mint(newHook, amount);
        vm.startPrank(newHook);
        usds.approve(address(wrapper), amount);
        uint256 shares = wrapper.deposit(amount, newHook);
        vm.stopPrank();

        assertGt(shares, 0, "Hook should be able to deposit");
    }

    /**
     * @notice Fuzz test hook cannot deposit after being removed.
     * @param newHook Random hook address.
     */
    function testFuzz_hook_cannotDepositAfterRemove(address newHook) public {
        vm.assume(newHook != address(0) && newHook != alphixHook && newHook != owner);
        vm.assume(newHook != address(wrapper) && newHook != address(usds) && newHook != address(susds));

        // Add then remove hook
        vm.startPrank(owner);
        wrapper.addAlphixHook(newHook);
        wrapper.removeAlphixHook(newHook);
        vm.stopPrank();

        // Try to deposit
        usds.mint(newHook, 1000e18);
        vm.startPrank(newHook);
        usds.approve(address(wrapper), 1000e18);

        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.deposit(1000e18, newHook);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test getAllAlphixHooks returns correct array.
     * @param hooksToAdd Number of hooks to add (1-5).
     */
    function testFuzz_getAllAlphixHooks_correctCount(uint8 hooksToAdd) public {
        hooksToAdd = uint8(bound(hooksToAdd, 1, 5));

        // Initial hook count
        uint256 initialCount = wrapper.getAllAlphixHooks().length;

        // Add hooks
        for (uint8 i = 0; i < hooksToAdd; i++) {
            address newHook = address(uint160(1000 + i));
            vm.prank(owner);
            wrapper.addAlphixHook(newHook);
        }

        address[] memory allHooks = wrapper.getAllAlphixHooks();
        assertEq(allHooks.length, initialCount + hooksToAdd, "Should have correct hook count");
    }
}
