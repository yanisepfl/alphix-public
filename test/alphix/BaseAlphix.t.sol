// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SortTokens} from "v4-core/test/utils/SortTokens.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* LOCAL IMPORTS */
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Deployers} from "../utils/Deployers.sol";

import {Alphix} from "../../src/Alphix.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";
import {Registry} from "../../src/Registry.sol";
import {IAlphixLogic} from "../../src/interfaces/IAlphixLogic.sol";

/**
 * @title BaseAlphixTest
 * @author Alphix
 * @notice Base test contract for Alphix following Uniswap v4-template pattern
 * @dev Provides common setup and helper functions for all Alphix tests
 */
abstract contract BaseAlphixTest is Test, Deployers {
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

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Alphix contracts (default stack wired in setUp)
    AccessManager public accessManager;
    Registry public registry;
    Alphix public hook;
    AlphixLogic public logicImplementation;
    ERC1967Proxy public logicProxy;
    IAlphixLogic public logic;

    // Default test tokens and pool
    Currency public currency0;
    Currency public currency1;
    PoolKey public key;
    PoolId public poolId;
    uint256 public tokenId;
    int24 public tickLower;
    int24 public tickUpper;
    int24 public defaultTickSpacing;

    // Pool type bounds
    IAlphixLogic.PoolTypeBounds public stableBounds;
    IAlphixLogic.PoolTypeBounds public standardBounds;
    IAlphixLogic.PoolTypeBounds public volatileBounds;

    // Namespace so each hook salt/address is unique
    uint16 private hookNamespace;

    /**
     * @notice Sets up the test environment with Alphix ecosystem
     * @dev Deploys Uniswap v4 infrastructure, Alphix contracts, a pool and seeds it with initial liquidity
     */
    function setUp() public virtual {
        // Deploy Uniswap v4 infrastructure (Permit2, PoolManager, PositionManager and Router)
        deployArtifacts();

        // Setup test addresses
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        unauthorized = makeAddr("unauthorized");

        // setup initial Hook namespace (so each hook is unique)
        hookNamespace = 0x4444;

        vm.startPrank(owner);

        // Setup pool type bounds
        _initializePoolTypeBounds();

        // Deploy a default Alphix Infrastructure (AccessManager, Registry, Hook, Logic)
        (accessManager, registry, hook, logicImplementation, logicProxy, logic) =
            _deployAlphixInfrastructure(poolManager, owner);

        // Setup default tokens and pool (18 decimals)
        (currency0, currency1) = deployCurrencyPairWithDecimals(18, 18);

        // Create default pool key
        defaultTickSpacing = 20;
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, defaultTickSpacing, IHooks(hook));
        poolId = key.toId();

        // Initialize pool (Uniswap side)
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Initialize pool (Alphix side)
        hook.initializePool(key, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);

        // Seed initial liquidity
        _seedInitialLiquidity();

        vm.stopPrank();
    }

    /**
     * @notice Initializes the fee bounds for different pool types
     * @dev Sets up stable, standard, and volatile pool bounds
     */
    function _initializePoolTypeBounds() internal {
        stableBounds = IAlphixLogic.PoolTypeBounds({minFee: 100, maxFee: 1000});
        standardBounds = IAlphixLogic.PoolTypeBounds({minFee: 500, maxFee: 10000});
        volatileBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: 50000});
    }

    /**
     * @notice Deploys a fresh Alphix Infrastructure
     * @param pm The pool manager to wire into the hook
     * @param alphixOwner The owner of the hook and logic proxy
     * @return am AccessManager instance
     * @return reg Registry instance
     * @return newHook Alphix hook
     * @return impl AlphixLogic implementation
     * @return proxy ERC1967 proxy pointing to AlphixLogic
     * @return newLogic IAlphixLogic interface for the proxy
     */
    function _deployAlphixInfrastructure(IPoolManager pm, address alphixOwner)
        internal
        returns (
            AccessManager am,
            Registry reg,
            Alphix newHook,
            AlphixLogic impl,
            ERC1967Proxy proxy,
            IAlphixLogic newLogic
        )
    {
        // AccessManager + Registry
        am = new AccessManager(alphixOwner);
        reg = new Registry(address(am));

        // Deploy Alphix Hook (CREATE2, + constructor pauses)
        newHook = _deployAlphixHook(pm, alphixOwner, am, reg);

        // Logic implementation + proxy
        (impl, proxy, newLogic) = _deployAlphixLogic(alphixOwner, address(newHook));

        // Finalize Hook initialization (unpauses)
        newHook.initialize(address(newLogic));
    }

    /**
     * @notice Deploy an Alphix Hook
     * @param pm The pool manager to wire into the hook
     * @param alphixOwner The owner of the hook
     * @param am The AccessManager instance
     * @param reg The Registry instance
     * @return newHook The deployed hook
     */
    function _deployAlphixHook(IPoolManager pm, address alphixOwner, AccessManager am, Registry reg)
        internal
        returns (Alphix newHook)
    {
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, am, reg);
        bytes memory ctor = abi.encode(pm, alphixOwner, address(reg));
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        newHook = Alphix(hookAddr);
    }

    /**
     * @notice Deploy Alphix Logic
     * @dev Deploys implementation and proxy and initializes it with provided owner and hook
     * @param alphixOwner The logic admin
     * @param hookAddr The hook address to wire
     * @return impl AlphixLogic implementation
     * @return proxy ERC1967Proxy instance
     * @return newLogic IAlphixLogic interface
     */
    function _deployAlphixLogic(address alphixOwner, address hookAddr)
        internal
        returns (AlphixLogic impl, ERC1967Proxy proxy, IAlphixLogic newLogic)
    {
        impl = new AlphixLogic();
        bytes memory initData = abi.encodeCall(
            impl.initialize, (alphixOwner, hookAddr, INITIAL_FEE, stableBounds, standardBounds, volatileBounds)
        );
        proxy = new ERC1967Proxy(address(impl), initData);
        newLogic = IAlphixLogic(address(proxy));
    }

    /**
     * @notice Seeds initial liquidity to the default pool
     * @dev Provides full-range liquidity
     */
    function _seedInitialLiquidity() internal {
        tickLower = TickMath.minUsableTick(defaultTickSpacing);
        tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        uint128 liquidityAmount = 100e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        // Handling Approvals with Permit2
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amount0Expected + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amount1Expected + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amount0Expected + 1), expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amount1Expected + 1), expiry);

        (tokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            Constants.ZERO_BYTES
        );
    }

    /* HELPER FUNCTIONS */

    /**
     * @notice Deploys a currency pair with custom decimals
     * @dev Creates two MockERC20 tokens, sorts them, and mints tokens to test addresses
     */
    function deployCurrencyPairWithDecimals(uint8 decimals0, uint8 decimals1) internal returns (Currency, Currency) {
        Currency raw0 = Currency.wrap(address(new MockERC20("Alphix Test Token 0", "ATT0", decimals0)));
        Currency raw1 = Currency.wrap(address(new MockERC20("Alphix Test Token 1", "ATT1", decimals1)));
        (Currency sorted0, Currency sorted1) =
            SortTokens.sort(MockERC20(Currency.unwrap(raw0)), MockERC20(Currency.unwrap(raw1)));
        MockERC20(Currency.unwrap(sorted0)).mint(owner, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sorted1)).mint(owner, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sorted0)).mint(user1, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sorted1)).mint(user1, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sorted0)).mint(user2, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sorted1)).mint(user2, INITIAL_TOKEN_AMOUNT);
        return (sorted0, sorted1);
    }

    /**
     * @notice Deploys a pool with custom token decimals and initializes it in Alphix
     * @dev Creates currencies, pool key, initializes in Uniswap, and configures in Alphix
     */
    function deployPoolWithDecimals(
        uint8 decimals0,
        uint8 decimals1,
        int24 tickSpacing,
        Alphix _hook,
        IAlphixLogic.PoolType poolType,
        uint24 initialFee,
        uint256 targetRatio
    ) internal returns (PoolKey memory _key, PoolId _poolId) {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(decimals0, decimals1);
        _key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(_hook));
        _poolId = _key.toId();

        poolManager.initialize(_key, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        _hook.initializePool(_key, initialFee, targetRatio, poolType);
        return (_key, _poolId);
    }

    /**
     * @notice Seeds liquidity to a pool with customizable parameters
     * @dev Supports both full-range and custom range liquidity positions
     */
    function seedLiquidity(
        PoolKey memory _key,
        address receiver,
        bool fullRange,
        uint256 rangePct,
        uint256 amount0,
        uint256 amount1
    ) internal returns (uint256) {
        TestData memory data;
        data.tickSpacing = _key.tickSpacing;
        (data.currentPrice, data.currentTick,,) = poolManager.getSlot0(_key.toId());

        if (fullRange || rangePct >= UNIT) {
            data.lowerTick = TickMath.minUsableTick(data.tickSpacing);
            data.upperTick = TickMath.maxUsableTick(data.tickSpacing);
        } else {
            data.priceRange = uint160(uint256(data.currentPrice) * rangePct / UNIT);
            data.lowerPrice = data.currentPrice - data.priceRange;
            data.upperPrice = data.currentPrice + data.priceRange;
            data._lowerTick = TickMath.getTickAtSqrtPrice(data.lowerPrice);
            data._upperTick = TickMath.getTickAtSqrtPrice(data.upperPrice);
            unchecked {
                data.lowerTick = int24((data._lowerTick / int256(data.tickSpacing)) * int256(data.tickSpacing));
                data.upperTick = int24((data._upperTick / int256(data.tickSpacing)) * int256(data.tickSpacing));
            }
        }

        data.liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            data.currentPrice,
            TickMath.getSqrtPriceAtTick(data.lowerTick),
            TickMath.getSqrtPriceAtTick(data.upperTick),
            amount0,
            amount1
        );

        MockERC20(Currency.unwrap(_key.currency0)).approve(address(permit2), amount0 + 1);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(permit2), amount1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(_key.currency0), address(positionManager), uint160(amount0 + 1), expiry);
        permit2.approve(Currency.unwrap(_key.currency1), address(positionManager), uint160(amount1 + 1), expiry);

        (data.newTokenId,) = positionManager.mint(
            _key,
            data.lowerTick,
            data.upperTick,
            data.liquidityAmount,
            amount0 + 1,
            amount1 + 1,
            receiver,
            block.timestamp,
            Constants.ZERO_BYTES
        );
        return data.newTokenId;
    }

    /* Internal */

    /**
     * @notice Compute a unique, permission-correct hook address
     * @dev Encodes v4 hook permissions into the low bits and namespaces the high bits to avoid collisions
     */
    function _computeNextHookAddress() internal returns (address) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        uint160 ns = uint160(hookNamespace++) << 144;
        return address(flags ^ ns);
    }

    /**
     * @notice Sets up AccessManager roles for the registry
     * @dev Grants registrar role to Hook and sets function-level permissions
     */
    function _setupAccessManagerRoles(address hookAddr, AccessManager am, Registry reg) internal {
        uint64 REGISTRAR_ROLE = 1;

        // Grant registrar role to hook
        am.grantRole(REGISTRAR_ROLE, hookAddr, 0);

        // Assign role to specific functions on Registry
        bytes4[] memory contractSelectors = new bytes4[](1);
        contractSelectors[0] = reg.registerContract.selector;
        am.setTargetFunctionRole(address(reg), contractSelectors, REGISTRAR_ROLE);

        bytes4[] memory poolSelectors = new bytes4[](1);
        poolSelectors[0] = reg.registerPool.selector;
        am.setTargetFunctionRole(address(reg), poolSelectors, REGISTRAR_ROLE);
    }

    /**
     * @notice Create a new Uniswap pool bound to a given hook without configuring it.
     * @param d0 Decimals for token0
     * @param d1 Decimals for token1
     * @param spacing Tick spacing for the pool
     * @param initialPrice Sqrt price at initialization (X96)
     * @param _hook Hook to bind in the PoolKey (IHooks)
     */
    function _newUninitializedPoolWithHook(uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice, Alphix _hook)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(d0, d1);
        k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(_hook));
        id = k.toId();
        poolManager.initialize(k, initialPrice);
    }

    /**
     * @notice Create and initialize a pool in Alphix for a given hook with supplied params.
     * @param ptype Pool type for Alphix configuration
     * @param fee Initial dynamic LP fee
     * @param ratio Initial target ratio
     * @param d0 Decimals for token0
     * @param d1 Decimals for token1
     * @param spacing Tick spacing for the pool
     * @param initialPrice Sqrt price at initialization (X96)
     * @param _hook Hook to bind in the PoolKey (IHooks)
     */
    function _initPoolWithHook(
        IAlphixLogic.PoolType ptype,
        uint24 fee,
        uint256 ratio,
        uint8 d0,
        uint8 d1,
        int24 spacing,
        uint160 initialPrice,
        Alphix _hook
    ) internal returns (PoolKey memory k, PoolId id) {
        (k, id) = _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, _hook);
        vm.prank(_hook.owner());
        _hook.initializePool(k, fee, ratio, ptype);
    }
}
