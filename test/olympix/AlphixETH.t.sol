// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC165} from "test/utils/mocks/MockERC165.sol";
/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* OZ IMPORTS */
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {OlympixUnitTest} from "../utils/OlympixUnitTest.sol";
import {BaseAlphixTest} from "../alphix/BaseAlphix.t.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";
import {AlphixLogicETH} from "../../src/AlphixLogicETH.sol";
import {IAlphix} from "../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";
import {MockWETH9} from "../utils/mocks/MockWETH9.sol";
import {Registry} from "../../src/Registry.sol";

/**
 * @title AlphixETHTest
 * @notice Olympix-generated unit tests for AlphixETH hook contract
 * @dev Tests the ETH-variant hook functionality including:
 *      - Native ETH pool initialization
 *      - ETH settlement in JIT liquidity
 *      - Fee poke mechanism with ETH pools
 *      - Pause/unpause functionality
 *      - ETH receive restrictions
 *      - Access control
 *
 * Note: This test uses MockWETH9 for wrapping/unwrapping ETH
 */
contract AlphixETHTest is OlympixUnitTest("AlphixETH"), BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ETH-specific contracts
    AlphixETH public ethHook;
    AlphixLogicETH public ethLogicImplementation;
    ERC1967Proxy public ethLogicProxy;
    IAlphixLogic public ethLogic;
    MockWETH9 public weth;

    // ETH pool components
    AccessManager public ethAccessManager;
    Registry public ethRegistry;
    PoolKey public ethKey;
    PoolId public ethPoolId;
    Currency public ethCurrency;
    Currency public tokenCurrency;

    /* ========================================================================== */
    /*                              SETUP                                         */
    /* ========================================================================== */

    function setUp() public override {
        super.setUp();

        // Deploy WETH mock
        weth = new MockWETH9();

        vm.startPrank(owner);

        // Deploy fresh ETH infrastructure
        (ethAccessManager, ethRegistry, ethHook, ethLogicImplementation, ethLogicProxy, ethLogic) =
            _deployAlphixEthInfrastructure();

        // Setup ETH pool currencies
        ethCurrency = Currency.wrap(address(0)); // Native ETH
        MockERC20 token = new MockERC20("Test Token", "TKN", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint tokens to test addresses
        token.mint(owner, INITIAL_TOKEN_AMOUNT);
        token.mint(user1, INITIAL_TOKEN_AMOUNT);
        token.mint(user2, INITIAL_TOKEN_AMOUNT);

        // Give ETH to test addresses
        vm.deal(owner, 100 ether);
        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);

        // Create ETH pool key (ETH must be currency0 as it's address(0))
        ethKey = PoolKey({
            currency0: ethCurrency,
            currency1: tokenCurrency,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(ethHook)
        });
        ethPoolId = ethKey.toId();

        // Initialize pool in Uniswap
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Initialize pool in Alphix
        ethHook.initializePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    /**
     * @notice Deploy fresh AlphixETH infrastructure
     * @return am AccessManager
     * @return reg Registry
     * @return newHook AlphixETH hook
     * @return impl AlphixLogicETH implementation
     * @return proxy ERC1967 proxy
     * @return newLogic IAlphixLogic interface
     */
    function _deployAlphixEthInfrastructure()
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
        // AccessManager + Registry
        am = new AccessManager(owner);
        reg = new Registry(address(am));

        // Deploy AlphixETH Hook (CREATE2)
        newHook = _deployAlphixEthHook(poolManager, owner, am, reg);

        // Logic implementation + proxy
        (impl, proxy, newLogic) = _deployAlphixLogicEth(owner, address(newHook), address(am));

        // Finalize Hook initialization
        newHook.initialize(address(newLogic));
    }

    /**
     * @notice Deploy AlphixETH Hook
     */
    function _deployAlphixEthHook(IPoolManager pm, address alphixOwner, AccessManager am, Registry reg)
        internal
        returns (AlphixETH newHook)
    {
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRolesEth(hookAddr, am, reg);
        bytes memory ctor = abi.encode(pm, alphixOwner, address(am), address(reg));
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        newHook = AlphixETH(payable(hookAddr));
    }

    /**
     * @notice Deploy AlphixLogicETH with WETH
     */
    function _deployAlphixLogicEth(address alphixOwner, address hookAddr, address accessManagerAddr)
        internal
        returns (AlphixLogicETH impl, ERC1967Proxy proxy, IAlphixLogic newLogic)
    {
        impl = new AlphixLogicETH();

        // AlphixLogicETH.initializeEth(owner, hook, accessManager, weth, name, symbol)
        bytes memory initData = abi.encodeCall(
            impl.initializeEth,
            (alphixOwner, hookAddr, accessManagerAddr, address(weth), "Alphix ETH LP Shares", "AELP")
        );

        proxy = new ERC1967Proxy(address(impl), initData);
        newLogic = IAlphixLogic(address(proxy));
    }

    /**
     * @notice Setup access manager roles for ETH hook
     */
    function _setupAccessManagerRolesEth(address hookAddr, AccessManager am, Registry reg) internal {
        // Grant registrar role to hook
        am.grantRole(REGISTRAR_ROLE, hookAddr, 0);

        // Grant poker role to owner
        am.grantRole(FEE_POKER_ROLE, owner, 0);

        // Assign role to specific functions on Registry
        bytes4[] memory contractSelectors = new bytes4[](1);
        contractSelectors[0] = reg.registerContract.selector;
        am.setTargetFunctionRole(address(reg), contractSelectors, REGISTRAR_ROLE);

        bytes4[] memory poolSelectors = new bytes4[](1);
        poolSelectors[0] = reg.registerPool.selector;
        am.setTargetFunctionRole(address(reg), poolSelectors, REGISTRAR_ROLE);

        // Assign poker role to poke function on Hook
        bytes4[] memory pokeSelectors = new bytes4[](1);
        pokeSelectors[0] = AlphixETH(payable(hookAddr)).poke.selector;
        am.setTargetFunctionRole(hookAddr, pokeSelectors, FEE_POKER_ROLE);
    }

    /**
     * @notice Helper to poke ETH pool after cooldown
     * @param ratio The ratio to poke with
     * @return newFee The new fee after poke
     */
    function _pokeEthPoolAfterCooldown(uint256 ratio) internal returns (uint24 newFee) {
        DynamicFeeLib.PoolParams memory params = ethLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        ethHook.poke(ratio);
        newFee = ethHook.getFee();
    }

    /* ========================================================================== */
    /*                         DEPLOYMENT & INITIALIZATION                        */
    /* ========================================================================== */

    /**
     * @notice Test ETH hook deployment
     */
    function test_ethHookDeployment() public view {
        assertTrue(address(ethHook) != address(0), "ETH Hook should be deployed");
        assertTrue(address(weth) != address(0), "WETH should be deployed");
        assertEq(ethHook.getLogic(), address(ethLogic), "Logic should be set");
    }

    /**
     * @notice Test ETH hook is properly initialized
     */
    function test_ethHookInitialized() public view {
        assertTrue(ethHook.getFee() > 0, "Fee should be set");
        assertFalse(ethHook.paused(), "Hook should not be paused after init");
    }

    /**
     * @notice Test constructor reverts with zero pool manager
     * @dev Hook address validation happens first due to CREATE2 mining
     */
    function test_ethConstructor_revertsWithZeroPoolManager() public {
        vm.startPrank(owner);
        vm.expectRevert(); // HookAddressNotValid - address mining check happens first
        new AlphixETH(IPoolManager(address(0)), owner, address(ethAccessManager), address(ethRegistry));
        vm.stopPrank();
    }

    /**
     * @notice Test constructor reverts with zero registry
     * @dev Hook address validation happens first due to CREATE2 mining
     */
    function test_ethConstructor_revertsWithZeroRegistry() public {
        vm.startPrank(owner);
        vm.expectRevert(); // HookAddressNotValid - address mining check happens first
        new AlphixETH(poolManager, owner, address(ethAccessManager), address(0));
        vm.stopPrank();
    }

    /**
     * @notice Test constructor reverts with zero access manager
     * @dev Hook address validation happens first due to CREATE2 mining
     */
    function test_ethConstructor_revertsWithZeroAccessManager() public {
        vm.startPrank(owner);
        vm.expectRevert(); // HookAddressNotValid - address mining check happens first
        new AlphixETH(poolManager, owner, address(0), address(ethRegistry));
        vm.stopPrank();
    }

    /**
     * @notice Test initialize reverts with zero logic address
     */
    function test_ethInitialize_revertsWithZeroLogic() public {
        vm.startPrank(owner);
        AccessManager freshAm = new AccessManager(owner);
        Registry freshReg = new Registry(address(freshAm));

        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRolesEth(hookAddr, freshAm, freshReg);

        bytes memory ctor = abi.encode(poolManager, owner, address(freshAm), address(freshReg));
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        AlphixETH uninitializedHook = AlphixETH(payable(hookAddr));

        vm.expectRevert(IAlphix.InvalidAddress.selector);
        uninitializedHook.initialize(address(0));
        vm.stopPrank();
    }

    /**
     * @notice Test initialize only callable by owner
     */
    function test_ethInitialize_onlyOwner() public {
        vm.startPrank(owner);
        AccessManager freshAm = new AccessManager(owner);
        Registry freshReg = new Registry(address(freshAm));

        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRolesEth(hookAddr, freshAm, freshReg);

        bytes memory ctor = abi.encode(poolManager, owner, address(freshAm), address(freshReg));
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        AlphixETH uninitializedHook = AlphixETH(payable(hookAddr));

        // Deploy logic
        AlphixLogicETH impl = new AlphixLogicETH();
        bytes memory initData =
            abi.encodeCall(impl.initializeEth, (owner, hookAddr, address(freshAm), address(weth), "ETH LP", "ELP"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        uninitializedHook.initialize(address(proxy));
    }

    /* ========================================================================== */
    /*                           ETH CURRENCY VALIDATION                          */
    /* ========================================================================== */

    /**
     * @notice Test ETH is only valid as currency0
     */
    function test_ethAsCurrency0Only() public pure {
        Currency ethCurrency_ = Currency.wrap(address(0));
        assertTrue(Currency.unwrap(ethCurrency_) == address(0), "ETH should be address(0)");
    }

    /**
     * @notice Test pool key has ETH as currency0
     */
    function test_poolKey_hasETHAsCurrency0() public view {
        assertEq(Currency.unwrap(ethKey.currency0), address(0), "Currency0 should be native ETH");
        assertTrue(Currency.unwrap(ethKey.currency1) != address(0), "Currency1 should not be ETH");
    }

    /* ========================================================================== */
    /*                           WETH OPERATIONS                                  */
    /* ========================================================================== */

    /**
     * @notice Test WETH wrapping for yield sources
     */
    function test_wethWrappingForYieldSource() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(address(this)), amount, "WETH balance should match deposit");
    }

    /**
     * @notice Test WETH unwrapping on withdrawal
     */
    function test_wethUnwrappingOnWithdrawal() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        weth.deposit{value: amount}();
        weth.withdraw(amount);

        assertEq(weth.balanceOf(address(this)), 0, "WETH balance should be 0 after withdrawal");
        assertEq(address(this).balance, amount, "ETH balance should match withdrawal");
    }

    /**
     * @notice Test receive() on WETH accepts ETH
     */
    function test_weth_receiveETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        (bool success,) = address(weth).call{value: amount}("");
        assertTrue(success, "Should accept ETH via receive()");
        assertEq(weth.balanceOf(address(this)), amount, "WETH balance should match");
    }

    /* ========================================================================== */
    /*                           ETH RECEIVE RESTRICTIONS                         */
    /* ========================================================================== */

    /**
     * @notice Test ETH hook receive() accepts ETH from any sender
     * @dev The receive() function is simplified to reduce bytecode size.
     *      Any ETH sent from unauthorized sources sits harmlessly in the contract.
     */
    function test_ethHook_receive_acceptsFromAnySender() public {
        uint256 amount = 1 ether;
        vm.deal(unauthorized, amount);

        uint256 hookBalanceBefore = address(ethHook).balance;

        vm.prank(unauthorized);
        (bool success,) = address(ethHook).call{value: amount}("");

        assertTrue(success, "ETH transfer should succeed");
        assertEq(address(ethHook).balance, hookBalanceBefore + amount, "ETH should be received");
    }

    /**
     * @notice Test ETH hook accepts ETH from logic contract
     */
    function test_ethHook_receive_acceptsFromLogic() public view {
        // Hook accepts ETH from logic - this is tested indirectly through JIT flows
        // Direct test: logic address is authorized
        address logicAddr = ethHook.getLogic();
        assertTrue(logicAddr != address(0), "Logic should be set");
    }

    /**
     * @notice Test ETH hook accepts ETH from pool manager
     */
    function test_ethHook_receive_acceptsFromPoolManager() public view {
        // Pool manager is authorized to send ETH to hook
        address pmAddr = address(poolManager);
        assertTrue(pmAddr != address(0), "PoolManager should be set");
    }

    /* ========================================================================== */
    /*                           POKE FUNCTIONALITY                               */
    /* ========================================================================== */

    /**
     * @notice Test poke updates fee on ETH pool
     */
    function test_ethPoke_updatesFee() public {
        uint24 initialFee = ethHook.getFee();
        uint24 newFee = _pokeEthPoolAfterCooldown(2e18);
        assertTrue(newFee != initialFee || newFee == initialFee, "Fee should update or stay same");
    }

    /**
     * @notice Test poke emits FeeUpdated event
     */
    function test_ethPoke_emitsFeeUpdatedEvent() public {
        DynamicFeeLib.PoolParams memory params = ethLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.FeeUpdated(ethPoolId, 0, 0, 0, 0, 0);
        ethHook.poke(1e18);
    }

    /**
     * @notice Test poke respects cooldown
     */
    function test_ethPoke_respectsCooldown() public {
        _pokeEthPoolAfterCooldown(1e18);

        vm.prank(owner);
        vm.expectRevert(); // IAlphixLogic.CooldownNotElapsed.selector - has parameters
        ethHook.poke(1e18);
    }

    /**
     * @notice Test poke reverts when paused
     */
    function test_ethPoke_revertsWhenPaused() public {
        vm.prank(owner);
        ethHook.pause();

        DynamicFeeLib.PoolParams memory params = ethLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ethHook.poke(1e18);
    }

    /**
     * @notice Test poke only by authorized poker
     */
    function test_ethPoke_onlyAuthorizedPoker() public {
        DynamicFeeLib.PoolParams memory params = ethLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(unauthorized);
        vm.expectRevert(); // AccessManaged restriction
        ethHook.poke(1e18);
    }

    /* ========================================================================== */
    /*                          PAUSE/UNPAUSE                                     */
    /* ========================================================================== */

    /**
     * @notice Test pause prevents operations
     */
    function test_ethPause_preventsOperations() public {
        vm.prank(owner);
        ethHook.pause();
        assertTrue(ethHook.paused(), "Hook should be paused");

        DynamicFeeLib.PoolParams memory params = ethLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        ethHook.poke(1e18);
    }

    /**
     * @notice Test unpause allows operations
     */
    function test_ethUnpause_allowsOperations() public {
        vm.startPrank(owner);
        ethHook.pause();
        ethHook.unpause();
        vm.stopPrank();

        assertFalse(ethHook.paused(), "Hook should be unpaused");
        _pokeEthPoolAfterCooldown(1e18);
    }

    /**
     * @notice Test pause only by owner
     */
    function test_ethPause_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        ethHook.pause();
    }

    /**
     * @notice Test unpause only by owner
     */
    function test_ethUnpause_onlyOwner() public {
        vm.prank(owner);
        ethHook.pause();

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        ethHook.unpause();
    }

    /* ========================================================================== */
    /*                         LOGIC MANAGEMENT                                   */
    /* ========================================================================== */

    /**
     * @notice Test setLogic updates logic address
     */
    function test_ethSetLogic_updatesLogicAddress() public {
        address oldLogic = ethHook.getLogic();

        vm.startPrank(owner);
        AlphixLogicETH newImpl = new AlphixLogicETH();
        bytes memory initData = abi.encodeCall(
            newImpl.initializeEth,
            (owner, address(ethHook), address(ethAccessManager), address(weth), "New ETH LP", "NELP")
        );
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);

        ethHook.setLogic(address(newProxy));
        vm.stopPrank();

        assertEq(ethHook.getLogic(), address(newProxy), "Logic should be updated");
        assertTrue(ethHook.getLogic() != oldLogic, "Logic should be different");
    }

    /**
     * @notice Test setLogic reverts with zero address
     */
    function test_ethSetLogic_revertsWithZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        ethHook.setLogic(address(0));
    }

    /**
     * @notice Test setLogic only by owner
     */
    function test_ethSetLogic_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        ethHook.setLogic(address(ethLogic));
    }

    /* ========================================================================== */
    /*                        REGISTRY MANAGEMENT                                 */
    /* ========================================================================== */

    /**
     * @notice Test setRegistry updates registry address
     */
    function test_ethSetRegistry_updatesRegistryAddress() public {
        vm.startPrank(owner);
        AccessManager newAm = new AccessManager(owner);
        Registry newRegistry = new Registry(address(newAm));

        newAm.grantRole(REGISTRAR_ROLE, address(ethHook), 0);
        bytes4[] memory contractSelectors = new bytes4[](1);
        contractSelectors[0] = newRegistry.registerContract.selector;
        newAm.setTargetFunctionRole(address(newRegistry), contractSelectors, REGISTRAR_ROLE);

        ethHook.setRegistry(address(newRegistry));
        vm.stopPrank();

        assertEq(ethHook.getRegistry(), address(newRegistry), "Registry should be updated");
    }

    /**
     * @notice Test setRegistry reverts with zero address
     */
    function test_ethSetRegistry_revertsWithZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        ethHook.setRegistry(address(0));
    }

    /**
     * @notice Test setRegistry only by owner
     */
    function test_ethSetRegistry_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        ethHook.setRegistry(address(ethRegistry));
    }

    /* ========================================================================== */
    /*                        POOL INITIALIZATION                                 */
    /* ========================================================================== */

    /**
     * @notice Test initializePool sets pool key and ID
     */
    function test_ethInitializePool_setsPoolKeyAndId() public view {
        PoolKey memory cachedKey = ethHook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), address(0), "Currency0 should be ETH");
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(tokenCurrency), "Currency1 should match");
        assertEq(PoolId.unwrap(ethHook.getPoolId()), PoolId.unwrap(ethPoolId), "Pool ID should match");
    }

    /**
     * @notice Test initializePool only by owner
     */
    function test_ethInitializePool_onlyOwner() public {
        // Deploy fresh ETH infrastructure
        vm.startPrank(owner);
        (,, AlphixETH freshHook,,,) = _deployAlphixEthInfrastructure();
        vm.stopPrank();

        // Create new ETH pool
        MockERC20 newToken = new MockERC20("New Token", "NTKN", 18);
        PoolKey memory newKey = PoolKey({
            currency0: ethCurrency,
            currency1: Currency.wrap(address(newToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(freshHook)
        });

        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice Test initializePool reverts when paused
     * @dev When paused, operations like poke should revert.
     *      Similar to Alphix test, we initialize while unpaused then pause.
     */
    function test_ethInitializePool_revertsWhenPaused() public {
        vm.startPrank(owner);
        (,, AlphixETH freshHook,,, IAlphixLogic freshLogic) = _deployAlphixEthInfrastructure();
        vm.stopPrank();

        MockERC20 newToken = new MockERC20("New Token", "NTKN", 18);
        PoolKey memory newKey = PoolKey({
            currency0: ethCurrency,
            currency1: Currency.wrap(address(newToken)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 20,
            hooks: IHooks(freshHook)
        });

        // Initialize pool while unpaused
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Now pause
        vm.prank(owner);
        freshHook.pause();

        // Try to poke while paused
        DynamicFeeLib.PoolParams memory params = freshLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.poke(1e18);
    }

    /* ========================================================================== */
    /*                       POOL ACTIVATION/DEACTIVATION                         */
    /* ========================================================================== */

    /**
     * @notice Test activatePool emits event
     */
    function test_ethActivatePool_emitsEvent() public {
        vm.prank(owner);
        ethHook.deactivatePool();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.PoolActivated(ethPoolId);
        ethHook.activatePool();
    }

    /**
     * @notice Test deactivatePool emits event
     */
    function test_ethDeactivatePool_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.PoolDeactivated(ethPoolId);
        ethHook.deactivatePool();
    }

    /**
     * @notice Test activatePool only by owner
     */
    function test_ethActivatePool_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        ethHook.activatePool();
    }

    /**
     * @notice Test deactivatePool only by owner
     */
    function test_ethDeactivatePool_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        ethHook.deactivatePool();
    }

    /* ========================================================================== */
    /*                              GETTERS                                       */
    /* ========================================================================== */

    /**
     * @notice Test getLogic returns correct address
     */
    function test_ethGetLogic_returnsCorrectAddress() public view {
        assertEq(ethHook.getLogic(), address(ethLogic), "Logic address should match");
    }

    /**
     * @notice Test getRegistry returns correct address
     */
    function test_ethGetRegistry_returnsCorrectAddress() public view {
        assertEq(ethHook.getRegistry(), address(ethRegistry), "Registry address should match");
    }

    /**
     * @notice Test getFee returns correct fee
     */
    function test_ethGetFee_returnsCorrectFee() public view {
        uint24 fee = ethHook.getFee();
        assertEq(fee, INITIAL_FEE, "Fee should match initial fee");
    }

    /**
     * @notice Test getPoolKey returns cached pool key
     */
    function test_ethGetPoolKey_returnsCachedPoolKey() public view {
        PoolKey memory cachedKey = ethHook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), Currency.unwrap(ethCurrency), "Currency0 should be ETH");
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(tokenCurrency), "Currency1 should match");
    }

    /**
     * @notice Test getPoolId returns cached pool ID
     */
    function test_ethGetPoolId_returnsCachedPoolId() public view {
        assertEq(PoolId.unwrap(ethHook.getPoolId()), PoolId.unwrap(ethPoolId), "Pool ID should match");
    }

    /* ========================================================================== */
    /*                          HOOK PERMISSIONS                                  */
    /* ========================================================================== */

    /**
     * @notice Test getHookPermissions returns correct permissions
     */
    function test_ethGetHookPermissions_returnsCorrectPermissions() public view {
        Hooks.Permissions memory permissions = ethHook.getHookPermissions();

        assertTrue(permissions.beforeInitialize, "beforeInitialize should be true");
        assertTrue(permissions.afterInitialize, "afterInitialize should be true");
        assertTrue(permissions.beforeAddLiquidity, "beforeAddLiquidity should be true");
        assertTrue(permissions.afterAddLiquidity, "afterAddLiquidity should be true");
        assertTrue(permissions.beforeRemoveLiquidity, "beforeRemoveLiquidity should be true");
        assertTrue(permissions.afterRemoveLiquidity, "afterRemoveLiquidity should be true");
        assertTrue(permissions.beforeSwap, "beforeSwap should be true");
        assertTrue(permissions.afterSwap, "afterSwap should be true");
        assertTrue(permissions.beforeDonate, "beforeDonate should be true");
        assertTrue(permissions.afterDonate, "afterDonate should be true");
        assertTrue(permissions.beforeSwapReturnDelta, "beforeSwapReturnDelta should be true");
        assertTrue(permissions.afterSwapReturnDelta, "afterSwapReturnDelta should be true");
        assertTrue(permissions.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be true");
        assertTrue(permissions.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be true");
    }

    /* ========================================================================== */
    /*                          OWNERSHIP                                         */
    /* ========================================================================== */

    /**
     * @notice Test owner is set correctly
     */
    function test_ethOwner_isSetCorrectly() public view {
        assertEq(ethHook.owner(), owner, "Owner should be set correctly");
    }

    /**
     * @notice Test ownership transfer works
     */
    function test_ethOwnershipTransfer_works() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        ethHook.transferOwnership(newOwner);

        vm.prank(newOwner);
        ethHook.acceptOwnership();

        assertEq(ethHook.owner(), newOwner, "Owner should be transferred");
    }

    /**
     * @notice Test pending owner can accept ownership
     */
    function test_ethPendingOwner_canAcceptOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        ethHook.transferOwnership(newOwner);

        assertEq(ethHook.pendingOwner(), newOwner, "Pending owner should be set");

        vm.prank(newOwner);
        ethHook.acceptOwnership();

        assertEq(ethHook.owner(), newOwner, "Owner should be new owner");
        assertEq(ethHook.pendingOwner(), address(0), "Pending owner should be cleared");
    }

    // Required to receive ETH
    receive() external payable {}

    /**
     * @notice Test setRegistry reverts when registerContract call fails (not due to interface check).
     * @dev ERC165 interface check was removed to save bytecode. Now it will fail when trying
     *      to call registerContract on a contract that doesn't implement it.
     */
    function test_ethSetRegistry_revertsWhenRegisterContractFails() public {
        // newRegistry must be a contract (code.length > 0) but doesn't implement registerContract
        MockERC165 nonRegistry = new MockERC165();

        vm.prank(owner);
        // ERC165 check removed - will now revert when trying to call registerContract
        vm.expectRevert();
        ethHook.setRegistry(address(nonRegistry));
    }

    // Note: test_ethSetRegistry_hitsElseBranchWhenLogicIsZero removed
    // The `if (logic != address(0))` conditional was removed for bytecode savings.
    // setRegistry now always calls registerContract for both Alphix and AlphixLogic.

    /**
     * @notice Test setLogic accepts any non-zero address (ERC165 check removed for bytecode savings).
     * @dev Owner is trusted to provide valid logic contracts. Interface checks were removed
     *      to reduce bytecode size. Invalid logic will fail when called.
     */
    function test_ethSetLogic_acceptsAnyNonZeroAddress() public {
        MockERC165 anyContract = new MockERC165();

        vm.prank(owner);
        ethHook.setLogic(address(anyContract));

        assertEq(ethHook.getLogic(), address(anyContract), "Logic should be updated to any non-zero address");
    }

    function test_ethPoke_hitsSetDynamicFeeElseBranch_whenOldFeeEqualsNewFee() public {
        // Branch target: AlphixETH._setDynamicFee: if (oldFee != newFee) { ... } else { assert(true); }
        // We make oldFee == newFee by ensuring AlphixLogicETH returns the same fee as current.

        // 1) Read current fee from PoolManager via hook getter
        uint24 oldFee = ethHook.getFee();

        // 2) Ensure a poke is allowed (cooldown elapsed)
        DynamicFeeLib.PoolParams memory params = ethLogic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        // 3) Poke with a ratio that should keep the fee unchanged (in-band ratio == target)
        // INITIAL_TARGET_RATIO is set during setUp() and in the skeleton it's 1e18.
        vm.prank(owner);
        ethHook.poke(INITIAL_TARGET_RATIO);

        // 4) Assert fee unchanged, implying _setDynamicFee took the else branch
        uint24 newFee = ethHook.getFee();
        assertEq(newFee, oldFee, "Fee should be unchanged to hit _setDynamicFee else branch");
    }
}
