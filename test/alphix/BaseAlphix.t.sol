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
import {IAlphix} from "../../src/interfaces/IAlphix.sol";
import {IRegistry} from "../../src/interfaces/IRegistry.sol";

/**
 * @title BaseAlphixTest
 * @author Alphix
 * @notice Base test contract for Alphix following Uniswap v4-template pattern
 * @dev Provides common setup and helper functions for all Alphix tests.
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
    uint256 constant UNIT = 1e18; // Base unit

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Alphix contracts
    AccessManager public accessManager;
    Registry public registry;
    AlphixLogic public logicImplementation;
    ERC1967Proxy public logicProxy;
    IAlphixLogic public logic;
    Alphix public hook;

    // Default test tokens and pool
    Currency public currency0;
    Currency public currency1;
    PoolKey public key;
    PoolId public poolId;
    uint256 public tokenId;
    int24 public tickLower;
    int24 public tickUpper;
    int24 public defaultTickSpacing;

    // Namespace so each hook salt/address is unique
    uint16 private hookNamespace;

    // Pool type bounds
    IAlphixLogic.PoolTypeBounds public stableBounds;
    IAlphixLogic.PoolTypeBounds public standardBounds;
    IAlphixLogic.PoolTypeBounds public volatileBounds;

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

        // Deploy Alphix Infrastructure
        _deployAlphixInfrastructure();

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
        stableBounds = IAlphixLogic.PoolTypeBounds({
            minFee: 100, // 0.01%
            maxFee: 1000 // 0.1%
        });

        standardBounds = IAlphixLogic.PoolTypeBounds({
            minFee: 500, // 0.05%
            maxFee: 10000 // 1%
        });

        volatileBounds = IAlphixLogic.PoolTypeBounds({
            minFee: 1000, // 0.1%
            maxFee: 50000 // 5%
        });
    }

    /**
     * @notice Deploys the complete Alphix Infrastructure
     * @dev Deploys AccessManager, Registry, Alphix Hook and Logic
     */
    function _deployAlphixInfrastructure() internal {
        // Deploy AccessManager
        accessManager = new AccessManager(owner);

        // Deploy Registry
        registry = new Registry(address(accessManager));

        // Deploy Alphix Hook (following v4-template pattern) + Setup AccessManager roles
        hook = _deployAlphixHook();

        // Deploy AlphixLogic
        _deployAlphixLogic();

        // Initialize hook with logic address
        hook.initialize(address(logic));
    }

    /**
     * @notice Deploys the Alphix Hook with required flags
     * @dev Uses CREATE2 deployment pattern from v4-template
     * @return The deployed Alphix Hook contract
     */
    function _deployAlphixHook() internal returns (Alphix) {
        // Namespace built to get a unique hook address
        uint160 ns = uint160(hookNamespace) << 144;
        hookNamespace++;
        // Hook address built using flags (almost all are used for flexibility)
        address hookAddr = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            ) ^ ns // Namespace to avoid collisions
        );

        _setupAccessManagerRoles(hookAddr);

        bytes memory constructorArgs = abi.encode(poolManager, owner, address(registry));
        deployCodeTo("Alphix.sol:Alphix", constructorArgs, 0, hookAddr);
        return Alphix(hookAddr);
    }

    /**
     * @notice Deploys the AlphixLogic implementation and proxy
     */
    function _deployAlphixLogic() internal {
        // Deploy AlphixLogic implementation
        logicImplementation = new AlphixLogic();

        // Deploy AlphixLogic proxy
        bytes memory logicInitData = abi.encodeCall(
            logicImplementation.initialize,
            (owner, address(hook), INITIAL_FEE, stableBounds, standardBounds, volatileBounds)
        );

        logicProxy = new ERC1967Proxy(address(logicImplementation), logicInitData);
        logic = IAlphixLogic(address(logicProxy));
    }

    /**
     * @notice Sets up AccessManager roles for the registry
     * @dev Grants registrar role to Hook and sets function-level permissions
     * @param hookAddr The address of the Hook to grantRole to
     */
    function _setupAccessManagerRoles(address hookAddr) internal {
        uint64 REGISTRAR_ROLE = 1;

        // Grant registrar role to hook
        accessManager.grantRole(REGISTRAR_ROLE, address(hookAddr), 0);

        // Wrap each selector in a bytes4[] array
        bytes4[] memory contractSelectors = new bytes4[](1);
        contractSelectors[0] = registry.registerContract.selector;
        accessManager.setTargetFunctionRole(address(registry), contractSelectors, REGISTRAR_ROLE);

        bytes4[] memory poolSelectors = new bytes4[](1);
        poolSelectors[0] = registry.registerPool.selector;
        accessManager.setTargetFunctionRole(address(registry), poolSelectors, REGISTRAR_ROLE);
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

    /// HELPER FUNCTIONS ///

    /**
     * @notice Deploys a currency pair with custom decimals
     * @dev Creates two MockERC20 tokens, sorts them, and mints tokens to test addresses
     * @param decimals0 Number of decimals for the first token
     * @param decimals1 Number of decimals for the second token
     * @return currency0 The first sorted currency (lower address)
     * @return currency1 The second sorted currency (higher address)
     */
    function deployCurrencyPairWithDecimals(uint8 decimals0, uint8 decimals1) internal returns (Currency, Currency) {
        // Deploy test tokens
        Currency _currency0 = Currency.wrap(address(new MockERC20("Alphix Test Token 0", "ATT0", decimals0)));
        Currency _currency1 = Currency.wrap(address(new MockERC20("Alphix Test Token 1", "ATT1", decimals1)));

        // Sort tokens by address
        (Currency sortedCurrency0, Currency sortedCurrency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currency0)), MockERC20(Currency.unwrap(_currency1)));

        // Mint tokens to all test addresses
        MockERC20(Currency.unwrap(sortedCurrency0)).mint(owner, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sortedCurrency1)).mint(owner, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sortedCurrency0)).mint(user1, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sortedCurrency1)).mint(user1, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sortedCurrency0)).mint(user2, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(sortedCurrency1)).mint(user2, INITIAL_TOKEN_AMOUNT);

        return (sortedCurrency0, sortedCurrency1);
    }

    /**
     * @notice Deploys a pool with custom token decimals and initializes it in Alphix
     * @dev Creates currencies, pool key, initializes in Uniswap, and configures in Alphix
     * @param decimals0 Number of decimals for token0
     * @param decimals1 Number of decimals for token1
     * @param tickSpacing Tick spacing for the pool
     * @param poolType Pool type for Alphix configuration
     * @param initialFee Initial fee for the pool
     * @param targetRatio Target ratio for the pool
     * @return _key The created pool key
     * @return _poolId The pool identifier
     */
    function deployPoolWithDecimals(
        uint8 decimals0,
        uint8 decimals1,
        int24 tickSpacing,
        IAlphixLogic.PoolType poolType,
        uint24 initialFee,
        uint256 targetRatio
    ) internal returns (PoolKey memory _key, PoolId _poolId) {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(decimals0, decimals1);

        _key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(hook));
        _poolId = _key.toId();

        // Initialize pool in Uniswap
        poolManager.initialize(_key, Constants.SQRT_PRICE_1_1);

        // Initialize pool in Alphix
        vm.prank(owner);
        hook.initializePool(_key, initialFee, targetRatio, poolType);

        return (_key, _poolId);
    }

    /**
     * @notice Seeds liquidity to a pool with customizable parameters
     * @dev Supports both full-range and custom range liquidity positions
     * @param _key The pool key to add liquidity to
     * @param receiver Address that will receive the position NFT
     * @param fullRange Whether to use full tick range
     * @param rangePct Percentage range around current price (if not full range)
     * @param amount0 Amount of token0 to add as liquidity
     * @param amount1 Amount of token1 to add as liquidity
     * @return newTokenId The NFT token ID of the created position
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
            // Use full tick range
            data.lowerTick = TickMath.minUsableTick(data.tickSpacing);
            data.upperTick = TickMath.maxUsableTick(data.tickSpacing);
        } else {
            // Calculate custom range around current price
            data.priceRange = uint160(uint256(data.currentPrice).mulDiv(rangePct, UNIT));
            data.lowerPrice = data.currentPrice - data.priceRange;
            data.upperPrice = data.currentPrice + data.priceRange;
            data._lowerTick = TickMath.getTickAtSqrtPrice(data.lowerPrice);
            data._upperTick = TickMath.getTickAtSqrtPrice(data.upperPrice);

            // Round to nearest valid ticks
            unchecked {
                data.lowerTick = int24((data._lowerTick / int256(data.tickSpacing)) * int256(data.tickSpacing));
                data.upperTick = int24((data._upperTick / int256(data.tickSpacing)) * int256(data.tickSpacing));
            }
        }

        // Calculate liquidity amount
        data.liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            data.currentPrice,
            TickMath.getSqrtPriceAtTick(data.lowerTick),
            TickMath.getSqrtPriceAtTick(data.upperTick),
            amount0,
            amount1
        );

        // Handling Approvals with Permit2
        MockERC20(Currency.unwrap(_key.currency0)).approve(address(permit2), amount0 + 1);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(permit2), amount1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(_key.currency0), address(positionManager), uint160(amount0 + 1), expiry);
        permit2.approve(Currency.unwrap(_key.currency1), address(positionManager), uint160(amount1 + 1), expiry);

        // Mint the position
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
}
