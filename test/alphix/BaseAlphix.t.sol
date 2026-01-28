// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
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

/* LOCAL IMPORTS */
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Deployers} from "../utils/Deployers.sol";
import {Alphix} from "../../src/Alphix.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

/**
 * @title BaseAlphixTest
 * @author Alphix
 * @notice Base test contract for Alphix following Uniswap v4-template pattern
 * @dev Provides common setup and helper functions for all Alphix tests.
 *      Updated for simplified architecture: no AlphixLogic, no Registry, no proxy.
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
    uint64 constant FEE_POKER_ROLE = 1;
    uint64 constant YIELD_MANAGER_ROLE = 2;

    // Optional: derived safe cap if tests ever want to override logic default
    uint256 internal constant GLOBAL_MAX_ADJ_RATE_SAFE =
        (uint256(type(uint24).max) * 1e18) / uint256(LPFeeLibrary.MAX_LP_FEE);

    /// @dev Precomputed topic for FeeUpdated event - centralized to ensure consistency across all tests
    /// @dev Event signature: FeeUpdated(bytes32 indexed poolId, uint24 oldFee, uint24 newFee, uint256 oldTargetRatio, uint256 currentRatio, uint256 newTargetRatio)
    bytes32 internal constant FEE_UPDATED_TOPIC =
        keccak256("FeeUpdated(bytes32,uint24,uint24,uint256,uint256,uint256)");

    // Test addresses
    address public owner;
    address public user1;
    address public user2;
    address public unauthorized;

    // Alphix contracts (default stack wired in setUp)
    AccessManager public accessManager;
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

    // Default pool parameters (used for single-pool-per-hook architecture)
    DynamicFeeLib.PoolParams public defaultPoolParams;

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

        // Setup default pool params
        _initializeDefaultPoolParams();

        // Deploy a default Alphix Infrastructure (AccessManager + Hook)
        (accessManager, hook) = _deployAlphixInfrastructure(poolManager, owner);

        // Setup default tokens and pool (18 decimals)
        (currency0, currency1) = deployCurrencyPairWithDecimals(18, 18);

        // Create default pool key
        defaultTickSpacing = 20;
        // forge-lint: disable-next-line(named-struct-fields)
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, defaultTickSpacing, IHooks(hook));
        poolId = key.toId();

        // Initialize pool (Uniswap side)
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);

        // Initialize pool (Alphix side) with full-range tick bounds
        int24 initTickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 initTickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        hook.initializePool(key, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, initTickLower, initTickUpper);

        // Seed initial liquidity
        _seedInitialLiquidity();

        vm.stopPrank();
    }

    /**
     * @notice Initializes the default pool parameters
     * @dev Sets up default params for single-pool-per-hook architecture
     */
    function _initializeDefaultPoolParams() internal {
        defaultPoolParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001, // Wide range to support various pool types
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21, // 1000x
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });
    }

    /**
     * @notice Deploys a fresh Alphix Infrastructure
     * @param pm The pool manager to wire into the hook
     * @param alphixOwner The owner of the hook
     * @return am AccessManager instance
     * @return newHook Alphix hook
     */
    function _deployAlphixInfrastructure(IPoolManager pm, address alphixOwner)
        internal
        returns (AccessManager am, Alphix newHook)
    {
        // AccessManager
        am = new AccessManager(alphixOwner);

        // Deploy Alphix Hook (CREATE2)
        newHook = _deployAlphixHook(pm, alphixOwner, am);
    }

    /**
     * @notice Deploy an Alphix Hook
     * @param pm The pool manager to wire into the hook
     * @param alphixOwner The owner of the hook
     * @param am The AccessManager instance
     * @return newHook The deployed hook
     */
    function _deployAlphixHook(IPoolManager pm, address alphixOwner, AccessManager am)
        internal
        returns (Alphix newHook)
    {
        address hookAddr = _computeNextHookAddress();
        _setupAccessManagerRoles(hookAddr, am);
        bytes memory ctor = abi.encode(pm, alphixOwner, address(am), "Alphix LP Shares", "ALP");
        deployCodeTo("src/Alphix.sol:Alphix", ctor, hookAddr);
        newHook = Alphix(hookAddr);
    }

    /**
     * @notice Deploy a fresh Alphix infrastructure without initializing a pool.
     * @dev Used by tests that need to test pool initialization on a clean hook.
     *      Automatically pranks as owner during deployment.
     * @return freshHook The new hook
     */
    function _deployFreshAlphixStack() internal returns (Alphix freshHook) {
        // Deploy fresh infrastructure (must be as owner for AccessManager operations)
        vm.startPrank(owner);
        (, Alphix newHook) = _deployAlphixInfrastructure(poolManager, owner);
        vm.stopPrank();

        freshHook = newHook;
    }

    /**
     * @notice Deploy a fresh Alphix infrastructure without initializing a pool,
     *         returning also the AccessManager for role management.
     * @dev Used by tests that need access to the AccessManager for role manipulation.
     *      Automatically pranks as owner during deployment.
     * @return freshHook The new hook
     * @return freshAccessManager The new AccessManager for this hook
     */
    function _deployFreshAlphixStackFull() internal returns (Alphix freshHook, AccessManager freshAccessManager) {
        // Deploy fresh infrastructure (must be as owner for AccessManager operations)
        vm.startPrank(owner);
        (AccessManager freshAm, Alphix newHook) = _deployAlphixInfrastructure(poolManager, owner);
        vm.stopPrank();

        freshHook = newHook;
        freshAccessManager = freshAm;
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
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amount0Expected + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
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
     * @dev Creates currencies, pool key, initializes in Uniswap, and configures in Alphix.
     *      Uses defaultPoolParams for pool configuration.
     */
    function deployPoolWithDecimals(
        uint8 decimals0,
        uint8 decimals1,
        int24 tickSpacing,
        Alphix _hook,
        uint24 initialFee,
        uint256 targetRatio
    ) internal returns (PoolKey memory _key, PoolId _poolId) {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(decimals0, decimals1);
        // forge-lint: disable-next-line(named-struct-fields)
        _key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(_hook));
        _poolId = _key.toId();

        vm.prank(owner);
        poolManager.initialize(_key, Constants.SQRT_PRICE_1_1);
        int24 tickLower_ = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper_ = TickMath.maxUsableTick(tickSpacing);
        vm.prank(owner);
        _hook.initializePool(_key, initialFee, targetRatio, defaultPoolParams, tickLower_, tickUpper_);
        return (_key, _poolId);
    }

    /**
     * @notice Deploys a pool with custom token decimals and custom pool params
     * @dev Creates currencies, pool key, initializes in Uniswap, and configures in Alphix.
     */
    function deployPoolWithDecimalsAndParams(
        uint8 decimals0,
        uint8 decimals1,
        int24 tickSpacing,
        Alphix _hook,
        uint24 initialFee,
        uint256 targetRatio,
        DynamicFeeLib.PoolParams memory poolParams
    ) internal returns (PoolKey memory _key, PoolId _poolId) {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(decimals0, decimals1);
        // forge-lint: disable-next-line(named-struct-fields)
        _key = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(_hook));
        _poolId = _key.toId();

        vm.prank(owner);
        poolManager.initialize(_key, Constants.SQRT_PRICE_1_1);
        int24 tickLower_ = TickMath.minUsableTick(tickSpacing);
        int24 tickUpper_ = TickMath.maxUsableTick(tickSpacing);
        vm.prank(owner);
        _hook.initializePool(_key, initialFee, targetRatio, poolParams, tickLower_, tickUpper_);
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
            // forge-lint: disable-next-line(unsafe-typecast)
            data.priceRange = uint160(uint256(data.currentPrice) * rangePct / UNIT);
            data.lowerPrice = data.currentPrice - data.priceRange;
            data.upperPrice = data.currentPrice + data.priceRange;
            data._lowerTick = TickMath.getTickAtSqrtPrice(data.lowerPrice);
            data._upperTick = TickMath.getTickAtSqrtPrice(data.upperPrice);
            unchecked {
                int256 lowerTickRounded = data._lowerTick / int256(data.tickSpacing);
                int256 upperTickRounded = data._upperTick / int256(data.tickSpacing);
                // forge-lint: disable-next-line(unsafe-typecast)
                data.lowerTick = int24(lowerTickRounded * int256(data.tickSpacing));
                // forge-lint: disable-next-line(unsafe-typecast)
                data.upperTick = int24(upperTickRounded * int256(data.tickSpacing));
            }
        }

        data.liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            // forge-lint: disable-next-line(unsafe-typecast)
            data.currentPrice,
            // forge-lint: disable-next-line(unsafe-typecast)
            TickMath.getSqrtPriceAtTick(data.lowerTick),
            TickMath.getSqrtPriceAtTick(data.upperTick),
            amount0,
            // forge-lint: disable-next-line(unsafe-typecast)
            amount1
        );

        MockERC20(Currency.unwrap(_key.currency0)).approve(address(permit2), amount0 + 1);
        MockERC20(Currency.unwrap(_key.currency1)).approve(address(permit2), amount1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(_key.currency0), address(positionManager), uint160(amount0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
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
        // Grant poker role to owner (by default, tests can override)
        am.grantRole(FEE_POKER_ROLE, owner, 0);

        // Assign poker role to poke function on Hook
        bytes4[] memory pokeSelectors = new bytes4[](1);
        pokeSelectors[0] = Alphix(hookAddr).poke.selector;
        // forge-lint: disable-next-line(named-struct-fields)
        am.setTargetFunctionRole(hookAddr, pokeSelectors, FEE_POKER_ROLE);
    }

    /**
     * @notice Configure YIELD_MANAGER_ROLE for Alphix hook
     * @dev Grants the role to the specified address and sets function-level permissions
     * @param yieldManagerAddr The address to grant YIELD_MANAGER_ROLE
     * @param am The AccessManager instance
     * @param hookAddr The Alphix hook address
     */
    function _setupYieldManagerRole(address yieldManagerAddr, AccessManager am, address hookAddr) internal {
        // Grant yield manager role
        am.grantRole(YIELD_MANAGER_ROLE, yieldManagerAddr, 0);

        // Assign yield manager role to setYieldSource function on Alphix hook
        bytes4[] memory yieldManagerSelectors = new bytes4[](1);
        yieldManagerSelectors[0] = Alphix(hookAddr).setYieldSource.selector;
        am.setTargetFunctionRole(hookAddr, yieldManagerSelectors, YIELD_MANAGER_ROLE);
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
        // forge-lint: disable-next-line(named-struct-fields)
        k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(_hook));
        id = k.toId();
        vm.prank(_hook.owner());
        poolManager.initialize(k, initialPrice);
    }

    /**
     * @notice Create and initialize a pool in Alphix for a given hook with supplied params.
     * @dev Uses defaultPoolParams for pool configuration.
     * @param fee Initial dynamic LP fee
     * @param ratio Initial target ratio
     * @param d0 Decimals for token0
     * @param d1 Decimals for token1
     * @param spacing Tick spacing for the pool
     * @param initialPrice Sqrt price at initialization (X96)
     * @param _hook Hook to bind in the PoolKey (IHooks)
     */
    function _initPoolWithHook(
        uint24 fee,
        uint256 ratio,
        uint8 d0,
        uint8 d1,
        int24 spacing,
        uint160 initialPrice,
        Alphix _hook
    ) internal returns (PoolKey memory k, PoolId id) {
        (k, id) = _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, _hook);
        int24 tickLower_ = TickMath.minUsableTick(spacing);
        int24 tickUpper_ = TickMath.maxUsableTick(spacing);
        vm.prank(_hook.owner());
        _hook.initializePool(k, fee, ratio, defaultPoolParams, tickLower_, tickUpper_);
    }

    /**
     * @notice Create and initialize a pool in Alphix for a given hook with custom pool params.
     * @param fee Initial dynamic LP fee
     * @param ratio Initial target ratio
     * @param d0 Decimals for token0
     * @param d1 Decimals for token1
     * @param spacing Tick spacing for the pool
     * @param initialPrice Sqrt price at initialization (X96)
     * @param _hook Hook to bind in the PoolKey (IHooks)
     * @param poolParams Custom pool parameters
     */
    function _initPoolWithHookAndParams(
        uint24 fee,
        uint256 ratio,
        uint8 d0,
        uint8 d1,
        int24 spacing,
        uint160 initialPrice,
        Alphix _hook,
        DynamicFeeLib.PoolParams memory poolParams
    ) internal returns (PoolKey memory k, PoolId id) {
        (k, id) = _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, _hook);
        int24 tickLower_ = TickMath.minUsableTick(spacing);
        int24 tickUpper_ = TickMath.maxUsableTick(spacing);
        vm.prank(_hook.owner());
        _hook.initializePool(k, fee, ratio, poolParams, tickLower_, tickUpper_);
    }

    /**
     * @notice Create and initialize a pool in Alphix with custom tick range.
     * @dev Used by tests that need specific JIT tick ranges.
     * @param fee Initial dynamic LP fee
     * @param ratio Initial target ratio
     * @param d0 Decimals for token0
     * @param d1 Decimals for token1
     * @param spacing Tick spacing for the pool
     * @param initialPrice Sqrt price at initialization (X96)
     * @param _hook Hook to bind in the PoolKey (IHooks)
     * @param _tickLower Lower tick boundary for JIT liquidity
     * @param _tickUpper Upper tick boundary for JIT liquidity
     */
    function _initPoolWithHookAndTickRange(
        uint24 fee,
        uint256 ratio,
        uint8 d0,
        uint8 d1,
        int24 spacing,
        uint160 initialPrice,
        Alphix _hook,
        int24 _tickLower,
        int24 _tickUpper
    ) internal returns (PoolKey memory k, PoolId id) {
        (k, id) = _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, _hook);
        vm.prank(_hook.owner());
        _hook.initializePool(k, fee, ratio, defaultPoolParams, _tickLower, _tickUpper);
    }

    /**
     * @notice Calls modifyLiquidities expecting a specific revert.
     * @dev Mirrors PositionManager mint internals to ensure the next external call is the failing one.
     */
    function _expectRevertOnModifyLiquiditiesMint(
        PoolKey memory k,
        int24 tl,
        int24 tu,
        uint256 liquidityAmount,
        uint256 amt0Max,
        uint256 amt1Max,
        address recipient
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(0), // Actions.MINT_POSITION
            uint8(4), // Actions.SETTLE_PAIR
            uint8(5), // Actions.SWEEP
            uint8(5) // Actions.SWEEP
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(k, tl, tu, liquidityAmount, amt0Max, amt1Max, recipient, Constants.ZERO_BYTES);
        params[1] = abi.encode(k.currency0, k.currency1);
        params[2] = abi.encode(k.currency0, recipient);
        params[3] = abi.encode(k.currency1, recipient);

        vm.expectRevert();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }

    /**
     * @notice Expects decreaseLiquidity path to revert with a specific selector by calling modifyLiquidities directly
     * @dev Mirrors PositionManager.decreaseLiquidity internals (Actions.DECREASE_LIQUIDITY + TAKE_PAIR)
     */
    function _expectRevertOnModifyLiquiditiesDecrease(
        uint256 _tokenId,
        uint256 liquidityToRemove,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient
    ) internal {
        (Currency c0, Currency c1) = positionManager.getCurrencies(_tokenId);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(_tokenId, liquidityToRemove, amount0Min, amount1Min, Constants.ZERO_BYTES);
        params[1] = abi.encode(c0, c1, recipient);

        bytes memory actions = abi.encodePacked(
            uint8(1), // Actions.DECREASE_LIQUIDITY
            uint8(7) // Actions.TAKE_PAIR
        );

        vm.expectRevert();
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
    }
}
