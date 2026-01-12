// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/* LOCAL IMPORTS */
import {OlympixUnitTest} from "../utils/OlympixUnitTest.sol";
import {BaseAlphixTest} from "../alphix/BaseAlphix.t.sol";
import {Registry, IRegistry} from "../../src/Registry.sol";

/**
 * @title RegistryTest
 * @notice Olympix-generated unit tests for Registry contract
 * @dev Tests the registry functionality including:
 *      - Constructor validation
 *      - Contract registration
 *      - Pool registration
 *      - View functions
 *      - ERC165 interface support
 */
contract RegistryTest is OlympixUnitTest("Registry"), BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    /* ========================================================================== */
    /*                              SETUP                                         */
    /* ========================================================================== */

    function setUp() public override {
        super.setUp();
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    /**
     * @notice Helper to create a fresh Registry with its own AccessManager
     */
    function _createFreshRegistry() internal returns (AccessManager am, Registry reg) {
        am = new AccessManager(owner);
        reg = new Registry(address(am));
    }

    /**
     * @notice Helper to grant REGISTRAR_ROLE to an address for a specific function
     */
    function _grantRegistrarRole(AccessManager am, Registry reg, address grantee, bytes4 selector) internal {
        vm.prank(owner);
        am.grantRole(REGISTRAR_ROLE, grantee, 0);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        vm.prank(owner);
        am.setTargetFunctionRole(address(reg), selectors, REGISTRAR_ROLE);
    }

    /**
     * @notice Helper to create a test pool key
     */
    function _createTestPoolKey() internal returns (PoolKey memory) {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        return PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hook)
        });
    }

    /* ========================================================================== */
    /*                         CONSTRUCTOR TESTS                                  */
    /* ========================================================================== */

    /**
     * @notice Test constructor reverts on zero access manager
     * @dev Covers branch: accessManager == address(0) -> revert
     */
    function test_constructor_revertsOnZeroAccessManager() public {
        vm.expectRevert(IRegistry.InvalidAccessManager.selector);
        new Registry(address(0));
    }

    /**
     * @notice Test constructor sets authority correctly
     * @dev Covers: constructor success path
     */
    function test_constructor_setsAuthorityCorrectly() public {
        AccessManager am = new AccessManager(owner);
        Registry reg = new Registry(address(am));
        assertEq(reg.authority(), address(am), "Authority should be set");
    }

    /* ========================================================================== */
    /*                      REGISTER CONTRACT TESTS                               */
    /* ========================================================================== */

    /**
     * @notice Test registerContract reverts on zero address
     * @dev Covers branch: contractAddress == address(0) -> revert InvalidAddress
     */
    function test_registerContract_revertsOnZeroAddress() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerContract.selector);

        vm.prank(owner);
        vm.expectRevert(IRegistry.InvalidAddress.selector);
        reg.registerContract(IRegistry.ContractKey.Alphix, address(0));
    }

    /**
     * @notice Test registerContract stores value and emits event
     * @dev Covers: contracts[key] = contractAddress; emit ContractRegistered
     */
    function test_registerContract_storesAndEmitsEvent() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerContract.selector);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IRegistry.ContractRegistered(IRegistry.ContractKey.Alphix, address(hook));
        reg.registerContract(IRegistry.ContractKey.Alphix, address(hook));

        assertEq(reg.getContract(IRegistry.ContractKey.Alphix), address(hook), "Contract should be stored");
    }

    /**
     * @notice Test registerContract can overwrite existing value
     * @dev Covers: overwrite behavior
     */
    function test_registerContract_canOverwrite() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerContract.selector);

        address addr1 = makeAddr("addr1");
        address addr2 = makeAddr("addr2");

        vm.prank(owner);
        reg.registerContract(IRegistry.ContractKey.Alphix, addr1);
        assertEq(reg.getContract(IRegistry.ContractKey.Alphix), addr1);

        vm.prank(owner);
        reg.registerContract(IRegistry.ContractKey.Alphix, addr2);
        assertEq(reg.getContract(IRegistry.ContractKey.Alphix), addr2, "Should overwrite");
    }

    /**
     * @notice Test registerContract works for AlphixLogic key
     * @dev Covers: both ContractKey enum values
     */
    function test_registerContract_worksForAlphixLogicKey() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerContract.selector);

        vm.prank(owner);
        reg.registerContract(IRegistry.ContractKey.AlphixLogic, address(logic));

        assertEq(reg.getContract(IRegistry.ContractKey.AlphixLogic), address(logic));
    }

    /* ========================================================================== */
    /*                        REGISTER POOL TESTS                                 */
    /* ========================================================================== */

    /**
     * @notice Test registerPool reverts on duplicate registration
     * @dev Covers branch: pools[poolId].timestamp != 0 -> revert PoolAlreadyRegistered
     */
    function test_registerPool_revertsOnDuplicate() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        PoolKey memory k = _createTestPoolKey();
        PoolId id = k.toId();

        vm.prank(owner);
        reg.registerPool(k, 500, 5e17);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRegistry.PoolAlreadyRegistered.selector, id));
        reg.registerPool(k, 600, 6e17);
    }

    /**
     * @notice Test registerPool stores all fields correctly
     * @dev Covers: all PoolInfo field assignments (lines 76-89)
     */
    function test_registerPool_storesAllFieldsCorrectly() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 60, hooks: IHooks(hook)
        });

        uint24 initialFee = 500;
        uint256 targetRatio = 5e17;
        uint256 timestampBefore = block.timestamp;

        vm.prank(owner);
        reg.registerPool(k, initialFee, targetRatio);

        PoolId id = k.toId();
        IRegistry.PoolInfo memory info = reg.getPoolInfo(id);

        assertEq(info.token0, Currency.unwrap(c0), "token0");
        assertEq(info.token1, Currency.unwrap(c1), "token1");
        assertEq(info.fee, LPFeeLibrary.DYNAMIC_FEE_FLAG, "fee");
        assertEq(info.tickSpacing, 60, "tickSpacing");
        assertEq(info.hooks, address(hook), "hooks");
        assertEq(info.initialFee, initialFee, "initialFee");
        assertEq(info.initialTargetRatio, targetRatio, "initialTargetRatio");
        assertGe(info.timestamp, timestampBefore, "timestamp");
    }

    /**
     * @notice Test registerPool adds to allPools array
     * @dev Covers: allPools.push(poolId) (line 91)
     */
    function test_registerPool_addsToAllPoolsArray() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        assertEq(reg.listPools().length, 0, "Should start empty");

        PoolKey memory k = _createTestPoolKey();

        vm.prank(owner);
        reg.registerPool(k, 500, 5e17);

        PoolId[] memory pools = reg.listPools();
        assertEq(pools.length, 1, "Should have 1 pool");
        assertEq(PoolId.unwrap(pools[0]), PoolId.unwrap(k.toId()), "Pool ID should match");
    }

    /**
     * @notice Test registerPool emits PoolRegistered event
     * @dev Covers: emit PoolRegistered (line 92)
     */
    function test_registerPool_emitsEvent() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        PoolKey memory k = _createTestPoolKey();

        vm.prank(owner);
        vm.expectEmit(true, true, true, false);
        emit IRegistry.PoolRegistered(
            k.toId(), Currency.unwrap(k.currency0), Currency.unwrap(k.currency1), 0, address(0)
        );
        reg.registerPool(k, 500, 5e17);
    }

    /* ========================================================================== */
    /*                      GET HOOK FOR POOL TESTS                               */
    /* ========================================================================== */

    /**
     * @notice Test getHookForPool returns correct hook address
     * @dev Covers: return pools[poolId].hooks (line 99)
     */
    function test_getHookForPool_returnsCorrectHook() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        PoolKey memory k = _createTestPoolKey();

        vm.prank(owner);
        reg.registerPool(k, 500, 5e17);

        assertEq(reg.getHookForPool(k.toId()), address(hook), "Hook should match");
    }

    /**
     * @notice Test getHookForPool returns zero for unregistered pool
     * @dev Covers: default value return path
     */
    function test_getHookForPool_returnsZeroForUnregistered() public {
        (, Registry reg) = _createFreshRegistry();
        assertEq(reg.getHookForPool(poolId), address(0), "Should return zero");
    }

    /* ========================================================================== */
    /*                        VIEW FUNCTIONS TESTS                                */
    /* ========================================================================== */

    /**
     * @notice Test getContract returns zero for unregistered key
     * @dev Covers: return contracts[key] (line 108) - default value path
     */
    function test_getContract_returnsZeroForUnregistered() public {
        (, Registry reg) = _createFreshRegistry();
        assertEq(reg.getContract(IRegistry.ContractKey.Alphix), address(0));
        assertEq(reg.getContract(IRegistry.ContractKey.AlphixLogic), address(0));
    }

    /**
     * @notice Test getPoolInfo returns empty struct for unregistered pool
     * @dev Covers: return pools[poolId] (line 115) - default value path
     */
    function test_getPoolInfo_returnsEmptyForUnregistered() public {
        (, Registry reg) = _createFreshRegistry();
        IRegistry.PoolInfo memory info = reg.getPoolInfo(poolId);
        assertEq(info.token0, address(0));
        assertEq(info.token1, address(0));
        assertEq(info.fee, 0);
        assertEq(info.tickSpacing, 0);
        assertEq(info.hooks, address(0));
        assertEq(info.initialFee, 0);
        assertEq(info.initialTargetRatio, 0);
        assertEq(info.timestamp, 0);
    }

    /**
     * @notice Test listPools returns empty array initially
     * @dev Covers: return allPools (line 122) - empty array path
     */
    function test_listPools_returnsEmptyInitially() public {
        (, Registry reg) = _createFreshRegistry();
        PoolId[] memory pools = reg.listPools();
        assertEq(pools.length, 0);
    }

    /**
     * @notice Test listPools returns all registered pools
     * @dev Covers: return allPools (line 122) - populated array path
     */
    function test_listPools_returnsAllRegisteredPools() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        // Register 3 pools
        PoolKey memory k1 = _createTestPoolKey();
        PoolKey memory k2 = _createTestPoolKey();
        PoolKey memory k3 = _createTestPoolKey();

        vm.startPrank(owner);
        reg.registerPool(k1, 100, 3e17);
        reg.registerPool(k2, 500, 5e17);
        reg.registerPool(k3, 3000, 7e17);
        vm.stopPrank();

        PoolId[] memory pools = reg.listPools();
        assertEq(pools.length, 3, "Should have 3 pools");
    }

    /* ========================================================================== */
    /*                      SUPPORTS INTERFACE TESTS                              */
    /* ========================================================================== */

    /**
     * @notice Test supportsInterface returns true for IRegistry
     * @dev Covers branch: interfaceId == type(IRegistry).interfaceId -> true (line 129)
     */
    function test_supportsInterface_IRegistry() public view {
        assertTrue(registry.supportsInterface(type(IRegistry).interfaceId));
    }

    /**
     * @notice Test supportsInterface returns true for IERC165
     * @dev Covers branch: super.supportsInterface (ERC165 base) -> true (line 129)
     */
    function test_supportsInterface_IERC165() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
    }

    /**
     * @notice Test supportsInterface returns false for unknown interface
     * @dev Covers: both branches return false for unknown interfaceId
     */
    function test_supportsInterface_returnsFalseForUnknown() public view {
        assertFalse(registry.supportsInterface(bytes4(0xdeadbeef)));
    }

    /* ========================================================================== */
    /*                           INTEGRATION TESTS                                */
    /* ========================================================================== */

    /**
     * @notice Test default deployment from BaseAlphixTest has registry configured
     * @dev Verifies the base test setup properly registers hook and logic
     */
    function test_baseSetup_registryConfigured() public view {
        // Hook should be registered
        assertEq(registry.getContract(IRegistry.ContractKey.Alphix), address(hook), "Hook should be registered");

        // Logic should be registered
        assertEq(
            registry.getContract(IRegistry.ContractKey.AlphixLogic), address(logicProxy), "Logic should be registered"
        );

        // Default pool should be registered
        IRegistry.PoolInfo memory info = registry.getPoolInfo(poolId);
        assertEq(info.token0, Currency.unwrap(key.currency0), "Pool token0");
        assertEq(info.token1, Currency.unwrap(key.currency1), "Pool token1");
        assertTrue(info.timestamp > 0, "Pool should have timestamp");
    }

    /**
     * @notice Test multiple pools can be registered and retrieved
     */
    function test_multiplePools_allRetrievable() public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        // Register 3 pools with different params
        PoolKey memory k1 = _createTestPoolKey();
        PoolKey memory k2 = _createTestPoolKey();
        PoolKey memory k3 = _createTestPoolKey();

        vm.startPrank(owner);
        reg.registerPool(k1, 100, 3e17);
        reg.registerPool(k2, 500, 5e17);
        reg.registerPool(k3, 3000, 7e17);
        vm.stopPrank();

        // Verify each pool's info
        IRegistry.PoolInfo memory info1 = reg.getPoolInfo(k1.toId());
        assertEq(info1.initialFee, 100);
        assertEq(info1.initialTargetRatio, 3e17);

        IRegistry.PoolInfo memory info2 = reg.getPoolInfo(k2.toId());
        assertEq(info2.initialFee, 500);
        assertEq(info2.initialTargetRatio, 5e17);

        IRegistry.PoolInfo memory info3 = reg.getPoolInfo(k3.toId());
        assertEq(info3.initialFee, 3000);
        assertEq(info3.initialTargetRatio, 7e17);
    }

    /* ========================================================================== */
    /*                              FUZZ TESTS                                    */
    /* ========================================================================== */

    /**
     * @notice Fuzz test registerContract with any valid address
     */
    function testFuzz_registerContract_anyValidAddress(address addr) public {
        vm.assume(addr != address(0));

        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerContract.selector);

        vm.prank(owner);
        reg.registerContract(IRegistry.ContractKey.Alphix, addr);

        assertEq(reg.getContract(IRegistry.ContractKey.Alphix), addr);
    }

    /**
     * @notice Fuzz test registerPool with various fee and ratio parameters
     */
    function testFuzz_registerPool_varyingParams(uint24 initialFee, uint256 targetRatio) public {
        (AccessManager am, Registry reg) = _createFreshRegistry();
        _grantRegistrarRole(am, reg, owner, reg.registerPool.selector);

        PoolKey memory k = _createTestPoolKey();

        vm.prank(owner);
        reg.registerPool(k, initialFee, targetRatio);

        IRegistry.PoolInfo memory info = reg.getPoolInfo(k.toId());
        assertEq(info.initialFee, initialFee);
        assertEq(info.initialTargetRatio, targetRatio);
    }

    /**
     * @notice Fuzz test supportsInterface with random interface IDs
     */
    function testFuzz_supportsInterface_randomIds(bytes4 interfaceId) public view {
        // Should only return true for IRegistry and IERC165
        bool expected = (interfaceId == type(IRegistry).interfaceId) || (interfaceId == type(IERC165).interfaceId);
        assertEq(registry.supportsInterface(interfaceId), expected);
    }
}
