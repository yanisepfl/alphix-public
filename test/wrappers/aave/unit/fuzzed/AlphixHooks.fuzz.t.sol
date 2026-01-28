// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title AlphixHooksFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave hook management functions.
 */
contract AlphixHooksFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test adding random addresses as hooks.
     * @param hookAddress Random address to add as hook.
     */
    function testFuzz_addAlphixHook_succeeds(address hookAddress) public {
        vm.assume(hookAddress != address(0));
        vm.assume(hookAddress != alphixHook); // Already added in setUp

        vm.prank(owner);
        wrapper.addAlphixHook(hookAddress);

        assertTrue(wrapper.isAlphixHook(hookAddress), "Hook should be added");
    }

    /**
     * @notice Fuzz test that non-owner cannot add hooks.
     * @param caller Random caller address.
     * @param hookAddress Random hook address.
     */
    function testFuzz_addAlphixHook_revertsIfNotOwner(address caller, address hookAddress) public {
        vm.assume(caller != owner);
        vm.assume(hookAddress != address(0));
        vm.assume(hookAddress != alphixHook);

        vm.prank(caller);
        vm.expectRevert();
        wrapper.addAlphixHook(hookAddress);
    }

    /**
     * @notice Fuzz test removing hooks.
     * @param hookAddress Random address to add then remove.
     */
    function testFuzz_removeAlphixHook_succeeds(address hookAddress) public {
        vm.assume(hookAddress != address(0));
        vm.assume(hookAddress != alphixHook);

        // Add then remove
        vm.startPrank(owner);
        wrapper.addAlphixHook(hookAddress);
        assertTrue(wrapper.isAlphixHook(hookAddress), "Should be added");

        wrapper.removeAlphixHook(hookAddress);
        assertFalse(wrapper.isAlphixHook(hookAddress), "Should be removed");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that non-owner cannot remove hooks.
     * @param caller Random caller address.
     */
    function testFuzz_removeAlphixHook_revertsIfNotOwner(address caller) public {
        vm.assume(caller != owner);

        vm.prank(caller);
        vm.expectRevert();
        wrapper.removeAlphixHook(alphixHook);
    }

    /**
     * @notice Fuzz test isAlphixHook for random addresses.
     * @param randomAddress Random address to check.
     */
    function testFuzz_isAlphixHook_returnsFalseForRandomAddress(address randomAddress) public view {
        vm.assume(randomAddress != alphixHook);

        assertFalse(wrapper.isAlphixHook(randomAddress), "Should be false for random address");
    }

    /**
     * @notice Fuzz test maxDeposit for random addresses.
     * @param randomAddress Random address to check.
     */
    function testFuzz_maxDeposit_zeroForUnauthorized(address randomAddress) public view {
        vm.assume(randomAddress != alphixHook);
        vm.assume(randomAddress != owner);

        assertEq(wrapper.maxDeposit(randomAddress), 0, "Should be 0 for unauthorized");
    }

    /**
     * @notice Fuzz test adding multiple hooks and verifying getAllAlphixHooks.
     * @param numHooks Number of hooks to add (bounded).
     */
    function testFuzz_getAllAlphixHooks_multipleHooks(uint8 numHooks) public {
        numHooks = uint8(bound(numHooks, 1, 20));

        // Add hooks (alphixHook already exists)
        for (uint8 i = 0; i < numHooks; i++) {
            address newHook = makeAddr(string(abi.encodePacked("hook", i)));
            vm.prank(owner);
            wrapper.addAlphixHook(newHook);
        }

        address[] memory hooks = wrapper.getAllAlphixHooks();
        assertEq(hooks.length, numHooks + 1, "Should have correct number of hooks");
    }

    /**
     * @notice Fuzz test each hook can deposit to itself.
     * @param depositAmount The deposit amount.
     * @dev Cross-deposit is no longer allowed (receiver == msg.sender constraint).
     */
    function testFuzz_hookDepositsToSelf_succeeds(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 1_000_000_000e6);

        address hook2 = makeAddr("hook2");

        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Hook2 deposits to self
        asset.mint(hook2, depositAmount);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, hook2);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares");
        assertEq(wrapper.balanceOf(hook2), shares, "Hook2 should receive shares");
    }

    /**
     * @notice Fuzz test hook can deposit after being re-added.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_reAddedHook_canDeposit(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 1_000_000e6);

        // Remove and re-add hook
        vm.startPrank(owner);
        wrapper.removeAlphixHook(alphixHook);
        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Should be able to deposit
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares after re-add");
    }

    /**
     * @notice Fuzz test adding and removing multiple hooks maintains consistency.
     * @param addCount Number of hooks to add.
     * @param removeCount Number of hooks to remove.
     */
    function testFuzz_addRemove_maintainsConsistency(uint8 addCount, uint8 removeCount) public {
        addCount = uint8(bound(addCount, 1, 10));
        removeCount = uint8(bound(removeCount, 0, addCount));

        address[] memory hooks = new address[](addCount);

        // Add hooks
        vm.startPrank(owner);
        for (uint8 i = 0; i < addCount; i++) {
            hooks[i] = makeAddr(string(abi.encodePacked("testHook", i)));
            wrapper.addAlphixHook(hooks[i]);
        }

        // Remove some hooks
        for (uint8 i = 0; i < removeCount; i++) {
            wrapper.removeAlphixHook(hooks[i]);
        }
        vm.stopPrank();

        // Verify state
        uint256 expectedHooks = 1 + addCount - removeCount; // 1 for alphixHook from setUp
        assertEq(wrapper.getAllAlphixHooks().length, expectedHooks, "Wrong hook count");

        // Verify removed hooks are not authorized
        for (uint8 i = 0; i < removeCount; i++) {
            assertFalse(wrapper.isAlphixHook(hooks[i]), "Removed hook should not be authorized");
        }

        // Verify remaining hooks are authorized
        for (uint8 i = removeCount; i < addCount; i++) {
            assertTrue(wrapper.isAlphixHook(hooks[i]), "Remaining hook should be authorized");
        }
    }
}
