// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";

/**
 * @title AccessAndOwnershipTest
 * @author Alphix
 * @notice Validates ownership, two-step transfers, and AccessManager-gated permissions for Alphix hook
 */
contract AccessAndOwnershipTest is BaseAlphixTest {
    /* TESTS */

    /**
     * @notice Default owners are set as expected after base setup
     */
    function test_default_owners() public view {
        // Hook owner
        assertEq(hook.owner(), owner, "hook owner");
    }

    /**
     * @notice Transfer hook ownership via two-step, only new owner can call owner-only functions afterwards
     */
    function test_hook_two_step_ownership_transfer() public {
        // Deploy a fresh hook for this test (single-pool-per-hook architecture)
        Alphix freshHook = _deployFreshAlphixStack();

        address newOwner = makeAddr("newHookOwner");

        // Initiate transfer
        vm.prank(owner);
        freshHook.transferOwnership(newOwner);

        // Accept transfer
        vm.prank(newOwner);
        freshHook.acceptOwnership();

        assertEq(freshHook.owner(), newOwner, "hook owner not updated");

        // New owner can initialize fresh pool on the hook
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        vm.prank(newOwner);
        freshHook.initializePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Old owner now unauthorized for owner-only functions - create another fresh hook for this test
        Alphix anotherHook = _deployFreshAlphixStack();
        (PoolKey memory anotherKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, anotherHook);

        // Transfer ownership to newOwner
        vm.prank(owner);
        anotherHook.transferOwnership(newOwner);
        vm.prank(newOwner);
        anotherHook.acceptOwnership();

        // Old owner should be unauthorized
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        anotherHook.initializePool(anotherKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice Only owner can call admin endpoints on hook
     */
    function test_only_owner_can_call_admin_endpoints() public {
        // Confirm non-owner reverts on a restricted function
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        hook.setGlobalMaxAdjRate(1e19);

        // Owner can call
        vm.prank(owner);
        hook.setGlobalMaxAdjRate(1e19); // Should succeed

        // Transfer hook ownership
        address newOwner = makeAddr("newHookOwner");
        vm.prank(owner);
        hook.transferOwnership(newOwner);
        vm.prank(newOwner);
        hook.acceptOwnership();

        // Old owner can no longer call
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        hook.setGlobalMaxAdjRate(5e18);

        // New owner can call
        vm.prank(newOwner);
        hook.setGlobalMaxAdjRate(5e18); // Should succeed
    }
}
