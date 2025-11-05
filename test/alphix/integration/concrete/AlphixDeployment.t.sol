// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* OZ IMPORTS */
import {AccessManager, IAccessManaged} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";
import {Registry} from "../../../../src/Registry.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {MockERC165} from "../../../utils/mocks/MockERC165.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";

contract AlphixDeploymentTest is BaseAlphixTest {
    /* TESTS */

    /**
     * @notice Verifies Alphix Hook is paused by constructor and unpaused by initialize.
     */
    function test_constructor_pauseThenInitializeUnpause() public {
        vm.startPrank(owner);
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        assertTrue(testHook.paused(), "Hook should be paused by constructor");
        testHook.initialize(address(logic));
        assertFalse(testHook.paused(), "Hook should be unpaused after initialize");
        vm.stopPrank();
    }

    /**
     * @notice Constructor should revert if poolManager is zero.
     */
    function test_constructor_revertsOnZeroPoolManager() public {
        vm.startPrank(owner);
        // Reverts because the Hook address has not been mined as per Uniswap V4's requirement
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new Alphix(IPoolManager(address(0)), owner, address(accessManager), address(registry));

        // Reverts because of Alphix Hook constructor restriction
        AccessManager testAm = new AccessManager(owner);
        Registry testReg = new Registry(address(testAm));
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, testAm, testReg);
        bytes memory ctor = abi.encode(IPoolManager(address(0)), owner, address(testAm), address(testReg));
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        vm.stopPrank();
    }

    /**
     * @notice constructor should revert if owner is zero.
     */
    function test_constructor_revertsOnZeroOwner() public {
        vm.startPrank(owner);
        // Reverts because the Hook address has not been mined as per Uniswap V4's requirement
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new Alphix(poolManager, address(0), address(accessManager), address(registry));

        // Reverts because of Alphix Hook constructor restriction
        AccessManager testAm = new AccessManager(owner);
        Registry testReg = new Registry(address(testAm));
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, testAm, testReg);
        bytes memory ctor = abi.encode(poolManager, address(0), address(testAm), address(testReg));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        vm.stopPrank();
    }

    /**
     * @notice constructor should revert if registry is zero.
     */
    function test_constructor_revertsOnZeroRegistry() public {
        vm.startPrank(owner);
        // Reverts because the Hook address has not been mined as per Uniswap V4's requirement
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new Alphix(poolManager, owner, address(accessManager), address(0));

        // Reverts because of Alphix Hook constructor restriction
        AccessManager testAm = new AccessManager(owner);
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, testAm, Registry(address(0)));
        bytes memory ctor = abi.encode(poolManager, owner, address(testAm), address(0));
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        vm.stopPrank();
    }

    /**
     * @notice Constructor should revert if AccessManager hasn't granted registrar role the hook address.
     */
    function test_constructor_revertsOnBadAccessManager() public {
        vm.startPrank(owner);
        // Compute a valid hook address
        address hookAddr = _computeNextHookAddress();
        // Deploy a Registry governed by a fresh AccessManager that never granted roles
        AccessManager badAm = new AccessManager(owner);
        Registry badReg = new Registry(address(badAm));

        // Expect revert from AccessManager when hook constructor calls registerContract
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, hookAddr));

        // Deploy hook via CREATE2 at hookAddr; constructor will call registry.registerContract and revert
        bytes memory ctor = abi.encode(poolManager, owner, address(badAm), address(badReg));
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        vm.stopPrank();
    }

    /**
     * @notice initialize should revert when called by a non-owner.
     */
    function test_initialize_revertsWithBadOwner() public {
        vm.startPrank(owner);
        // Deploy a test hook properly authorized
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        vm.stopPrank();

        // Attempt to initialize from an unauthorized account
        vm.prank(unauthorized);
        // Expect revert from Ownable when calling initialize
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        testHook.initialize(address(logic));
    }

    /**
     * @notice Deploying Alphix Infrastructure works with user1.
     */
    function test_deployAlphixInfrastructure_user1_success() public {
        vm.startPrank(user1);
        (, Registry testRegistry, Alphix testHook,,, IAlphixLogic testLogic) =
            _deployAlphixInfrastructure(poolManager, user1);
        assertEq(testHook.getLogic(), address(testLogic), "Logic not set");
        assertEq(testHook.getRegistry(), address(testRegistry), "Registry not set");
        assertFalse(testHook.paused(), "Hook should be unpaused");
        vm.stopPrank();
    }

    /**
     * @notice Tests that multiple initialization attempts are properly blocked.
     * @dev Verifies protection against re-initialization attacks and concurrent initialization attempts.
     */
    function test_multipleInitializationRevert() public {
        vm.startPrank(owner);

        // Deploy a test hook that starts paused
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        assertTrue(testHook.paused(), "Test hook should be paused");

        // Deploy a test logic
        (,, IAlphixLogic testLogic) = _deployAlphixLogic(owner, address(testHook));
        assertTrue(testHook.paused(), "Hook should be paused after construction and before initialize");

        // Normal initialization should succeed
        testHook.initialize(address(testLogic));
        assertFalse(testHook.paused(), "Hook should be unpaused after initialize");
        assertEq(testHook.getLogic(), address(testLogic), "Logic should be set");

        // Expect revert from Initializable when contract already initialized
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        testHook.initialize(address(testLogic));
        // testHook should remain unchanged
        assertFalse(testHook.paused(), "Hook should be unpaused after initialize");
        assertEq(testHook.getLogic(), address(testLogic), "Logic should be set");

        // Try initialization with different logic address (should still revert)
        (,, IAlphixLogic newLogic) = _deployAlphixLogic(owner, address(testHook));

        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        testHook.initialize(address(newLogic));

        // Try initialization from unauthorized account (should revert even if not initialized)
        Alphix testHook2 = _deployAlphixHook(poolManager, owner, accessManager, registry);
        // Deploy a test logic
        (,, testLogic) = _deployAlphixLogic(owner, address(testHook2));
        assertTrue(testHook2.paused(), "Hook should be paused after construction and before initialize");
        vm.stopPrank();

        vm.prank(unauthorized);
        // Expect revert from Ownable when calling initialize
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        testHook2.initialize(address(testLogic));
        assertTrue(testHook2.paused(), "Hook should still be paused");

        // Try concurrent initialization attempts from different accounts
        vm.startPrank(owner);
        Alphix testHook3 = _deployAlphixHook(poolManager, owner, accessManager, registry);
        // Deploy a test logic
        (,, testLogic) = _deployAlphixLogic(owner, address(testHook3));
        assertTrue(testHook3.paused(), "Hook should be paused after construction and before initialize");
        vm.stopPrank();

        // Simulate race condition: both user1 and owner try to initialize
        vm.prank(user1);
        // Expect revert from Ownable when calling initialize
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        testHook3.initialize(address(testLogic));

        // Owner should still be able to initialize normally after failed unauthorized attempt
        vm.prank(owner);
        testHook3.initialize(address(testLogic));
        assertFalse(testHook3.paused(), "Hook should be unpaused");
        assertEq(testHook3.getLogic(), address(testLogic), "Logic should be set");

        // Verify that even after successful initialization, re-initialization is blocked
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        testHook3.initialize(address(testLogic));
        // testHook3 should remain unchanged
        assertFalse(testHook3.paused(), "Hook should be unpaused after initialize");
        assertEq(testHook3.getLogic(), address(testLogic), "Logic should be set");
    }

    /**
     * @notice Tests initialization with malicious logic contracts.
     * @dev Verifies that only valid IAlphixLogic contracts can be set during initialization.
     */
    function test_initializationWithMaliciousLogic() public {
        vm.startPrank(owner);

        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);

        // Try to initialize with a non-contract address
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        testHook.initialize(address(0));

        // Try to initialize with an EOA
        vm.expectRevert(); // supportsInterface call on EOA
        testHook.initialize(makeAddr("eoa"));

        // Try to initialize with a contract that doesn't implement supportsInterface
        MockERC20 maliciousToken = new MockERC20("Evil Token Contract", "ETC", 18);
        vm.expectRevert();
        testHook.initialize(address(maliciousToken));

        // Try to initialize with a contract that fails to implement supportsInterface
        MockERC165 maliciousContract = new MockERC165();
        vm.expectRevert(IAlphixLogic.InvalidLogicContract.selector);
        testHook.initialize(address(maliciousContract));

        // Verify hook is still paused and uninitialized after failed attempts
        assertTrue(testHook.paused(), "Hook should still be paused after failed initializations");
        assertEq(testHook.getLogic(), address(0), "Logic should still be zero after failed initializations");

        // Normal initialization should still work after failed attempts
        (,, IAlphixLogic testLogic) = _deployAlphixLogic(owner, address(testHook));
        assertTrue(testHook.paused(), "Hook should still be paused after logic deployment");
        testHook.initialize(address(testLogic));
        assertFalse(testHook.paused(), "Hook should be unpaused after successful initialization");
        assertEq(testHook.getLogic(), address(testLogic), "Logic should be set correctly");

        vm.stopPrank();
    }

    /**
     * @notice setLogic should update logic and emit LogicUpdated.
     * @dev Initializes the replacement logic with unified params.
     */
    function test_setLogic_success() public {
        AlphixLogic newImpl = new AlphixLogic();
        ERC1967Proxy newProxy = new ERC1967Proxy(
            address(newImpl),
            abi.encodeCall(newImpl.initialize, (owner, address(hook), stableParams, standardParams, volatileParams))
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
        MockERC20 maliciousContract = new MockERC20("Malicious Contract", "MC", 18);
        vm.prank(owner);
        vm.expectRevert();
        hook.setLogic(address(maliciousContract));

        MockERC165 mockErc165 = new MockERC165();
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidLogicContract.selector);
        hook.setLogic(address(mockErc165));
    }

    /**
     * @notice setLogic should revert when caller is not owner.
     */
    function test_setLogic_revertsOnNonOwner() public {
        AlphixLogic newImpl = new AlphixLogic();
        ERC1967Proxy newProxy = new ERC1967Proxy(
            address(newImpl),
            abi.encodeCall(newImpl.initialize, (owner, address(hook), stableParams, standardParams, volatileParams))
        );
        address oldLogic = hook.getLogic();
        vm.prank(user1);
        // Expect revert from Ownable when calling setLogic
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        hook.setLogic(address(newProxy));
        assertEq(hook.getLogic(), oldLogic, "Logic should not update on non-owner");
    }

    /**
     * @notice setRegistry should update registry and emit RegistryUpdated.
     */
    function test_setRegistry_success() public {
        Registry newReg = new Registry(address(accessManager));
        vm.startPrank(owner);
        _setupAccessManagerRoles(address(hook), accessManager, newReg);
        vm.stopPrank();
        address oldRegistry = hook.getRegistry();
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IAlphix.RegistryUpdated(oldRegistry, address(newReg));
        hook.setRegistry(address(newReg));
        assertEq(hook.getRegistry(), address(newReg), "Registry not updated");
    }

    /**
     * @notice setRegistry should revert when not adding hook as a registrar in the registry.
     */
    function test_setRegistryWithoutSettingRegistrarRole_revert() public {
        Registry newReg = new Registry(address(accessManager));
        address oldRegistry = hook.getRegistry();
        vm.prank(owner);
        // Expect revert from AccessManager when hook constructor calls setRegistry
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(hook)));
        hook.setRegistry(address(newReg));
        assertEq(hook.getRegistry(), oldRegistry, "Registry not updated");
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
        // Expect revert from Ownable when calling setRegistry
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        hook.setRegistry(address(registry));
    }

    /**
     * @notice setRegistry should revert when setting to an EOA (non-contract).
     * @dev Addresses Olympix finding: call_to_non_contract_registry
     * Note: Calling supportsInterface() on an EOA reverts with empty data (no code to execute)
     */
    function test_setRegistry_revertsOnEOA() public {
        address eoaRegistry = makeAddr("eoaRegistry");
        assertEq(eoaRegistry.code.length, 0, "Should be EOA with no code");

        vm.prank(owner);
        vm.expectRevert(); // Generic revert - supportsInterface call on EOA fails
        hook.setRegistry(eoaRegistry);

        // Verify registry was not changed
        assertEq(hook.getRegistry(), address(registry), "Registry should not have changed");
    }

    /**
     * @notice setRegistry should revert when setting to a contract without IRegistry interface.
     * @dev Addresses Olympix finding: call_to_non_contract_registry
     */
    function test_setRegistry_revertsOnNonRegistryContract() public {
        // Deploy a contract that doesn't implement IRegistry
        MockERC20 notARegistry = new MockERC20("Not Registry", "NR", 18);
        assertTrue(address(notARegistry).code.length > 0, "Should be a contract");

        vm.prank(owner);
        // Expect revert when checking interface support
        vm.expectRevert();
        hook.setRegistry(address(notARegistry));

        // Verify registry was not changed
        assertEq(hook.getRegistry(), address(registry), "Registry should not have changed");
    }

    /**
     * @notice setRegistry should revert when setting to a contract that implements ERC165 but not IRegistry.
     * @dev Addresses Olympix finding: call_to_non_contract_registry
     */
    function test_setRegistry_revertsOnInvalidInterface() public {
        // Deploy a contract with ERC165 but wrong interface
        MockERC165 wrongInterface = new MockERC165();
        assertTrue(address(wrongInterface).code.length > 0, "Should be a contract");

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        hook.setRegistry(address(wrongInterface));

        // Verify registry was not changed
        assertEq(hook.getRegistry(), address(registry), "Registry should not have changed");
    }

    /**
     * @notice Pause and unpause should work when called by owner.
     */
    function test_pauseAndUnpause_owner() public {
        assertFalse(hook.paused(), "Unpause failed");
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Pause failed");
        vm.prank(owner);
        hook.unpause();
        assertFalse(hook.paused(), "Unpause failed");
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Pause failed");
    }

    /**
     * @notice Pause should revert when caller is not owner.
     */
    function test_pause_revertsOnNonOwner() public {
        assertFalse(hook.paused(), "Unpause failed");
        vm.prank(user1);
        // Expect revert from Ownable when calling pause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        hook.pause();
        assertFalse(hook.paused(), "Unpause failed");
    }

    /**
     * @notice unpause should revert when caller is not owner.
     */
    function test_unpause_revertsOnNonOwner() public {
        assertFalse(hook.paused(), "Unpause failed");
        vm.prank(user1);
        // Expect revert from Ownable when calling unpause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user1));
        hook.unpause();
        assertFalse(hook.paused(), "Unpause failed");
    }

    /**
     * @notice unpause should revert when contract is unpaused already.
     */
    function test_unpauseWhenUnpaused_revert() public {
        assertFalse(hook.paused(), "Unpause failed");
        vm.prank(owner);
        // Expect revert because the contract is already unpaused
        vm.expectRevert(Pausable.ExpectedPause.selector);
        hook.unpause();
        assertFalse(hook.paused(), "Unpause failed");
    }

    /**
     * @notice pause should revert when contract is paused already.
     */
    function test_pauseWhenpaused_revert() public {
        assertFalse(hook.paused(), "Unpause failed");
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Pause failed");
        // Expect revert because the contract is already paused
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Pause failed");
    }

    /**
     * @notice getLogic() and getRegistry() should return correct values.
     */
    function test_getters() public view {
        assertEq(hook.getLogic(), address(logic), "getLogic mismatch");
        assertEq(hook.getRegistry(), address(registry), "getRegistry mismatch");
    }

    /**
     * @notice After initialize, per-pool-type unified params should be set and a default global max adj rate should be applied.
     * @dev Verifies logic.initialize consumed the initializer args for STABLE/STANDARD/VOLATILE and set a sane global cap.
     */
    function test_initialize_setsUnifiedParamsAndDefaultCap() public view {
        // Verify STABLE params match initializer arguments
        IAlphixLogic.PoolType ptStable = IAlphixLogic.PoolType.STABLE;
        DynamicFeeLib.PoolTypeParams memory ps = logic.getPoolTypeParams(ptStable);
        assertEq(ps.minFee, stableParams.minFee, "minFee mismatch (STABLE)");
        assertEq(ps.maxFee, stableParams.maxFee, "maxFee mismatch (STABLE)");
        assertEq(ps.baseMaxFeeDelta, stableParams.baseMaxFeeDelta, "baseMaxFeeDelta mismatch (STABLE)");
        assertEq(ps.lookbackPeriod, stableParams.lookbackPeriod, "lookbackPeriod mismatch (STABLE)");
        assertEq(ps.minPeriod, stableParams.minPeriod, "minPeriod mismatch (STABLE)");
        assertEq(ps.ratioTolerance, stableParams.ratioTolerance, "ratioTolerance mismatch (STABLE)");
        assertEq(ps.linearSlope, stableParams.linearSlope, "linearSlope mismatch (STABLE)");
        assertEq(ps.maxCurrentRatio, stableParams.maxCurrentRatio, "maxCurrentRatio mismatch (STABLE)");
        assertEq(ps.upperSideFactor, stableParams.upperSideFactor, "upperSideFactor mismatch (STABLE)");
        assertEq(ps.lowerSideFactor, stableParams.lowerSideFactor, "lowerSideFactor mismatch (STABLE)");

        // Verify STANDARD params match initializer arguments
        IAlphixLogic.PoolType ptStandard = IAlphixLogic.PoolType.STANDARD;
        ps = logic.getPoolTypeParams(ptStandard);
        assertEq(ps.minFee, standardParams.minFee, "minFee mismatch (STANDARD)");
        assertEq(ps.maxFee, standardParams.maxFee, "maxFee mismatch (STANDARD)");
        assertEq(ps.baseMaxFeeDelta, standardParams.baseMaxFeeDelta, "baseMaxFeeDelta mismatch (STANDARD)");
        assertEq(ps.lookbackPeriod, standardParams.lookbackPeriod, "lookbackPeriod mismatch (STANDARD)");
        assertEq(ps.minPeriod, standardParams.minPeriod, "minPeriod mismatch (STANDARD)");
        assertEq(ps.ratioTolerance, standardParams.ratioTolerance, "ratioTolerance mismatch (STANDARD)");
        assertEq(ps.linearSlope, standardParams.linearSlope, "linearSlope mismatch (STANDARD)");
        assertEq(ps.maxCurrentRatio, standardParams.maxCurrentRatio, "maxCurrentRatio mismatch (STANDARD)");
        assertEq(ps.upperSideFactor, standardParams.upperSideFactor, "upperSideFactor mismatch (STANDARD)");
        assertEq(ps.lowerSideFactor, standardParams.lowerSideFactor, "lowerSideFactor mismatch (STANDARD)");

        // Verify VOLATILE params match initializer arguments
        IAlphixLogic.PoolType ptVolatile = IAlphixLogic.PoolType.VOLATILE;
        ps = logic.getPoolTypeParams(ptVolatile);
        assertEq(ps.minFee, volatileParams.minFee, "minFee mismatch (VOLATILE)");
        assertEq(ps.maxFee, volatileParams.maxFee, "maxFee mismatch (VOLATILE)");
        assertEq(ps.baseMaxFeeDelta, volatileParams.baseMaxFeeDelta, "baseMaxFeeDelta mismatch (VOLATILE)");
        assertEq(ps.lookbackPeriod, volatileParams.lookbackPeriod, "lookbackPeriod mismatch (VOLATILE)");
        assertEq(ps.minPeriod, volatileParams.minPeriod, "minPeriod mismatch (VOLATILE)");
        assertEq(ps.ratioTolerance, volatileParams.ratioTolerance, "ratioTolerance mismatch (VOLATILE)");
        assertEq(ps.linearSlope, volatileParams.linearSlope, "linearSlope mismatch (VOLATILE)");
        assertEq(ps.maxCurrentRatio, volatileParams.maxCurrentRatio, "maxCurrentRatio mismatch (VOLATILE)");
        assertEq(ps.upperSideFactor, volatileParams.upperSideFactor, "upperSideFactor mismatch (VOLATILE)");
        assertEq(ps.lowerSideFactor, volatileParams.lowerSideFactor, "lowerSideFactor mismatch (VOLATILE)");

        // Verify a default global cap is set inside logic and is within safe bound
        uint256 cap = logic.getGlobalMaxAdjRate();
        assertTrue(cap > 0, "global cap should be set");
        assertTrue(cap <= GLOBAL_MAX_ADJ_RATE_SAFE, "global cap should be <= safe bound");
    }

    /**
     * @notice Fuzz test: setRegistry should always revert on EOA addresses.
     * @dev Addresses Olympix finding: call_to_non_contract_registry
     * Note: Calling supportsInterface() on an EOA reverts with empty data (no code to execute)
     */
    function testFuzz_setRegistry_revertsOnAnyEOA(address eoaAddress) public {
        // Filter out addresses with code
        vm.assume(eoaAddress.code.length == 0);
        // Filter out zero address (already tested separately)
        vm.assume(eoaAddress != address(0));

        vm.prank(owner);
        vm.expectRevert(); // Generic revert - supportsInterface call on EOA fails
        hook.setRegistry(eoaAddress);

        // Verify registry was not changed
        assertEq(hook.getRegistry(), address(registry), "Registry should not have changed");
    }

    /**
     * @notice Fuzz test: setRegistry should work with valid Registry contracts.
     * @dev Creates new Registry instances and verifies they can be set successfully.
     */
    function testFuzz_setRegistry_worksWithValidRegistry(uint8 iterations) public {
        iterations = uint8(bound(iterations, 1, 10)); // Limit to reasonable number

        vm.startPrank(owner);
        for (uint256 i = 0; i < iterations; i++) {
            // Deploy a new valid Registry
            Registry newReg = new Registry(address(accessManager));

            // Setup roles for the new registry
            _setupAccessManagerRoles(address(hook), accessManager, newReg);

            // Set the new registry
            address oldReg = hook.getRegistry();
            hook.setRegistry(address(newReg));

            // Verify it was set correctly
            assertEq(hook.getRegistry(), address(newReg), "Registry should be updated");
            assertTrue(address(newReg) != oldReg, "New registry should be different from old");
            assertTrue(address(newReg).code.length > 0, "New registry should be a contract");

            // Verify Registry supports IRegistry interface
            assertTrue(
                IERC165(address(newReg)).supportsInterface(type(IRegistry).interfaceId),
                "New registry should support IRegistry interface"
            );
        }
        vm.stopPrank();
    }
}
