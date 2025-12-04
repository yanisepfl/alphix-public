// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* LOCAL IMPORTS */
import {OlympixUnitTest} from "../OlympixUnitTest.sol";
import {Deployers} from "../../utils/Deployers.sol";
import {Alphix} from "../../../src/Alphix.sol";
import {AlphixLogic} from "../../../src/AlphixLogic.sol";
import {Registry} from "../../../src/Registry.sol";
import {IAlphixLogic} from "../../../src/interfaces/IAlphixLogic.sol";
import {IAlphix} from "../../../src/interfaces/IAlphix.sol";
import {IRegistry} from "../../../src/interfaces/IRegistry.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";

/**
 * @title AlphixUnitTest
 * @notice Olympix-generated unit tests for the Alphix contract
 * @dev Tests core functionality: constructor, initialization, hook lifecycle, fee management, access control
 */
contract AlphixUnitTest is OlympixUnitTest("Alphix"), Test, Deployers {
    using PoolIdLibrary for PoolKey;

    // Constants
    uint24 constant INITIAL_FEE = 500; // 0.05%
    uint256 constant INITIAL_TARGET_RATIO = 5e17; // 50%
    uint64 constant FEE_POKER_ROLE = 1;
    uint64 constant REGISTRAR_ROLE = 2;

    // Contracts under test
    Alphix public hook;
    AlphixLogic public logicImplementation;
    ERC1967Proxy public logicProxy;
    IAlphixLogic public logic;
    AccessManager public accessManager;
    Registry public registry;

    // Test addresses
    address public owner;
    address public feePoker;
    address public unauthorized;

    // Test pool
    Currency public currency0;
    Currency public currency1;
    PoolKey public key;
    PoolId public poolId;

    // setUp() is run before each test
    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        deployArtifacts();

        // Setup test addresses
        owner = makeAddr("owner");
        feePoker = makeAddr("feePoker");
        unauthorized = makeAddr("unauthorized");

        vm.startPrank(owner);

        // Deploy AccessManager
        accessManager = new AccessManager(owner);

        // Deploy Registry
        registry = new Registry(address(accessManager));

        // Grant registrar role to owner
        accessManager.grantRole(REGISTRAR_ROLE, owner, 0);

        // Deploy Alphix hook
        hook = new Alphix(poolManager, owner, address(accessManager), address(registry));

        // Deploy AlphixLogic implementation
        logicImplementation = new AlphixLogic();

        // Deploy AlphixLogic proxy
        bytes memory initData = abi.encodeWithSelector(
            AlphixLogic.initialize.selector,
            owner,
            address(hook),
            address(registry),
            _getDefaultStableParams(),
            _getDefaultStandardParams(),
            _getDefaultVolatileParams()
        );
        logicProxy = new ERC1967Proxy(address(logicImplementation), initData);
        logic = IAlphixLogic(address(logicProxy));

        // Initialize hook with logic
        hook.initialize(address(logic));

        // Grant fee poker role
        accessManager.grantRole(FEE_POKER_ROLE, feePoker, 0);

        // Setup test currencies
        (currency0, currency1) = deployCurrencyPairWithDecimals(18, 18);

        // Create pool key
        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        vm.stopPrank();
    }

    /* HELPER FUNCTIONS */

    function deployCurrencyPairWithDecimals(uint8 decimals0, uint8 decimals1) internal returns (Currency, Currency) {
        Currency raw0 = Currency.wrap(address(new MockERC20("Test Token 0", "TT0", decimals0)));
        Currency raw1 = Currency.wrap(address(new MockERC20("Test Token 1", "TT1", decimals1)));
        (Currency sorted0, Currency sorted1) =
            SortTokens.sort(MockERC20(Currency.unwrap(raw0)), MockERC20(Currency.unwrap(raw1)));
        deal(Currency.unwrap(sorted0), owner, 1_000_000e18);
        deal(Currency.unwrap(sorted1), owner, 1_000_000e18);
        return (sorted0, sorted1);
    }

    function _getDefaultStableParams() internal pure returns (DynamicFeeLib.PoolTypeParams memory) {
        return DynamicFeeLib.PoolTypeParams({
            minFee: 10,
            maxFee: 500,
            baseMaxFeeDelta: 100,
            lookbackPeriod: 300,
            minPeriod: 60,
            ratioTolerance: 5e15,
            linearSlope: 2e16,
            maxCurrentRatio: 99e16,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });
    }

    function _getDefaultStandardParams() internal pure returns (DynamicFeeLib.PoolTypeParams memory) {
        return DynamicFeeLib.PoolTypeParams({
            minFee: 50,
            maxFee: 3000,
            baseMaxFeeDelta: 200,
            lookbackPeriod: 600,
            minPeriod: 120,
            ratioTolerance: 1e16,
            linearSlope: 1e17,
            maxCurrentRatio: 99e16,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });
    }

    function _getDefaultVolatileParams() internal pure returns (DynamicFeeLib.PoolTypeParams memory) {
        return DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            baseMaxFeeDelta: 500,
            lookbackPeriod: 900,
            minPeriod: 180,
            ratioTolerance: 2e16,
            linearSlope: 3e17,
            maxCurrentRatio: 99e16,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });
    }

    function _getCustomStableParams(uint24 minFee, uint24 maxFee, uint256 linearSlope)
        internal
        pure
        returns (DynamicFeeLib.PoolTypeParams memory)
    {
        return DynamicFeeLib.PoolTypeParams({
            minFee: minFee,
            maxFee: maxFee,
            baseMaxFeeDelta: 100,
            lookbackPeriod: 300,
            minPeriod: 60,
            ratioTolerance: 5e15,
            linearSlope: linearSlope,
            maxCurrentRatio: 99e16,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });
    }

    function _getCustomVolatileParams(
        uint24 minFee,
        uint24 maxFee,
        uint256 linearSlope,
        uint24 lookback,
        uint256 upperSideFactor,
        uint256 lowerSideFactor
    ) internal pure returns (DynamicFeeLib.PoolTypeParams memory) {
        return DynamicFeeLib.PoolTypeParams({
            minFee: minFee,
            maxFee: maxFee,
            baseMaxFeeDelta: 500,
            lookbackPeriod: lookback,
            minPeriod: 180,
            ratioTolerance: 2e16,
            linearSlope: linearSlope,
            maxCurrentRatio: 99e16,
            upperSideFactor: upperSideFactor,
            lowerSideFactor: lowerSideFactor
        });
    }

    function _createAndInitializePool(int24 tickSpacing, IAlphixLogic.PoolType poolType)
        internal
        returns (PoolKey memory newKey, PoolId newPoolId)
    {
        // Create new currencies
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);

        // Create pool key
        newKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
        newPoolId = newKey.toId();

        // Initialize pool
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Activate pool in logic (pool activation happens in afterInitialize hook)
        // No need to manually call activatePool here - it's called by the hook
    }

    function _seedLiquidity(PoolKey memory poolKey, int24 tickSpacing, uint128 liquidityAmount)
        internal
        returns (uint256 tokenId)
    {
        // TODO: Olympix will generate full liquidity seeding implementation
        // For now, this is a stub that can be used in test stubs
        // Full implementation should:
        // 1. Calculate tick range using TickMath
        // 2. Calculate amounts using LiquidityAmounts
        // 3. Deal tokens to owner
        // 4. Approve Permit2
        // 5. Call positionManager to mint position
        return 0;
    }

    function _performSwap(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified) internal {
        // Prepare swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? 4295128739 : 1461446703485210103287273052203988822378723970342
        });

        // Execute swap
        poolManager.swap(poolKey, params, "");
    }

    /* EXAMPLE TEST STUBS - Olympix will generate comprehensive tests based on these patterns */

    // Constructor tests
    function test_constructor_setsPoolManager() public view {
        // Test that constructor correctly sets the pool manager
    }

    function test_constructor_revertsOnZeroPoolManager() public {
        // Test that constructor reverts when pool manager is zero address
    }

    function test_constructor_revertsOnZeroRegistry() public {
        // Test that constructor reverts when registry is zero address
    }

    function test_constructor_revertsOnZeroAccessManager() public {
        // Test that constructor reverts when access manager is zero address
    }

    function test_constructor_registersInRegistry() public view {
        // Test that constructor registers the hook in the registry
    }

    function test_constructor_startsPaused() public view {
        // Test that hook starts in paused state
    }

    // Initialization tests
    function test_initialize_setsLogic() public {
        // Test that initialize correctly sets the logic contract
    }

    function test_initialize_revertsOnZeroLogic() public {
        // Test that initialize reverts when logic address is zero
    }

    function test_initialize_revertsWhenAlreadyInitialized() public {
        // Test that initialize reverts on second call
    }

    function test_initialize_revertsWhenNotOwner() public {
        // Test that initialize reverts when called by non-owner
    }

    function test_initialize_unpauses() public {
        // Test that initialize unpauses the contract
    }

    function test_initialize_registersLogicInRegistry() public {
        // Test that initialize registers logic in registry
    }

    // Hook permission tests
    function test_getHookPermissions_returnsCorrectFlags() public view {
        // Test that getHookPermissions returns correct permission flags
    }

    // afterInitialize hook tests
    function test_afterInitialize_activatesPool() public {
        // Test that afterInitialize activates the pool
    }

    function test_afterInitialize_revertsWhenPaused() public {
        // Test that afterInitialize reverts when contract is paused
    }

    function test_afterInitialize_revertsWithInvalidHook() public {
        // Test that afterInitialize reverts with invalid hook address
    }

    function test_afterInitialize_setsInitialDynamicFee() public {
        // Test that afterInitialize sets the initial dynamic fee
    }

    function test_afterInitialize_emitsPoolActivated() public {
        // Test that afterInitialize emits PoolActivated event
    }

    // beforeSwap hook tests
    function test_beforeSwap_updatesFeeBasedOnRatio() public {
        // Test that beforeSwap updates fee based on pool ratio
    }

    function test_beforeSwap_revertsWhenPaused() public {
        // Test that beforeSwap reverts when contract is paused
    }

    function test_beforeSwap_handlesCooldownPeriod() public {
        // Test that beforeSwap respects cooldown period
    }

    function test_beforeSwap_emitsFeeUpdated() public {
        // Test that beforeSwap emits FeeUpdated event
    }

    // Poke function tests
    function test_poke_updatesDynamicFee() public {
        // Test that poke updates the dynamic fee
    }

    function test_poke_revertsWhenUnauthorized() public {
        // Test that poke reverts when caller lacks FEE_POKER_ROLE
    }

    function test_poke_revertsWhenPaused() public {
        // Test that poke reverts when contract is paused
    }

    function test_poke_revertsWithInvalidPool() public {
        // Test that poke reverts with invalid pool
    }

    // Pause/Unpause tests
    function test_pause_pausesContract() public {
        // Test that pause correctly pauses the contract
    }

    function test_pause_revertsWhenNotOwner() public {
        // Test that pause reverts when called by non-owner
    }

    function test_unpause_unpausesContract() public {
        // Test that unpause correctly unpauses the contract
    }

    function test_unpause_revertsWhenNotOwner() public {
        // Test that unpause reverts when called by non-owner
    }

    // Logic update tests
    function test_setLogic_updatesLogicAddress() public {
        // Test that setLogic updates the logic contract address
    }

    function test_setLogic_revertsOnZeroAddress() public {
        // Test that setLogic reverts on zero address
    }

    function test_setLogic_revertsWhenUnauthorized() public {
        // Test that setLogic reverts when caller unauthorized
    }

    function test_setLogic_emitsLogicUpdated() public {
        // Test that setLogic emits LogicUpdated event
    }

    function test_setLogic_updatesRegistryContract() public {
        // Test that setLogic updates the registry
    }

    // Registry update tests
    function test_setRegistry_updatesRegistryAddress() public {
        // Test that setRegistry updates the registry address
    }

    function test_setRegistry_revertsOnInvalidInterface() public {
        // Test that setRegistry reverts on invalid interface
    }

    function test_setRegistry_revertsWhenUnauthorized() public {
        // Test that setRegistry reverts when caller unauthorized
    }

    function test_setRegistry_emitsRegistryUpdated() public {
        // Test that setRegistry emits RegistryUpdated event
    }

    function test_setRegistry_registersContracts() public {
        // Test that setRegistry registers hook and logic in new registry
    }

    // Pool activation/deactivation tests
    function test_activatePool_activatesInactivePool() public {
        // Test that activatePool activates an inactive pool
    }

    function test_activatePool_revertsWhenAlreadyActive() public {
        // Test that activatePool reverts when pool already active
    }

    function test_activatePool_revertsWhenUnauthorized() public {
        // Test that activatePool reverts when caller unauthorized
    }

    function test_activatePool_emitsPoolActivated() public {
        // Test that activatePool emits PoolActivated event
    }

    function test_deactivatePool_deactivatesActivePool() public {
        // Test that deactivatePool deactivates an active pool
    }

    function test_deactivatePool_revertsWhenAlreadyInactive() public {
        // Test that deactivatePool reverts when pool already inactive
    }

    function test_deactivatePool_revertsWhenUnauthorized() public {
        // Test that deactivatePool reverts when caller unauthorized
    }

    function test_deactivatePool_emitsPoolDeactivated() public {
        // Test that deactivatePool emits PoolDeactivated event
    }

    // View function tests
    function test_getLogic_returnsCorrectAddress() public view {
        // Test that getLogic returns correct logic address
    }

    function test_getRegistry_returnsCorrectAddress() public view {
        // Test that getRegistry returns correct registry address
    }

    // Access control integration tests
    function test_restricted_onlyOwner() public {
        // Test that owner-restricted functions revert for non-owners
    }

    function test_restricted_accessManaged() public {
        // Test that access-managed functions revert for unauthorized callers
    }

    // Reentrancy protection tests
    function test_reentrancy_protected() public {
        // Test that functions are protected against reentrancy
    }

    // ERC165 support tests
    function test_supportsInterface_returnsTrue() public view {
        // Test that supportsInterface returns true for IAlphix
    }

    function test_supportsInterface_returnsFalse() public view {
        // Test that supportsInterface returns false for unsupported interfaces
    }
}
