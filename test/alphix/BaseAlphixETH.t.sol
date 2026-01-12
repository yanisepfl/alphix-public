// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* LOCAL IMPORTS */
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Deployers} from "../utils/Deployers.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";
import {AlphixLogicETH} from "../../src/AlphixLogicETH.sol";
import {Registry} from "../../src/Registry.sol";
import {IAlphixLogic} from "../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";
import {MockWETH9} from "../utils/mocks/MockWETH9.sol";

/**
 * @title BaseAlphixETHTest
 * @author Alphix
 * @notice Base test contract for AlphixETH (native ETH pools) tests
 * @dev Provides common setup and helper functions for all AlphixETH tests
 */
abstract contract BaseAlphixETHTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using FullMath for uint256;

    /**
     * @notice Struct to avoid stack too deep errors in complex operations
     */
    struct TestData {
        int24 tickSpacing;
        int24 lowerTick;
        int24 upperTick;
        uint160 currentPrice;
        uint160 lowerPrice;
        uint160 upperPrice;
        uint160 priceRange;
        int24 currentTick;
        int256 tick;
        int256 delta;
        int256 _lowerTick;
        int256 _upperTick;
        uint128 liquidityAmount;
        uint256 newTokenId;
    }

    // Constants
    uint256 constant INITIAL_TOKEN_AMOUNT = 1_000_000e18;
    uint24 constant INITIAL_FEE = 500; // 0.05%
    uint256 constant INITIAL_TARGET_RATIO = 5e17; // 50%
    uint256 constant UNIT = 1e18;
    uint64 constant FEE_POKER_ROLE = 1;
    uint64 constant REGISTRAR_ROLE = 2;
    uint64 constant YIELD_MANAGER_ROLE = 3;

    // Optional: derived safe cap if tests ever want to override logic default
    uint256 internal constant GLOBAL_MAX_ADJ_RATE_SAFE =
        (uint256(type(uint24).max) * 1e18) / uint256(LPFeeLibrary.MAX_LP_FEE);

    /// @dev Precomputed topic for FeeUpdated event
    bytes32 internal constant FEE_UPDATED_TOPIC =
        keccak256("FeeUpdated(bytes32,uint24,uint24,uint256,uint256,uint256)");

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // AlphixETH contracts (default stack wired in setUp)
    AccessManager public accessManager;
    Registry public registry;
    AlphixETH public hook;
    AlphixLogicETH public logicImplementation;
    ERC1967Proxy public logicProxy;
    IAlphixLogic public logic;
    MockWETH9 public weth;

    // Default test tokens and pool
    Currency public ethCurrency; // Native ETH (address(0))
    Currency public tokenCurrency; // ERC20 token
    MockERC20 public token;
    PoolKey public key;
    PoolId public poolId;
    uint256 public tokenId;
    int24 public tickLower;
    int24 public tickUpper;
    int24 public defaultTickSpacing;

    // Default pool parameters
    DynamicFeeLib.PoolParams public defaultPoolParams;

    // Namespace so each hook salt/address is unique
    uint16 private hookNamespace;

    /**
     * @notice Sets up the test environment with AlphixETH ecosystem
     * @dev Deploys Uniswap v4 infrastructure, AlphixETH contracts, an ETH pool and seeds it with initial liquidity
     */
    function setUp() public virtual {
        // Deploy Uniswap v4 infrastructure (Permit2, PoolManager, PositionManager and Router)
        deployArtifacts();

        // Setup test addresses
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // Give ETH to test addresses
        vm.deal(owner, 1000 ether);
        vm.deal(user1, 1000 ether);
        vm.deal(user2, 1000 ether);

        // setup initial Hook namespace (so each hook is unique)
        hookNamespace = 0x5555;

        vm.startPrank(owner);

        // Deploy WETH mock
        weth = new MockWETH9();

        // Setup default pool params
        _initializeDefaultPoolParams();

        // Deploy a default AlphixETH Infrastructure (AccessManager, Registry, Hook, Logic)
        (accessManager, registry, hook, logicImplementation, logicProxy, logic) =
            _deployAlphixEthInfrastructure(poolManager, owner);

        // Setup ETH pool currencies
        ethCurrency = Currency.wrap(address(0)); // Native ETH
        token = new MockERC20("Test Token", "TKN", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint tokens to test addresses
        token.mint(owner, INITIAL_TOKEN_AMOUNT);
        token.mint(user1, INITIAL_TOKEN_AMOUNT);
        token.mint(user2, INITIAL_TOKEN_AMOUNT);

        // Create default ETH pool key (ETH must be currency0 as it's address(0))
        defaultTickSpacing = 20;
        key = PoolKey({
            currency0: ethCurrency,
            currency1: tokenCurrency,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(hook)
        });
        poolId = key.toId();

        // Initialize pool (Uniswap side)
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Initialize pool (Alphix side)
        hook.initializePool(key, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        vm.stopPrank();
    }

    /**
     * @notice Initializes the default pool parameters
     */
    function _initializeDefaultPoolParams() internal {
        defaultPoolParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });
    }

    /**
     * @notice Deploys a fresh AlphixETH Infrastructure
     */
    function _deployAlphixEthInfrastructure(IPoolManager pm, address alphixOwner)
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
        am = new AccessManager(alphixOwner);
        reg = new Registry(address(am));

        // Deploy AlphixETH Hook (CREATE2, + constructor pauses)
        newHook = _deployAlphixEthHook(pm, alphixOwner, am, reg);

        // Logic implementation + proxy
        (impl, proxy, newLogic) = _deployAlphixLogicEth(alphixOwner, address(newHook), address(am));

        // Finalize Hook initialization (unpauses)
        newHook.initialize(address(newLogic));
    }

    /**
     * @notice Deploy an AlphixETH Hook
     */
    function _deployAlphixEthHook(IPoolManager pm, address alphixOwner, AccessManager am, Registry reg)
        internal
        returns (AlphixETH newHook)
    {
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, am, reg);
        bytes memory ctor = abi.encode(pm, alphixOwner, address(am), address(reg));
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        newHook = AlphixETH(payable(hookAddr));
    }

    /**
     * @notice Deploy AlphixLogicETH
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
     * @notice Deploy a fresh AlphixETH stack without pool initialization
     */
    function _deployFreshAlphixEthStack() internal returns (AlphixETH freshHook, IAlphixLogic freshLogic) {
        vm.startPrank(owner);
        (,, AlphixETH newHook,,, IAlphixLogic newLogic) = _deployAlphixEthInfrastructure(poolManager, owner);
        vm.stopPrank();

        freshHook = newHook;
        freshLogic = newLogic;
    }

    /**
     * @notice Deploy a fresh AlphixETH stack returning all components
     */
    function _deployFreshAlphixEthStackFull()
        internal
        returns (AlphixETH freshHook, IAlphixLogic freshLogic, AccessManager freshAccessManager, Registry freshRegistry)
    {
        vm.startPrank(owner);
        (AccessManager freshAm, Registry freshReg, AlphixETH newHook,,, IAlphixLogic newLogic) =
            _deployAlphixEthInfrastructure(poolManager, owner);
        vm.stopPrank();

        freshHook = newHook;
        freshLogic = newLogic;
        freshAccessManager = freshAm;
        freshRegistry = freshReg;
    }

    /**
     * @notice Deploys a new ERC20 token for ETH pool testing
     */
    function deployEthPoolToken(uint8 decimals) internal returns (Currency) {
        MockERC20 newToken = new MockERC20("ETH Pool Token", "EPT", decimals);
        newToken.mint(owner, INITIAL_TOKEN_AMOUNT);
        newToken.mint(user1, INITIAL_TOKEN_AMOUNT);
        newToken.mint(user2, INITIAL_TOKEN_AMOUNT);
        return Currency.wrap(address(newToken));
    }

    /**
     * @notice Creates an ETH pool key with a given token
     */
    function createEthPoolKey(Currency tokenCurr, int24 tickSpacing, AlphixETH _hook)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: tokenCurr,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(_hook)
        });
    }

    /* Internal */

    /**
     * @notice Compute a unique, permission-correct hook address
     */
    function _computeNextHookAddress() internal returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 ns = uint160(hookNamespace++) << 144;
        return address(flags ^ ns);
    }

    /**
     * @notice Sets up AccessManager roles for the registry and hook
     */
    function _setupAccessManagerRoles(address hookAddr, AccessManager am, Registry reg) internal {
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
     * @notice Configure YIELD_MANAGER_ROLE for AlphixLogicETH
     */
    function _setupYieldManagerRole(address yieldManagerAddr, AccessManager am, address payable logicAddr) internal {
        // Grant yield manager role
        am.grantRole(YIELD_MANAGER_ROLE, yieldManagerAddr, 0);

        // Assign yield manager role to specific functions on AlphixLogicETH
        bytes4[] memory yieldManagerSelectors = new bytes4[](4);
        yieldManagerSelectors[0] = AlphixLogicETH(logicAddr).setYieldSource.selector;
        yieldManagerSelectors[1] = AlphixLogicETH(logicAddr).setTickRange.selector;
        yieldManagerSelectors[2] = AlphixLogicETH(logicAddr).setYieldTaxPips.selector;
        yieldManagerSelectors[3] = AlphixLogicETH(logicAddr).setYieldTreasury.selector;
        am.setTargetFunctionRole(logicAddr, yieldManagerSelectors, YIELD_MANAGER_ROLE);
    }

    /**
     * @notice Create a new Uniswap ETH pool bound to a given hook without configuring it.
     */
    function _newUninitializedEthPoolWithHook(uint8 tokenDecimals, int24 spacing, uint160 initialPrice, AlphixETH _hook)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        Currency tokenCurr = deployEthPoolToken(tokenDecimals);
        k = createEthPoolKey(tokenCurr, spacing, _hook);
        id = k.toId();
        poolManager.initialize(k, initialPrice);
    }

    /**
     * @notice Create and initialize an ETH pool in Alphix for a given hook.
     */
    function _initEthPoolWithHook(
        uint24 fee,
        uint256 ratio,
        uint8 tokenDecimals,
        int24 spacing,
        uint160 initialPrice,
        AlphixETH _hook
    ) internal returns (PoolKey memory k, PoolId id) {
        (k, id) = _newUninitializedEthPoolWithHook(tokenDecimals, spacing, initialPrice, _hook);
        vm.prank(_hook.owner());
        _hook.initializePool(k, fee, ratio, defaultPoolParams);
    }
}
