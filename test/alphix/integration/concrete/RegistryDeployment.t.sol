// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/* SOLMATE IMPORTS */

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Registry, IRegistry} from "../../../../src/Registry.sol";

/**
 * @title RegistryDeploymentTest
 * @author Alphix
 * @notice Tests for Registry deployment and registration flows (contracts and pools)
 * @dev Uses a fresh Registry/AccessManager for empty-state tests to avoid default pre-registrations
 */
contract RegistryDeploymentTest is BaseAlphixTest {
    /* TESTS */

    /**
     * @notice constructor wiring succeeds on the default Registry
     */
    function test_constructor_success() public view {
        assertTrue(address(registry) != address(0), "registry addr has not been properly set up in base setup");
        assertEq(registry.authority(), address(accessManager), "authority mismatch");
    }

    /**
     * @notice constructor reverts when access manager is zero address
     */
    function test_constructor_revertsOnZeroAccessManager() public {
        vm.expectRevert(IRegistry.InvalidAccessManager.selector);
        new Registry(address(0));
    }

    /**
     * @notice getContract returns zero for an unregistered key on a fresh Registry
     */
    function test_getContract_returnsZeroForUnregistered() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));
        assertEq(reg2.getContract(IRegistry.ContractKey.Alphix), address(0), "should be zero");
        assertEq(reg2.getContract(IRegistry.ContractKey.AlphixLogic), address(0), "should be zero");
    }

    /**
     * @notice getPoolInfo returns empty struct for an unregistered pool on a fresh Registry
     */
    function test_getPoolInfo_returnsEmptyForUnregistered() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        // Use an existing PoolId from the default key and registry
        IRegistry.PoolInfo memory info = reg2.getPoolInfo(poolId);
        assertEq(info.token0, address(0), "token0");
        assertEq(info.token1, address(0), "token1");
        assertEq(info.fee, 0, "fee");
        assertEq(info.tickSpacing, 0, "spacing");
        assertEq(info.hooks, address(0), "hooks");
        assertEq(info.initialFee, 0, "init fee");
        assertEq(info.initialTargetRatio, 0, "init ratio");
        assertEq(info.timestamp, 0, "timestamp");
    }

    /**
     * @notice listPools is empty initially on a fresh Registry
     */
    function test_listPools_emptyInitially() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));
        PoolId[] memory pools = reg2.listPools();
        assertEq(pools.length, 0, "empty");
    }

    /**
     * @notice registerContract succeeds for authorized registrar on a fresh Registry
     */
    function test_registerContract_success() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IRegistry.ContractRegistered(IRegistry.ContractKey.Alphix, address(hook));
        reg2.registerContract(IRegistry.ContractKey.Alphix, address(hook));

        assertEq(reg2.getContract(IRegistry.ContractKey.Alphix), address(hook), "registry value mismatch");
    }

    /**
     * @notice registerContract reverts on zero address on a fresh Registry
     */
    function test_registerContract_revertsOnZeroAddress() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        vm.prank(owner);
        vm.expectRevert(IRegistry.InvalidAddress.selector);
        reg2.registerContract(IRegistry.ContractKey.Alphix, address(0));
    }

    /**
     * @notice registerContract reverts for unauthorized caller on a fresh Registry
     */
    function test_registerContract_revertsOnUnauthorized() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(unauthorized);
        vm.expectRevert();
        reg2.registerContract(IRegistry.ContractKey.Alphix, address(hook));
    }

    /**
     * @notice registerContract overwrites existing and emits event on a fresh Registry
     */
    function test_registerContract_overwritesExisting() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        vm.prank(owner);
        reg2.registerContract(IRegistry.ContractKey.Alphix, address(hook));

        address newAddress = makeAddr("newHook");
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IRegistry.ContractRegistered(IRegistry.ContractKey.Alphix, newAddress);
        reg2.registerContract(IRegistry.ContractKey.Alphix, newAddress);

        assertEq(reg2.getContract(IRegistry.ContractKey.Alphix), newAddress, "overwrite failed");
    }

    /**
     * @notice registerPool succeeds and stores metadata on a fresh Registry with a fresh pool key
     */
    function test_registerPool_success() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        // Create a fresh pool key bound to the same hook
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory kFresh = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hook)
        });
        PoolId idFresh = kFresh.toId();

        // Register the pool (avoid event brittleness; assert via storage)
        vm.prank(owner);
        reg2.registerPool(kFresh, INITIAL_FEE, INITIAL_TARGET_RATIO);

        IRegistry.PoolInfo memory info = reg2.getPoolInfo(idFresh);
        assertEq(info.token0, Currency.unwrap(kFresh.currency0), "token0");
        assertEq(info.token1, Currency.unwrap(kFresh.currency1), "token1");
        assertEq(info.fee, kFresh.fee, "fee flag");
        assertEq(info.tickSpacing, kFresh.tickSpacing, "spacing");
        assertEq(info.hooks, address(hook), "hooks");
        assertEq(info.initialFee, INITIAL_FEE, "init fee");
        assertEq(info.initialTargetRatio, INITIAL_TARGET_RATIO, "init ratio");
        assertTrue(info.timestamp > 0, "timestamp > 0");

        PoolId[] memory pools = reg2.listPools();
        assertEq(pools.length, 1, "list len");
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(idFresh), "list[0]");
    }

    /**
     * @notice registerPool reverts on duplicate registrations on a fresh Registry
     */
    function test_registerPool_revertsOnDuplicate() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory kFresh = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 30, hooks: IHooks(hook)
        });
        PoolId idFresh = kFresh.toId();

        vm.prank(owner);
        reg2.registerPool(kFresh, INITIAL_FEE, INITIAL_TARGET_RATIO);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRegistry.PoolAlreadyRegistered.selector, idFresh));
        reg2.registerPool(kFresh, 5000, 7e17);
    }

    /**
     * @notice registerPool reverts for unauthorized caller on a fresh Registry
     */
    function test_registerPool_revertsOnUnauthorized() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory kFresh = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 30, hooks: IHooks(hook)
        });

        vm.prank(unauthorized);
        vm.expectRevert();
        reg2.registerPool(kFresh, INITIAL_FEE, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice listPools returns multiple poolIds when multiple pools registered on a fresh Registry
     */
    function test_listPools_multiplePools() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        // First pool
        (Currency a0, Currency a1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k1 = PoolKey({
            currency0: a0, currency1: a1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(hook)
        });
        PoolId id1 = k1.toId();

        // Second pool
        (Currency b0, Currency b1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k2 = PoolKey({
            currency0: b0, currency1: b1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hook)
        });
        PoolId id2 = k2.toId();

        vm.prank(owner);
        reg2.registerPool(k1, 500, 5e17);

        vm.prank(owner);
        reg2.registerPool(k2, 5000, 7e17);

        PoolId[] memory pools = reg2.listPools();
        assertEq(pools.length, 2, "len");
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(id1), "id0");
        assertEq(PoolId.unwrap(pools[1]), PoolId.unwrap(id2), "id1");
    }

    /**
     * @notice supports multiple contract keys; latest value retrievable on a fresh Registry
     */
    function test_multipleContractTypes() public {
        AccessManager am2 = new AccessManager(owner);
        Registry reg2 = new Registry(address(am2));

        vm.prank(owner);
        am2.grantRole(REGISTRAR_ROLE, owner, 0);

        vm.prank(owner);
        reg2.registerContract(IRegistry.ContractKey.Alphix, address(hook));

        vm.prank(owner);
        reg2.registerContract(IRegistry.ContractKey.AlphixLogic, address(logic));

        assertEq(reg2.getContract(IRegistry.ContractKey.Alphix), address(hook), "alphix");
        assertEq(reg2.getContract(IRegistry.ContractKey.AlphixLogic), address(logic), "logic");
    }

    /**
     * @notice supportsInterface returns true for IRegistry interface
     */
    function test_supportsInterface_IRegistry() public view {
        assertTrue(registry.supportsInterface(type(IRegistry).interfaceId), "should support IRegistry");
    }

    /**
     * @notice supportsInterface returns true for IERC165 (ERC165 compliance)
     */
    function test_supportsInterface_IERC165() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId), "should support IERC165");
    }

    /**
     * @notice supportsInterface returns false for unsupported interfaces
     */
    function test_supportsInterface_unsupported() public view {
        // Use a fixed interface ID that is known to be unsupported
        bytes4 unsupportedInterfaceId = 0x12345678;
        assertFalse(registry.supportsInterface(unsupportedInterfaceId), "should not support interface");
    }

    /**
     * @notice After BaseAlphixTest setup—hook and logic are deployed and default pool is initialized—Registry should contain both contracts and the pool
     */
    function test_registry_reflects_default_deployment_and_pool() public view {
        // The hook contract should be registered under the Alphix key
        assertEq(registry.getContract(IRegistry.ContractKey.Alphix), address(hook), "hook not registered");

        // The logic proxy should be registered under the AlphixLogic key
        assertEq(registry.getContract(IRegistry.ContractKey.AlphixLogic), address(logicProxy), "logic not registered");

        // The default poolId from setup should be registered
        IRegistry.PoolInfo memory info = registry.getPoolInfo(poolId);
        assertEq(info.token0, Currency.unwrap(key.currency0), "default token0");
        assertEq(info.token1, Currency.unwrap(key.currency1), "default token1");
        assertEq(info.fee, key.fee, "default fee");
        assertEq(info.tickSpacing, key.tickSpacing, "default tickSpacing");
        assertEq(info.hooks, address(hook), "default hooks");
        assertEq(info.initialFee, INITIAL_FEE, "default initialFee");
        assertEq(info.initialTargetRatio, INITIAL_TARGET_RATIO, "default initialTargetRatio");
        assertTrue(info.timestamp > 0, "default timestamp");

        // The pool list should include exactly that default poolId
        PoolId[] memory pools = registry.listPools();
        assertEq(pools.length, 1, "only default pool");
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(poolId), "default poolId");
    }
}
