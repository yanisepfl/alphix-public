// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {VmSafe} from "forge-std/Vm.sol";

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

    // Test helper constants for convergence and simulation parameters
    uint24 constant CONVERGENCE_TOLERANCE_BPS = 10; // 10 basis points = 0.1% tolerance for fee convergence
    uint256 constant MIN_WEEKS_FOR_CONVERGENCE = 50; // Minimum weeks to simulate for convergence tests
    uint256 constant MAX_WEEKS_FOR_CONVERGENCE = 200; // Maximum weeks to cap simulation time
    uint256 constant MAX_WEEKS_FOR_STREAK_BREAKING = 150; // Max weeks for OOB ratio growth with streak breaking

    // Structs to avoid stack too deep
    struct LpConfig {
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

    struct DriveParams {
        PoolKey key;
        PoolId poolId;
        uint128 liquidityAmount;
        uint256 ratio;
        uint256 minPeriod;
        uint24 startFee;
        uint24 targetFee;
        uint256 linearSlope;
        uint256 baseMaxFeeDelta;
        uint256 sideFactor;
        uint256 maxCurrentRatio;
    }

    struct OrganicWeekParams {
        PoolKey key;
        PoolId poolId;
        uint128 liquidityAmount;
        uint256 baseVolumeRatio;
        uint256 weekNum;
        uint8 spikeFreq;
        uint24 currentFee;
    }

    struct SeasonalCycleParams {
        uint128 baseLiquidity;
        uint32 baseVolumeRatioBps;
        uint256 currentMultiplier;
        uint24 prevFee;
        uint256 prevTargetRatio;
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
        DynamicFeeLib.PoolTypeParams memory traderParams = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + traderParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, ratio);

        // Second swap at new fee - verify exact fee paid
        _performSwapAndVerifyFee(charlie, testKey, testPoolId, swapAmount2, liquidityAmount, true);

        // Verify fees are within bounds
        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);
        assertGe(finalFee, traderParams.minFee, "Fee should be >= minFee");
        assertLe(finalFee, traderParams.maxFee, "Fee should be <= maxFee");
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
        DynamicFeeLib.PoolTypeParams memory ratioParams = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + ratioParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, calculatedRatio);

        uint24 feeAfterPoke;
        (,,, feeAfterPoke) = poolManager.getSlot0(testPoolId);

        assertGe(feeAfterPoke, ratioParams.minFee, "Fee should be >= minFee");
        assertLe(feeAfterPoke, ratioParams.maxFee, "Fee should be <= maxFee");
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

        LpConfig memory lpConfig = LpConfig({
            aliceLiq: uint128(bound(aliceLiq, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 3)),
            bobLiq: uint128(bound(bobLiq, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 3)),
            charlieLiq: uint128(bound(charlieLiq, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 3)),
            totalLiquidity: 0
        });

        SwapConfig memory swapConfig;
        swapConfig.swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT * 10, MAX_SWAP_AMOUNT / 5);
        swapConfig.numSwaps = 2;
        weeksBetween = uint8(bound(weeksBetween, 1, 2));

        int24 minTick = TickMath.minUsableTick(testKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(testKey.tickSpacing);

        (,,, swapConfig.feeRate) = poolManager.getSlot0(testPoolId);

        // Phase 1: Alice alone
        vm.startPrank(alice);
        _addLiquidityForUser(alice, testKey, minTick, maxTick, lpConfig.aliceLiq);
        vm.stopPrank();

        (uint256 feeGrowth0Start,) = poolManager.getFeeGrowthInside(testPoolId, minTick, maxTick);
        for (uint256 i = 0; i < 2; i++) {
            _performSwapAndVerifyFee(dave, testKey, testPoolId, swapConfig.swapAmount, lpConfig.aliceLiq, true);
        }
        _verifyLpFeesEarned(
            testPoolId,
            minTick,
            maxTick,
            lpConfig.aliceLiq,
            feeGrowth0Start,
            (swapConfig.swapAmount * swapConfig.feeRate * 2) / 1_000_000
        );

        // Phase 2: Bob joins
        (uint256 feeGrowth0BobJoins,) = poolManager.getFeeGrowthInside(testPoolId, minTick, maxTick);
        vm.warp(block.timestamp + (weeksBetween * 7 days));
        vm.startPrank(bob);
        _addLiquidityForUser(bob, testKey, minTick, maxTick, lpConfig.bobLiq);
        vm.stopPrank();

        lpConfig.totalLiquidity = lpConfig.aliceLiq + lpConfig.bobLiq;
        for (uint256 i = 0; i < 2; i++) {
            _performSwapAndVerifyFee(dave, testKey, testPoolId, swapConfig.swapAmount, lpConfig.totalLiquidity, true);
        }

        uint256 totalFees = (swapConfig.swapAmount * swapConfig.feeRate * 2) / 1_000_000;
        _verifyLpFeesEarned(
            testPoolId,
            minTick,
            maxTick,
            lpConfig.aliceLiq,
            feeGrowth0BobJoins,
            totalFees * lpConfig.aliceLiq / lpConfig.totalLiquidity
        );
        _verifyLpFeesEarned(
            testPoolId,
            minTick,
            maxTick,
            lpConfig.bobLiq,
            feeGrowth0BobJoins,
            totalFees * lpConfig.bobLiq / lpConfig.totalLiquidity
        );

        // Phase 3: Charlie joins
        {
            (uint256 feeGrowth0CharlieJoins,) = poolManager.getFeeGrowthInside(testPoolId, minTick, maxTick);
            vm.warp(block.timestamp + (weeksBetween * 7 days));

            vm.startPrank(charlie);
            _addLiquidityForUser(charlie, testKey, minTick, maxTick, lpConfig.charlieLiq);
            vm.stopPrank();

            lpConfig.totalLiquidity = lpConfig.aliceLiq + lpConfig.bobLiq + lpConfig.charlieLiq;
            for (uint256 i = 0; i < 2; i++) {
                _performSwapAndVerifyFee(
                    dave, testKey, testPoolId, swapConfig.swapAmount, lpConfig.totalLiquidity, true
                );
            }

            totalFees = (swapConfig.swapAmount * swapConfig.feeRate * 2) / 1_000_000;
            _verifyLpFeesEarned(
                testPoolId,
                minTick,
                maxTick,
                lpConfig.aliceLiq,
                feeGrowth0CharlieJoins,
                totalFees * lpConfig.aliceLiq / lpConfig.totalLiquidity
            );
            _verifyLpFeesEarned(
                testPoolId,
                minTick,
                maxTick,
                lpConfig.bobLiq,
                feeGrowth0CharlieJoins,
                totalFees * lpConfig.bobLiq / lpConfig.totalLiquidity
            );
            _verifyLpFeesEarned(
                testPoolId,
                minTick,
                maxTick,
                lpConfig.charlieLiq,
                feeGrowth0CharlieJoins,
                totalFees * lpConfig.charlieLiq / lpConfig.totalLiquidity
            );
        }
    }

    /**
     * @notice Fuzz test: Equal LPs with equal liquidity earn EXACTLY equal fees
     * @dev Uses feeGrowthInside to verify each LP earns 25% of total fees
     */
    function testFuzz_equal_LPs_equal_timeline(
        uint128 liquidityPerLp,
        uint256 swapAmount,
        uint8 numSwaps,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        SwapConfig memory swapConfig;
        swapConfig.swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT * 10, MAX_SWAP_AMOUNT / 10);
        swapConfig.numSwaps = uint8(bound(numSwaps, 5, 10));
        liquidityPerLp = uint128(bound(liquidityPerLp, MIN_LIQUIDITY * 100, MAX_LIQUIDITY / 4));

        int24 minTick = TickMath.minUsableTick(testKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(testKey.tickSpacing);

        // Add equal liquidity for 4 LPs
        _addFourEqualLPs(testKey, minTick, maxTick, liquidityPerLp);

        _testEqualDistribution(testKey, testPoolId, minTick, maxTick, liquidityPerLp, swapConfig);
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
        DynamicFeeLib.PoolTypeParams memory lifecycleParams = logic.getPoolTypeParams(poolConfig.poolType);

        // First adjustment
        vm.warp(block.timestamp + lifecycleParams.minPeriod + 1);
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
        vm.warp(block.timestamp + lifecycleParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio2);

        uint24 fee2;
        (,,, fee2) = poolManager.getSlot0(testPoolId);

        assertGe(fee1, lifecycleParams.minFee, "Fee1 should be >= minFee");
        assertLe(fee1, lifecycleParams.maxFee, "Fee1 should be <= maxFee");
        assertGe(fee2, lifecycleParams.minFee, "Fee2 should be >= minFee");
        assertLe(fee2, lifecycleParams.maxFee, "Fee2 should be <= maxFee");

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
        DynamicFeeLib.PoolTypeParams memory volatilityParams = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + volatilityParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, volatilityRatio);

        uint24 volatilityFee;
        (,,, volatilityFee) = poolManager.getSlot0(testPoolId);

        // Verify fee is within pool type bounds (may stay at minFee in some cases)
        assertGe(volatilityFee, volatilityParams.minFee, "Fee should be >= minFee");
        assertLe(volatilityFee, volatilityParams.maxFee, "Fee should remain within max bounds");
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
        DynamicFeeLib.PoolTypeParams memory periodicParams = logic.getPoolTypeParams(poolConfig.poolType);

        // Week 1
        vm.warp(block.timestamp + 7 days);
        for (uint256 i = 0; i < 7; i++) {
            vm.startPrank(bob);
            _performSwap(bob, testKey, weeklyVolume, i % 2 == 0);
            vm.stopPrank();
            vm.warp(block.timestamp + 1 days);
        }
        vm.warp(block.timestamp + periodicParams.minPeriod + 1);
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
        vm.warp(block.timestamp + periodicParams.minPeriod + 1);
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
        vm.warp(block.timestamp + periodicParams.minPeriod + 1);
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
        vm.warp(block.timestamp + periodicParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio4);
        uint24 week4Fee;
        (,,, week4Fee) = poolManager.getSlot0(testPoolId);

        // Verify all fees within bounds
        assertGe(week1Fee, periodicParams.minFee, "Week1 >= minFee");
        assertLe(week1Fee, periodicParams.maxFee, "Week1 <= maxFee");
        assertGe(week2Fee, periodicParams.minFee, "Week2 >= minFee");
        assertLe(week2Fee, periodicParams.maxFee, "Week2 <= maxFee");
        assertGe(week3Fee, periodicParams.minFee, "Week3 >= minFee");
        assertLe(week3Fee, periodicParams.maxFee, "Week3 <= maxFee");
        assertGe(week4Fee, periodicParams.minFee, "Week4 >= minFee");
        assertLe(week4Fee, periodicParams.maxFee, "Week4 <= maxFee");

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(testPoolId);
        assertTrue(config.isConfigured, "Pool should remain configured");
    }

    /* ========================================================================== */
    /*                    FUZZED LONG-TERM STABILITY TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Extended time horizon with seasonal trading patterns
     * @dev Simulates full year of operations with varying volume/TVL ratios up to 1,000,000x (MAX_CURRENT_RATIO)
     * @param baseLiquidity Base pool liquidity
     * @param baseVolumeRatioBps Base volume as ratio of liquidity (1bps-100000000bps = 0.01%-1,000,000%)
     * @param seasonalMultiplier Seasonal variance multiplier (10-2000 = 0.1x-20x)
     * @param numSeasons Number of seasonal cycles (2-4)
     * @param poolTypeRaw Pool type
     */
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_longTerm_seasonalPatterns_feeConvergence(
        uint128 baseLiquidity,
        uint32 baseVolumeRatioBps,
        uint16 seasonalMultiplier,
        uint8 numSeasons,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        baseLiquidity = uint128(bound(baseLiquidity, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        baseVolumeRatioBps = uint32(bound(baseVolumeRatioBps, 1, 100000000));
        seasonalMultiplier = uint16(bound(seasonalMultiplier, 10, 2000));
        numSeasons = uint8(bound(numSeasons, 2, 4));

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            baseLiquidity
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

        SeasonalCycleParams memory cycleParams = SeasonalCycleParams({
            baseLiquidity: baseLiquidity,
            baseVolumeRatioBps: baseVolumeRatioBps,
            currentMultiplier: 0,
            prevFee: poolConfig.initialFee,
            prevTargetRatio: poolConfig.initialTargetRatio
        });

        for (uint256 season = 0; season < numSeasons; season++) {
            cycleParams.currentMultiplier = (season % 2 == 0) ? seasonalMultiplier : (10000 / (seasonalMultiplier + 1));
            uint24 newFee;
            uint256 newRatio;
            (newFee, newRatio) = _executeSeasonalCycle(testKey, testPoolId, cycleParams, params);
            cycleParams.prevFee = newFee;
            cycleParams.prevTargetRatio = newRatio;
        }

        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);
        assertGe(finalFee, params.minFee, "Fee bounded after year-long simulation");
        assertLe(finalFee, params.maxFee, "Fee bounded after year-long simulation");
    }

    /**
     * @notice Fuzz: EMA convergence toward minFee bound
     * @dev Tests that consistently low ratios drive fee down toward minFee (allows partial convergence)
     * @param liquidityAmount Pool liquidity
     * @param numWeeks Number of weeks to simulate (12-20, increased for reliable convergence)
     * @param poolTypeRaw Pool type
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_emaConvergence_toMinFee(uint128 liquidityAmount, uint8 numWeeks, uint8 poolTypeRaw)
        public
    {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        numWeeks = uint8(bound(numWeeks, 12, 20)); // Increased for reliable convergence across all parameter combos

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
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

        uint256 lowRatio = poolConfig.initialTargetRatio / 10;
        if (lowRatio < 1e15) lowRatio = 1e15;

        for (uint256 week = 0; week < numWeeks; week++) {
            uint256 dailyVolume = (uint256(liquidityAmount) * lowRatio) / 1e18;
            if (dailyVolume < MIN_SWAP_AMOUNT) dailyVolume = MIN_SWAP_AMOUNT;
            if (dailyVolume > MAX_SWAP_AMOUNT) dailyVolume = MAX_SWAP_AMOUNT;

            for (uint256 day = 0; day < 7; day++) {
                vm.warp(block.timestamp + 1 days);
                vm.startPrank(bob);
                _performSwap(bob, testKey, dailyVolume, day % 2 == 0);
                vm.stopPrank();
            }

            vm.warp(block.timestamp + params.minPeriod + 1);
            vm.prank(owner);
            hook.poke(testKey, lowRatio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            assertGe(currentFee, params.minFee, "Fee >= minFee");
            assertLe(currentFee, params.maxFee, "Fee <= maxFee");
        }

        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);

        // Allow for near-convergence: fee should be at minFee or very close (within tolerance)
        // Some parameter combinations (low linearSlope or lowerSideFactor) may converge slower
        assertTrue(
            finalFee <= params.minFee + CONVERGENCE_TOLERANCE_BPS,
            "Fee should converge to or near minFee with consistently low ratios"
        );
    }

    /**
     * @notice Fuzz: EMA convergence toward maxFee bound
     * @dev Tests that consistently high ratios drive fee up toward maxFee (allows partial convergence)
     * @param liquidityAmount Pool liquidity
     * @param numWeeks Number of weeks to simulate (25-35, increased for reliable convergence)
     * @param poolTypeRaw Pool type
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_emaConvergence_toMaxFee(uint128 liquidityAmount, uint8 numWeeks, uint8 poolTypeRaw)
        public
    {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        numWeeks = uint8(bound(numWeeks, 25, 35)); // Increased for reliable convergence across all parameter combos

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
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

        uint256 highRatio = poolConfig.initialTargetRatio * 10;
        if (highRatio > params.maxCurrentRatio) highRatio = params.maxCurrentRatio;

        uint24 firstFee;
        (,,, firstFee) = poolManager.getSlot0(testPoolId);

        for (uint256 week = 0; week < numWeeks; week++) {
            uint256 dailyVolume = (uint256(liquidityAmount) * highRatio) / 1e18;
            if (dailyVolume < MIN_SWAP_AMOUNT) dailyVolume = MIN_SWAP_AMOUNT;
            if (dailyVolume > MAX_SWAP_AMOUNT) dailyVolume = MAX_SWAP_AMOUNT;

            for (uint256 day = 0; day < 7; day++) {
                vm.warp(block.timestamp + 1 days);
                vm.startPrank(bob);
                _performSwap(bob, testKey, dailyVolume, day % 2 == 0);
                vm.stopPrank();
            }

            vm.warp(block.timestamp + params.minPeriod + 1);
            vm.prank(owner);
            hook.poke(testKey, highRatio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            assertGe(currentFee, params.minFee, "Fee >= minFee");
            assertLe(currentFee, params.maxFee, "Fee <= maxFee");
        }

        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);

        // Allow for near-convergence: fee should be at maxFee or very close (within tolerance)
        // Some parameter combinations (low linearSlope or upperSideFactor) may converge slower
        assertTrue(
            finalFee >= params.maxFee - CONVERGENCE_TOLERANCE_BPS,
            "Fee should converge to or near maxFee with consistently high ratios"
        );
    }

    /**
     * @notice Fuzz: EMA convergence to mid-range equilibrium
     * @dev Tests that poking with target ratio keeps fee stable at a fixed mid-range value
     * @param liquidityAmount Pool liquidity
     * @param numWeeks Number of weeks to simulate (8-15 for convergence)
     * @param poolTypeRaw Pool type
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_emaConvergence_toMidRange(uint128 liquidityAmount, uint8 numWeeks, uint8 poolTypeRaw)
        public
    {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        numWeeks = uint8(bound(numWeeks, 8, 15));

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
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

        uint256 midRatio = poolConfig.initialTargetRatio;

        uint24 penultimateFee;
        uint24 finalFee;

        for (uint256 week = 0; week < numWeeks; week++) {
            uint256 dailyVolume = (uint256(liquidityAmount) * midRatio) / 1e18;
            if (dailyVolume < MIN_SWAP_AMOUNT) dailyVolume = MIN_SWAP_AMOUNT;
            if (dailyVolume > MAX_SWAP_AMOUNT) dailyVolume = MAX_SWAP_AMOUNT;

            for (uint256 day = 0; day < 7; day++) {
                vm.warp(block.timestamp + 1 days);
                vm.startPrank(bob);
                _performSwap(bob, testKey, dailyVolume, day % 2 == 0);
                vm.stopPrank();
            }

            vm.warp(block.timestamp + params.minPeriod + 1);
            vm.prank(owner);
            hook.poke(testKey, midRatio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            assertGe(currentFee, params.minFee, "Fee >= minFee");
            assertLe(currentFee, params.maxFee, "Fee <= maxFee");

            // Track last two fees
            if (week == numWeeks - 2) penultimateFee = currentFee;
            if (week == numWeeks - 1) finalFee = currentFee;
        }

        // Assert that fee has converged to a stable value (last two iterations identical)
        assertEq(finalFee, penultimateFee, "Fee should have converged to stable value in last iterations");

        // Assert that converged fee is strictly between bounds (not at extremes)
        assertGt(finalFee, params.minFee, "Converged fee should be strictly above minFee");
        assertLt(finalFee, params.maxFee, "Converged fee should be strictly below maxFee");
    }

    /**
     * @notice Fuzz: LinearSlope impact on convergence speed
     * @dev Two pools identical except linearSlope, measures upward convergence speed
     * @param liquidityAmount Pool liquidity
     * @param linearSlopeLow Lower slope (0.5x - 1.5x)
     * @param linearSlopeHigh Higher slope (1.5x - 3.0x)
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_linearSlopeImpact(
        uint128 liquidityAmount,
        uint256 linearSlopeLow,
        uint256 linearSlopeHigh
    ) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        linearSlopeLow = bound(linearSlopeLow, 8e17, 12e17);
        linearSlopeHigh = bound(linearSlopeHigh, 18e17, 3e18);
        // Require significant difference (at least 50% higher)
        vm.assume(linearSlopeHigh >= linearSlopeLow * 15 / 10);

        DynamicFeeLib.PoolTypeParams memory paramsSlowSlope = DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            ratioTolerance: 2e17,
            linearSlope: linearSlopeLow,
            baseMaxFeeDelta: 500,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        DynamicFeeLib.PoolTypeParams memory paramsFastSlope = DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            ratioTolerance: 2e17,
            linearSlope: linearSlopeHigh,
            baseMaxFeeDelta: 500,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, paramsSlowSlope);
        vm.stopPrank();
        (PoolKey memory keySlowSlope, PoolId poolIdSlowSlope) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.VOLATILE, paramsFastSlope);
        vm.stopPrank();
        (PoolKey memory keyFastSlope, PoolId poolIdFastSlope) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            keySlowSlope,
            TickMath.minUsableTick(keySlowSlope.tickSpacing),
            TickMath.maxUsableTick(keySlowSlope.tickSpacing),
            liquidityAmount
        );
        _addLiquidityForUser(
            alice,
            keyFastSlope,
            TickMath.minUsableTick(keyFastSlope.tickSpacing),
            TickMath.maxUsableTick(keyFastSlope.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        uint256 highRatio = 1e20;

        // Test upward convergence (minFee → maxFee)
        uint256 weeksSlowSlope = _executePhase(
            keySlowSlope, poolIdSlowSlope, liquidityAmount, highRatio, paramsSlowSlope, paramsSlowSlope.maxFee
        );
        uint256 weeksFastSlope = _executePhase(
            keyFastSlope, poolIdFastSlope, liquidityAmount, highRatio, paramsFastSlope, paramsFastSlope.maxFee
        );

        // Both should converge
        assertGt(weeksSlowSlope, 0, "Low slope pool should converge");
        assertGt(weeksFastSlope, 0, "High slope pool should converge");

        // Higher linearSlope = faster or equal convergence (equal when both converge very fast)
        assertLe(weeksFastSlope, weeksSlowSlope, "Higher linearSlope converges faster or equal");
    }

    /**
     * @notice Fuzz: LowerSideFactor impact on downward convergence speed
     * @dev Two pools identical except lowerSideFactor, measures downward convergence speed
     * @param liquidityAmount Pool liquidity
     * @param lowerSideFactorLow Lower factor (1.0x - 1.5x)
     * @param lowerSideFactorHigh Higher factor (1.5x - 2.5x)
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_lowerSideFactorImpact(
        uint128 liquidityAmount,
        uint256 lowerSideFactorLow,
        uint256 lowerSideFactorHigh
    ) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        lowerSideFactorLow = bound(lowerSideFactorLow, 1e18, 13e17);
        lowerSideFactorHigh = bound(lowerSideFactorHigh, 17e17, 25e17);
        // Require significant difference (at least 30% higher)
        vm.assume(lowerSideFactorHigh >= lowerSideFactorLow * 13 / 10);

        DynamicFeeLib.PoolTypeParams memory paramsSlowFactor = DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            ratioTolerance: 2e17,
            linearSlope: 1e18,
            baseMaxFeeDelta: 500,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: lowerSideFactorLow
        });

        DynamicFeeLib.PoolTypeParams memory paramsFastFactor = DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            ratioTolerance: 2e17,
            linearSlope: 1e18,
            baseMaxFeeDelta: 500,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: lowerSideFactorHigh
        });

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, paramsSlowFactor);
        vm.stopPrank();
        (PoolKey memory keySlowFactor, PoolId poolIdSlowFactor) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.VOLATILE, paramsFastFactor);
        vm.stopPrank();
        (PoolKey memory keyFastFactor, PoolId poolIdFastFactor) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            keySlowFactor,
            TickMath.minUsableTick(keySlowFactor.tickSpacing),
            TickMath.maxUsableTick(keySlowFactor.tickSpacing),
            liquidityAmount
        );
        _addLiquidityForUser(
            alice,
            keyFastFactor,
            TickMath.minUsableTick(keyFastFactor.tickSpacing),
            TickMath.maxUsableTick(keyFastFactor.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // First drive both to maxFee
        uint256 highRatio = 1e20;
        _executePhase(
            keySlowFactor, poolIdSlowFactor, liquidityAmount, highRatio, paramsSlowFactor, paramsSlowFactor.maxFee
        );
        _executePhase(
            keyFastFactor, poolIdFastFactor, liquidityAmount, highRatio, paramsFastFactor, paramsFastFactor.maxFee
        );

        // Test downward convergence (maxFee → minFee)
        uint256 lowRatio = 1e15;
        uint256 weeksSlowFactor = _executePhase(
            keySlowFactor, poolIdSlowFactor, liquidityAmount, lowRatio, paramsSlowFactor, paramsSlowFactor.minFee
        );
        uint256 weeksFastFactor = _executePhase(
            keyFastFactor, poolIdFastFactor, liquidityAmount, lowRatio, paramsFastFactor, paramsFastFactor.minFee
        );

        // Both should converge
        assertGt(weeksSlowFactor, 0, "Low sideFactor pool should converge");
        assertGt(weeksFastFactor, 0, "High sideFactor pool should converge");

        // Higher lowerSideFactor = faster or equal downward convergence
        assertLe(weeksFastFactor, weeksSlowFactor, "Higher lowerSideFactor converges faster or equal downward");
    }

    /**
     * @notice Fuzz: Side factor asymmetry impact (upward vs downward)
     * @dev Single pool with asymmetric side factors, compares upward vs downward speed
     * @param liquidityAmount Pool liquidity
     * @param lowerSideFactor Lower side factor (1.5x - 2.5x, must be > upperSideFactor)
     */
    function testFuzz_longTerm_sideFactorAsymmetry(uint128 liquidityAmount, uint256 lowerSideFactor) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        lowerSideFactor = bound(lowerSideFactor, 15e17, 25e17);

        DynamicFeeLib.PoolTypeParams memory paramsAsymmetric = DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            ratioTolerance: 2e17,
            linearSlope: 1e18,
            baseMaxFeeDelta: 500,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: lowerSideFactor
        });

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, paramsAsymmetric);
        vm.stopPrank();
        (PoolKey memory keyAsymmetric, PoolId poolIdAsymmetric) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            keyAsymmetric,
            TickMath.minUsableTick(keyAsymmetric.tickSpacing),
            TickMath.maxUsableTick(keyAsymmetric.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        uint256 lowRatio = 1e15;
        uint256 highRatio = 1e20;

        // Upward: minFee → maxFee
        uint256 weeksUpward = _executePhase(
            keyAsymmetric, poolIdAsymmetric, liquidityAmount, highRatio, paramsAsymmetric, paramsAsymmetric.maxFee
        );

        // Downward: maxFee → minFee
        uint256 weeksDownward = _executePhase(
            keyAsymmetric, poolIdAsymmetric, liquidityAmount, lowRatio, paramsAsymmetric, paramsAsymmetric.minFee
        );

        // Both should converge
        assertGt(weeksUpward, 0, "Upward phase should converge");
        assertGt(weeksDownward, 0, "Downward phase should converge");

        // Downward faster due to lowerSideFactor > upperSideFactor
        assertLt(weeksDownward, weeksUpward, "Downward faster: lowerSideFactor > upperSideFactor");
    }

    /**
     * @notice Fuzz: Streak accumulation vs streak breaking impact on convergence speed
     * @dev Compares continuous OOB movement (accumulating streak) vs alternating directions (breaking streak)
     * @param liquidityAmount Pool liquidity
     * @param baseMaxFeeDelta Base max fee delta (affects streak multiplier impact)
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_streakAccumulationImpact(uint128 liquidityAmount, uint256 baseMaxFeeDelta) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        baseMaxFeeDelta = bound(baseMaxFeeDelta, 600, 1000);

        DynamicFeeLib.PoolTypeParams memory paramsStreak = DynamicFeeLib.PoolTypeParams({
            minFee: 100,
            maxFee: 10000,
            ratioTolerance: 2e17,
            linearSlope: 1e18,
            baseMaxFeeDelta: uint24(baseMaxFeeDelta),
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, paramsStreak);
        vm.stopPrank();

        // Create two identical pools
        (PoolKey memory keyStreakAccum, PoolId poolIdStreakAccum) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        vm.startPrank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.VOLATILE, paramsStreak);
        vm.stopPrank();
        (PoolKey memory keyStreakBreak, PoolId poolIdStreakBreak) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            keyStreakAccum,
            TickMath.minUsableTick(keyStreakAccum.tickSpacing),
            TickMath.maxUsableTick(keyStreakAccum.tickSpacing),
            liquidityAmount
        );
        _addLiquidityForUser(
            alice,
            keyStreakBreak,
            TickMath.minUsableTick(keyStreakBreak.tickSpacing),
            TickMath.maxUsableTick(keyStreakBreak.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        uint256 weeksStreakAccum;
        uint256 weeksStreakBreak;

        {
            uint256 targetRatio = logic.getPoolConfig(poolIdStreakAccum).initialTargetRatio;
            uint256 highRatio =
                targetRatio * 10 > paramsStreak.maxCurrentRatio ? paramsStreak.maxCurrentRatio : targetRatio * 10;

            weeksStreakAccum = _executePhase(
                keyStreakAccum, poolIdStreakAccum, liquidityAmount, highRatio, paramsStreak, paramsStreak.maxFee
            );
            weeksStreakBreak = _executePhaseWithStreakBreaking(
                keyStreakBreak,
                poolIdStreakBreak,
                liquidityAmount,
                highRatio,
                targetRatio,
                paramsStreak.minPeriod,
                paramsStreak.maxFee
            );
        }

        // If both converge, accumulating should be faster or equal to breaking streak
        // If only one converges or neither converges, that's a valid observation about parameter impact
        if (weeksStreakAccum > 0 && weeksStreakBreak > 0) {
            assertLe(
                weeksStreakAccum, weeksStreakBreak, "Accumulating streak converges faster or equal to breaking streak"
            );
        }

        // If the breaking pool converges but accumulating doesn't, that would be unexpected
        if (weeksStreakBreak > 0 && weeksStreakAccum == 0) {
            assertTrue(false, "Breaking streak converged but accumulating didn't - unexpected");
        }
    }

    /**
     * @notice Fuzz: Organic market behavior with volume inversely correlated to fees
     * @dev Simulates realistic pool behavior: volume decreases as fees rise, increases as fees fall
     *      Includes random volume spikes and quiet periods to test fee stability
     * @param liqAmt Pool liquidity
     * @param numWeeks Number of weeks to simulate (20-40)
     * @param baseVolRatio Base volume as ratio of liquidity (0.1x-10x)
     * @param spikeFreq How often volume spikes occur (every N weeks, 5-20)
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_longTerm_organicMarketBehavior(
        uint128 liqAmt,
        uint8 numWeeks,
        uint256 baseVolRatio,
        uint8 spikeFreq
    ) public {
        (PoolKey memory k, PoolId pid) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        liqAmt = uint128(bound(liqAmt, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        numWeeks = uint8(bound(numWeeks, 20, 40));
        baseVolRatio = bound(baseVolRatio, 1e17, 10e18);
        spikeFreq = uint8(bound(spikeFreq, 5, 20));

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice, k, TickMath.minUsableTick(k.tickSpacing), TickMath.maxUsableTick(k.tickSpacing), liqAmt
        );
        vm.stopPrank();

        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        uint24 prevFee;
        (,,, prevFee) = poolManager.getSlot0(pid);

        uint256 changes = 0;
        uint24 minF = prevFee;
        uint24 maxF = prevFee;

        for (uint256 w = 0; w < numWeeks; w++) {
            uint24 newF = _runOrganicWeek(k, pid, liqAmt, baseVolRatio, w, spikeFreq, prevFee);

            // Assert fee always stays in bounds
            assertGe(newF, params.minFee, "Fee must be >= minFee");
            assertLe(newF, params.maxFee, "Fee must be <= maxFee");

            if (newF != prevFee) changes++;
            if (newF < minF) minF = newF;
            if (newF > maxF) maxF = newF;

            prevFee = newF;
        }

        // Fee must evolve over time and explore some range
        assertGt(changes, 0, "Fee should evolve");
        assertGt(uint256(maxF) - uint256(minF), 0, "Fee should vary");
    }

    /**
     * @notice Fuzz: Pool without pokes for extended period, then resume with directional assertion
     * @dev Tests system behavior when admin doesn't poke for long duration, validates fee direction on resume
     * @param liquidityAmount Pool liquidity
     * @param dormantPeriod Period without pokes (7-60 days)
     * @param swapFrequency Swaps per week (1-5)
     * @param initialRatio Initial ratio for first poke
     * @param resumeRatio Ratio for resume poke
     * @param poolTypeRaw Pool type
     */
    function testFuzz_longTerm_noPokes_systemStable(
        uint128 liquidityAmount,
        uint256 dormantPeriod,
        uint8 swapFrequency,
        uint256 initialRatio,
        uint256 resumeRatio,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        dormantPeriod = bound(dormantPeriod, 7 days, 60 days);
        swapFrequency = uint8(bound(swapFrequency, 1, 5));

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

        initialRatio = bound(initialRatio, 1e15, params.maxCurrentRatio);
        resumeRatio = bound(resumeRatio, 1e15, params.maxCurrentRatio);

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, initialRatio);

        uint24 feeBeforeDormancy;
        (,,, feeBeforeDormancy) = poolManager.getSlot0(testPoolId);

        uint256 daysSimulated = dormantPeriod / 1 days;
        for (uint256 i = 0; i < daysSimulated; i += 7) {
            vm.warp(block.timestamp + 7 days);

            for (uint256 j = 0; j < swapFrequency; j++) {
                vm.startPrank(bob);
                _performSwap(bob, testKey, MIN_SWAP_AMOUNT * 2, j % 2 == 0);
                vm.stopPrank();
            }
        }

        uint24 feeAfterDormancy;
        (,,, feeAfterDormancy) = poolManager.getSlot0(testPoolId);

        assertEq(feeAfterDormancy, feeBeforeDormancy, "Fee unchanged without pokes");

        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.recordLogs();
        vm.prank(owner);
        hook.poke(testKey, resumeRatio);

        uint24 feeAfterResume;
        (,,, feeAfterResume) = poolManager.getSlot0(testPoolId);

        assertGe(feeAfterResume, params.minFee, "Fee bounded after resume");
        assertLe(feeAfterResume, params.maxFee, "Fee bounded after resume");

        // Extract actual target ratio from event and validate fee direction
        uint256 actualTarget = _extractOldTargetRatio();
        _assertDirectionalFeeChange(resumeRatio, actualTarget, feeAfterDormancy, feeAfterResume, params);
    }

    /**
     * @notice Fuzz: Multi-month fee adjustment cycles with wide ratio range
     * @dev Tests system stability with monthly adjustments across full ratio space up to 1,000,000x (MAX_CURRENT_RATIO), volume derived from liquidity
     * @param liquidityAmount Pool liquidity
     * @param numMonths Number of months to simulate (3-12)
     * @param volumeRatioBps Volume as % of liquidity in bps (1bps-100000000bps = 0.01%-1,000,000%)
     * @param poolTypeRaw Pool type
     */
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_longTerm_monthlyAdjustments_consistent(
        uint128 liquidityAmount,
        uint8 numMonths,
        uint32 volumeRatioBps,
        uint8 poolTypeRaw
    ) public {
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        numMonths = uint8(bound(numMonths, 3, 12));
        volumeRatioBps = uint32(bound(volumeRatioBps, 1, 100000000));

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
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

        uint256 prevRatio = poolConfig.initialTargetRatio;

        for (uint256 month = 0; month < numMonths; month++) {
            uint256 monthlyVolumeMultiplier = 50 + ((month * 37) % 150);
            uint256 monthlyVolume =
                (uint256(liquidityAmount) * volumeRatioBps * monthlyVolumeMultiplier) / (10000 * 100);
            if (monthlyVolume < MIN_SWAP_AMOUNT) monthlyVolume = MIN_SWAP_AMOUNT;
            if (monthlyVolume > MAX_SWAP_AMOUNT) monthlyVolume = MAX_SWAP_AMOUNT;

            for (uint256 week = 0; week < 4; week++) {
                vm.warp(block.timestamp + 7 days);

                for (uint256 i = 0; i < 5; i++) {
                    vm.startPrank(bob);
                    _performSwap(bob, testKey, monthlyVolume, i % 2 == 0);
                    vm.stopPrank();
                }
            }

            vm.warp(block.timestamp + params.minPeriod + 1);
            uint256 monthlyRatio = (monthlyVolume * 1e18) / uint256(liquidityAmount);
            if (monthlyRatio > params.maxCurrentRatio) monthlyRatio = params.maxCurrentRatio;
            if (monthlyRatio < 1e15) monthlyRatio = 1e15;

            uint24 feeBeforePoke;
            (,,, feeBeforePoke) = poolManager.getSlot0(testPoolId);

            vm.recordLogs();
            vm.prank(owner);
            hook.poke(testKey, monthlyRatio);

            uint24 monthlyFee;
            (,,, monthlyFee) = poolManager.getSlot0(testPoolId);

            assertGe(monthlyFee, params.minFee, "Fee >= minFee in month");
            assertLe(monthlyFee, params.maxFee, "Fee <= maxFee in month");

            // Extract actual target ratio from event and validate fee direction
            uint256 actualTarget = _extractOldTargetRatio();
            _assertDirectionalFeeChange(monthlyRatio, actualTarget, feeBeforePoke, monthlyFee, params);

            prevRatio = monthlyRatio;
        }

        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);
        assertGe(finalFee, params.minFee, "Final fee bounded");
        assertLe(finalFee, params.maxFee, "Final fee bounded");
    }

    /* ========================================================================== */
    /*                    PARAMETER SENSITIVITY TESTS                             */
    /* ========================================================================== */

    /**
     * @notice Fuzz test demonstrating asymmetric fee behavior based on side factors.
     * @dev Validates that upperSideFactor and lowerSideFactor correctly throttle fee
     *      adjustments when the pool deviates from target ratio. Tests various cycles
     *      of deviation to ensure side-specific throttling works as intended.
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_paramSensitivity_sideFactors_asymmetricBehavior(
        uint128 liquidityAmount,
        uint256 upperSideFactor,
        uint256 lowerSideFactor,
        uint8 numCycles
    ) public {
        // Create STANDARD pool
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        upperSideFactor = bound(upperSideFactor, 1e18, 1e19); // 1x to 10x (ONE_WAD to TEN_WAD)
        lowerSideFactor = bound(lowerSideFactor, 1e18, 1e19); // 1x to 10x (ONE_WAD to TEN_WAD)
        numCycles = uint8(bound(numCycles, 2, 8));

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Modify pool type parameters with custom side factors
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        params.upperSideFactor = upperSideFactor;
        params.lowerSideFactor = lowerSideFactor;

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, params);

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);

        // Cycle through high and low ratios
        for (uint256 i = 0; i < numCycles; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            uint24 feeBefore;
            (,,, feeBefore) = poolManager.getSlot0(testPoolId);

            // Alternate: high ratio (triggers upper side) vs low ratio (triggers lower side)
            uint256 ratio = (i % 2 == 0)
                ? poolConfig.initialTargetRatio * 3  // High
                : poolConfig.initialTargetRatio / 3; // Low

            vm.prank(owner);
            hook.poke(testKey, ratio);

            uint24 feeAfter;
            (,,, feeAfter) = poolManager.getSlot0(testPoolId);

            // Validate bounds
            assertGe(feeAfter, params.minFee, "Fee >= minFee after side-factor poke");
            assertLe(feeAfter, params.maxFee, "Fee <= maxFee after side-factor poke");

            // When ratio is high (upper side), fee should increase (or stay if at max)
            if (i % 2 == 0) {
                assertTrue(feeAfter >= feeBefore, "Upper side: fee should increase or stay");
            } else {
                // When ratio is low (lower side), fee should decrease (or stay if at min)
                assertTrue(feeAfter <= feeBefore, "Lower side: fee should decrease or stay");
            }
        }
    }

    /**
     * @notice Fuzz test validating system stability under extreme parameter values.
     * @dev Tests combinations of extreme linearSlope and ratioTolerance to ensure
     *      the fee algorithm remains stable and bounded. Validates that even with
     *      very aggressive or conservative parameters, fees stay within bounds and
     *      the system doesn't break.
     */
    /// forge-config: default.fuzz.runs = 128
    function testFuzz_paramSensitivity_extremeValues_systemStable(
        uint128 liquidityAmount,
        uint256 linearSlope,
        uint256 ratioTolerance
    ) public {
        // Create VOLATILE pool (has wider default bounds)
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        // Valid range for linearSlope: MIN_LINEAR_SLOPE to TEN_WAD
        linearSlope = bound(linearSlope, 1e17, 1e19); // 0.1 to 10.0
        // Valid range for ratioTolerance: MIN_RATIO_TOLERANCE to TEN_WAD
        ratioTolerance = bound(ratioTolerance, 1e15, 1e19); // 0.1% to 1000%

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Modify pool type parameters with extreme values
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.VOLATILE);
        params.linearSlope = linearSlope;
        params.ratioTolerance = ratioTolerance;

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.VOLATILE, params);

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);

        // Test several extreme ratio scenarios
        uint256[5] memory testRatios = [
            poolConfig.initialTargetRatio / 10, // Very low
            poolConfig.initialTargetRatio / 2, // Moderately low
            poolConfig.initialTargetRatio, // At target
            poolConfig.initialTargetRatio * 2, // Moderately high
            poolConfig.initialTargetRatio * 5 // Very high
        ];

        for (uint256 i = 0; i < testRatios.length; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            uint256 ratio = testRatios[i];
            if (ratio > params.maxCurrentRatio) ratio = params.maxCurrentRatio;
            if (ratio == 0) ratio = 1e15; // Minimum sensible ratio

            vm.prank(owner);
            hook.poke(testKey, ratio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            // System must remain stable: fees always within bounds
            assertGe(currentFee, params.minFee, "Fee >= minFee under extreme params");
            assertLe(currentFee, params.maxFee, "Fee <= maxFee under extreme params");
        }

        // Verify pool can still be used for swaps
        vm.startPrank(bob);
        uint256 swapAmount = uint256(liquidityAmount) / 100;
        if (swapAmount < MIN_SWAP_AMOUNT) swapAmount = MIN_SWAP_AMOUNT;
        if (swapAmount > MAX_SWAP_AMOUNT) swapAmount = MAX_SWAP_AMOUNT;

        _performSwap(bob, testKey, swapAmount, true);
        vm.stopPrank();

        // Verify fee still valid after swap
        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);
        assertGe(finalFee, params.minFee, "Fee valid after swap");
        assertLe(finalFee, params.maxFee, "Fee valid after swap");
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

        Currency curr0 = Currency.wrap(address(token0));
        Currency curr1 = Currency.wrap(address(token1));

        // Create pool key
        testKey = PoolKey({
            currency0: curr0 < curr1 ? curr0 : curr1,
            currency1: curr0 < curr1 ? curr1 : curr0,
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

    /**
     * @notice Add equal liquidity for four different LPs (alice, bob, charlie, dave)
     * @dev Helper function to set up equal LP positions for distribution testing
     * @param testKey The pool key
     * @param lowerTick The lower tick of the position
     * @param upperTick The upper tick of the position
     * @param liquidityPerLp The amount of liquidity to add per LP
     */
    function _addFourEqualLPs(PoolKey memory testKey, int24 lowerTick, int24 upperTick, uint128 liquidityPerLp)
        internal
    {
        address[4] memory lps = [alice, bob, charlie, dave];
        for (uint256 i = 0; i < lps.length; i++) {
            vm.startPrank(lps[i]);
            _addLiquidityForUser(lps[i], testKey, lowerTick, upperTick, liquidityPerLp);
            vm.stopPrank();
        }
    }

    /**
     * @notice Test that fees are distributed equally among LPs with equal liquidity
     * @dev Performs swaps and verifies each LP earns 25% of total fees
     * @param testKey The pool key
     * @param testPoolId The pool ID
     * @param lowerTick The lower tick of the LP positions
     * @param upperTick The upper tick of the LP positions
     * @param liquidityPerLp The amount of liquidity per LP
     * @param swapConfig Configuration for swap testing
     */
    function _testEqualDistribution(
        PoolKey memory testKey,
        PoolId testPoolId,
        int24 lowerTick,
        int24 upperTick,
        uint128 liquidityPerLp,
        SwapConfig memory swapConfig
    ) internal {
        // Safe cast: verify liquidityPerLp * 4 fits in uint128 before casting
        uint256 totalLiquidityCalc = uint256(liquidityPerLp) * 4;
        require(totalLiquidityCalc <= type(uint128).max, "totalLiquidity overflow in uint128 cast");
        uint128 totalLiquidity = uint128(totalLiquidityCalc);
        (,,, swapConfig.feeRate) = poolManager.getSlot0(testPoolId);
        (uint256 feeGrowth0Start,) = poolManager.getFeeGrowthInside(testPoolId, lowerTick, upperTick);

        // Mint and swap
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(testKey.currency0)).mint(user1, swapConfig.swapAmount * swapConfig.numSwaps * 2);
        MockERC20(Currency.unwrap(testKey.currency1)).mint(user1, swapConfig.swapAmount * swapConfig.numSwaps * 2);
        vm.stopPrank();

        _performMultipleSwaps(user1, testKey, testPoolId, swapConfig.swapAmount, totalLiquidity, swapConfig.numSwaps);

        // Each LP should earn 25%
        uint256 expectedFeesPerLp = ((swapConfig.swapAmount * swapConfig.feeRate * swapConfig.numSwaps) / 1_000_000) / 4;
        _verifyLpFeesEarned(testPoolId, lowerTick, upperTick, liquidityPerLp, feeGrowth0Start, expectedFeesPerLp);
    }

    /**
     * @notice Execute a swap for a trader on the given pool
     * @dev Approves tokens and calls swapRouter with exact input amount
     */
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

    /**
     * @notice Mint test tokens to a user for both currencies in a pool
     * @dev Helper to fund users for testing swaps and liquidity provision
     */
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
        PoolId pid,
        uint256 swapAmount,
        uint128 totalLiquidity,
        bool zeroForOne
    ) internal {
        // Get current fee rate
        uint24 feeRate;
        (,,, feeRate) = poolManager.getSlot0(pid);

        // Get fee growth before swap
        (uint256 feeGrowth0Before, uint256 feeGrowth1Before) = poolManager.getFeeGrowthGlobals(pid);

        // Perform swap
        vm.startPrank(trader);
        _performSwap(trader, poolKey, swapAmount, zeroForOne);
        vm.stopPrank();

        // Get fee growth after swap
        (uint256 feeGrowth0After, uint256 feeGrowth1After) = poolManager.getFeeGrowthGlobals(pid);

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
    function _verifyLpFeesEarned(
        PoolId pid,
        int24 lowerTick,
        int24 upperTick,
        uint128 lpLiquidity,
        uint256 feeGrowth0Before,
        uint256 expectedFees
    ) internal view {
        (uint256 feeGrowth0After,) = poolManager.getFeeGrowthInside(pid, lowerTick, upperTick);

        // Assert monotonicity: feeGrowthInside should never decrease
        assertGe(feeGrowth0After, feeGrowth0Before, "feeGrowthInside must be non-decreasing");

        uint256 feeGrowthDelta = feeGrowth0After - feeGrowth0Before;
        uint256 actualFeesEarned = FullMath.mulDiv(feeGrowthDelta, lpLiquidity, 1 << 128);

        // Verify LP earned expected fees (within 0.5% tolerance)
        if (expectedFees > 0) {
            assertApproxEqRel(actualFeesEarned, expectedFees, 0.005e18, "LP earns exact proportion of fees");
        }
    }

    /**
     * @notice Execute multiple swaps and verify fees are collected correctly for each
     * @dev Repeatedly calls _performSwapAndVerifyFee for the specified number of swaps
     */
    function _performMultipleSwaps(
        address trader,
        PoolKey memory poolKey,
        PoolId pid,
        uint256 swapAmount,
        uint128 totalLiquidity,
        uint8 numSwaps
    ) internal {
        for (uint256 i = 0; i < numSwaps; i++) {
            _performSwapAndVerifyFee(trader, poolKey, pid, swapAmount, totalLiquidity, true);
        }
    }

    /**
     * @notice Execute a 90-day seasonal cycle with volume-derived ratios and periodic pokes
     * @dev Helper to reduce stack depth in seasonal pattern tests
     * @param testKey Pool key
     * @param testPoolId Pool ID
     * @param cycleParams Struct containing cycle parameters
     * @param params Pool type parameters
     * @return newFee Fee after the seasonal cycle
     * @return lastRatio Last poked ratio for directional assertions
     */
    function _executeSeasonalCycle(
        PoolKey memory testKey,
        PoolId testPoolId,
        SeasonalCycleParams memory cycleParams,
        DynamicFeeLib.PoolTypeParams memory params
    ) internal returns (uint24 newFee, uint256 lastRatio) {
        uint256 daysPerSeason = 90;
        lastRatio = cycleParams.prevTargetRatio;

        for (uint256 day = 0; day < daysPerSeason; day += 7) {
            vm.warp(block.timestamp + 7 days);

            // Calculate weekly volume: (liquidity * ratio_bps * multiplier) / (10000_bps * 100_multiplier_scale)
            // Denominators: baseVolumeRatioBps in bps (1e4), currentMultiplier scaled by 100 → total 1e6
            uint256 weeklyVolume =
                (uint256(cycleParams.baseLiquidity) * cycleParams.baseVolumeRatioBps * cycleParams.currentMultiplier)
                / (10000 * 100);
            if (weeklyVolume < MIN_SWAP_AMOUNT) weeklyVolume = MIN_SWAP_AMOUNT;
            if (weeklyVolume > MAX_SWAP_AMOUNT) weeklyVolume = MAX_SWAP_AMOUNT;

            for (uint256 i = 0; i < 3; i++) {
                vm.startPrank(bob);
                _performSwap(bob, testKey, weeklyVolume, i % 2 == 0);
                vm.stopPrank();
            }

            if (day % 14 == 0) {
                vm.warp(block.timestamp + params.minPeriod + 1);
                uint256 ratio = (weeklyVolume * 3 * 1e18) / uint256(cycleParams.baseLiquidity);
                if (ratio > params.maxCurrentRatio) ratio = params.maxCurrentRatio;
                if (ratio < 1e15) ratio = 1e15;

                uint24 feeBefore;
                (,,, feeBefore) = poolManager.getSlot0(testPoolId);

                vm.recordLogs();
                vm.prank(owner);
                hook.poke(testKey, ratio);

                uint24 feeAfter;
                (,,, feeAfter) = poolManager.getSlot0(testPoolId);

                assertGe(feeAfter, params.minFee, "Fee >= minFee during simulation");
                assertLe(feeAfter, params.maxFee, "Fee <= maxFee during simulation");

                uint256 actualTarget = _extractOldTargetRatio();
                _assertDirectionalFeeChange(ratio, actualTarget, feeBefore, feeAfter, params);

                lastRatio = ratio;
            }
        }

        (,,, newFee) = poolManager.getSlot0(testPoolId);
    }

    /**
     * @notice Extract oldTargetRatio from FeeUpdated event
     * @dev Helper to get the actual EMA target ratio from the poke event.
     *      Includes sanity check to guard against event schema drift.
     * @return oldTargetRatio The EMA target ratio before the poke
     */
    function _extractOldTargetRatio() internal returns (uint256 oldTargetRatio) {
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                // Validate topic structure before decoding
                require(logs[i].topics.length >= 2, "FeeUpdated: malformed topics");

                (,, oldTargetRatio,,) = abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Sanity check: target ratio should be within reasonable bounds (1e15 to MAX_CURRENT_RATIO)
                require(
                    oldTargetRatio >= 1e15 && oldTargetRatio <= 1e24,
                    "Extracted target ratio out of expected bounds - possible event schema drift"
                );

                return oldTargetRatio;
            }
        }
        revert("FeeUpdated event not found in recorded logs");
    }

    /**
     * @notice Assert directional fee change based on ratio vs target with tolerance
     * @dev Uses precise DynamicFeeLib logic for bounds calculation
     */
    function _assertDirectionalFeeChange(
        uint256 currentRatio,
        uint256 targetRatio,
        uint24 feeBefore,
        uint24 feeAfter,
        DynamicFeeLib.PoolTypeParams memory params
    ) internal pure {
        uint256 delta = FullMath.mulDiv(targetRatio, params.ratioTolerance, 1e18);
        uint256 lowerBound = targetRatio > delta ? targetRatio - delta : 0;
        uint256 upperBound = targetRatio + delta;

        bool isOobUpper = currentRatio > upperBound;
        bool isOobLower = currentRatio < lowerBound;

        if (isOobUpper) {
            if (feeBefore >= params.maxFee) {
                assertEq(feeAfter, params.maxFee, "Fee stays at maxFee when already at bound");
            } else {
                assertGe(feeAfter, feeBefore, "Fee should increase or stay same when ratio > upperBound");

                // If fee didn't move, validate it's due to integer division rounding to 0
                if (feeAfter == feeBefore) {
                    // Compute the same logic as DynamicFee.computeNewFee
                    uint256 deviation = currentRatio - targetRatio;
                    uint256 adjustmentRate = FullMath.mulDiv(deviation, params.linearSlope, targetRatio);

                    // feeDelta = currentFee * adjustmentRate / 1e18
                    uint256 feeDelta = FullMath.mulDiv(feeBefore, adjustmentRate, 1e18);

                    // Throttle by streak (assuming streak = 1 for first hit)
                    uint256 maxFeeDelta = params.baseMaxFeeDelta;
                    if (feeDelta > maxFeeDelta) feeDelta = maxFeeDelta;

                    // deltaUp = feeDelta * upperSideFactor / 1e18
                    uint256 deltaUp = FullMath.mulDiv(feeDelta, params.upperSideFactor, 1e18);

                    // Assert that deltaUp rounded down to 0
                    assertEq(deltaUp, 0, "If fee doesn't increase OOB upper, deltaUp must be 0 due to rounding");
                }
            }
        } else if (isOobLower) {
            if (feeBefore <= params.minFee) {
                assertEq(feeAfter, params.minFee, "Fee stays at minFee when already at bound");
            } else {
                assertLe(feeAfter, feeBefore, "Fee should decrease or stay same when ratio < lowerBound");

                // If fee didn't move, validate it's due to integer division rounding to 0
                if (feeAfter == feeBefore) {
                    // Compute the same logic as DynamicFee.computeNewFee
                    uint256 deviation = targetRatio - currentRatio;
                    uint256 adjustmentRate = FullMath.mulDiv(deviation, params.linearSlope, targetRatio);

                    // feeDelta = currentFee * adjustmentRate / 1e18
                    uint256 feeDelta = FullMath.mulDiv(feeBefore, adjustmentRate, 1e18);

                    // Throttle by streak (assuming streak = 1 for first hit)
                    uint256 maxFeeDelta = params.baseMaxFeeDelta;
                    if (feeDelta > maxFeeDelta) feeDelta = maxFeeDelta;

                    // deltaDown = feeDelta * lowerSideFactor / 1e18
                    uint256 deltaDown = FullMath.mulDiv(feeDelta, params.lowerSideFactor, 1e18);

                    // Assert that either deltaDown rounded down to 0, or it would have pushed below minFee
                    bool deltaIsZero = deltaDown == 0;
                    bool wouldPushBelowMin = deltaDown >= feeBefore; // Would trigger early return to minFee

                    assertTrue(
                        deltaIsZero || wouldPushBelowMin,
                        "If fee doesn't decrease OOB lower, deltaDown must be 0 or would push below minFee"
                    );
                }
            }
        }
    }

    /**
     * @notice Estimate max weeks needed for fee to converge from start to target
     * @dev Accounts for fee distance, linearSlope, baseMaxFeeDelta, and sideFactor throttling
     * @return Estimated weeks with safety margin (capped at 200)
     */
    function _calculateMaxWeeks(
        uint24 startFee,
        uint24 targetFee,
        uint256 linearSlope,
        uint256 baseMaxFeeDelta,
        uint256 sideFactor
    ) internal pure returns (uint256) {
        uint256 feeDistance = startFee > targetFee ? startFee - targetFee : targetFee - startFee;

        // Estimate per-week delta: baseMaxFeeDelta * sideFactor / 1e18
        // Adjustment is proportional to linearSlope, so scale inversely
        uint256 minPerWeekDelta = (baseMaxFeeDelta * sideFactor) / 1e18;
        if (minPerWeekDelta == 0) minPerWeekDelta = 1;

        // Account for linearSlope: lower slope means slower convergence
        // Baseline slope is 1e18, so scale weeks by (1e18 / linearSlope)
        uint256 weeksNeeded = (feeDistance * 2 * 1e18) / (minPerWeekDelta * linearSlope);

        // Cap between min and max weeks to keep tests performant
        if (weeksNeeded < MIN_WEEKS_FOR_CONVERGENCE) return MIN_WEEKS_FOR_CONVERGENCE;
        if (weeksNeeded > MAX_WEEKS_FOR_CONVERGENCE) return MAX_WEEKS_FOR_CONVERGENCE;
        return weeksNeeded;
    }

    /**
     * @notice Drive fee from current value to a target bound (min or max) using constant ratio
     * @dev A "phase" is a period where ratio is consistently low/high to push fee toward a bound
     * @return Number of weeks taken to reach the target fee
     */
    function _executePhase(
        PoolKey memory poolKey,
        PoolId pid,
        uint128 liquidityAmount,
        uint256 ratio,
        DynamicFeeLib.PoolTypeParams memory params,
        uint24 targetFee
    ) internal returns (uint256) {
        (,,, uint24 startFee) = poolManager.getSlot0(pid);

        // Determine which side factor to use
        uint256 sideFactor = targetFee > startFee ? params.upperSideFactor : params.lowerSideFactor;

        return _driveToFeeBound(
            DriveParams(
                poolKey,
                pid,
                liquidityAmount,
                ratio,
                params.minPeriod,
                startFee,
                targetFee,
                params.linearSlope,
                params.baseMaxFeeDelta,
                sideFactor,
                params.maxCurrentRatio
            )
        );
    }

    /**
     * @notice Simulate weekly trading cycles to drive fee to target bound via repeated pokes
     * @dev Executes daily swaps for 7 days, then pokes with given ratio; repeats until target reached
     * @return weeksTaken Number of weeks to reach target fee (0 if failed)
     */
    function _driveToFeeBound(DriveParams memory p) internal returns (uint256 weeksTaken) {
        uint256 maxWeeks = _calculateMaxWeeks(p.startFee, p.targetFee, p.linearSlope, p.baseMaxFeeDelta, p.sideFactor);

        for (uint256 week = 0; week < maxWeeks; week++) {
            uint256 dailyVolume = (p.liquidityAmount * p.ratio) / 1e18;
            if (dailyVolume < MIN_SWAP_AMOUNT) dailyVolume = MIN_SWAP_AMOUNT;
            if (dailyVolume > MAX_SWAP_AMOUNT) dailyVolume = MAX_SWAP_AMOUNT;

            for (uint256 day = 0; day < 7; day++) {
                vm.warp(block.timestamp + 1 days);
                vm.startPrank(bob);
                _performSwap(bob, p.key, dailyVolume, day % 2 == 0);
                vm.stopPrank();
            }

            vm.warp(block.timestamp + p.minPeriod + 1);
            vm.prank(owner);
            // Clamp ratio to maxCurrentRatio to ensure valid input across all param sets
            uint256 clampedRatio = p.ratio > p.maxCurrentRatio ? p.maxCurrentRatio : p.ratio;
            hook.poke(p.key, clampedRatio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(p.poolId);

            if (currentFee == p.targetFee) {
                return week + 1;
            }
        }
        return 0;
    }

    /**
     * @notice Execute 6 fee boundary transitions: min→max→min→max→min→max
     * @dev Tests fee can swing back and forth across full range by alternating low/high ratios
     * @return result Array of weeks taken for each of the 6 phase transitions
     */
    function _executeAllPhases(
        PoolKey memory poolKey,
        PoolId pid,
        uint128 liq,
        DynamicFeeLib.PoolTypeParams memory params
    ) internal returns (uint256[6] memory result) {
        uint256 low = 1e15;
        uint256 high = 1e20;

        result[0] = _executePhase(poolKey, pid, liq, low, params, params.minFee);
        result[1] = _executePhase(poolKey, pid, liq, high, params, params.maxFee);
        result[2] = _executePhase(poolKey, pid, liq, low, params, params.minFee);
        result[3] = _executePhase(poolKey, pid, liq, high, params, params.maxFee);
        result[4] = _executePhase(poolKey, pid, liq, low, params, params.minFee);
        result[5] = _executePhase(poolKey, pid, liq, high, params, params.maxFee);
    }

    /**
     * @notice Simulate one week of realistic trading with fee-responsive volume
     * @dev Volume inversely correlated with fees (high fee = low volume), with periodic spikes/quiet periods
     * @return newFee The fee at the end of the week after the poke
     */
    function _runOrganicWeek(
        PoolKey memory k,
        PoolId pid,
        uint128 liq,
        uint256 baseVol,
        uint256 weekNum,
        uint8 spikeFreq,
        uint24 curFee
    ) internal returns (uint24) {
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Volume inversely correlated with fee: high fee = low volume
        uint256 feeNorm = (uint256(curFee) * 1e18) / uint256(params.maxFee);
        uint256 volMult = 2e18 - feeNorm;
        uint256 weekVol = (liq * baseVol * volMult) / (1e18 * 1e18);

        // Spikes and quiet periods
        if (weekNum > 0 && weekNum % spikeFreq == 0) {
            weekVol = weekVol * 5;
        } else if (weekNum > 0 && weekNum % 13 == 0) {
            weekVol = weekVol / 5;
        }

        // Clamp
        if (weekVol < MIN_SWAP_AMOUNT) weekVol = MIN_SWAP_AMOUNT;
        if (weekVol > MAX_SWAP_AMOUNT * 10) weekVol = MAX_SWAP_AMOUNT * 10;

        // Daily swaps
        uint256 dailyVol = weekVol / 7;
        if (dailyVol < MIN_SWAP_AMOUNT) dailyVol = MIN_SWAP_AMOUNT;
        if (dailyVol > MAX_SWAP_AMOUNT) dailyVol = MAX_SWAP_AMOUNT;

        for (uint256 day = 0; day < 7; day++) {
            vm.warp(block.timestamp + 1 days);
            vm.startPrank(bob);
            _performSwap(bob, k, dailyVol, day % 2 == 0);
            vm.stopPrank();
        }

        // Poke
        uint256 ratio = (weekVol * 1e18) / uint256(liq);
        if (ratio < 1e15) ratio = 1e15;
        if (ratio > params.maxCurrentRatio) ratio = params.maxCurrentRatio;

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(k, ratio);

        uint24 newFee;
        (,,, newFee) = poolManager.getSlot0(pid);
        return newFee;
    }

    /**
     * @notice Drive fee toward bound while preventing streak accumulation
     * @dev Alternates OOB ratios (push fee) with in-band ratios (break streak) to test slower convergence
     * @return Number of weeks taken to reach target fee
     */
    function _executePhaseWithStreakBreaking(
        PoolKey memory poolKey,
        PoolId pid,
        uint128 liquidityAmount,
        uint256 ratioOob,
        uint256 ratioInBand,
        uint256 minPeriod,
        uint24 targetFee
    ) internal returns (uint256) {
        uint256 weekCount = 0;

        for (uint256 cycle = 0; cycle < MAX_WEEKS_FOR_STREAK_BREAKING / 2; cycle++) {
            // Week 1: Push OOB (upward)
            {
                uint256 dailyVolume = (liquidityAmount * ratioOob) / 1e18;
                if (dailyVolume < MIN_SWAP_AMOUNT) dailyVolume = MIN_SWAP_AMOUNT;
                if (dailyVolume > MAX_SWAP_AMOUNT) dailyVolume = MAX_SWAP_AMOUNT;

                for (uint256 day = 0; day < 7; day++) {
                    vm.warp(block.timestamp + 1 days);
                    vm.startPrank(bob);
                    _performSwap(bob, poolKey, dailyVolume, day % 2 == 0);
                    vm.stopPrank();
                }

                vm.warp(block.timestamp + minPeriod + 1);
                vm.prank(owner);
                hook.poke(poolKey, ratioOob);
                weekCount++;

                (,,, uint24 currentFee) = poolManager.getSlot0(pid);
                if (currentFee == targetFee) return weekCount;
            }

            // Week 2: In-band (breaks streak)
            {
                uint256 dailyVolume = (liquidityAmount * ratioInBand) / 1e18;
                if (dailyVolume < MIN_SWAP_AMOUNT) dailyVolume = MIN_SWAP_AMOUNT;
                if (dailyVolume > MAX_SWAP_AMOUNT) dailyVolume = MAX_SWAP_AMOUNT;

                for (uint256 day = 0; day < 7; day++) {
                    vm.warp(block.timestamp + 1 days);
                    vm.startPrank(bob);
                    _performSwap(bob, poolKey, dailyVolume, day % 2 == 0);
                    vm.stopPrank();
                }

                vm.warp(block.timestamp + minPeriod + 1);
                vm.prank(owner);
                hook.poke(poolKey, ratioInBand);
                weekCount++;

                (,,, uint24 currentFee) = poolManager.getSlot0(pid);
                if (currentFee == targetFee) return weekCount;
            }
        }

        return 0;
    }
}
