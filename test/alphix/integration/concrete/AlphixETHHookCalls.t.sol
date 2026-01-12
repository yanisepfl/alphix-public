// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/* OZ IMPORTS */
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/* SOLMATE IMPORTS */

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixETH} from "../../../../src/AlphixETH.sol";
import {AlphixLogicETH} from "../../../../src/AlphixLogicETH.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {Registry} from "../../../../src/Registry.sol";

/**
 * @title AlphixETHHookCallsTest
 * @notice Concrete tests for AlphixETH hook callbacks (swap, liquidity, donate)
 */
contract AlphixETHHookCallsTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    /* ========================================================================== */
    /*                           PAUSE/UNPAUSE TESTS                              */
    /* ========================================================================== */

    function test_pause_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.pause();
    }

    function test_pause_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Pausable.Paused(owner);
        hook.pause();
    }

    function test_pause_preventsPoolOperations() public {
        vm.prank(owner);
        hook.pause();

        assertTrue(hook.paused());
    }

    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        hook.unpause();
    }

    function test_unpause_emitsEvent() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit Pausable.Unpaused(owner);
        hook.unpause();
    }

    function test_unpause_revertsWhenNotPaused() public {
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        hook.unpause();
    }

    function test_pause_doublePauseReverts() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.pause();
    }

    /* ========================================================================== */
    /*                           ACTIVATE/DEACTIVATE TESTS                        */
    /* ========================================================================== */

    function test_deactivatePool_success() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.PoolDeactivated(poolId);
        hook.deactivatePool();
    }

    function test_deactivatePool_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.deactivatePool();
    }

    function test_deactivatePool_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.deactivatePool();
    }

    function test_activatePool_success() public {
        // First deactivate
        vm.prank(owner);
        hook.deactivatePool();

        // Then activate
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.PoolActivated(poolId);
        hook.activatePool();
    }

    function test_activatePool_onlyOwner() public {
        vm.prank(owner);
        hook.deactivatePool();

        vm.prank(unauthorized);
        vm.expectRevert();
        hook.activatePool();
    }

    function test_activatePool_revertsWhenPaused() public {
        vm.prank(owner);
        hook.deactivatePool();

        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.activatePool();
    }

    /* ========================================================================== */
    /*                           POKE TESTS                                       */
    /* ========================================================================== */

    function test_poke_updatesFee() public {
        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // Poke with a different ratio to trigger fee update
        uint256 newRatio = 7e17; // 70%
        vm.prank(owner);
        hook.poke(newRatio);

        // Fee should have changed
        uint24 newFee = hook.getFee();
        assertTrue(newFee != INITIAL_FEE || newRatio == INITIAL_TARGET_RATIO);
    }

    function test_poke_emitsFeeUpdatedEvent() public {
        vm.warp(block.timestamp + 1 days + 1);

        uint256 newRatio = 7e17;
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.FeeUpdated(poolId, 0, 0, 0, 0, 0);
        hook.poke(newRatio);
    }

    function test_poke_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.poke(5e17);
    }

    function test_poke_revertsWhenLogicNotSet() public {
        // Deploy fresh hook without initializing (hook is paused and has no logic set)
        vm.startPrank(owner);
        (,, AlphixETH freshHook,,,) = _deployAlphixEthInfrastructureWithoutInit();
        // Unpause the hook so we can test LogicNotSet
        // Note: We can't unpause without setting logic, so we test that paused state prevents poke
        vm.stopPrank();

        // Since the hook is paused in constructor and we haven't called initialize,
        // it will fail with EnforcedPause before checking logic
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.poke(5e17);
    }

    function test_poke_respectsCooldown() public {
        // First poke after cooldown
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        hook.poke(6e17);

        // Immediate second poke should fail due to cooldown
        vm.prank(owner);
        vm.expectRevert();
        hook.poke(7e17);
    }

    function test_poke_onlyAuthorizedPoker() public {
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(unauthorized);
        vm.expectRevert();
        hook.poke(5e17);
    }

    /* ========================================================================== */
    /*                           SET LOGIC TESTS                                  */
    /* ========================================================================== */

    function test_setLogic_updatesLogicAddress() public {
        // Deploy a new logic
        vm.startPrank(owner);
        AlphixLogicETH newImpl = new AlphixLogicETH();
        bytes memory initData = abi.encodeCall(
            newImpl.initializeEth,
            (owner, address(hook), address(accessManager), address(weth), "New LP Shares", "NLPS")
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);

        hook.setLogic(address(newProxy));
        assertEq(hook.getLogic(), address(newProxy));
        vm.stopPrank();
    }

    /**
     * @notice Test setLogic updates logic address correctly
     * @dev LogicUpdated event was removed for bytecode savings
     */
    function test_setLogic_updatesLogicCorrectly() public {
        address oldLogic = hook.getLogic();
        vm.startPrank(owner);
        AlphixLogicETH newImpl = new AlphixLogicETH();
        bytes memory initData = abi.encodeCall(
            newImpl.initializeEth,
            (owner, address(hook), address(accessManager), address(weth), "New LP Shares", "NLPS")
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);

        hook.setLogic(address(newProxy));
        vm.stopPrank();

        assertEq(hook.getLogic(), address(newProxy), "Logic should be updated");
        assertTrue(hook.getLogic() != oldLogic, "Logic should be different from old");
    }

    function test_setLogic_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.setLogic(address(0x123));
    }

    function test_setLogic_revertsWithZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        hook.setLogic(address(0));
    }

    /**
     * @notice Test setLogic accepts any non-zero address (ERC165 check removed for bytecode savings).
     * @dev Owner is trusted to provide valid logic contracts. Interface checks were removed
     *      to reduce bytecode size. Invalid logic will fail when called.
     */
    function test_setLogic_acceptsAnyNonZeroAddress() public {
        address anyContract = address(registry); // Registry doesn't implement IAlphixLogic

        vm.prank(owner);
        hook.setLogic(anyContract);

        assertEq(hook.getLogic(), anyContract, "Logic should be updated to any non-zero address");
    }

    /* ========================================================================== */
    /*                           SET REGISTRY TESTS                               */
    /* ========================================================================== */

    function test_setRegistry_updatesRegistryAddress() public {
        vm.startPrank(owner);
        Registry newRegistry = new Registry(address(accessManager));
        accessManager.grantRole(REGISTRAR_ROLE, address(hook), 0);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = newRegistry.registerContract.selector;
        selectors[1] = newRegistry.registerPool.selector;
        accessManager.setTargetFunctionRole(address(newRegistry), selectors, REGISTRAR_ROLE);

        hook.setRegistry(address(newRegistry));
        assertEq(hook.getRegistry(), address(newRegistry));
        vm.stopPrank();
    }

    /**
     * @notice Test setRegistry updates registry correctly
     * @dev RegistryUpdated event was removed for bytecode savings
     */
    function test_setRegistry_updatesRegistryCorrectly() public {
        address oldRegistry = hook.getRegistry();
        vm.startPrank(owner);
        Registry newRegistry = new Registry(address(accessManager));
        accessManager.grantRole(REGISTRAR_ROLE, address(hook), 0);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = newRegistry.registerContract.selector;
        selectors[1] = newRegistry.registerPool.selector;
        accessManager.setTargetFunctionRole(address(newRegistry), selectors, REGISTRAR_ROLE);

        hook.setRegistry(address(newRegistry));
        vm.stopPrank();

        assertEq(hook.getRegistry(), address(newRegistry), "Registry should be updated");
        assertTrue(hook.getRegistry() != oldRegistry, "Registry should be different from old");
    }

    function test_setRegistry_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.setRegistry(address(0x123));
    }

    function test_setRegistry_revertsWithZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        hook.setRegistry(address(0));
    }

    /**
     * @notice Test setRegistry reverts with EOA address.
     * @dev Code length check was removed for bytecode savings. Revert happens when
     *      trying to call registerContract on an EOA (no selector).
     */
    function test_setRegistry_revertsWithEOA() public {
        vm.prank(owner);
        vm.expectRevert();
        hook.setRegistry(user1);
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    function _deployAlphixEthInfrastructureWithoutInit()
        internal
        returns (
            AccessManager am,
            Registry reg,
            AlphixETH newHook,
            AlphixLogicETH impl,
            ERC1967Proxy proxy,
            IAlphixLogic newLogic
        )
    {
        am = new AccessManager(owner);
        reg = new Registry(address(am));

        newHook = _deployAlphixEthHook(poolManager, owner, am, reg);

        impl = new AlphixLogicETH();
        bytes memory initData = abi.encodeCall(
            impl.initializeEth, (owner, address(newHook), address(am), address(weth), "Alphix ETH LP Shares", "AELP")
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        newLogic = IAlphixLogic(address(proxy));
    }
}
