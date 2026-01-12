// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";

/**
 * @title AccessAndOwnershipTest
 * @author Alphix
 * @notice Validates ownership, two-step transfers, and AccessManager-gated permissions across Alphix components
 */
contract AccessAndOwnershipTest is BaseAlphixTest {
    /* TESTS */

    /**
     * @notice Default owners are set as expected after base setup
     */
    function test_default_owners() public view {
        // Hook owner
        assertEq(hook.owner(), owner, "hook owner");

        // Logic owner (via proxy)
        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), owner, "logic proxy owner");
    }

    /**
     * @notice Transfer hook ownership via two-step, only new owner can call owner-only functions afterwards
     */
    function test_hook_two_step_ownership_transfer() public {
        // Deploy a fresh hook + logic stack for this test (single-pool-per-hook architecture)
        (Alphix freshHook,) = _deployFreshAlphixStack();

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
        (Alphix anotherHook,) = _deployFreshAlphixStack();
        (PoolKey memory anotherKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, anotherHook);

        // Transfer ownership to newOwner
        vm.prank(owner);
        anotherHook.transferOwnership(newOwner);
        vm.prank(newOwner);
        anotherHook.acceptOwnership();

        // Old owner should be unauthorized
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        anotherHook.initializePool(anotherKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice Transfer logic proxy ownership via two-step; only new owner can pause/unpause and upgrade
     */
    function test_logic_two_step_ownership_transfer_and_admin_ops() public {
        address newOwner = makeAddr("newLogicOwner");

        // Initiate transfer on proxy
        vm.prank(owner);
        Ownable2StepUpgradeable(address(logicProxy)).transferOwnership(newOwner);

        // Accept ownership
        vm.prank(newOwner);
        Ownable2StepUpgradeable(address(logicProxy)).acceptOwnership();

        assertEq(Ownable2StepUpgradeable(address(logicProxy)).owner(), newOwner, "logic owner not updated");

        // New owner can pause
        vm.prank(newOwner);
        AlphixLogic(address(logicProxy)).pause();

        // Old owner cannot unpause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        AlphixLogic(address(logicProxy)).unpause();

        // New owner can unpause
        vm.prank(newOwner);
        AlphixLogic(address(logicProxy)).unpause();

        // New owner can upgrade (to identical impl for smoke)
        AlphixLogic newImpl = new AlphixLogic();
        vm.prank(newOwner);
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newImpl), bytes(""));

        // Verify EIP-1967 implementation slot updated
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address impl = address(uint160(uint256(vm.load(address(logicProxy), implSlot))));
        assertEq(impl, address(newImpl), "logic proxy impl not updated");

        // Old owner cannot upgrade
        AlphixLogic newerImpl = new AlphixLogic();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        AlphixLogic(address(logicProxy)).upgradeToAndCall(address(newerImpl), bytes(""));
    }

    /**
     * @notice AccessManager: only REGISTRAR_ROLE can register contracts and pools; role transfer and revocation works
     */
    function test_access_manager_roles_and_revocation() public {
        // Grant role to owner
        vm.prank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, owner, 0);

        // Owner can register contract
        vm.prank(owner);
        registry.registerContract(IRegistry.ContractKey.Alphix, address(hook));
        assertEq(registry.getContract(IRegistry.ContractKey.Alphix), address(hook), "contract not set");

        // Owner can register a fresh pool
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory freshKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 30, hooks: IHooks(hook)
        });
        PoolId freshId = freshKey.toId();

        vm.prank(owner);
        registry.registerPool(freshKey, 500, 5e17);
        IRegistry.PoolInfo memory info = registry.getPoolInfo(freshId);
        assertEq(info.hooks, address(hook), "pool not stored");

        // Revoke role from owner
        vm.prank(owner);
        accessManager.revokeRole(REGISTRAR_ROLE, owner);

        // Now owner should be unauthorized to register more
        vm.prank(owner);
        vm.expectRevert();
        registry.registerContract(IRegistry.ContractKey.AlphixLogic, address(logicProxy));

        vm.prank(owner);
        vm.expectRevert();
        registry.registerPool(freshKey, 5000, 7e17);

        // Grant role to user1; user1 can now register
        vm.prank(owner);
        accessManager.grantRole(REGISTRAR_ROLE, user1, 0);

        vm.prank(user1);
        registry.registerContract(IRegistry.ContractKey.AlphixLogic, address(logicProxy));
        assertEq(registry.getContract(IRegistry.ContractKey.AlphixLogic), address(logicProxy), "logic not set by user1");
    }

    /**
     * @notice Only hook can call logic-onlyAlphixHook entrypoints; ownership changes on hook update the authority
     */
    function test_only_owner_can_call_logic_admin_endpoints_despite_ownership_changes() public {
        // Confirm non-owner reverts on a restricted function (now onlyOwner, not onlyAlphixHook)
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
        logic.setGlobalMaxAdjRate(1e19);

        // Transfer logic ownership
        address newOwner = makeAddr("newLogicOwner");
        vm.prank(owner);
        AlphixLogic(address(logic)).transferOwnership(newOwner);
        vm.prank(newOwner);
        AlphixLogic(address(logic)).acceptOwnership();

        // Old owner can no longer call
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner));
        logic.setGlobalMaxAdjRate(1e19);

        // New owner can call
        vm.prank(newOwner);
        logic.setGlobalMaxAdjRate(1e19); // Should succeed
    }
}
