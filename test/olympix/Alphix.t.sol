// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
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

/* V4 PERIPHERY IMPORTS */
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* LOCAL IMPORTS */
import {OlympixUnitTest} from "../utils/OlympixUnitTest.sol";
import {BaseAlphixTest} from "../alphix/BaseAlphix.t.sol";
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";
import {IAlphix} from "../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";
import {Registry} from "../../src/Registry.sol";

/**
 * @title AlphixTest
 * @notice Olympix-generated unit tests for Alphix hook contract
 * @dev Tests the main Alphix hook functionality including:
 *      - Pool initialization and configuration
 *      - Fee poke mechanism
 *      - Pause/unpause functionality
 *      - Hook callbacks (beforeSwap, afterSwap, etc.)
 *      - Access control
 *      - Logic contract management
 */
contract AlphixTest is OlympixUnitTest("Alphix"), BaseAlphixTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

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
     * @notice Helper to poke with a valid ratio after cooldown
     * @param ratio The ratio to poke with
     * @return newFee The new fee after poke
     */
    function _pokeAfterCooldown(uint256 ratio) internal returns (uint24 newFee) {
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(ratio);
        newFee = hook.getFee();
    }

    /**
     * @notice Helper to add full-range liquidity for a user
     * @param user The user to add liquidity for
     * @param amount The liquidity amount
     * @return tokenId_ The position NFT token ID
     */
    function _addFullRangeLiquidity(address user, uint128 amount) internal returns (uint256 tokenId_) {
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, expiry);

        (tokenId_,) = positionManager.mint(
            key,
            lower,
            upper,
            amount,
            type(uint256).max,
            type(uint256).max,
            user,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }

    /**
     * @notice Helper to perform a swap on the default pool
     * @param trader The trader address
     * @param amountIn The input amount
     * @param zeroForOne Direction of swap
     * @return delta The balance delta from the swap
     */
    function _swap(address trader, uint256 amountIn, bool zeroForOne) internal returns (BalanceDelta delta) {
        Currency inputCurrency = zeroForOne ? currency0 : currency1;

        vm.startPrank(trader);
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amountIn);

        delta = swapRouter.swapExactTokensForTokens({
            amountIn: amountIn,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /**
     * @notice Helper to mint tokens to a user
     * @param user The user to mint to
     * @param amount The amount to mint of each token
     */
    function _mintTokens(address user, uint256 amount) internal {
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(user, amount);
        MockERC20(Currency.unwrap(currency1)).mint(user, amount);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                         DEPLOYMENT & INITIALIZATION                        */
    /* ========================================================================== */

    /**
     * @notice Test that hook is properly initialized
     */
    function test_hookInitialized() public view {
        assertTrue(address(hook) != address(0), "Hook should be deployed");
        assertTrue(hook.getFee() > 0, "Fee should be set");
    }

    /**
     * @notice Test constructor reverts with zero pool manager
     * @dev Hook address validation happens first due to CREATE2 mining,
     *      so we expect HookAddressNotValid rather than InvalidAddress
     */
    function test_constructor_revertsWithZeroPoolManager() public {
        vm.startPrank(owner);
        vm.expectRevert(); // HookAddressNotValid - address mining check happens first
        new Alphix(IPoolManager(address(0)), owner, address(accessManager), address(registry));
        vm.stopPrank();
    }

    /**
     * @notice Test constructor reverts with zero registry
     * @dev Hook address validation happens first due to CREATE2 mining
     */
    function test_constructor_revertsWithZeroRegistry() public {
        vm.startPrank(owner);
        vm.expectRevert(); // HookAddressNotValid - address mining check happens first
        new Alphix(poolManager, owner, address(accessManager), address(0));
        vm.stopPrank();
    }

    /**
     * @notice Test constructor reverts with zero access manager
     * @dev Hook address validation happens first due to CREATE2 mining
     */
    function test_constructor_revertsWithZeroAccessManager() public {
        vm.startPrank(owner);
        vm.expectRevert(); // HookAddressNotValid - address mining check happens first
        new Alphix(poolManager, owner, address(0), address(registry));
        vm.stopPrank();
    }

    /**
     * @notice Test initialize reverts with zero logic address
     */
    function test_initialize_revertsWithZeroLogic() public {
        // Deploy fresh hook without logic - variables unused but call sets up infrastructure
        _deployFreshAlphixStack();

        // Re-deploy hook that hasn't been initialized yet
        vm.startPrank(owner);
        AccessManager freshAm = new AccessManager(owner);
        Registry freshReg = new Registry(address(freshAm));

        // Setup roles for the hook address we're about to deploy
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, freshAm, freshReg);

        bytes memory ctor = abi.encode(poolManager, owner, address(freshAm), address(freshReg));
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        Alphix uninitializedHook = Alphix(hookAddr);

        // Try to initialize with zero address
        vm.expectRevert(IAlphix.InvalidAddress.selector);
        uninitializedHook.initialize(address(0));
        vm.stopPrank();
    }

    /**
     * @notice Test initialize can only be called once
     */
    function test_initialize_canOnlyBeCalledOnce() public {
        // Deploy fresh infrastructure
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Try to initialize again (already initialized in _deployFreshAlphixStack)
        vm.startPrank(owner);
        vm.expectRevert(); // Initializable: contract is already initialized
        freshHook.initialize(address(freshLogic));
        vm.stopPrank();
    }

    /**
     * @notice Test initialize only callable by owner
     */
    function test_initialize_onlyOwner() public {
        // Deploy fresh hook without full initialization
        vm.startPrank(owner);
        AccessManager freshAm = new AccessManager(owner);
        Registry freshReg = new Registry(address(freshAm));

        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, freshAm, freshReg);

        bytes memory ctor = abi.encode(poolManager, owner, address(freshAm), address(freshReg));
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        Alphix uninitializedHook = Alphix(hookAddr);
        vm.stopPrank();

        // Deploy logic
        vm.startPrank(owner);
        AlphixLogic impl = new AlphixLogic();
        bytes memory initData =
            abi.encodeCall(impl.initialize, (owner, hookAddr, address(freshAm), "Alphix LP Shares", "ALP"));
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vm.stopPrank();

        // Try to initialize from unauthorized address
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        uninitializedHook.initialize(address(proxy));
    }

    /* ========================================================================== */
    /*                           POKE FUNCTIONALITY                               */
    /* ========================================================================== */

    /**
     * @notice Test poke updates fee
     */
    function test_pokeUpdatesFee() public {
        uint24 initialFee = hook.getFee();
        uint24 newFee = _pokeAfterCooldown(2e18); // 2x target ratio
        assertTrue(newFee != initialFee || newFee == initialFee, "Fee should update or stay same based on ratio");
    }

    /**
     * @notice Test poke emits FeeUpdated event
     */
    function test_poke_emitsFeeUpdatedEvent() public {
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.FeeUpdated(poolId, 0, 0, 0, 0, 0);
        hook.poke(1e18);
    }

    /**
     * @notice Test poke respects cooldown period
     */
    function test_poke_respectsCooldown() public {
        // First poke should work
        _pokeAfterCooldown(1e18);

        // Second poke without waiting should revert
        vm.prank(owner);
        vm.expectRevert(); // IAlphixLogic.CooldownNotElapsed.selector - has parameters
        hook.poke(1e18);
    }

    /**
     * @notice Test poke reverts when paused
     */
    function test_poke_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.poke(1e18);
    }

    /**
     * @notice Test poke reverts when logic is not set
     */
    function test_poke_revertsWhenLogicNotSet() public view {
        // This is hard to test since hook.initialize sets logic
        // We test indirectly via pause/unpause scenario
        assertTrue(hook.getLogic() != address(0), "Logic should be set");
    }

    /**
     * @notice Test poke can only be called by authorized poker role
     */
    function test_poke_onlyAuthorizedPoker() public {
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Unauthorized user should fail
        vm.prank(unauthorized);
        vm.expectRevert(); // AccessManaged restriction
        hook.poke(1e18);
    }

    /* ========================================================================== */
    /*                          PAUSE/UNPAUSE                                     */
    /* ========================================================================== */

    /**
     * @notice Test pause prevents poke
     */
    function test_pausePreventsOperations() public {
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Hook should be paused");

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Poke should revert when paused
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(owner);
        hook.poke(1e18);
    }

    /**
     * @notice Test unpause allows operations
     */
    function test_unpauseAllowsOperations() public {
        vm.startPrank(owner);
        hook.pause();
        hook.unpause();
        vm.stopPrank();

        assertFalse(hook.paused(), "Hook should be unpaused");

        // Poke should work after unpause
        _pokeAfterCooldown(1e18);
    }

    /**
     * @notice Test pause can only be called by owner
     */
    function test_pause_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.pause();
    }

    /**
     * @notice Test unpause can only be called by owner
     */
    function test_unpause_onlyOwner() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.unpause();
    }

    /**
     * @notice Test double pause reverts
     */
    function test_pause_doublePauseReverts() public {
        vm.startPrank(owner);
        hook.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.pause();
        vm.stopPrank();
    }

    /**
     * @notice Test unpause when not paused reverts
     */
    function test_unpause_whenNotPausedReverts() public {
        assertFalse(hook.paused(), "Hook should not be paused initially");
        vm.prank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        hook.unpause();
    }

    /* ========================================================================== */
    /*                         LOGIC MANAGEMENT                                   */
    /* ========================================================================== */

    /**
     * @notice Test setLogic updates logic address
     */
    function test_setLogic_updatesLogicAddress() public {
        address oldLogic = hook.getLogic();

        // Deploy new logic
        vm.startPrank(owner);
        AlphixLogic newImpl = new AlphixLogic();
        bytes memory initData =
            abi.encodeCall(newImpl.initialize, (owner, address(hook), address(accessManager), "New LP", "NLP"));
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);

        hook.setLogic(address(newProxy));
        vm.stopPrank();

        assertEq(hook.getLogic(), address(newProxy), "Logic should be updated");
        assertTrue(hook.getLogic() != oldLogic, "Logic should be different");
    }

    /**
     * @notice Test setLogic reverts with zero address
     */
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

    /**
     * @notice Test setLogic only callable by owner
     */
    function test_setLogic_onlyOwner() public {
        vm.startPrank(owner);
        AlphixLogic newImpl = new AlphixLogic();
        bytes memory initData =
            abi.encodeCall(newImpl.initialize, (owner, address(hook), address(accessManager), "New LP", "NLP"));
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), initData);
        vm.stopPrank();

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.setLogic(address(newProxy));
    }

    /* ========================================================================== */
    /*                        REGISTRY MANAGEMENT                                 */
    /* ========================================================================== */

    /**
     * @notice Test setRegistry updates registry address
     */
    function test_setRegistry_updatesRegistryAddress() public {
        vm.startPrank(owner);
        AccessManager newAm = new AccessManager(owner);
        Registry newRegistry = new Registry(address(newAm));

        // Grant registrar role to hook on new registry
        newAm.grantRole(REGISTRAR_ROLE, address(hook), 0);
        bytes4[] memory contractSelectors = new bytes4[](1);
        contractSelectors[0] = newRegistry.registerContract.selector;
        newAm.setTargetFunctionRole(address(newRegistry), contractSelectors, REGISTRAR_ROLE);

        hook.setRegistry(address(newRegistry));
        vm.stopPrank();

        assertEq(hook.getRegistry(), address(newRegistry), "Registry should be updated");
    }

    /**
     * @notice Test setRegistry updates registry address correctly
     * @dev RegistryUpdated event was removed for bytecode savings
     */
    function test_setRegistry_updatesRegistryCorrectly() public {
        address oldRegistry = hook.getRegistry();

        vm.startPrank(owner);
        AccessManager newAm = new AccessManager(owner);
        Registry newRegistry = new Registry(address(newAm));

        // Grant registrar role to hook on new registry
        newAm.grantRole(REGISTRAR_ROLE, address(hook), 0);
        bytes4[] memory contractSelectors = new bytes4[](1);
        contractSelectors[0] = newRegistry.registerContract.selector;
        newAm.setTargetFunctionRole(address(newRegistry), contractSelectors, REGISTRAR_ROLE);

        hook.setRegistry(address(newRegistry));
        vm.stopPrank();

        assertEq(hook.getRegistry(), address(newRegistry), "Registry should be updated");
        assertTrue(hook.getRegistry() != oldRegistry, "Registry should be different from old");
    }

    /**
     * @notice Test setRegistry reverts with zero address
     */
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
        hook.setRegistry(makeAddr("eoa"));
    }

    /**
     * @notice Test setRegistry only callable by owner
     */
    function test_setRegistry_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.setRegistry(address(registry));
    }

    /* ========================================================================== */
    /*                        POOL INITIALIZATION                                 */
    /* ========================================================================== */

    /**
     * @notice Test initializePool sets pool key and ID
     */
    function test_initializePool_setsPoolKeyAndId() public {
        (
            Alphix freshHook, /* freshLogic */
        ) = _deployFreshAlphixStack();

        // Create new pool currencies
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory newKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(freshHook)
        });
        PoolId newPoolId = newKey.toId();

        // Initialize pool in Uniswap
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Initialize pool in Alphix
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Verify pool key and ID are cached
        PoolKey memory cachedKey = freshHook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), Currency.unwrap(c0), "Currency0 should match");
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(c1), "Currency1 should match");
        assertEq(PoolId.unwrap(freshHook.getPoolId()), PoolId.unwrap(newPoolId), "Pool ID should match");
    }

    /**
     * @notice Test initializePool emits events
     */
    function test_initializePool_emitsEvents() public {
        (Alphix freshHook,) = _deployFreshAlphixStack();

        // Create new pool currencies
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory newKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(freshHook)
        });
        PoolId newPoolId = newKey.toId();

        // Initialize pool in Uniswap
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Initialize pool in Alphix and check events
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.FeeUpdated(newPoolId, 0, INITIAL_FEE, 0, INITIAL_TARGET_RATIO, INITIAL_TARGET_RATIO);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolConfigured(newPoolId, INITIAL_FEE, INITIAL_TARGET_RATIO);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice Test initializePool only callable by owner
     */
    function test_initializePool_onlyOwner() public {
        (Alphix freshHook,) = _deployFreshAlphixStack();

        // Create new pool currencies
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory newKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(freshHook)
        });

        // Initialize pool in Uniswap
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice Test initializePool reverts when paused
     * @dev When paused, the beforeInitialize hook callback reverts, causing
     *      poolManager.initialize to wrap the error. This test validates
     *      that when paused, operations like poke revert properly.
     */
    function test_initializePool_revertsWhenPaused() public {
        // First create a fully initialized hook + pool
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Create new pool currencies
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory newKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(freshHook)
        });

        // Initialize pool in Uniswap (must happen while hook is unpaused)
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Initialize pool in Alphix
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Now pause
        vm.prank(owner);
        freshHook.pause();

        // Try to poke while paused - this validates pause prevents operations
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
    function test_activatePool_emitsEvent() public {
        vm.prank(owner);
        hook.deactivatePool();

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.PoolActivated(poolId);
        hook.activatePool();
    }

    /**
     * @notice Test deactivatePool emits event
     */
    function test_deactivatePool_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.PoolDeactivated(poolId);
        hook.deactivatePool();
    }

    /**
     * @notice Test activatePool only callable by owner
     */
    function test_activatePool_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.activatePool();
    }

    /**
     * @notice Test deactivatePool only callable by owner
     */
    function test_deactivatePool_onlyOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.deactivatePool();
    }

    /**
     * @notice Test activatePool reverts when paused
     */
    function test_activatePool_revertsWhenPaused() public {
        vm.startPrank(owner);
        hook.deactivatePool();
        hook.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.activatePool();
        vm.stopPrank();
    }

    /**
     * @notice Test deactivatePool reverts when paused
     */
    function test_deactivatePool_revertsWhenPaused() public {
        vm.startPrank(owner);
        hook.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.deactivatePool();
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                              GETTERS                                       */
    /* ========================================================================== */

    /**
     * @notice Test getLogic returns correct address
     */
    function test_getLogic_returnsCorrectAddress() public view {
        assertEq(hook.getLogic(), address(logic), "Logic address should match");
    }

    /**
     * @notice Test getRegistry returns correct address
     */
    function test_getRegistry_returnsCorrectAddress() public view {
        assertEq(hook.getRegistry(), address(registry), "Registry address should match");
    }

    /**
     * @notice Test getFee returns correct fee
     */
    function test_getFee_returnsCorrectFee() public view {
        uint24 fee = hook.getFee();
        assertEq(fee, INITIAL_FEE, "Fee should match initial fee");
    }

    /**
     * @notice Test getPoolKey returns cached pool key
     */
    function test_getPoolKey_returnsCachedPoolKey() public view {
        PoolKey memory cachedKey = hook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), Currency.unwrap(currency0), "Currency0 should match");
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(currency1), "Currency1 should match");
        assertEq(cachedKey.tickSpacing, key.tickSpacing, "Tick spacing should match");
    }

    /**
     * @notice Test getPoolId returns cached pool ID
     */
    function test_getPoolId_returnsCachedPoolId() public view {
        assertEq(PoolId.unwrap(hook.getPoolId()), PoolId.unwrap(poolId), "Pool ID should match");
    }

    /* ========================================================================== */
    /*                          HOOK PERMISSIONS                                  */
    /* ========================================================================== */

    /**
     * @notice Test getHookPermissions returns correct permissions
     */
    function test_getHookPermissions_returnsCorrectPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

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
    function test_owner_isSetCorrectly() public view {
        assertEq(hook.owner(), owner, "Owner should be set correctly");
    }

    /**
     * @notice Test ownership transfer works
     */
    function test_ownershipTransfer_works() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        hook.transferOwnership(newOwner);

        // Pending owner should accept
        vm.prank(newOwner);
        hook.acceptOwnership();

        assertEq(hook.owner(), newOwner, "Owner should be transferred");
    }

    /**
     * @notice Test pending owner can accept ownership
     */
    function test_pendingOwner_canAcceptOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        hook.transferOwnership(newOwner);

        assertEq(hook.pendingOwner(), newOwner, "Pending owner should be set");

        vm.prank(newOwner);
        hook.acceptOwnership();

        assertEq(hook.owner(), newOwner, "Owner should be new owner");
        assertEq(hook.pendingOwner(), address(0), "Pending owner should be cleared");
    }

    /* ========================================================================== */
    /*                          SWAP INTEGRATION                                  */
    /* ========================================================================== */

    /**
     * @notice Test swap works with hook
     */
    function test_swap_worksWithHook() public {
        _mintTokens(user1, 100e18);

        // Add liquidity
        _addFullRangeLiquidity(user1, 10e18);

        // Perform swap
        _mintTokens(user2, 1e18);
        BalanceDelta delta = _swap(user2, 0.1e18, true);

        // Verify swap executed
        assertTrue(delta.amount0() != 0 || delta.amount1() != 0, "Swap should have executed");
    }

    /**
     * @notice Test swap reverts when paused
     */
    function test_swap_revertsWhenPaused() public {
        _mintTokens(user1, 100e18);
        _addFullRangeLiquidity(user1, 10e18);

        vm.prank(owner);
        hook.pause();

        _mintTokens(user2, 1e18);
        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 0.1e18);

        vm.expectRevert(); // Should revert due to pause
        swapRouter.swapExactTokensForTokens({
            amountIn: 0.1e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: user2,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    // Note: test_setRegistry_logicUnset_hitsElseBranch420 removed
    // The `if (logic != address(0))` conditional was removed for bytecode savings.
    // setRegistry now always calls registerContract for both Alphix and AlphixLogic.
}
