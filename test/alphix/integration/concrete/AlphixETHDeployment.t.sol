// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixETH} from "../../../../src/AlphixETH.sol";
import {AlphixLogicETH} from "../../../../src/AlphixLogicETH.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";
import {Registry} from "../../../../src/Registry.sol";

/**
 * @title AlphixETHDeploymentTest
 * @notice Concrete tests for AlphixETH deployment and initialization
 */
contract AlphixETHDeploymentTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    /* ========================================================================== */
    /*                           CONSTRUCTOR TESTS                                */
    /* ========================================================================== */

    function test_constructor_setsCorrectPoolManager() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
    }

    function test_constructor_setsCorrectOwner() public view {
        assertEq(hook.owner(), owner);
    }

    function test_constructor_setsCorrectRegistry() public view {
        assertEq(hook.getRegistry(), address(registry));
    }

    function test_constructor_registersInRegistry() public view {
        assertEq(registry.getContract(IRegistry.ContractKey.Alphix), address(hook));
    }

    function test_constructor_revertsWithZeroPoolManager() public {
        vm.startPrank(owner);
        AccessManager am = new AccessManager(owner);
        Registry reg = new Registry(address(am));
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, am, reg);

        bytes memory ctor = abi.encode(address(0), owner, address(am), address(reg));
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        vm.stopPrank();
    }

    function test_constructor_revertsWithZeroRegistry() public {
        vm.startPrank(owner);
        AccessManager am = new AccessManager(owner);
        address hookAddr = _computeNextHookAddress();

        bytes memory ctor = abi.encode(address(poolManager), owner, address(am), address(0));
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        vm.stopPrank();
    }

    function test_constructor_revertsWithZeroAccessManager() public {
        vm.startPrank(owner);
        Registry reg = new Registry(address(accessManager));
        address hookAddr = _computeNextHookAddress();

        bytes memory ctor = abi.encode(address(poolManager), owner, address(0), address(reg));
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           INITIALIZER TESTS                                */
    /* ========================================================================== */

    function test_initialize_setsLogic() public view {
        assertEq(hook.getLogic(), address(logic));
    }

    function test_initialize_unpausesHook() public view {
        assertFalse(hook.paused());
    }

    function test_initialize_registersLogicInRegistry() public view {
        assertEq(registry.getContract(IRegistry.ContractKey.AlphixLogic), address(logic));
    }

    function test_initialize_revertsWithZeroLogic() public {
        vm.startPrank(owner);
        (,, AlphixETH freshHook,,,) = _deployAlphixEthInfrastructureWithoutInit();

        vm.expectRevert(IAlphix.InvalidAddress.selector);
        freshHook.initialize(address(0));
        vm.stopPrank();
    }

    function test_initialize_revertsOnSecondCall() public {
        vm.prank(owner);
        vm.expectRevert();
        hook.initialize(address(logic));
    }

    function test_initialize_revertsOnNonOwner() public {
        vm.startPrank(owner);
        (,, AlphixETH freshHook,,, IAlphixLogic freshLogic) = _deployAlphixEthInfrastructureWithoutInit();
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert();
        freshHook.initialize(address(freshLogic));
    }

    /* ========================================================================== */
    /*                           POOL INITIALIZATION TESTS                        */
    /* ========================================================================== */

    function test_initializePool_setsPoolKeyAndId() public {
        (AlphixETH freshHook,) = _deployFreshAlphixEthStack();

        // Create new ETH pool
        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);
        PoolId newPoolId = newKey.toId();

        // Initialize pool in Uniswap
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Initialize pool in Alphix
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Verify pool key and ID are cached
        PoolKey memory cachedKey = freshHook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), address(0), "Currency0 should be ETH");
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(newToken), "Currency1 should match");
        assertEq(PoolId.unwrap(freshHook.getPoolId()), PoolId.unwrap(newPoolId), "Pool ID should match");
    }

    /**
     * @notice Test initializePool emits events
     */
    function test_initializePool_emitsEvents() public {
        (AlphixETH freshHook,) = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);
        PoolId newPoolId = newKey.toId();

        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.FeeUpdated(newPoolId, 0, INITIAL_FEE, 0, INITIAL_TARGET_RATIO, INITIAL_TARGET_RATIO);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolConfigured(newPoolId, INITIAL_FEE, INITIAL_TARGET_RATIO);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    function test_initializePool_revertsOnNonOwner() public {
        (AlphixETH freshHook,) = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        vm.prank(unauthorized);
        vm.expectRevert();
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    function test_initializePool_revertsWhenPaused() public {
        (AlphixETH freshHook,) = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Pause the hook
        vm.prank(owner);
        freshHook.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /* ========================================================================== */
    /*                           ETH RECEIVE TESTS                                */
    /* ========================================================================== */

    function test_receive_acceptsETHFromLogic() public {
        // Logic contract can send ETH to hook
        vm.deal(address(logic), 1 ether);
        vm.prank(address(logic));
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Hook should accept ETH from logic");
    }

    function test_receive_acceptsETHFromPoolManager() public {
        // PoolManager can send ETH to hook
        vm.deal(address(poolManager), 1 ether);
        vm.prank(address(poolManager));
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Hook should accept ETH from pool manager");
    }

    /**
     * @notice Test receive() accepts ETH from any sender.
     * @dev Simplified receive() for bytecode savings - accepts all ETH transfers.
     *      Unused ETH sits harmlessly in the contract.
     */
    function test_receive_acceptsFromAnySender() public {
        // Random address can send ETH (simplified for bytecode savings)
        uint256 amount = 1 ether;
        vm.deal(user1, amount);
        vm.prank(user1);
        (bool success,) = address(hook).call{value: amount}("");
        assertTrue(success, "Should accept ETH from any sender");
    }

    /**
     * @notice Test receive() accepts ETH from owner.
     * @dev Simplified receive() for bytecode savings - accepts all ETH transfers.
     */
    function test_receive_acceptsFromOwner() public {
        uint256 amount = 1 ether;
        vm.deal(owner, amount);
        vm.prank(owner);
        (bool success,) = address(hook).call{value: amount}("");
        assertTrue(success, "Should accept ETH from owner");
    }

    /* ========================================================================== */
    /*                           GETTER TESTS                                     */
    /* ========================================================================== */

    function test_getLogic_returnsCorrectAddress() public view {
        assertEq(hook.getLogic(), address(logic));
    }

    function test_getRegistry_returnsCorrectAddress() public view {
        assertEq(hook.getRegistry(), address(registry));
    }

    function test_getFee_returnsCorrectFee() public view {
        assertEq(hook.getFee(), INITIAL_FEE);
    }

    function test_getPoolKey_returnsCachedPoolKey() public view {
        PoolKey memory cachedKey = hook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), address(0));
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(tokenCurrency));
        assertEq(cachedKey.tickSpacing, defaultTickSpacing);
    }

    function test_getPoolId_returnsCachedPoolId() public view {
        assertEq(PoolId.unwrap(hook.getPoolId()), PoolId.unwrap(poolId));
    }

    function test_getHookPermissions_returnsCorrectPermissions() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertTrue(perms.beforeDonate);
        assertTrue(perms.afterDonate);
        assertTrue(perms.beforeSwapReturnDelta);
        assertTrue(perms.afterSwapReturnDelta);
        assertTrue(perms.afterAddLiquidityReturnDelta);
        assertTrue(perms.afterRemoveLiquidityReturnDelta);
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    /**
     * @notice Deploy AlphixETH infrastructure without calling initialize
     */
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
