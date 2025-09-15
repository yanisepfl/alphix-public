// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {Registry} from "../../../../src/Registry.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";

/**
 * @title AlphixDeploymentTest
 * @notice Integration tests for Alphix constructor, initialize, and admin functions.
 * @dev Inherits BaseAlphixTest for shared setup and helper functions.
 */
contract AlphixDeploymentTest is BaseAlphixTest {
    /**
     * @notice Verifies Hook is paused by constructor and unpaused by initialize().
     */
    function test_constructor_pauseThenInitializeUnpause() public {
        vm.startPrank(owner);
        // Deploy fresh hook instance
        Alphix freshHook = _deployAlphixHook();
        // After construction, hook must be paused
        assertTrue(freshHook.paused(), "Hook should be paused by constructor");
        // Initialize unpauses
        freshHook.initialize(address(logic));
        assertFalse(freshHook.paused(), "Hook should be unpaused after initialize");
        vm.stopPrank();
    }

    /**
     * @notice constructor should revert if poolManager is zero.
     */
    function test_constructor_revertsOnZeroPoolManager() public {
        // Predict the address of the next contract created
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        // Expect Uniswap’s Hook‐address validation to revert
        vm.expectRevert(
            abi.encodeWithSelector(
                Hooks.HookAddressNotValid.selector,
                predicted // the address of the new Alphix contract
            )
        );
        new Alphix(IPoolManager(address(0)), owner, address(registry));
    }

    /**
     * @notice constructor should revert if owner is zero.
     */
    function test_constructor_revertsOnZeroOwner() public {
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        new Alphix(IPoolManager(address(poolManager)), address(0), address(registry));
    }

    /**
     * @notice constructor should revert if registry is zero.
     */
    function test_constructor_revertsOnZeroRegistry() public {
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        new Alphix(IPoolManager(address(poolManager)), owner, address(0));
    }

    /**
     * @notice initialize should set logic and unpause the hook.
     */
    function test_initialize_success() public {
        Alphix fresh = _deployAlphixHook();
        vm.prank(owner);
        fresh.initialize(address(logic));
        assertEq(fresh.getLogic(), address(logic), "Logic not set");
        assertFalse(fresh.paused(), "Hook should be unpaused");
    }

    /**
     * @notice initialize should revert on zero logic address.
     */
    function test_initialize_revertsOnZeroLogic() public {
        Alphix fresh = _deployAlphixHook();
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        fresh.initialize(address(0));
    }

    /**
     * @notice initialize should revert when caller is not owner.
     */
    function test_initialize_revertsOnNonOwner() public {
        Alphix fresh = _deployAlphixHook();
        vm.prank(user1);
        vm.expectRevert("Ownable2Step: caller is not the owner");
        fresh.initialize(address(logic));
    }

    /**
     * @notice setLogic should update logic and emit LogicUpdated.
     */
    function test_setLogic_success() public {
        AlphixLogic newImpl = new AlphixLogic();
        ERC1967Proxy newProxy = new ERC1967Proxy(
            address(newImpl),
            abi.encodeCall(
                newImpl.initialize,
                (owner, address(hook), INITIAL_FEE, stableBounds, standardBounds, volatileBounds)
            )
        );
        address oldLogic = hook.getLogic();
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IAlphix.LogicUpdated(oldLogic, address(newProxy));
        hook.setLogic(address(newProxy));
        assertEq(hook.getLogic(), address(newProxy), "Logic not updated");
    }

    /**
     * @notice setLogic should revert on zero address.
     */
    function test_setLogic_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        hook.setLogic(address(0));
    }

    /**
     * @notice setLogic should revert on invalid logic contract.
     */
    function test_setLogic_revertsOnInvalidInterface() public {
        MockERC20 bad = new MockERC20("Bad", "BAD", 18);
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidLogicContract.selector);
        hook.setLogic(address(bad));
    }

    /**
     * @notice setLogic should revert when caller is not owner.
     */
    function test_setLogic_revertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable2Step: caller is not the owner");
        hook.setLogic(address(logic));
    }

    /**
     * @notice setRegistry should update registry and emit RegistryUpdated.
     */
    function test_setRegistry_success() public {
        Registry newReg = new Registry(address(accessManager));
        address oldRegistry = hook.getRegistry();
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IAlphix.RegistryUpdated(oldRegistry, address(newReg));
        hook.setRegistry(address(newReg));
        assertEq(hook.getRegistry(), address(newReg), "Registry not updated");
    }

    /**
     * @notice setRegistry should revert on zero address.
     */
    function test_setRegistry_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        hook.setRegistry(address(0));
    }

    /**
     * @notice setRegistry should revert when caller is not owner.
     */
    function test_setRegistry_revertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable2Step: caller is not the owner");
        hook.setRegistry(address(registry));
    }

    /**
     * @notice pause and unpause should work for owner only.
     */
    function test_pauseAndUnpause_owner() public {
        vm.prank(owner);
        hook.unpause();
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Pause failed");
        vm.prank(owner);
        hook.unpause();
        assertFalse(hook.paused(), "Unpause failed");
    }

    /**
     * @notice pause should revert when caller is not owner.
     */
    function test_pause_revertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable2Step: caller is not the owner");
        hook.pause();
    }

    /**
     * @notice unpause should revert when caller is not owner.
     */
    function test_unpause_revertsOnNonOwner() public {
        vm.prank(user1);
        vm.expectRevert("Ownable2Step: caller is not the owner");
        hook.unpause();
    }

    /**
     * @notice getLogic() and getRegistry() should return correct values.
     */
    function test_getters() public view {
        assertEq(hook.getLogic(), address(logic), "getLogic mismatch");
        assertEq(hook.getRegistry(), address(registry), "getRegistry mismatch");
    }
}
