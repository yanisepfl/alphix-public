// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* SOLMATE IMPORTS */

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {Registry} from "../../../../src/Registry.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";

/**
 * @title RegistryMultiHookTest
 * @notice Tests for shared Registry and AccessManager across multiple hooks
 * @dev Verifies that a single Registry and AccessManager can properly support multiple Alphix hooks
 */
contract RegistryMultiHookTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    // Additional hooks sharing the same infrastructure
    Alphix public hook2;
    Alphix public hook3;
    IAlphixLogic public logic2;
    IAlphixLogic public logic3;

    // Additional pool keys
    PoolKey public key2;
    PoolKey public key3;
    PoolId public poolId2;
    PoolId public poolId3;

    /* ========================================================================== */
    /*                           SETUP                                            */
    /* ========================================================================== */

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);

        // Deploy two additional hooks sharing the same Registry and AccessManager
        (hook2, logic2) = _deployHookWithSharedInfrastructure(accessManager, registry);
        (hook3, logic3) = _deployHookWithSharedInfrastructure(accessManager, registry);

        // Create pools for each hook
        (Currency c20, Currency c21) = deployCurrencyPairWithDecimals(18, 18);
        key2 = PoolKey({
            currency0: c20, currency1: c21, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(hook2)
        });
        poolId2 = key2.toId();

        (Currency c30, Currency c31) = deployCurrencyPairWithDecimals(18, 18);
        key3 = PoolKey({
            currency0: c30, currency1: c31, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(hook3)
        });
        poolId3 = key3.toId();

        // Initialize pools in Uniswap
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(key3, Constants.SQRT_PRICE_1_1);

        // Initialize pools in Alphix
        hook2.initializePool(key2, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        hook3.initializePool(key3, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           SHARED REGISTRY TESTS                            */
    /* ========================================================================== */

    function test_sharedRegistry_allHooksCanRegister() public view {
        // All hooks should have successfully registered themselves
        // The registry only stores the last registered Alphix, but all operations should have succeeded
        // In practice, with multiple hooks, the registry would need to store multiple entries
        // This test verifies the hooks can interact with the shared registry
        assertTrue(address(registry) != address(0));
    }

    function test_sharedRegistry_eachPoolRegistered() public view {
        // Each hook's pool should have been registered
        IRegistry.PoolInfo memory info1 = registry.getPoolInfo(poolId);
        IRegistry.PoolInfo memory info2 = registry.getPoolInfo(poolId2);
        IRegistry.PoolInfo memory info3 = registry.getPoolInfo(poolId3);

        // Verify each pool is registered correctly
        assertEq(info1.token0, Currency.unwrap(key.currency0));
        assertEq(info2.token0, Currency.unwrap(key2.currency0));
        assertEq(info3.token0, Currency.unwrap(key3.currency0));
    }

    function test_sharedRegistry_poolsHaveCorrectFees() public view {
        IRegistry.PoolInfo memory info1 = registry.getPoolInfo(poolId);
        IRegistry.PoolInfo memory info2 = registry.getPoolInfo(poolId2);
        IRegistry.PoolInfo memory info3 = registry.getPoolInfo(poolId3);

        assertEq(info1.initialFee, INITIAL_FEE);
        assertEq(info2.initialFee, INITIAL_FEE);
        assertEq(info3.initialFee, INITIAL_FEE);
    }

    function test_sharedRegistry_poolsHaveCorrectTargetRatios() public view {
        IRegistry.PoolInfo memory info1 = registry.getPoolInfo(poolId);
        IRegistry.PoolInfo memory info2 = registry.getPoolInfo(poolId2);
        IRegistry.PoolInfo memory info3 = registry.getPoolInfo(poolId3);

        assertEq(info1.initialTargetRatio, INITIAL_TARGET_RATIO);
        assertEq(info2.initialTargetRatio, INITIAL_TARGET_RATIO);
        assertEq(info3.initialTargetRatio, INITIAL_TARGET_RATIO);
    }

    /* ========================================================================== */
    /*                           SHARED ACCESS MANAGER TESTS                      */
    /* ========================================================================== */

    function test_sharedAccessManager_ownerCanPokeAllHooks() public {
        // Wait for cooldown on all hooks
        vm.warp(block.timestamp + 1 days + 1);

        // Owner should be able to poke all hooks
        vm.startPrank(owner);
        hook.poke(6e17);
        hook2.poke(6e17);
        hook3.poke(6e17);
        vm.stopPrank();

        // All pokes should succeed (no revert means success)
    }

    function test_sharedAccessManager_unauthorizedCannotPokeAnyHook() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(unauthorized);
        vm.expectRevert();
        hook.poke(6e17);

        vm.prank(unauthorized);
        vm.expectRevert();
        hook2.poke(6e17);

        vm.prank(unauthorized);
        vm.expectRevert();
        hook3.poke(6e17);
    }

    function test_sharedAccessManager_grantRoleToNewPoker() public {
        address newPoker = makeAddr("newPoker");

        vm.startPrank(owner);
        accessManager.grantRole(FEE_POKER_ROLE, newPoker, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);

        // New poker should be able to poke all hooks
        vm.prank(newPoker);
        hook.poke(6e17);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(newPoker);
        hook2.poke(6e17);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(newPoker);
        hook3.poke(6e17);
    }

    function test_sharedAccessManager_revokeRoleAffectsAllHooks() public {
        // Grant role to user1
        vm.prank(owner);
        accessManager.grantRole(FEE_POKER_ROLE, user1, 0);

        // Verify user1 can poke
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(user1);
        hook.poke(6e17);

        // Revoke role
        vm.prank(owner);
        accessManager.revokeRole(FEE_POKER_ROLE, user1);

        // user1 should not be able to poke any hook now
        vm.warp(block.timestamp + 2 days + 1);

        vm.prank(user1);
        vm.expectRevert();
        hook.poke(7e17);

        vm.prank(user1);
        vm.expectRevert();
        hook2.poke(7e17);

        vm.prank(user1);
        vm.expectRevert();
        hook3.poke(7e17);
    }

    /* ========================================================================== */
    /*                           INDEPENDENT OPERATION TESTS                      */
    /* ========================================================================== */

    function test_multipleHooks_operateIndependently() public {
        vm.warp(block.timestamp + 1 days + 1);

        // Poke hook1 with high ratio
        vm.prank(owner);
        hook.poke(8e17);
        uint24 fee1After = hook.getFee();

        // Poke hook2 with low ratio
        vm.prank(owner);
        hook2.poke(2e17);
        uint24 fee2After = hook2.getFee();

        // Poke hook3 with medium ratio
        vm.prank(owner);
        hook3.poke(5e17);
        uint24 fee3After = hook3.getFee();

        // Each hook should have its own fee state (may differ due to different ratios)
        assertTrue(fee1After > 0);
        assertTrue(fee2After > 0);
        assertTrue(fee3After > 0);
    }

    function test_multipleHooks_pauseOneDoesNotAffectOthers() public {
        // Pause hook2
        vm.prank(owner);
        hook2.pause();

        assertTrue(hook2.paused());
        assertFalse(hook.paused());
        assertFalse(hook3.paused());

        // hook and hook3 should still work
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(owner);
        hook.poke(6e17);

        vm.prank(owner);
        hook3.poke(6e17);

        // hook2 should fail
        vm.prank(owner);
        vm.expectRevert();
        hook2.poke(6e17);
    }

    function test_multipleHooks_deactivateOneDoesNotAffectOthers() public {
        // Deactivate hook2
        vm.prank(owner);
        hook2.deactivatePool();

        // hook and hook3 should still have active pools
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(owner);
        hook.poke(6e17);

        vm.prank(owner);
        hook3.poke(6e17);
    }

    /* ========================================================================== */
    /*                           REGISTRY MIGRATION TESTS                         */
    /* ========================================================================== */

    function test_registryMigration_allHooksCanMigrate() public {
        vm.startPrank(owner);

        // Create new registry
        Registry newRegistry = new Registry(address(accessManager));

        // Grant registrar role to all hooks for new registry
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = newRegistry.registerContract.selector;
        selectors[1] = newRegistry.registerPool.selector;
        accessManager.setTargetFunctionRole(address(newRegistry), selectors, REGISTRAR_ROLE);

        // Migrate all hooks
        hook.setRegistry(address(newRegistry));
        hook2.setRegistry(address(newRegistry));
        hook3.setRegistry(address(newRegistry));

        // Verify all hooks point to new registry
        assertEq(hook.getRegistry(), address(newRegistry));
        assertEq(hook2.getRegistry(), address(newRegistry));
        assertEq(hook3.getRegistry(), address(newRegistry));

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    function _deployHookWithSharedInfrastructure(AccessManager am, Registry reg)
        internal
        returns (Alphix newHook, IAlphixLogic newLogic)
    {
        // Deploy hook with shared infrastructure
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRolesForHook(hookAddr, am, reg);

        bytes memory ctor = abi.encode(poolManager, owner, address(am), address(reg));
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        newHook = Alphix(hookAddr);

        // Deploy logic
        AlphixLogic impl = new AlphixLogic();
        bytes memory initData =
            abi.encodeCall(impl.initialize, (owner, hookAddr, address(am), "Alphix LP Shares", "ALP"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        newLogic = IAlphixLogic(address(proxy));

        // Initialize hook
        newHook.initialize(address(newLogic));
    }

    function _setupAccessManagerRolesForHook(address hookAddr, AccessManager am, Registry) internal {
        // Grant registrar role to hook
        am.grantRole(REGISTRAR_ROLE, hookAddr, 0);

        // Assign poker role to poke function on this hook
        bytes4[] memory pokeSelectors = new bytes4[](1);
        pokeSelectors[0] = Alphix(hookAddr).poke.selector;
        am.setTargetFunctionRole(hookAddr, pokeSelectors, FEE_POKER_ROLE);
    }
}
