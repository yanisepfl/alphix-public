// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixFullIntegrationFuzzTest
 * @author Alphix
 * @notice Fuzzed full-cycle integration tests simulating realistic multi-user pool scenarios
 * @dev Adapts concrete tests from AlphixFullIntegration.t.sol with fuzzed parameters
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

    // Structs to avoid stack too deep
    struct LPConfig {
        uint128 aliceLiq;
        uint128 bobLiq;
        uint128 charlieLiq;
        uint128 totalLiquidity;
    }

    struct SwapConfig {
        uint256 swapAmount;
        uint8 numSwaps;
        uint24 feeRate;
    }

    uint256 constant MAX_RATIO = 1e18;

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
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_multiUser_liquidity_provision_various_amounts(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint128 charlieLiq,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        aliceLiq = uint128(bound(aliceLiq, MIN_LIQUIDITY, MAX_LIQUIDITY));
        bobLiq = uint128(bound(bobLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        charlieLiq = uint128(bound(charlieLiq, MIN_LIQUIDITY, MAX_LIQUIDITY));

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            aliceLiq
        );
        vm.stopPrank();

        vm.startPrank(bob);
        _addLiquidityForUser(
            bob,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            bobLiq
        );
        vm.stopPrank();

        vm.startPrank(charlie);
        _addLiquidityForUser(
            charlie,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            charlieLiq
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool should be configured");
    }

    /**
     * @notice Fuzz: Gradual liquidity buildup with varying amounts and timing
     * @param aliceLiq Alice's liquidity
     * @param bobLiq Bob's liquidity
     * @param charlieLiq Charlie's liquidity
     * @param daveLiq Dave's liquidity
     * @param daysBetween Days between LP entries (1-5)
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_multiUser_gradual_liquidity_buildup(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint128 charlieLiq,
        uint128 daveLiq,
        uint8 daysBetween,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        aliceLiq = uint128(bound(aliceLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        bobLiq = uint128(bound(bobLiq, MIN_LIQUIDITY, MAX_LIQUIDITY));
        charlieLiq = uint128(bound(charlieLiq, MIN_LIQUIDITY, MAX_LIQUIDITY));
        daveLiq = uint128(bound(daveLiq, MIN_LIQUIDITY, MAX_LIQUIDITY / 2));
        daysBetween = uint8(bound(daysBetween, 1, 5));

        // Alice enters first
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            aliceLiq
        );
        vm.stopPrank();

        // Bob enters after daysBetween
        vm.warp(block.timestamp + (daysBetween * 1 days));
        vm.startPrank(bob);
        _addLiquidityForUser(
            bob,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            bobLiq
        );
        vm.stopPrank();

        // Charlie enters after another daysBetween
        vm.warp(block.timestamp + (daysBetween * 1 days));
        vm.startPrank(charlie);
        _addLiquidityForUser(
            charlie,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            charlieLiq
        );
        vm.stopPrank();

        // Dave enters last
        vm.warp(block.timestamp + (daysBetween * 1 days));
        vm.startPrank(dave);
        _addLiquidityForUser(
            dave,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            daveLiq
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool should be configured with gradual liquidity");
    }

    /* ========================================================================== */
    /*                       FUZZED TRADING ACTIVITY TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Swap activity with varying volumes
     * @param liquidityAmount Initial liquidity
     * @param swap1 First swap amount
     * @param swap2 Second swap amount
     * @param swap3 Third swap amount
     * @param swap4 Fourth swap amount
     * @param swap5 Fifth swap amount
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_multiUser_swap_activity_creates_volume(
        uint128 liquidityAmount,
        uint256 swap1,
        uint256 swap2,
        uint256 swap3,
        uint256 swap4,
        uint256 swap5,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        swap1 = bound(swap1, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        swap2 = bound(swap2, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        swap3 = bound(swap3, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        swap4 = bound(swap4, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        swap5 = bound(swap5, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);

        // Setup liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Mint tokens to all traders (each trader gets only what they need for their swap)
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(bob, swap1);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(bob, swap1);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(charlie, swap2);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(charlie, swap2);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(dave, swap3);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(dave, swap3);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(user1, swap4);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(user1, swap4);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(user2, swap5);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(user2, swap5);
        vm.stopPrank();

        // Day 1: Multiple traders create volume
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(bob);
        _performSwap(bob, testKey, swap1, true);
        vm.stopPrank();

        vm.startPrank(charlie);
        _performSwap(charlie, testKey, swap2, false);
        vm.stopPrank();

        vm.startPrank(dave);
        _performSwap(dave, testKey, swap3, true);
        vm.stopPrank();

        // Day 2: More trading
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(user1);
        _performSwap(user1, testKey, swap4, false);
        vm.stopPrank();

        vm.startPrank(user2);
        _performSwap(user2, testKey, swap5, true);
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool should be operational after swaps");
    }

    /**
     * @notice Fuzz: Directional trading pressure
     * @param liquidityAmount Pool liquidity
     * @param swapAmount Size of each directional swap
     * @param numSwaps Number of directional swaps (1-5)
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_multiUser_directional_trading_pressure(
        uint128 liquidityAmount,
        uint256 swapAmount,
        uint8 numSwaps,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 20, MAX_LIQUIDITY));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        numSwaps = uint8(bound(numSwaps, 1, 5));

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Sustained buying pressure
        for (uint256 i = 0; i < numSwaps; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.startPrank(bob);
            _performSwap(bob, testKey, swapAmount, true);
            vm.stopPrank();
        }

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool operational despite directional pressure");
    }

    /* ========================================================================== */
    /*                       FUZZED FEE VERIFICATION TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Traders pay correct dynamic fees
     * @param liquidityAmount Initial liquidity
     * @param swapAmount1 First swap amount
     * @param swapAmount2 Second swap amount
     * @param ratio Ratio for fee calculation
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    /**
     * @notice Fuzz test: Traders pay EXACT fees based on pool's dynamic fee rate
     * @dev Uses feeGrowthGlobal for precise verification (99.5%+ accuracy)
     */
    function testFuzz_traders_pay_correct_dynamic_fees(
        uint128 liquidityAmount,
        uint256 swapAmount1,
        uint256 swapAmount2,
        uint256 ratio,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        // Use large liquidity to minimize price impact for accurate fee measurement
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        swapAmount1 = bound(swapAmount1, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        swapAmount2 = bound(swapAmount2, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        ratio = bound(ratio, 5e16, MAX_RATIO);

        // Setup liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // First swap - verify exact fee paid
        _performSwapAndVerifyFee(bob, testKey, testPoolId, swapAmount1, liquidityAmount, true);

        // Update fee via poke
        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, ratio);

        // Second swap at new fee - verify exact fee paid
        _performSwapAndVerifyFee(charlie, testKey, testPoolId, swapAmount2, liquidityAmount, true);

        // Verify fees are within bounds
        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);
        assertGe(finalFee, params.minFee, "Fee should be >= minFee");
        assertLe(finalFee, params.maxFee, "Fee should be <= maxFee");
    }

    /**
     * @notice Fuzz: Realistic ratio calculation from volumes
     * @param aliceLiq Alice's liquidity
     * @param bobLiq Bob's liquidity
     * @param charlieLiq Charlie's liquidity
     * @param dailyVolume Daily trading volume
     * @param numDays Number of trading days (1-7)
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_realistic_ratio_calculation_from_volumes(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint128 charlieLiq,
        uint256 dailyVolume,
        uint8 numDays,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        aliceLiq = uint128(bound(aliceLiq, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        bobLiq = uint128(bound(bobLiq, MIN_LIQUIDITY * 5, MAX_LIQUIDITY / 2));
        charlieLiq = uint128(bound(charlieLiq, MIN_LIQUIDITY * 15, MAX_LIQUIDITY));
        dailyVolume = bound(dailyVolume, MIN_SWAP_AMOUNT * 3, MAX_SWAP_AMOUNT);
        numDays = uint8(bound(numDays, 1, 7));

        // Setup liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            aliceLiq
        );
        vm.stopPrank();

        vm.startPrank(bob);
        _addLiquidityForUser(
            bob,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            bobLiq
        );
        vm.stopPrank();

        vm.startPrank(charlie);
        _addLiquidityForUser(
            charlie,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            charlieLiq
        );
        vm.stopPrank();

        uint256 totalLiquidity = uint256(aliceLiq) + uint256(bobLiq) + uint256(charlieLiq);

        // Simulate trading
        for (uint256 i = 0; i < numDays; i++) {
            vm.startPrank(dave);
            _performSwap(dave, testKey, dailyVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }

        // Calculate realistic ratio
        uint256 totalVolume = dailyVolume * numDays;
        uint256 calculatedRatio = (totalVolume * 1e18) / totalLiquidity;
        if (calculatedRatio > MAX_RATIO) calculatedRatio = MAX_RATIO;

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, calculatedRatio);

        uint24 feeAfterPoke;
        (,,, feeAfterPoke) = poolManager.getSlot0(testPoolId);

        assertGe(feeAfterPoke, params.minFee, "Fee should be >= minFee");
        assertLe(feeAfterPoke, params.maxFee, "Fee should be <= maxFee");
        assertGt(feeAfterPoke, 0, "Fee should be positive after activity");
    }

    /**
     * @notice Fuzz test: LPs earn EXACT fees proportional to liquidity AND time
     * @dev Uses feeGrowthInside for position-specific tracking
     * Tests: (1) Alice earns 100% when alone, (2) Alice/Bob split based on liquidity, (3) All three split proportionally
     */
    function testFuzz_complex_LP_fee_distribution_different_timelines(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint128 charlieLiq,
        uint256 swapAmount,
        uint8 weeksBetween,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        LPConfig memory lpConfig = LPConfig({
            aliceLiq: uint128(bound(aliceLiq, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 3)),
            bobLiq: uint128(bound(bobLiq, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 3)),
            charlieLiq: uint128(bound(charlieLiq, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 3)),
            totalLiquidity: 0
        });

        SwapConfig memory swapConfig;
        swapConfig.swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT * 10, MAX_SWAP_AMOUNT / 5);
        swapConfig.numSwaps = 2;
        weeksBetween = uint8(bound(weeksBetween, 1, 2));

        int24 tickLower = TickMath.minUsableTick(testKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(testKey.tickSpacing);

        (,,, swapConfig.feeRate) = poolManager.getSlot0(testPoolId);

        // Phase 1: Alice alone
        vm.startPrank(alice);
        _addLiquidityForUser(alice, testKey, tickLower, tickUpper, lpConfig.aliceLiq);
        vm.stopPrank();

        (uint256 feeGrowth0_start,) = poolManager.getFeeGrowthInside(testPoolId, tickLower, tickUpper);
        for (uint256 i = 0; i < 2; i++) {
            _performSwapAndVerifyFee(dave, testKey, testPoolId, swapConfig.swapAmount, lpConfig.aliceLiq, true);
        }
        _verifyLPFeesEarned(
            testPoolId,
            tickLower,
            tickUpper,
            lpConfig.aliceLiq,
            feeGrowth0_start,
            (swapConfig.swapAmount * swapConfig.feeRate * 2) / 1_000_000
        );

        // Phase 2: Bob joins
        (uint256 feeGrowth0_bobJoins,) = poolManager.getFeeGrowthInside(testPoolId, tickLower, tickUpper);
        vm.warp(block.timestamp + (weeksBetween * 7 days));
        vm.startPrank(bob);
        _addLiquidityForUser(bob, testKey, tickLower, tickUpper, lpConfig.bobLiq);
        vm.stopPrank();

        lpConfig.totalLiquidity = lpConfig.aliceLiq + lpConfig.bobLiq;
        for (uint256 i = 0; i < 2; i++) {
            _performSwapAndVerifyFee(dave, testKey, testPoolId, swapConfig.swapAmount, lpConfig.totalLiquidity, true);
        }

        uint256 totalFees = (swapConfig.swapAmount * swapConfig.feeRate * 2) / 1_000_000;
        _verifyLPFeesEarned(
            testPoolId,
            tickLower,
            tickUpper,
            lpConfig.aliceLiq,
            feeGrowth0_bobJoins,
            totalFees * lpConfig.aliceLiq / lpConfig.totalLiquidity
        );
        _verifyLPFeesEarned(
            testPoolId,
            tickLower,
            tickUpper,
            lpConfig.bobLiq,
            feeGrowth0_bobJoins,
            totalFees * lpConfig.bobLiq / lpConfig.totalLiquidity
        );

        // Phase 3: Charlie joins
        {
            (uint256 feeGrowth0_charlieJoins,) = poolManager.getFeeGrowthInside(testPoolId, tickLower, tickUpper);
            vm.warp(block.timestamp + (weeksBetween * 7 days));

            vm.startPrank(charlie);
            _addLiquidityForUser(charlie, testKey, tickLower, tickUpper, lpConfig.charlieLiq);
            vm.stopPrank();

            lpConfig.totalLiquidity = lpConfig.aliceLiq + lpConfig.bobLiq + lpConfig.charlieLiq;
            for (uint256 i = 0; i < 2; i++) {
                _performSwapAndVerifyFee(
                    dave, testKey, testPoolId, swapConfig.swapAmount, lpConfig.totalLiquidity, true
                );
            }

            totalFees = (swapConfig.swapAmount * swapConfig.feeRate * 2) / 1_000_000;
            _verifyLPFeesEarned(
                testPoolId,
                tickLower,
                tickUpper,
                lpConfig.aliceLiq,
                feeGrowth0_charlieJoins,
                totalFees * lpConfig.aliceLiq / lpConfig.totalLiquidity
            );
            _verifyLPFeesEarned(
                testPoolId,
                tickLower,
                tickUpper,
                lpConfig.bobLiq,
                feeGrowth0_charlieJoins,
                totalFees * lpConfig.bobLiq / lpConfig.totalLiquidity
            );
            _verifyLPFeesEarned(
                testPoolId,
                tickLower,
                tickUpper,
                lpConfig.charlieLiq,
                feeGrowth0_charlieJoins,
                totalFees * lpConfig.charlieLiq / lpConfig.totalLiquidity
            );
        }
    }

    /**
     * @notice Fuzz test: Equal LPs with equal liquidity earn EXACTLY equal fees
     * @dev Uses feeGrowthInside to verify each LP earns 25% of total fees
     */
    function testFuzz_equal_LPs_equal_timeline(
        uint128 liquidityPerLP,
        uint256 swapAmount,
        uint8 numSwaps,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        SwapConfig memory swapConfig;
        swapConfig.swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT * 10, MAX_SWAP_AMOUNT / 10);
        swapConfig.numSwaps = uint8(bound(numSwaps, 5, 10));
        liquidityPerLP = uint128(bound(liquidityPerLP, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 4));

        int24 tickLower = TickMath.minUsableTick(testKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(testKey.tickSpacing);

        // Add equal liquidity for 4 LPs
        _addFourEqualLPs(testKey, tickLower, tickUpper, liquidityPerLP);

        _testEqualDistribution(testKey, testPoolId, tickLower, tickUpper, liquidityPerLP, swapConfig);
    }

    function _addFourEqualLPs(PoolKey memory testKey, int24 tickLower, int24 tickUpper, uint128 liquidityPerLP)
        internal
    {
        address[4] memory lps = [alice, bob, charlie, dave];
        for (uint256 i = 0; i < lps.length; i++) {
            vm.startPrank(lps[i]);
            _addLiquidityForUser(lps[i], testKey, tickLower, tickUpper, liquidityPerLP);
            vm.stopPrank();
        }
    }

    function _testEqualDistribution(
        PoolKey memory testKey,
        PoolId testPoolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityPerLP,
        SwapConfig memory swapConfig
    ) internal {
        uint128 totalLiquidity = liquidityPerLP * 4;
        (,,, swapConfig.feeRate) = poolManager.getSlot0(testPoolId);
        (uint256 feeGrowth0_start,) = poolManager.getFeeGrowthInside(testPoolId, tickLower, tickUpper);

        // Mint and swap
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(user1, swapConfig.swapAmount * swapConfig.numSwaps * 2);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(user1, swapConfig.swapAmount * swapConfig.numSwaps * 2);
        vm.stopPrank();

        _performMultipleSwaps(user1, testKey, testPoolId, swapConfig.swapAmount, totalLiquidity, swapConfig.numSwaps);

        // Each LP should earn 25%
        uint256 expectedFeesPerLP = ((swapConfig.swapAmount * swapConfig.feeRate * swapConfig.numSwaps) / 1_000_000) / 4;
        _verifyLPFeesEarned(testPoolId, tickLower, tickUpper, liquidityPerLP, feeGrowth0_start, expectedFeesPerLP);
    }

    /* ========================================================================== */
    /*                    FUZZED INTERMEDIATE COMPLEXITY TESTS                    */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Pool lifecycle with fee adjustments
     * @param liquidityAmount Initial liquidity
     * @param ratio1 First ratio
     * @param ratio2 Second ratio
     * @param swapVolume Swap volume between adjustments
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_complete_pool_lifecycle_with_fee_adjustments(
        uint128 liquidityAmount,
        uint256 ratio1,
        uint256 ratio2,
        uint256 swapVolume,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        ratio1 = bound(ratio1, 5e16, MAX_RATIO / 10);
        ratio2 = bound(ratio2, 5e16, MAX_RATIO);
        swapVolume = bound(swapVolume, MIN_SWAP_AMOUNT * 5, MAX_SWAP_AMOUNT);

        // Setup
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);

        // First adjustment
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio1);

        uint24 fee1;
        (,,, fee1) = poolManager.getSlot0(testPoolId);

        // Trading
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 7; i++) {
            vm.startPrank(bob);
            _performSwap(bob, testKey, swapVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }

        // Second adjustment
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio2);

        uint24 fee2;
        (,,, fee2) = poolManager.getSlot0(testPoolId);

        assertGe(fee1, params.minFee, "Fee1 should be >= minFee");
        assertLe(fee1, params.maxFee, "Fee1 should be <= maxFee");
        assertGe(fee2, params.minFee, "Fee2 should be >= minFee");
        assertLe(fee2, params.maxFee, "Fee2 should be <= maxFee");

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool should remain configured");
    }

    /**
     * @notice Fuzz: High volatility scenario
     * @param liquidityAmount Pool liquidity
     * @param largeSwap1 First large swap
     * @param largeSwap2 Second large swap
     * @param volatilityRatio Ratio reflecting volatility
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_high_volatility_scenario_with_dynamic_fees(
        uint128 liquidityAmount,
        uint256 largeSwap1,
        uint256 largeSwap2,
        uint256 volatilityRatio,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MAX_LIQUIDITY / 2, MAX_LIQUIDITY));
        largeSwap1 = bound(largeSwap1, MAX_SWAP_AMOUNT / 2, MAX_SWAP_AMOUNT);
        largeSwap2 = bound(largeSwap2, MAX_SWAP_AMOUNT / 2, MAX_SWAP_AMOUNT);
        volatilityRatio = bound(volatilityRatio, MAX_RATIO / 3, MAX_RATIO);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Mint tokens to traders for volatility swaps
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(charlie, largeSwap1 * 2);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(charlie, largeSwap1 * 2);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(dave, largeSwap2 * 2);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(dave, largeSwap2 * 2);
        vm.stopPrank();

        // Volatility spike
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(charlie);
        _performSwap(charlie, testKey, largeSwap1, true);
        vm.stopPrank();

        vm.startPrank(dave);
        _performSwap(dave, testKey, largeSwap2, false);
        vm.stopPrank();

        // Admin responds
        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, volatilityRatio);

        uint24 volatilityFee;
        (,,, volatilityFee) = poolManager.getSlot0(testPoolId);

        // Verify fee is within pool type bounds (may stay at minFee in some cases)
        assertGe(volatilityFee, params.minFee, "Fee should be >= minFee");
        assertLe(volatilityFee, params.maxFee, "Fee should remain within max bounds");
    }

    /**
     * @notice Fuzz: Periodic fee adjustments over multiple weeks
     * @param liquidityAmount Initial liquidity
     * @param ratio1 Week 1 ratio
     * @param ratio2 Week 2 ratio
     * @param ratio3 Week 3 ratio
     * @param ratio4 Week 4 ratio
     * @param weeklyVolume Weekly trading volume
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_periodic_fee_adjustments_over_month(
        uint128 liquidityAmount,
        uint256 ratio1,
        uint256 ratio2,
        uint256 ratio3,
        uint256 ratio4,
        uint256 weeklyVolume,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 20, MAX_LIQUIDITY));
        ratio1 = bound(ratio1, 5e16, MAX_RATIO);
        ratio2 = bound(ratio2, 5e16, MAX_RATIO);
        ratio3 = bound(ratio3, 5e16, MAX_RATIO);
        ratio4 = bound(ratio4, 5e16, MAX_RATIO);
        weeklyVolume = bound(weeklyVolume, MIN_SWAP_AMOUNT * 2, MAX_SWAP_AMOUNT / 2);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);

        // Week 1
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 7; i++) {
            vm.startPrank(bob);
            _performSwap(bob, testKey, weeklyVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio1);
        uint24 week1Fee;
        (,,, week1Fee) = poolManager.getSlot0(testPoolId);

        // Week 2
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 7; i++) {
            vm.startPrank(bob);
            _performSwap(bob, testKey, weeklyVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio2);
        uint24 week2Fee;
        (,,, week2Fee) = poolManager.getSlot0(testPoolId);

        // Week 3
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 7; i++) {
            vm.startPrank(bob);
            _performSwap(bob, testKey, weeklyVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio3);
        uint24 week3Fee;
        (,,, week3Fee) = poolManager.getSlot0(testPoolId);

        // Week 4
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 7; i++) {
            vm.startPrank(bob);
            _performSwap(bob, testKey, weeklyVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio4);
        uint24 week4Fee;
        (,,, week4Fee) = poolManager.getSlot0(testPoolId);

        // Verify all fees within bounds
        assertGe(week1Fee, params.minFee, "Week1 >= minFee");
        assertLe(week1Fee, params.maxFee, "Week1 <= maxFee");
        assertGe(week2Fee, params.minFee, "Week2 >= minFee");
        assertLe(week2Fee, params.maxFee, "Week2 <= maxFee");
        assertGe(week3Fee, params.minFee, "Week3 >= minFee");
        assertLe(week3Fee, params.maxFee, "Week3 <= maxFee");
        assertGe(week4Fee, params.minFee, "Week4 >= minFee");
        assertLe(week4Fee, params.maxFee, "Week4 <= maxFee");

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool should remain configured");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    /**
     * @notice Creates and initializes a new pool with a specific pool type
     * @param poolType The pool type to initialize
     * @return testKey The pool key for the new pool
     * @return testPoolId The pool ID for the new pool
     */
    function _createPoolWithType(IAlphixLogic.PoolType poolType)
        internal
        returns (PoolKey memory testKey, PoolId testPoolId)
    {
        // Create new tokens
        MockERC20 token0 = new MockERC20("Test Token 0", "TEST0", 18);
        MockERC20 token1 = new MockERC20("Test Token 1", "TEST1", 18);

        // Mint tokens to test users
        vm.startPrank(owner);
        token0.mint(alice, INITIAL_TOKEN_AMOUNT);
        token0.mint(bob, INITIAL_TOKEN_AMOUNT);
        token0.mint(charlie, INITIAL_TOKEN_AMOUNT);
        token0.mint(dave, INITIAL_TOKEN_AMOUNT);
        token1.mint(alice, INITIAL_TOKEN_AMOUNT);
        token1.mint(bob, INITIAL_TOKEN_AMOUNT);
        token1.mint(charlie, INITIAL_TOKEN_AMOUNT);
        token1.mint(dave, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // Create pool key
        testKey = PoolKey({
            currency0: currency0 < currency1 ? currency0 : currency1,
            currency1: currency0 < currency1 ? currency1 : currency0,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool in PoolManager
        poolManager.initialize(testKey, Constants.SQRT_PRICE_1_1);
        testPoolId = testKey.toId();

        // Initialize pool in Alphix with specified pool type
        vm.prank(owner);
        hook.initializePool(testKey, INITIAL_FEE, INITIAL_TARGET_RATIO, poolType);
    }

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

    /**
     * @notice Precisely verify trader pays exact fees using feeGrowthGlobal
     * @dev Uses Uniswap V4's internal fee accounting for accuracy
     */
    function _performSwapAndVerifyFee(
        address trader,
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 swapAmount,
        uint128 totalLiquidity,
        bool zeroForOne
    ) internal {
        // Get current fee rate
        uint24 feeRate;
        (,,, feeRate) = poolManager.getSlot0(poolId);

        // Get fee growth before swap
        (uint256 feeGrowth0Before, uint256 feeGrowth1Before) = poolManager.getFeeGrowthGlobals(poolId);

        // Perform swap
        vm.startPrank(trader);
        _performSwap(trader, poolKey, swapAmount, zeroForOne);
        vm.stopPrank();

        // Get fee growth after swap
        (uint256 feeGrowth0After, uint256 feeGrowth1After) = poolManager.getFeeGrowthGlobals(poolId);

        // Calculate actual fees collected from feeGrowth delta
        uint256 feeGrowthDelta =
            zeroForOne ? (feeGrowth0After - feeGrowth0Before) : (feeGrowth1After - feeGrowth1Before);
        uint256 actualFeesCollected = FullMath.mulDiv(feeGrowthDelta, totalLiquidity, 1 << 128);

        // Calculate expected fees
        uint256 expectedFees = (swapAmount * feeRate) / 1_000_000;

        // Verify fees are accurate (within 0.5% tolerance for AMM curve effects)
        if (expectedFees > 0) {
            assertApproxEqRel(actualFeesCollected, expectedFees, 0.005e18, "Trader pays exact fee");
        }
    }

    /**
     * @notice Verify LP earns exact fees proportional to their liquidity
     * @dev Uses feeGrowthInside for position-specific fee tracking
     */
    function _verifyLPFeesEarned(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 lpLiquidity,
        uint256 feeGrowth0Before,
        uint256 expectedFees
    ) internal view {
        (uint256 feeGrowth0After,) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
        uint256 feeGrowthDelta = feeGrowth0After - feeGrowth0Before;
        uint256 actualFeesEarned = FullMath.mulDiv(feeGrowthDelta, lpLiquidity, 1 << 128);

        // Verify LP earned expected fees (within 0.5% tolerance)
        if (expectedFees > 0) {
            assertApproxEqRel(actualFeesEarned, expectedFees, 0.005e18, "LP earns exact proportion of fees");
        }
    }

    function _performMultipleSwaps(
        address trader,
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 swapAmount,
        uint128 totalLiquidity,
        uint8 numSwaps
    ) internal {
        for (uint256 i = 0; i < numSwaps; i++) {
            _performSwapAndVerifyFee(trader, poolKey, poolId, swapAmount, totalLiquidity, true);
        }
    }
}
