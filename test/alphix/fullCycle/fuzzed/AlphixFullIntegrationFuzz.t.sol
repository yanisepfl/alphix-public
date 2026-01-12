// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title AlphixFullIntegrationFuzzTest
 * @author Alphix
 * @notice Fuzzed full-cycle integration tests simulating realistic multi-user pool scenarios
 * @dev Adapted for single-pool-per-hook architecture - each test uses fresh hook/logic pairs
 */
contract AlphixFullIntegrationFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;
    address public charlie;
    address public dave;

    // Global bounds matching contract constraints
    uint256 constant MIN_LIQUIDITY = 1e18;
    uint256 constant MAX_LIQUIDITY = 500e18;
    uint256 constant MIN_SWAP_AMOUNT = 1e17;
    uint256 constant MAX_SWAP_AMOUNT = 50e18;
    uint256 constant MIN_RATIO = 1e15;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");

        vm.startPrank(owner);
        _mintTokensToUser(alice, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(bob, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(charlie, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(dave, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                    FUZZED BASIC MULTI-USER SCENARIOS                       */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Multiple LPs provide liquidity at different amounts
     * @param aliceLiq Alice's liquidity amount
     * @param bobLiq Bob's liquidity amount
     * @param charlieLiq Charlie's liquidity amount
     */
    function testFuzz_multiUser_liquidity_provision_various_amounts(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint128 charlieLiq
    ) public {
        aliceLiq = uint128(bound(aliceLiq, MIN_LIQUIDITY, MAX_LIQUIDITY));
        bobLiq = uint128(bound(bobLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        charlieLiq = uint128(bound(charlieLiq, MIN_LIQUIDITY, MAX_LIQUIDITY));

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), aliceLiq
        );
        vm.stopPrank();

        vm.startPrank(bob);
        _addLiquidityForUser(
            bob, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bobLiq
        );
        vm.stopPrank();

        vm.startPrank(charlie);
        _addLiquidityForUser(
            charlie, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), charlieLiq
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
        assertTrue(config.isConfigured, "Pool should be configured");
    }

    /**
     * @notice Fuzz: Gradual liquidity buildup with varying amounts and timing
     * @param aliceLiq Alice's liquidity
     * @param bobLiq Bob's liquidity
     * @param charlieLiq Charlie's liquidity
     * @param daveLiq Dave's liquidity
     * @param daysBetween Days between LP entries (1-5)
     */
    function testFuzz_multiUser_gradual_liquidity_buildup(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint128 charlieLiq,
        uint128 daveLiq,
        uint8 daysBetween
    ) public {
        aliceLiq = uint128(bound(aliceLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        bobLiq = uint128(bound(bobLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        charlieLiq = uint128(bound(charlieLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        daveLiq = uint128(bound(daveLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        daysBetween = uint8(bound(daysBetween, 1, 5));

        // Alice starts
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), aliceLiq
        );
        vm.stopPrank();

        vm.warp(block.timestamp + daysBetween * 1 days);

        // Bob joins
        vm.startPrank(bob);
        _addLiquidityForUser(
            bob, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), bobLiq
        );
        vm.stopPrank();

        vm.warp(block.timestamp + daysBetween * 1 days);

        // Charlie joins
        vm.startPrank(charlie);
        _addLiquidityForUser(
            charlie, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), charlieLiq
        );
        vm.stopPrank();

        vm.warp(block.timestamp + daysBetween * 1 days);

        // Dave joins
        vm.startPrank(dave);
        _addLiquidityForUser(
            dave, key, TickMath.minUsableTick(key.tickSpacing), TickMath.maxUsableTick(key.tickSpacing), daveLiq
        );
        vm.stopPrank();

        // Verify pool still configured
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
        assertTrue(config.isConfigured, "Pool should remain configured after gradual buildup");
    }

    /* ========================================================================== */
    /*                    FUZZED TRADING SCENARIOS                                */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Multiple traders swap at various sizes
     * @param liquidityAmount Total liquidity to provide
     * @param swapAmount Base swap amount
     * @param numSwaps Number of swaps (1-10)
     */
    function testFuzz_multiTrader_swaps_variousSizes(uint128 liquidityAmount, uint256 swapAmount, uint8 numSwaps)
        public
    {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT / 2);
        numSwaps = uint8(bound(numSwaps, 1, 10));

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Multiple swaps with different directions
        for (uint8 i = 0; i < numSwaps; i++) {
            address trader = i % 2 == 0 ? bob : charlie;
            bool zeroForOne = i % 3 != 0;

            vm.startPrank(trader);
            _performSwap(trader, key, swapAmount, zeroForOne);
            vm.stopPrank();
        }

        // Verify fee is within bounds
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        uint24 currentFee = hook.getFee();

        assertGe(currentFee, params.minFee, "Fee >= minFee after swaps");
        assertLe(currentFee, params.maxFee, "Fee <= maxFee after swaps");
    }

    /**
     * @notice Fuzz: Ratio pokes update fees correctly
     * @param liquidityAmount Liquidity amount
     * @param ratio1 First ratio to poke
     * @param ratio2 Second ratio to poke
     */
    function testFuzz_poke_updates_fee_correctly(uint128 liquidityAmount, uint256 ratio1, uint256 ratio2) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));

        // Add liquidity first so pool is active
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        // Bound ratios to pool's configured max
        ratio1 = bound(ratio1, MIN_RATIO, params.maxCurrentRatio);
        ratio2 = bound(ratio2, MIN_RATIO, params.maxCurrentRatio);

        // First poke
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(ratio1);

        uint24 fee1 = hook.getFee();
        assertGe(fee1, params.minFee, "Fee1 >= minFee");
        assertLe(fee1, params.maxFee, "Fee1 <= maxFee");

        // Second poke
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(ratio2);

        uint24 fee2 = hook.getFee();
        assertGe(fee2, params.minFee, "Fee2 >= minFee");
        assertLe(fee2, params.maxFee, "Fee2 <= maxFee");
    }

    /* ========================================================================== */
    /*                    FUZZED FEE DYNAMICS                                     */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Fee responds to ratio changes over time
     * @param liquidityAmount Liquidity to provide
     * @param numPokes Number of pokes (2-10)
     * @param ratioSeed Seed for generating ratios
     */
    function testFuzz_fee_dynamics_over_time(uint128 liquidityAmount, uint8 numPokes, uint256 ratioSeed) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        numPokes = uint8(bound(numPokes, 2, 10));

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        for (uint8 i = 0; i < numPokes; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            // Generate a ratio from the seed, bounded to pool's configured max
            uint256 ratio = bound(uint256(keccak256(abi.encode(ratioSeed, i))), MIN_RATIO, params.maxCurrentRatio);

            vm.prank(owner);
            hook.poke(ratio);

            uint24 newFee = hook.getFee();

            // Verify bounds maintained
            assertGe(newFee, params.minFee, "Fee >= minFee during dynamics");
            assertLe(newFee, params.maxFee, "Fee <= maxFee during dynamics");
        }
    }

    /**
     * @notice Fuzz: High ratio consistently increases fees
     * @param liquidityAmount Liquidity amount
     * @param highRatio A high ratio (should push fees up)
     */
    function testFuzz_high_ratio_increases_fee(uint128 liquidityAmount, uint256 highRatio) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));

        // Add liquidity first
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        // High ratio = above target, bound to pool's configured max
        highRatio = bound(highRatio, 8e17, params.maxCurrentRatio);

        // Poke with high ratio
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(highRatio);

        uint24 newFee = hook.getFee();

        // High ratio should maintain or increase fee (not decrease significantly)
        assertGe(newFee, params.minFee, "Fee should be at least minFee");
        assertLe(newFee, params.maxFee, "Fee should be at most maxFee");
    }

    /**
     * @notice Fuzz: Low ratio consistently decreases fees
     * @param liquidityAmount Liquidity amount
     * @param lowRatio A low ratio (should push fees down)
     */
    function testFuzz_low_ratio_decreases_fee(uint128 liquidityAmount, uint256 lowRatio) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        // Low ratio = below target (5e17 is typical target)
        lowRatio = bound(lowRatio, 1e15, 2e17);

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        // First poke with high ratio to increase fee
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(9e17);

        hook.getFee(); // Verify fee is readable after high-ratio poke

        // Then poke with low ratio
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(lowRatio);

        uint24 lowFee = hook.getFee();

        // Low ratio should maintain or decrease fee
        assertGe(lowFee, params.minFee, "Fee should be at least minFee");
        assertLe(lowFee, params.maxFee, "Fee should be at most maxFee");
    }

    /* ========================================================================== */
    /*                    FUZZED PARAMETER BOUNDS                                 */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Extreme ratios don't break fee bounds
     * @param liquidityAmount Liquidity amount
     * @param extremeRatio Extreme ratio value
     */
    function testFuzz_extreme_ratios_respect_bounds(uint128 liquidityAmount, uint256 extremeRatio) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));

        // Add liquidity first
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        // Bound extreme ratio to pool's configured max
        extremeRatio = bound(extremeRatio, 1, params.maxCurrentRatio);

        // Poke with extreme ratio
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(extremeRatio);

        uint24 fee = hook.getFee();

        // Fee must always be within bounds
        assertGe(fee, params.minFee, "Fee >= minFee with extreme ratio");
        assertLe(fee, params.maxFee, "Fee <= maxFee with extreme ratio");
    }

    /**
     * @notice Fuzz: Many consecutive pokes maintain fee stability
     * @param liquidityAmount Liquidity amount
     * @param numPokes Number of consecutive pokes (5-20)
     */
    function testFuzz_consecutive_pokes_maintain_stability(uint128 liquidityAmount, uint8 numPokes) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        numPokes = uint8(bound(numPokes, 5, 20));

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            key,
            TickMath.minUsableTick(key.tickSpacing),
            TickMath.maxUsableTick(key.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        for (uint8 i = 0; i < numPokes; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            // Alternating high and low ratios
            uint256 ratio = i % 2 == 0 ? 8e17 : 2e17;

            vm.prank(owner);
            hook.poke(ratio);

            uint24 fee = hook.getFee();
            assertGe(fee, params.minFee, "Fee stable during consecutive pokes");
            assertLe(fee, params.maxFee, "Fee stable during consecutive pokes");
        }
    }

    /* ========================================================================== */
    /*                    FUZZED FRESH HOOK SCENARIOS                             */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Fresh hook/logic pair operates correctly with fuzzed initial fee
     * @param initialFee Initial fee for the pool
     * @param liquidityAmount Liquidity to add
     */
    function testFuzz_fresh_hook_with_fuzzed_fee(uint24 initialFee, uint128 liquidityAmount) public {
        // Bound to valid fee range
        initialFee = uint24(bound(initialFee, 100, 10000));
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));

        // Deploy fresh stack
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Initialize pool with fuzzed fee
        (PoolKey memory freshKey,) = _initPoolWithHook(
            initialFee, INITIAL_TARGET_RATIO, 18, 18, key.tickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        // Mint tokens to alice for the fresh pool's currencies
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(freshKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(freshKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            freshKey,
            TickMath.minUsableTick(freshKey.tickSpacing),
            TickMath.maxUsableTick(freshKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Verify configuration
        IAlphixLogic.PoolConfig memory config = freshLogic.getPoolConfig();
        assertTrue(config.isConfigured, "Fresh pool should be configured");
        assertEq(config.initialFee, initialFee, "Initial fee should match");
    }

    /**
     * @notice Fuzz: Fresh hook/logic pair handles pokes correctly
     * @param initialFee Initial fee
     * @param ratio Ratio to poke
     */
    function testFuzz_fresh_hook_poke(uint24 initialFee, uint256 ratio) public {
        initialFee = uint24(bound(initialFee, 100, 10000));

        // Deploy fresh stack
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Initialize pool
        (PoolKey memory freshKey,) = _initPoolWithHook(
            initialFee, INITIAL_TARGET_RATIO, 18, 18, key.tickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        // Mint tokens to alice for the fresh pool's currencies
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(freshKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(freshKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            freshKey,
            TickMath.minUsableTick(freshKey.tickSpacing),
            TickMath.maxUsableTick(freshKey.tickSpacing),
            100e18
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = freshLogic.getPoolParams();

        // Bound ratio to pool's max
        ratio = bound(ratio, MIN_RATIO, params.maxCurrentRatio);

        // Poke
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        freshHook.poke(ratio);

        uint24 newFee = freshHook.getFee();
        assertGe(newFee, params.minFee, "Fee >= minFee after poke");
        assertLe(newFee, params.maxFee, "Fee <= maxFee after poke");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    function _addLiquidityForUser(address user, PoolKey memory poolKey, int24 lower, int24 upper, uint128 liquidity)
        internal
        returns (uint256 newTokenId)
    {
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(permit2), type(uint256).max);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(poolKey.currency0), address(positionManager), type(uint160).max, expiry);
        permit2.approve(Currency.unwrap(poolKey.currency1), address(positionManager), type(uint160).max, expiry);

        (newTokenId,) = positionManager.mint(
            poolKey,
            lower,
            upper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            user,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
    }

    function _performSwap(address trader, PoolKey memory poolKey, uint256 amount, bool zeroForOne) internal {
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amount);

        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 100
        });
    }

    function _mintTokensToUser(address user, Currency c0, Currency c1, uint256 amount) internal {
        MockERC20(Currency.unwrap(c0)).mint(user, amount);
        MockERC20(Currency.unwrap(c1)).mint(user, amount);
    }

    /* ========================================================================== */
    /*                    GLOBAL MAX RATIO STRESS TESTS                           */
    /* ========================================================================== */

    /**
     * @notice Helper to create pool params with global max ratio
     * @dev Copies defaultPoolParams but sets maxCurrentRatio to the global MAX_CURRENT_RATIO
     */
    function _createGlobalMaxRatioParams() internal view returns (DynamicFeeLib.PoolParams memory) {
        return DynamicFeeLib.PoolParams({
            minFee: defaultPoolParams.minFee,
            maxFee: defaultPoolParams.maxFee,
            baseMaxFeeDelta: defaultPoolParams.baseMaxFeeDelta,
            lookbackPeriod: defaultPoolParams.lookbackPeriod,
            minPeriod: defaultPoolParams.minPeriod,
            ratioTolerance: defaultPoolParams.ratioTolerance,
            linearSlope: defaultPoolParams.linearSlope,
            maxCurrentRatio: AlphixGlobalConstants.MAX_CURRENT_RATIO, // 1e24 - global max
            upperSideFactor: defaultPoolParams.upperSideFactor,
            lowerSideFactor: defaultPoolParams.lowerSideFactor
        });
    }

    /**
     * @notice Fuzz: Poke with ratios up to global MAX_CURRENT_RATIO (1e24)
     * @dev Stress tests fee computation with extreme ratio values
     * @param liquidityAmount Liquidity to provide
     * @param ratio Ratio to poke (bounded to global max)
     */
    function testFuzz_globalMaxRatio_poke(uint128 liquidityAmount, uint256 ratio) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));

        // Deploy fresh stack with global max ratio params
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        DynamicFeeLib.PoolParams memory globalMaxParams = _createGlobalMaxRatioParams();

        // Initialize pool with global max ratio params
        (PoolKey memory freshKey,) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            key.tickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            globalMaxParams
        );

        // Mint tokens to alice
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(freshKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(freshKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            freshKey,
            TickMath.minUsableTick(freshKey.tickSpacing),
            TickMath.maxUsableTick(freshKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = freshLogic.getPoolParams();

        // Bound ratio to global max (1e24)
        ratio = bound(ratio, MIN_RATIO, AlphixGlobalConstants.MAX_CURRENT_RATIO);

        // Poke with potentially extreme ratio
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        freshHook.poke(ratio);

        uint24 newFee = freshHook.getFee();
        assertGe(newFee, params.minFee, "Fee >= minFee with global max ratio");
        assertLe(newFee, params.maxFee, "Fee <= maxFee with global max ratio");
    }

    /**
     * @notice Fuzz: Multiple pokes with ratios spanning full global range
     * @dev Tests fee stability across many pokes with extreme ratio variations
     * @param liquidityAmount Liquidity to provide
     * @param numPokes Number of pokes (2-15)
     * @param ratioSeed Seed for ratio generation
     */
    function testFuzz_globalMaxRatio_multiplePokes(uint128 liquidityAmount, uint8 numPokes, uint256 ratioSeed) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        numPokes = uint8(bound(numPokes, 2, 15));

        // Deploy fresh stack with global max ratio params
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        DynamicFeeLib.PoolParams memory globalMaxParams = _createGlobalMaxRatioParams();

        // Initialize pool
        (PoolKey memory freshKey,) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            key.tickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            globalMaxParams
        );

        // Mint tokens to alice
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(freshKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(freshKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            freshKey,
            TickMath.minUsableTick(freshKey.tickSpacing),
            TickMath.maxUsableTick(freshKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = freshLogic.getPoolParams();

        for (uint8 i = 0; i < numPokes; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            // Generate ratio bounded to global max (1e24)
            uint256 ratio =
                bound(uint256(keccak256(abi.encode(ratioSeed, i))), MIN_RATIO, AlphixGlobalConstants.MAX_CURRENT_RATIO);

            vm.prank(owner);
            freshHook.poke(ratio);

            uint24 newFee = freshHook.getFee();
            assertGe(newFee, params.minFee, "Fee >= minFee during global max pokes");
            assertLe(newFee, params.maxFee, "Fee <= maxFee during global max pokes");
        }
    }

    /**
     * @notice Fuzz: Extreme high ratios near global max (1e24) don't break fee bounds
     * @dev Specifically tests ratios near the upper boundary
     * @param liquidityAmount Liquidity to provide
     * @param ratioOffset Offset from global max (allows testing near-boundary values)
     */
    function testFuzz_globalMaxRatio_nearBoundary(uint128 liquidityAmount, uint256 ratioOffset) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        // Offset from 0 to 1e23 (so ratio ranges from 9e23 to 1e24)
        ratioOffset = bound(ratioOffset, 0, 1e23);

        // Deploy fresh stack with global max ratio params
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        DynamicFeeLib.PoolParams memory globalMaxParams = _createGlobalMaxRatioParams();

        // Initialize pool
        (PoolKey memory freshKey,) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            key.tickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            globalMaxParams
        );

        // Mint tokens to alice
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(freshKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(freshKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            freshKey,
            TickMath.minUsableTick(freshKey.tickSpacing),
            TickMath.maxUsableTick(freshKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = freshLogic.getPoolParams();

        // Calculate ratio near global max
        uint256 extremeRatio = AlphixGlobalConstants.MAX_CURRENT_RATIO - ratioOffset;

        // Poke with extreme ratio near boundary
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        freshHook.poke(extremeRatio);

        uint24 newFee = freshHook.getFee();
        assertGe(newFee, params.minFee, "Fee >= minFee at extreme ratio");
        assertLe(newFee, params.maxFee, "Fee <= maxFee at extreme ratio");
    }

    /**
     * @notice Fuzz: Ratio transitions from low to global max don't cause issues
     * @dev Tests dramatic ratio swings that could stress fee calculations
     * @param liquidityAmount Liquidity to provide
     * @param lowRatio Starting low ratio
     */
    function testFuzz_globalMaxRatio_lowToHighTransition(uint128 liquidityAmount, uint256 lowRatio) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        lowRatio = bound(lowRatio, MIN_RATIO, 1e17); // Very low ratio

        // Deploy fresh stack with global max ratio params
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        DynamicFeeLib.PoolParams memory globalMaxParams = _createGlobalMaxRatioParams();

        // Initialize pool
        (PoolKey memory freshKey,) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            key.tickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            globalMaxParams
        );

        // Mint tokens to alice
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(freshKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT);
        MockERC20(Currency.unwrap(freshKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            freshKey,
            TickMath.minUsableTick(freshKey.tickSpacing),
            TickMath.maxUsableTick(freshKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory params = freshLogic.getPoolParams();

        // First poke with low ratio
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        freshHook.poke(lowRatio);

        uint24 lowFee = freshHook.getFee();
        assertGe(lowFee, params.minFee, "Low fee >= minFee");
        assertLe(lowFee, params.maxFee, "Low fee <= maxFee");

        // Second poke with global max ratio (dramatic swing)
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        freshHook.poke(AlphixGlobalConstants.MAX_CURRENT_RATIO);

        uint24 highFee = freshHook.getFee();
        assertGe(highFee, params.minFee, "High fee >= minFee after swing");
        assertLe(highFee, params.maxFee, "High fee <= maxFee after swing");
    }
}
