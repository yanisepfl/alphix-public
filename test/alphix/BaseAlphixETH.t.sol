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

/* LOCAL IMPORTS */
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Deployers} from "../utils/Deployers.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

/**
 * @title BaseAlphixETHTest
 * @author Alphix
 * @notice Base test contract for AlphixETH (native ETH pools) tests
 * @dev Provides common setup and helper functions for all AlphixETH tests.
 *      Updated for simplified architecture: no AlphixLogicETH, no Registry, no proxy.
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
    AlphixETH public hook;

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

        // Setup default pool params
        _initializeDefaultPoolParams();

        // Deploy a default AlphixETH Infrastructure (AccessManager + Hook)
        (accessManager, hook) = _deployAlphixEthInfrastructure(poolManager, owner);

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
     * @param pm The pool manager to wire into the hook
     * @param alphixOwner The owner of the hook
     * @return am AccessManager instance
     * @return newHook AlphixETH hook
     */
    function _deployAlphixEthInfrastructure(IPoolManager pm, address alphixOwner)
        internal
        returns (AccessManager am, AlphixETH newHook)
    {
        // AccessManager
        am = new AccessManager(alphixOwner);

        // Deploy AlphixETH Hook (CREATE2)
        newHook = _deployAlphixEthHook(pm, alphixOwner, am);
    }

    /**
     * @notice Deploy an AlphixETH Hook
     * @param pm The pool manager to wire into the hook
     * @param alphixOwner The owner of the hook
     * @param am The AccessManager instance
     * @return newHook The deployed hook
     */
    function _deployAlphixEthHook(IPoolManager pm, address alphixOwner, AccessManager am)
        internal
        returns (AlphixETH newHook)
    {
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, am);
        bytes memory ctor = abi.encode(pm, alphixOwner, address(am), "Alphix ETH LP Shares", "AELP");
        deployCodeTo("src/AlphixETH.sol:AlphixETH", ctor, hookAddr);
        newHook = AlphixETH(payable(hookAddr));
    }

    /**
     * @notice Deploy a fresh AlphixETH stack without pool initialization
     * @return freshHook The new hook
     */
    function _deployFreshAlphixEthStack() internal returns (AlphixETH freshHook) {
        vm.startPrank(owner);
        (, AlphixETH newHook) = _deployAlphixEthInfrastructure(poolManager, owner);
        vm.stopPrank();

        freshHook = newHook;
    }

    /**
     * @notice Deploy a fresh AlphixETH stack returning all components
     * @return freshHook The new hook
     * @return freshAccessManager The new AccessManager for this hook
     */
    function _deployFreshAlphixEthStackFull() internal returns (AlphixETH freshHook, AccessManager freshAccessManager) {
        vm.startPrank(owner);
        (AccessManager freshAm, AlphixETH newHook) = _deployAlphixEthInfrastructure(poolManager, owner);
        vm.stopPrank();

        freshHook = newHook;
        freshAccessManager = freshAm;
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
        // Only set flags for enabled hooks - must match getHookPermissions()
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint160 ns = uint160(hookNamespace++) << 144;
        return address(flags ^ ns);
    }

    /**
     * @notice Sets up AccessManager roles for the hook
     * @dev Grants poker role to owner, sets function-level permissions
     */
    function _setupAccessManagerRoles(address hookAddr, AccessManager am) internal {
        // Grant poker role to owner
        am.grantRole(FEE_POKER_ROLE, owner, 0);

        // Assign poker role to poke function on Hook
        bytes4[] memory pokeSelectors = new bytes4[](1);
        pokeSelectors[0] = AlphixETH(payable(hookAddr)).poke.selector;
        am.setTargetFunctionRole(hookAddr, pokeSelectors, FEE_POKER_ROLE);
    }

    /**
     * @notice Configure YIELD_MANAGER_ROLE for AlphixETH hook
     * @dev Grants the role to the specified address and sets function-level permissions
     * @param yieldManagerAddr The address to grant YIELD_MANAGER_ROLE
     * @param am The AccessManager instance
     * @param hookAddr The AlphixETH hook address
     */
    function _setupYieldManagerRole(address yieldManagerAddr, AccessManager am, address hookAddr) internal {
        // Grant yield manager role
        am.grantRole(YIELD_MANAGER_ROLE, yieldManagerAddr, 0);

        // Assign yield manager role to specific functions on AlphixETH hook
        bytes4[] memory yieldManagerSelectors = new bytes4[](2);
        yieldManagerSelectors[0] = AlphixETH(payable(hookAddr)).setYieldSource.selector;
        yieldManagerSelectors[1] = AlphixETH(payable(hookAddr)).setTickRange.selector;
        am.setTargetFunctionRole(hookAddr, yieldManagerSelectors, YIELD_MANAGER_ROLE);
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
