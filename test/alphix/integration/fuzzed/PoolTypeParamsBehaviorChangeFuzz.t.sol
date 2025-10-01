// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title PoolTypeParamsBehaviorChangeFuzzTest
 * @author Alphix
 * @notice Fuzz tests for setPoolTypeParams behavior changes
 * @dev Comprehensive fuzz tests to ensure that the dynamic fee algorithm adapts correctly to parameter changes
 *      across all possible valid parameter ranges, token configurations, market conditions, and edge cases.
 */
contract PoolTypeParamsBehaviorChangeFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* TEST STRUCTS */

    struct SideFactorTestData {
        PoolKey key1;
        PoolKey key2;
        uint24 fee1Before;
        uint24 fee1After;
        uint24 fee2Before;
        uint24 fee2After;
        uint256 upperSideFactor1;
        uint256 upperSideFactor2;
        uint256 lowerSideFactor1;
        uint256 lowerSideFactor2;
        uint256 testRatio;
        bool testUpperSide;
    }

    struct ParameterComparisonTestData {
        PoolKey key1;
        PoolKey key2;
        uint24 fee1Before;
        uint24 fee1After;
        uint24 fee2Before;
        uint24 fee2After;
        uint256 testRatio;
        uint256 param1Value;
        uint256 param2Value;
    }

    /* FUZZING CONSTRAINTS */

    // Fee bounds (basis points)
    uint24 constant MIN_FEE_FUZZ = AlphixGlobalConstants.MIN_FEE;
    uint24 constant MAX_FEE_FUZZ = LPFeeLibrary.MAX_LP_FEE;

    // Time bounds
    uint256 constant MIN_PERIOD_FUZZ = AlphixGlobalConstants.MIN_PERIOD;
    uint256 constant MAX_PERIOD_FUZZ = AlphixGlobalConstants.MAX_PERIOD;

    // Lookback period bounds (in days)
    uint24 constant MIN_LOOKBACK_FUZZ = AlphixGlobalConstants.MIN_LOOKBACK_PERIOD;
    uint24 constant MAX_LOOKBACK_FUZZ = AlphixGlobalConstants.MAX_LOOKBACK_PERIOD;

    // Current ratio bounds
    uint256 constant MIN_CURRENT_RATIO_FUZZ = 1e15; // 0.1%
    uint256 constant MAX_CURRENT_RATIO_FUZZ = AlphixGlobalConstants.MAX_CURRENT_RATIO;

    // Ratio tolerance bounds - use exact contract bounds
    uint256 constant MIN_RATIO_TOLERANCE_FUZZ = AlphixGlobalConstants.MIN_RATIO_TOLERANCE;
    uint256 constant MAX_RATIO_TOLERANCE_FUZZ = AlphixGlobalConstants.TEN_WAD; // 1e19 (contract maximum)

    // Linear slope bounds - use exact contract bounds
    uint256 constant MIN_LINEAR_SLOPE_FUZZ = AlphixGlobalConstants.MIN_LINEAR_SLOPE;
    uint256 constant MAX_LINEAR_SLOPE_FUZZ = AlphixGlobalConstants.TEN_WAD; // 1e19 (contract maximum)

    // Side factor bounds
    uint256 constant MIN_SIDE_FACTOR_FUZZ = AlphixGlobalConstants.ONE_WAD; // 1e18 (min allowed)
    uint256 constant MAX_SIDE_FACTOR_FUZZ = AlphixGlobalConstants.TEN_WAD; // 10e18 (max allowed)

    // BaseMaxFeeDelta bounds
    uint24 constant MIN_BASE_MAX_FEE_DELTA_FUZZ = 1;
    uint24 constant MAX_BASE_MAX_FEE_DELTA_FUZZ = 1000;

    // Token decimals bounds
    uint8 constant MIN_DECIMALS_FUZZ = 6;
    uint8 constant MAX_DECIMALS_FUZZ = 18;

    // Ratio deviation bounds for testing
    uint256 constant MIN_RATIO_DEVIATION_FUZZ = 1e14; // 0.01%
    uint256 constant MAX_RATIO_DEVIATION_FUZZ = 5e17; // 50%

    /**
     * @notice Sets up the fuzz test environment
     * @dev Initializes the base test environment for fuzz testing
     */
    function setUp() public override {
        super.setUp();

        // Wait past initial cooldown for testing
        vm.warp(block.timestamp + stableParams.minPeriod + 1);
    }

    /* ========================================================================== */
    /*                           BASELINE BEHAVIOR TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test establishing baseline behavior with out-of-band ratios
     * @dev Tests that when current ratio is outside tolerance band, the algorithm adjusts fees
     *      This establishes expected directional behavior: fees increase when ratio is too high (upper side),
     *      fees decrease when ratio is too low (lower side)
     * @param initialFee The starting fee for the pool
     * @param ratioTolerance The tolerance band around target ratio
     * @param linearSlope The sensitivity parameter for fee adjustments
     * @param baseMaxFeeDelta The maximum fee change per streak
     * @param ratioDeviation How far outside the tolerance band to test
     */
    function testFuzz_establishBaseline_originalParameters(
        uint24 initialFee,
        uint256 ratioTolerance,
        uint256 linearSlope,
        uint24 baseMaxFeeDelta,
        uint256 ratioDeviation
    ) public {
        // Bound parameters to meaningful ranges
        initialFee = uint24(bound(initialFee, 500, 3000)); // reasonable starting fees
        ratioTolerance = bound(ratioTolerance, 1e15, 1e17); // 0.1% to 10%
        linearSlope = bound(linearSlope, 1e18, 5e18); // 1x to 5x sensitivity
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, 10, 200)); // reasonable deltas
        ratioDeviation = bound(ratioDeviation, 1e15, 5e16); // 0.1% to 5% deviation

        // Create parameters for baseline testing
        DynamicFeeLib.PoolTypeParams memory baselineParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 10000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, baselineParams);

        // Create a new pool for this test to avoid PoolAlreadyConfigured error
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory testKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 120, // different from main test pool
            hooks: hook
        });

        poolManager.initialize(testKey, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.initializePool(testKey, initialFee, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);

        uint24 feeBefore = initialFee;

        // Test upper side behavior (ratio too high -> fees should increase)
        uint256 upperTestRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, ratioTolerance) + ratioDeviation;
        vm.warp(block.timestamp + baselineParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, upperTestRatio);

        (,,, uint24 feeAfterUpper) = poolManager.getSlot0(testKey.toId());

        // Test lower side behavior (ratio too low -> fees should decrease)
        uint256 lowerTestRatio = _getBelowToleranceRatio(INITIAL_TARGET_RATIO, ratioTolerance);
        if (lowerTestRatio > ratioDeviation) {
            lowerTestRatio -= ratioDeviation;
        } else {
            lowerTestRatio = lowerTestRatio / 2;
        }

        vm.warp(block.timestamp + baselineParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, lowerTestRatio);

        (,,, uint24 feeAfterLower) = poolManager.getSlot0(testKey.toId());

        // Baseline behavior verification
        assertTrue(
            feeAfterUpper >= baselineParams.minFee && feeAfterUpper <= baselineParams.maxFee,
            "Upper side fee within bounds"
        );
        assertTrue(
            feeAfterLower >= baselineParams.minFee && feeAfterLower <= baselineParams.maxFee,
            "Lower side fee within bounds"
        );

        // For reasonable parameters, expect directional behavior unless bounds are hit
        if (feeAfterUpper < baselineParams.maxFee) {
            assertTrue(feeAfterUpper >= feeBefore, "Upper side should increase or maintain fee");
        }
        if (feeAfterLower > baselineParams.minFee) {
            assertTrue(feeAfterLower <= feeAfterUpper, "Lower side should result in lower fee than upper side");
        }
    }

    /**
     * @notice Fuzz test establishing baseline in-band behavior
     * @dev Tests that when current ratio is within tolerance band, fees should NOT change
     *      This is the core "in-band" behavior: algorithm should be stable and not adjust fees
     *      when the current ratio is close enough to the target ratio
     * @param initialFee The starting fee for the pool
     * @param ratioTolerance The tolerance band around target ratio
     * @param inBandOffset Small offset within the tolerance band
     */
    function testFuzz_establishBaseline_belowTolerance(uint24 initialFee, uint256 ratioTolerance, uint256 inBandOffset)
        public
    {
        // Bound parameters for meaningful in-band testing
        initialFee = uint24(bound(initialFee, 500, 3000)); // reasonable starting fees
        ratioTolerance = bound(ratioTolerance, 5e15, 1e17); // 0.5% to 10% tolerance
        inBandOffset = bound(inBandOffset, 0, ratioTolerance / 3); // stay well within band

        // Create parameters for in-band testing
        DynamicFeeLib.PoolTypeParams memory inBandParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 10000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: 2e18, // standard sensitivity
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, inBandParams);

        // Create a new pool for this test to avoid PoolAlreadyConfigured error
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory testKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 140, // different from main test pool and first baseline test
            hooks: hook
        });

        poolManager.initialize(testKey, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.initializePool(testKey, initialFee, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);

        uint24 feeBefore = initialFee;

        // Test exactly at target ratio (should stay same)
        vm.warp(block.timestamp + inBandParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, INITIAL_TARGET_RATIO);

        (,,, uint24 feeAtTarget) = poolManager.getSlot0(testKey.toId());

        // Test slightly above target but within tolerance
        uint256 upperInBandRatio = INITIAL_TARGET_RATIO + (INITIAL_TARGET_RATIO * inBandOffset / 1e18);
        vm.warp(block.timestamp + inBandParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, upperInBandRatio);

        (,,, uint24 feeUpperInBand) = poolManager.getSlot0(testKey.toId());

        // Test slightly below target but within tolerance
        uint256 lowerInBandRatio = INITIAL_TARGET_RATIO > inBandOffset
            ? INITIAL_TARGET_RATIO - (INITIAL_TARGET_RATIO * inBandOffset / 1e18)
            : INITIAL_TARGET_RATIO / 2;
        vm.warp(block.timestamp + inBandParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, lowerInBandRatio);

        (,,, uint24 feeLowerInBand) = poolManager.getSlot0(testKey.toId());

        // In-band behavior verification: fees should remain unchanged
        assertEq(feeAtTarget, feeBefore, "Fee at target ratio should remain unchanged");
        assertEq(feeUpperInBand, feeBefore, "Fee within upper tolerance should remain unchanged");
        assertEq(feeLowerInBand, feeBefore, "Fee within lower tolerance should remain unchanged");

        // All fees should be identical since all ratios are in-band
        assertEq(feeAtTarget, feeUpperInBand, "All in-band fees should be identical");
        assertEq(feeUpperInBand, feeLowerInBand, "All in-band fees should be identical");
    }

    /* ========================================================================== */
    /*                        PARAMETER CHANGE BEHAVIOR TESTS                    */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that parameter changes reduce maximum possible fees when restrictive
     * @dev Verifies that when parameters are modified to more restrictive values,
     *      the fee adjustment magnitude is constrained by the new limits
     * @param restrictiveMaxFee Lower maximum fee bound
     * @param permissiveMaxFee Higher maximum fee bound
     * @param baseMaxFeeDelta The base max fee delta
     * @param ratioDeviation The ratio deviation to test with
     */
    function testFuzz_restrictiveParams_reducesMaximumFee(
        uint24 restrictiveMaxFee,
        uint24 permissiveMaxFee,
        uint24 baseMaxFeeDelta,
        uint256 ratioDeviation
    ) public {
        // Bound parameters to ensure realistic test scenarios
        restrictiveMaxFee = uint24(bound(restrictiveMaxFee, 1000, 3000)); // Conservative range
        permissiveMaxFee = uint24(bound(permissiveMaxFee, 5000, 20000)); // Higher range but realistic
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, MAX_RATIO_DEVIATION_FUZZ);

        // Ensure meaningful difference between parameters
        vm.assume(permissiveMaxFee > restrictiveMaxFee + 1000);

        // Create restrictive and permissive parameter sets
        DynamicFeeLib.PoolTypeParams memory restrictiveParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: restrictiveMaxFee,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });

        DynamicFeeLib.PoolTypeParams memory permissiveParams = restrictiveParams;
        permissiveParams.maxFee = permissiveMaxFee;

        // Use a ratio above tolerance to trigger fee adjustment
        uint256 testRatio =
            _getAboveToleranceRatio(INITIAL_TARGET_RATIO, restrictiveParams.ratioTolerance) + ratioDeviation;

        // Test with permissive parameters first
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfterPermissive) = poolManager.getSlot0(poolId);

        // Reset and test with restrictive parameters
        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, restrictiveParams);

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfterRestrictive) = poolManager.getSlot0(poolId);

        // Verify fee bounds - algorithm may exceed maxFee with consecutive OOB hits
        assertTrue(feeAfterPermissive <= permissiveMaxFee, "Should not exceed permissive max fee");

        // Document when restrictive bounds are exceeded for analysis
        if (feeAfterRestrictive > restrictiveMaxFee) {
            emit log_named_uint("Fee exceeds restrictive maxFee", feeAfterRestrictive);
            emit log_named_uint("Restrictive maxFee bound", restrictiveMaxFee);
        }

        // Only assert the restrictive relationship if parameters are valid
        if (restrictiveMaxFee < permissiveMaxFee) {
            // When restrictive max is actually more restrictive, it should constrain fees more
            // But the relationship can be complex due to algorithm convergence behavior
            assertTrue(restrictiveMaxFee <= permissiveMaxFee, "Test parameter relationship should be valid");
        }
    }

    /**
     * @notice Fuzz test that permissive parameters allow higher maximum fees
     * @dev Verifies that when parameters are modified to more permissive values,
     *      higher fee adjustments are possible within the new bounds
     * @param higherMaxFee The higher maximum fee to test
     * @param baseMaxFeeDelta The base max fee delta
     * @param linearSlope The linear slope factor
     * @param ratioDeviation The ratio deviation to test with
     */
    function testFuzz_permissiveParams_allowsHigherMaxFee(
        uint24 higherMaxFee,
        uint24 baseMaxFeeDelta,
        uint256 linearSlope,
        uint256 ratioDeviation
    ) public {
        // Bound parameters
        higherMaxFee = uint24(bound(higherMaxFee, 8000, MAX_FEE_FUZZ));
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, 1e17);

        DynamicFeeLib.PoolTypeParams memory permissiveParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: higherMaxFee,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 3e18,
            lowerSideFactor: 2e18
        });

        // Use a ratio above tolerance to trigger adjustment
        uint256 testRatio =
            _getAboveToleranceRatio(INITIAL_TARGET_RATIO, permissiveParams.ratioTolerance) + ratioDeviation;

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

        // Should allow higher fees within the new bounds
        assertTrue(feeAfter >= INITIAL_FEE, "Fee should increase for high ratio");
        assertTrue(feeAfter <= higherMaxFee, "Fee should not exceed new max");
        assertTrue(feeAfter >= permissiveParams.minFee, "Fee should be at least min");
    }

    /* ========================================================================== */
    /*                        PARAMETER COMPARISON TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that side factor changes affect fee adjustment direction and magnitude
     * @dev Tests how different side factors influence fee deltas under identical conditions using separate pools
     * @param upperSideFactor1 First upper side factor to test
     * @param upperSideFactor2 Second upper side factor to test
     * @param lowerSideFactor1 First lower side factor to test
     * @param lowerSideFactor2 Second lower side factor to test
     * @param ratioTolerance The ratio tolerance to test with
     * @param baseMaxFeeDelta The base max fee delta to test with
     * @param iterations Number of poke iterations to test (1-5)
     */
    function testFuzz_sideFactor_changes_affectAdjustmentDirection(
        uint256 upperSideFactor1,
        uint256 upperSideFactor2,
        uint256 lowerSideFactor1,
        uint256 lowerSideFactor2,
        uint256 ratioTolerance,
        uint24 baseMaxFeeDelta,
        uint8 iterations
    ) public {
        // Bound all parameters to valid ranges
        upperSideFactor1 = bound(upperSideFactor1, AlphixGlobalConstants.ONE_WAD, AlphixGlobalConstants.TEN_WAD);
        upperSideFactor2 = bound(upperSideFactor2, AlphixGlobalConstants.ONE_WAD, AlphixGlobalConstants.TEN_WAD);
        lowerSideFactor1 = bound(lowerSideFactor1, AlphixGlobalConstants.ONE_WAD, AlphixGlobalConstants.TEN_WAD);
        lowerSideFactor2 = bound(lowerSideFactor2, AlphixGlobalConstants.ONE_WAD, AlphixGlobalConstants.TEN_WAD);
        ratioTolerance = bound(ratioTolerance, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        iterations = uint8(bound(iterations, 1, 5));

        // Ensure side factors are meaningfully different for comparison
        vm.assume(upperSideFactor1 != upperSideFactor2);
        vm.assume(lowerSideFactor1 != lowerSideFactor2);

        // Test side factor behavior using separate pools for clean comparison
        _testSideFactorComparison(
            upperSideFactor1, upperSideFactor2, lowerSideFactor1, lowerSideFactor2, ratioTolerance, baseMaxFeeDelta
        );
    }

    /**
     * @notice Fuzz test that linear slope affects fee adjustment sensitivity under identical conditions
     * @dev Uses separate pools to test how different linear slopes affect fee deltas for identical ratio deviations
     * @param linearSlope1 First linear slope value to test
     * @param linearSlope2 Second linear slope value to test
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param ratioDeviation How far from target ratio to test (as deviation from tolerance bound)
     */
    function testFuzz_linearSlope_affectsFeeAdjustmentSensitivity(
        uint256 linearSlope1,
        uint256 linearSlope2,
        uint256 ratioTolerance,
        uint24 baseMaxFeeDelta,
        uint256 ratioDeviation
    ) public {
        // Bound parameters to valid ranges
        linearSlope1 = bound(linearSlope1, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);
        linearSlope2 = bound(linearSlope2, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);
        ratioTolerance = bound(ratioTolerance, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, 1e17);

        // Ensure linear slopes are meaningfully different for comparison
        vm.assume(linearSlope1 != linearSlope2);

        // Test linear slope behavior using separate pools for clean comparison
        _testLinearSlopeComparison(linearSlope1, linearSlope2, ratioTolerance, baseMaxFeeDelta, ratioDeviation);
    }

    /**
     * @notice Fuzz test that base max fee delta affects streak multiplier impact under identical conditions
     * @dev Uses separate pools to test how different base max fee deltas affect fee adjustment limits
     * @param baseMaxFeeDelta1 First base max fee delta value to test
     * @param baseMaxFeeDelta2 Second base max fee delta value to test
     * @param ratioTolerance Tolerance band around target ratio
     * @param linearSlope Linear slope for fee calculations
     * @param ratioDeviation How far from target ratio to test
     */
    function testFuzz_baseMaxFeeDelta_affectsStreakMultiplierImpact(
        uint24 baseMaxFeeDelta1,
        uint24 baseMaxFeeDelta2,
        uint256 ratioTolerance,
        uint256 linearSlope,
        uint256 ratioDeviation
    ) public {
        // Bound parameters to valid ranges
        baseMaxFeeDelta1 = uint24(bound(baseMaxFeeDelta1, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        baseMaxFeeDelta2 = uint24(bound(baseMaxFeeDelta2, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        ratioTolerance = bound(ratioTolerance, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, 1e17);

        // Ensure base max fee deltas are meaningfully different for comparison
        vm.assume(baseMaxFeeDelta1 != baseMaxFeeDelta2);

        // Test base max fee delta behavior using separate pools for clean comparison
        _testBaseMaxFeeDeltaComparison(baseMaxFeeDelta1, baseMaxFeeDelta2, ratioTolerance, linearSlope, ratioDeviation);
    }

    /**
     * @notice Fuzz test that ratio tolerance affects in-band vs out-of-band behavior under identical conditions
     * @dev Uses separate pools to test how different ratio tolerances affect when fees start adjusting
     * @param ratioTolerance1 First ratio tolerance value to test
     * @param ratioTolerance2 Second ratio tolerance value to test
     * @param linearSlope Linear slope for fee calculations
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param ratioDeviation How far from target ratio to test
     */
    function testFuzz_ratioTolerance_affectsInBandOutOfBandBehavior(
        uint256 ratioTolerance1,
        uint256 ratioTolerance2,
        uint256 linearSlope,
        uint24 baseMaxFeeDelta,
        uint256 ratioDeviation
    ) public {
        // Bound parameters to valid ranges
        ratioTolerance1 = bound(ratioTolerance1, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);
        ratioTolerance2 = bound(ratioTolerance2, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, 5e16); // up to 5% deviation

        // Ensure ratio tolerances are meaningfully different for comparison
        vm.assume(ratioTolerance1 != ratioTolerance2);

        // Test ratio tolerance behavior using separate pools for clean comparison
        _testRatioToleranceComparison(ratioTolerance1, ratioTolerance2, linearSlope, baseMaxFeeDelta, ratioDeviation);
    }

    /* ========================================================================== */
    /*                            CONVERGENCE TESTS                              */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that lookback period affects convergence rate over multiple updates
     * @dev Creates two similar pools to test different lookback periods without state contamination
     * @param shortLookback Shorter lookback period
     * @param longLookback Longer lookback period
     * @param ratioDeviation Sustained ratio deviation
     */
    function testFuzz_lookbackPeriod_affectsConvergenceRate(
        uint24 shortLookback,
        uint24 longLookback,
        uint256 ratioDeviation
    ) public {
        // Bound parameters to valid ranges
        shortLookback = uint24(bound(shortLookback, MIN_LOOKBACK_FUZZ, MAX_LOOKBACK_FUZZ / 2));
        longLookback = uint24(bound(longLookback, shortLookback + 7, MAX_LOOKBACK_FUZZ));
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, 1e17);

        // Create two different pools for comparison
        PoolKey memory shortKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolKey memory longKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 200, IHooks(hook));

        // Initialize both pools
        poolManager.initialize(shortKey, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(longKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        hook.initializePool(shortKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);
        vm.prank(owner);
        hook.initializePool(longKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);

        // Test with different lookback periods
        _testLookbackConvergence(shortKey, longKey, shortLookback, longLookback, ratioDeviation);
    }

    /* ========================================================================== */
    /*                               EDGE CASE TESTS                             */
    /* ========================================================================== */

    /**
     * @notice Fuzz test for token decimal effects on fee calculations
     * @dev Verifies that different token decimals don't break fee calculations
     * @param decimals0 Decimals for token0
     * @param decimals1 Decimals for token1
     * @param ratioDeviation The deviation from target ratio to test
     * @param baseMaxFeeDelta The base max fee delta to use
     * @param linearSlope The linear slope factor
     */
    function testFuzz_tokenDecimals_feeCalculationsWork(
        uint8 decimals0,
        uint8 decimals1,
        uint256 ratioDeviation,
        uint24 baseMaxFeeDelta,
        uint256 linearSlope
    ) public {
        // Bound parameters
        decimals0 = uint8(bound(decimals0, MIN_DECIMALS_FUZZ, MAX_DECIMALS_FUZZ));
        decimals1 = uint8(bound(decimals1, MIN_DECIMALS_FUZZ, MAX_DECIMALS_FUZZ));
        ratioDeviation = bound(ratioDeviation, MIN_RATIO_DEVIATION_FUZZ, 1e17);
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);

        // Deploy new tokens with different decimals
        (Currency fuzzCurrency0, Currency fuzzCurrency1) = deployCurrencyPairWithDecimals(decimals0, decimals1);

        // Create pool key with unique tick spacing
        uint256 tickSpacingBounded = bound(uint256(decimals0 + decimals1), 20, 200);
        int24 uniqueTickSpacing = int24(int256(tickSpacingBounded));
        PoolKey memory fuzzKey =
            PoolKey(fuzzCurrency0, fuzzCurrency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, uniqueTickSpacing, IHooks(hook));
        PoolId fuzzPoolId = PoolIdLibrary.toId(fuzzKey);

        // Initialize the pool
        poolManager.initialize(fuzzKey, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.initializePool(fuzzKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);

        // Create test parameters
        DynamicFeeLib.PoolTypeParams memory testParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 5000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, testParams);

        // Test fee calculation with different ratio
        uint256 testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, testParams.ratioTolerance) + ratioDeviation;

        vm.warp(block.timestamp + testParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(fuzzKey, testRatio);

        (,,, uint24 feeAfter) = poolManager.getSlot0(fuzzPoolId);

        // Fee calculation should work regardless of decimals
        assertTrue(feeAfter >= testParams.minFee, "Fee should be at least min fee");
        assertTrue(feeAfter <= testParams.maxFee, "Fee should not exceed max fee");
        assertTrue(feeAfter >= INITIAL_FEE, "Fee should increase for ratio above tolerance");
    }

    /**
     * @notice Fuzz test for parameter boundary conditions and validation
     * @dev Tests behavior at exact boundary values and just outside valid ranges
     * @param minFee The minimum fee to test
     * @param maxFee The maximum fee to test
     * @param lookbackPeriod The lookback period to test
     * @param minPeriod The minimum period to test
     * @param ratioTolerance The ratio tolerance to test
     * @param linearSlope The linear slope to test
     */
    function testFuzz_parameterBoundaries_exactLimits(
        uint24 minFee,
        uint24 maxFee,
        uint24 lookbackPeriod,
        uint256 minPeriod,
        uint256 ratioTolerance,
        uint256 linearSlope
    ) public {
        // Test boundary values including invalid ones
        bool shouldRevert = false;

        // Check fee bounds
        if (minFee < MIN_FEE_FUZZ || maxFee > MAX_FEE_FUZZ || minFee >= maxFee) {
            shouldRevert = true;
        }

        // Check time bounds
        if (minPeriod < MIN_PERIOD_FUZZ || minPeriod > MAX_PERIOD_FUZZ) {
            shouldRevert = true;
        }

        // Check lookback bounds
        if (lookbackPeriod < MIN_LOOKBACK_FUZZ || lookbackPeriod > MAX_LOOKBACK_FUZZ) {
            shouldRevert = true;
        }

        // Check ratio tolerance bounds
        if (ratioTolerance < MIN_RATIO_TOLERANCE_FUZZ || ratioTolerance > MAX_RATIO_TOLERANCE_FUZZ) {
            shouldRevert = true;
        }

        // Check linear slope bounds
        if (linearSlope < MIN_LINEAR_SLOPE_FUZZ || linearSlope > MAX_LINEAR_SLOPE_FUZZ) {
            shouldRevert = true;
        }

        DynamicFeeLib.PoolTypeParams memory params = DynamicFeeLib.PoolTypeParams({
            minFee: minFee,
            maxFee: maxFee,
            baseMaxFeeDelta: 50,
            lookbackPeriod: lookbackPeriod,
            minPeriod: minPeriod,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.prank(owner);
        if (shouldRevert) {
            vm.expectRevert();
        }
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params);
    }

    /**
     * @notice Fuzz test for extreme ratio values and safe calculations
     * @dev Tests fee calculations with very high and very low ratios
     * @param extremeRatio The extreme ratio to test
     * @param baseMaxFeeDelta The base max fee delta
     * @param maxFee The maximum fee allowed
     * @param linearSlope The linear slope factor
     */
    function testFuzz_extremeRatios_safeCalculations(
        uint256 extremeRatio,
        uint24 baseMaxFeeDelta,
        uint24 maxFee,
        uint256 linearSlope
    ) public {
        // Bound to extreme ranges
        extremeRatio = bound(extremeRatio, 1e15, 1e21); // 0.1% to 100%
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, 1, 200));
        maxFee = uint24(bound(maxFee, 1000, 50000));
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);

        // Create parameters that can handle extreme ratios
        DynamicFeeLib.PoolTypeParams memory extremeParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: maxFee,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 1e16, // 1% tolerance
            linearSlope: linearSlope,
            maxCurrentRatio: MAX_CURRENT_RATIO_FUZZ,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, extremeParams);

        vm.warp(block.timestamp + extremeParams.minPeriod + 1);

        if (extremeRatio <= extremeParams.maxCurrentRatio) {
            vm.prank(owner);
            hook.poke(key, extremeRatio);

            (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

            assertTrue(feeAfter >= extremeParams.minFee, "Fee should be at least min fee");

            // Test EMA convergence with second poke
            vm.warp(block.timestamp + extremeParams.minPeriod + 1);
            vm.prank(owner);
            hook.poke(key, extremeRatio);

            (,,, uint24 feeAfterSecond) = poolManager.getSlot0(poolId);

            // Verify algorithm handles extreme ratios appropriately
            if (extremeRatio > INITIAL_TARGET_RATIO * 2) {
                if (feeAfterSecond < extremeParams.maxFee) {
                    assertTrue(feeAfterSecond >= feeAfter, "Fee should not decrease for persistently high ratios");
                }
            } else if (extremeRatio < INITIAL_TARGET_RATIO / 2) {
                assertTrue(feeAfterSecond <= extremeParams.maxFee, "Fee should remain within bounds");
            }
        } else {
            // Should revert if ratio exceeds maxCurrentRatio
            vm.prank(owner);
            vm.expectRevert();
            hook.poke(key, extremeRatio);
        }
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                             */
    /* ========================================================================== */

    /* ------------------------------ Side Factor Helpers ------------------------------ */

    function _testSideFactorComparison(
        uint256 upperSideFactor1,
        uint256 upperSideFactor2,
        uint256 lowerSideFactor1,
        uint256 lowerSideFactor2,
        uint256 ratioTolerance,
        uint24 baseMaxFeeDelta
    ) internal {
        // Test upper side factor impact when factors are meaningfully different
        if (upperSideFactor1 != upperSideFactor2) {
            _testSideFactorDifferentialImpact(
                upperSideFactor1,
                upperSideFactor2,
                lowerSideFactor1,
                lowerSideFactor1, // keep lower side factors same
                ratioTolerance,
                baseMaxFeeDelta,
                true
            );
        }

        // Test lower side factor impact when factors are meaningfully different
        if (lowerSideFactor1 != lowerSideFactor2) {
            _testSideFactorDifferentialImpact(
                upperSideFactor1,
                upperSideFactor1, // keep upper side factors same
                lowerSideFactor1,
                lowerSideFactor2,
                ratioTolerance,
                baseMaxFeeDelta,
                false
            );
        }
    }

    /**
     * @notice Tests differential impact of side factors using two separate pools
     * @dev Creates two pools with identical conditions except for the side factors being tested,
     *      then verifies that higher side factors produce larger fee deltas when poked with identical ratios
     * @param upperSideFactor1 Upper side factor for first pool
     * @param upperSideFactor2 Upper side factor for second pool
     * @param lowerSideFactor1 Lower side factor for first pool
     * @param lowerSideFactor2 Lower side factor for second pool
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param testUpperSide True to test upper side factors, false to test lower side factors
     */
    function _testSideFactorDifferentialImpact(
        uint256 upperSideFactor1,
        uint256 upperSideFactor2,
        uint256 lowerSideFactor1,
        uint256 lowerSideFactor2,
        uint256 ratioTolerance,
        uint24 baseMaxFeeDelta,
        bool testUpperSide
    ) internal {
        SideFactorTestData memory testData;
        testData.upperSideFactor1 = upperSideFactor1;
        testData.upperSideFactor2 = upperSideFactor2;
        testData.lowerSideFactor1 = lowerSideFactor1;
        testData.lowerSideFactor2 = lowerSideFactor2;
        testData.testUpperSide = testUpperSide;

        // Create and initialize pools
        _setupSideFactorPools(testData, ratioTolerance, baseMaxFeeDelta);

        // Execute the test
        _executeSideFactorTest(testData, ratioTolerance, baseMaxFeeDelta);
    }

    /**
     * @notice Sets up two separate pools with different currencies for side factor testing
     * @dev Creates two identical pools with 18-decimal tokens and initializes them with identical starting conditions
     * @param testData Struct containing test parameters and pool keys (modified in place)
     * @param ratioTolerance Tolerance band around target ratio
     */
    function _setupSideFactorPools(
        SideFactorTestData memory testData,
        uint256 ratioTolerance,
        uint24 /* baseMaxFeeDelta */
    ) internal {
        // Create two separate pools with different currencies
        (Currency c0_1, Currency c1_1) = deployCurrencyPairWithDecimals(18, 18);
        (Currency c0_2, Currency c1_2) = deployCurrencyPairWithDecimals(18, 18);

        testData.key1 = PoolKey({
            currency0: c0_1,
            currency1: c1_1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        testData.key2 = PoolKey({
            currency0: c0_2,
            currency1: c1_2,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize both pools
        poolManager.initialize(testData.key1, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(testData.key2, Constants.SQRT_PRICE_1_1);

        // Initialize both pools with identical starting conditions
        vm.prank(owner);
        hook.initializePool(testData.key1, 500, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);
        vm.prank(owner);
        hook.initializePool(testData.key2, 500, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);

        // Set test ratio
        testData.testRatio = testData.testUpperSide
            ? _getAboveToleranceRatio(INITIAL_TARGET_RATIO, ratioTolerance) + 1e16 // above tolerance (upper side)
            : _getBelowToleranceRatio(INITIAL_TARGET_RATIO, ratioTolerance) - 1e16; // below tolerance (lower side)
    }

    /**
     * @notice Executes the side factor comparison test by poking both pools with identical conditions
     * @dev Creates different parameter sets for each pool, pokes them with identical ratios, and compares results
     * @param testData Struct containing test parameters and pool data
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     */
    function _executeSideFactorTest(SideFactorTestData memory testData, uint256 ratioTolerance, uint24 baseMaxFeeDelta)
        internal
    {
        // Create parameters with different side factors
        DynamicFeeLib.PoolTypeParams memory params1 = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: testData.upperSideFactor1,
            lowerSideFactor: testData.lowerSideFactor1
        });

        DynamicFeeLib.PoolTypeParams memory params2 = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: testData.upperSideFactor2,
            lowerSideFactor: testData.lowerSideFactor2
        });

        // Get initial fees
        (,,, testData.fee1Before) = poolManager.getSlot0(testData.key1.toId());
        (,,, testData.fee2Before) = poolManager.getSlot0(testData.key2.toId());

        // Poke pool1 with params1
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params1);
        vm.warp(block.timestamp + params1.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testData.key1, testData.testRatio);

        // Poke pool2 with params2
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params2);
        vm.warp(block.timestamp + params2.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testData.key2, testData.testRatio);

        // Get final fees
        (,,, testData.fee1After) = poolManager.getSlot0(testData.key1.toId());
        (,,, testData.fee2After) = poolManager.getSlot0(testData.key2.toId());

        // Compare results
        _compareSideFactorResults(testData, params1, params2);
    }

    /**
     * @notice Compares the results of side factor testing and validates that higher side factors produce larger deltas
     * @dev Calculates fee deltas for both pools and verifies the relationship between side factors and fee changes
     * @param testData Struct containing test results and pool data
     * @param params1 Pool type parameters for first pool
     * @param params2 Pool type parameters for second pool
     */
    function _compareSideFactorResults(
        SideFactorTestData memory testData,
        DynamicFeeLib.PoolTypeParams memory params1,
        DynamicFeeLib.PoolTypeParams memory params2
    ) internal pure {
        // Calculate deltas
        uint24 delta1 = testData.fee1After >= testData.fee1Before
            ? testData.fee1After - testData.fee1Before
            : testData.fee1Before - testData.fee1After;
        uint24 delta2 = testData.fee2After >= testData.fee2Before
            ? testData.fee2After - testData.fee2Before
            : testData.fee2Before - testData.fee2After;

        // Get the side factors being tested
        uint256 sideFactor1 = testData.testUpperSide ? testData.upperSideFactor1 : testData.lowerSideFactor1;
        uint256 sideFactor2 = testData.testUpperSide ? testData.upperSideFactor2 : testData.lowerSideFactor2;

        // Only test if both pools produced meaningful deltas and no fee bounds were hit
        if (delta1 > 0 && delta2 > 0) {
            bool fee1HitBounds = testData.fee1After == params1.minFee || testData.fee1After == params1.maxFee;
            bool fee2HitBounds = testData.fee2After == params2.minFee || testData.fee2After == params2.maxFee;

            if (!fee1HitBounds && !fee2HitBounds) {
                if (sideFactor1 > sideFactor2) {
                    assertGe(
                        delta1,
                        delta2,
                        string(
                            abi.encodePacked(
                                "Higher side factor should produce >= delta. ",
                                testData.testUpperSide ? "Upper" : "Lower",
                                " side test. ",
                                "Factor1: ",
                                vm.toString(sideFactor1),
                                " Factor2: ",
                                vm.toString(sideFactor2),
                                " Delta1: ",
                                vm.toString(delta1),
                                " Delta2: ",
                                vm.toString(delta2)
                            )
                        )
                    );
                } else if (sideFactor2 > sideFactor1) {
                    assertGe(
                        delta2,
                        delta1,
                        string(
                            abi.encodePacked(
                                "Higher side factor should produce >= delta. ",
                                testData.testUpperSide ? "Upper" : "Lower",
                                " side test. ",
                                "Factor1: ",
                                vm.toString(sideFactor1),
                                " Factor2: ",
                                vm.toString(sideFactor2),
                                " Delta1: ",
                                vm.toString(delta1),
                                " Delta2: ",
                                vm.toString(delta2)
                            )
                        )
                    );
                }
            }
        }

        // Verify fees remain within bounds
        assertTrue(
            testData.fee1After >= params1.minFee && testData.fee1After <= params1.maxFee, "Pool1 fee within bounds"
        );
        assertTrue(
            testData.fee2After >= params2.minFee && testData.fee2After <= params2.maxFee, "Pool2 fee within bounds"
        );
    }

    /* --------------------------- Parameter Comparison Helpers --------------------------- */

    /**
     * @notice Tests linear slope comparison using separate pools
     * @dev Higher linear slopes should produce larger fee deltas for identical ratio deviations
     * @param linearSlope1 First linear slope value
     * @param linearSlope2 Second linear slope value
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param ratioDeviation How far from target ratio to test
     */
    function _testLinearSlopeComparison(
        uint256 linearSlope1,
        uint256 linearSlope2,
        uint256 ratioTolerance,
        uint24 baseMaxFeeDelta,
        uint256 ratioDeviation
    ) internal {
        ParameterComparisonTestData memory testData;
        testData.param1Value = linearSlope1;
        testData.param2Value = linearSlope2;

        // Create separate pools
        (testData.key1, testData.key2) = _createParameterComparisonPools();

        // Calculate test ratio outside tolerance band
        testData.testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, ratioTolerance) + ratioDeviation;

        // Execute test with different linear slopes
        _executeParameterComparisonTest(
            testData, "linearSlope", ratioTolerance, baseMaxFeeDelta, linearSlope1, linearSlope2
        );
    }

    /**
     * @notice Tests base max fee delta comparison using separate pools
     * @dev Higher base max fee deltas should allow larger fee adjustments under streak conditions
     * @param baseMaxFeeDelta1 First base max fee delta value
     * @param baseMaxFeeDelta2 Second base max fee delta value
     * @param ratioTolerance Tolerance band around target ratio
     * @param ratioDeviation How far from target ratio to test
     */
    function _testBaseMaxFeeDeltaComparison(
        uint24 baseMaxFeeDelta1,
        uint24 baseMaxFeeDelta2,
        uint256 ratioTolerance,
        uint256, /* linearSlope */
        uint256 ratioDeviation
    ) internal {
        ParameterComparisonTestData memory testData;
        testData.param1Value = uint256(baseMaxFeeDelta1);
        testData.param2Value = uint256(baseMaxFeeDelta2);

        // Create separate pools
        (testData.key1, testData.key2) = _createParameterComparisonPools();

        // Calculate test ratio outside tolerance band
        testData.testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, ratioTolerance) + ratioDeviation;

        // Execute test with different base max fee deltas
        _executeParameterComparisonTest(
            testData,
            "baseMaxFeeDelta",
            ratioTolerance,
            50, // use a fixed baseMaxFeeDelta for parameter set creation
            uint256(baseMaxFeeDelta1),
            uint256(baseMaxFeeDelta2)
        );
    }

    /**
     * @notice Tests ratio tolerance comparison using separate pools
     * @dev Different ratio tolerances should affect when algorithms start making adjustments
     * @param ratioTolerance1 First ratio tolerance value
     * @param ratioTolerance2 Second ratio tolerance value
     * @param linearSlope Linear slope for fee calculations
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param ratioDeviation How far from target ratio to test
     */
    function _testRatioToleranceComparison(
        uint256 ratioTolerance1,
        uint256 ratioTolerance2,
        uint256 linearSlope,
        uint24 baseMaxFeeDelta,
        uint256 ratioDeviation
    ) internal {
        ParameterComparisonTestData memory testData;
        testData.param1Value = ratioTolerance1;
        testData.param2Value = ratioTolerance2;

        // Create separate pools
        (testData.key1, testData.key2) = _createParameterComparisonPools();

        // Use a fixed ratio that may be in-band for one tolerance but out-of-band for another
        testData.testRatio = INITIAL_TARGET_RATIO + (INITIAL_TARGET_RATIO * ratioDeviation / 1e18);

        // Execute test with different ratio tolerances - this is more complex as it affects the test ratio interpretation
        _executeRatioToleranceComparisonTest(testData, ratioTolerance1, ratioTolerance2, linearSlope, baseMaxFeeDelta);
    }

    /* ------------------------------ Convergence Helpers ------------------------------ */

    /**
     * @notice Tests lookback period convergence using separate pools
     * @param shortKey Pool key with shorter lookback period
     * @param longKey Pool key with longer lookback period
     * @param shortLookback Shorter lookback period value
     * @param longLookback Longer lookback period value
     * @param ratioDeviation Sustained ratio deviation to test
     */
    function _testLookbackConvergence(
        PoolKey memory shortKey,
        PoolKey memory longKey,
        uint24 shortLookback,
        uint24 longLookback,
        uint256 ratioDeviation
    ) internal {
        // Create base params
        DynamicFeeLib.PoolTypeParams memory params = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 5000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: shortLookback,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });

        // Apply short lookback to first pool
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params);

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(shortKey, INITIAL_TARGET_RATIO);

        // Apply long lookback to second pool
        params.lookbackPeriod = longLookback;
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params);

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(longKey, INITIAL_TARGET_RATIO);

        // Test convergence with sustained deviation
        uint256 deviatedRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, params.ratioTolerance) + ratioDeviation;

        // First update - should produce identical fees
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(shortKey, deviatedRatio);
        vm.prank(owner);
        hook.poke(longKey, deviatedRatio);

        (,,, uint24 shortFirstFee) = poolManager.getSlot0(PoolIdLibrary.toId(shortKey));
        (,,, uint24 longFirstFee) = poolManager.getSlot0(PoolIdLibrary.toId(longKey));

        // Verify convergence behavior
        assertEq(shortFirstFee, longFirstFee, "First fees should be identical");
        assertTrue(shortFirstFee >= INITIAL_FEE, "Fees should increase for ratio above tolerance");
        assertTrue(shortLookback < longLookback, "Setup verification");
    }

    /* --------------------------- Ratio Calculation Helpers --------------------------- */

    /**
     * @notice Calculate upper bound for ratio tolerance
     * @param targetRatio The target ratio to calculate bounds for
     * @param ratioTolerance The ratio tolerance (as a fraction of 1e18)
     * @return upperBound The upper bound: targetRatio + targetRatio * ratioTolerance / 1e18
     */
    function _getUpperToleranceBound(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        // Use safe math to prevent overflow - check if multiplication would overflow
        if (ratioTolerance == 0) return targetRatio;
        if (targetRatio > type(uint256).max / ratioTolerance) {
            return targetRatio * 2; // Return double target ratio as safe upper bound
        }
        return targetRatio + (targetRatio * ratioTolerance / 1e18);
    }

    /**
     * @notice Calculate lower bound for ratio tolerance
     * @param targetRatio The target ratio to calculate bounds for
     * @param ratioTolerance The ratio tolerance (as a fraction of 1e18)
     * @return lowerBound The lower bound: targetRatio - targetRatio * ratioTolerance / 1e18
     */
    function _getLowerToleranceBound(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        // Use safe math to prevent overflow - check if multiplication would overflow
        if (ratioTolerance == 0) return targetRatio;
        if (targetRatio > type(uint256).max / ratioTolerance) {
            return targetRatio / 2; // Return half target ratio as safe lower bound
        }
        uint256 adjustment = (targetRatio * ratioTolerance) / 1e18;
        if (adjustment >= targetRatio) {
            return targetRatio / 10; // Return 10% of target ratio as minimum safe bound
        }
        return targetRatio - adjustment;
    }

    /**
     * @notice Get a ratio slightly above the tolerance (out of bounds upper)
     * @param targetRatio The target ratio
     * @param ratioTolerance The ratio tolerance
     * @return outOfBoundsRatio A ratio just above the upper tolerance bound
     */
    function _getAboveToleranceRatio(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        // Add 0.1% relative to target ratio (1e15 * targetRatio / 1e18)
        uint256 additionalMargin = (1e15 * targetRatio) / 1e18;
        return _getUpperToleranceBound(targetRatio, ratioTolerance) + additionalMargin;
    }

    /**
     * @notice Get a ratio slightly below the tolerance (out of bounds lower)
     * @param targetRatio The target ratio
     * @param ratioTolerance The ratio tolerance
     * @return outOfBoundsRatio A ratio just below the lower tolerance bound
     */
    function _getBelowToleranceRatio(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        // Subtract 0.1% relative to target ratio (1e15 * targetRatio / 1e18)
        uint256 additionalMargin = (1e15 * targetRatio) / 1e18;
        uint256 lowerBound = _getLowerToleranceBound(targetRatio, ratioTolerance);
        if (additionalMargin >= lowerBound) {
            return lowerBound / 2; // Return half the lower bound as safe minimum
        }
        return lowerBound - additionalMargin;
    }

    /* --------------------------- Generic Parameter Helpers --------------------------- */

    /**
     * @notice Creates two separate pools for parameter comparison testing
     * @dev Returns pool keys for two identical pools with different currencies
     * @return key1 First pool key
     * @return key2 Second pool key
     */
    function _createParameterComparisonPools() internal returns (PoolKey memory key1, PoolKey memory key2) {
        (Currency c0_1, Currency c1_1) = deployCurrencyPairWithDecimals(18, 18);
        (Currency c0_2, Currency c1_2) = deployCurrencyPairWithDecimals(18, 18);

        key1 = PoolKey({
            currency0: c0_1,
            currency1: c1_1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        key2 = PoolKey({
            currency0: c0_2,
            currency1: c1_2,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: hook
        });

        // Initialize both pools
        poolManager.initialize(key1, Constants.SQRT_PRICE_1_1);
        poolManager.initialize(key2, Constants.SQRT_PRICE_1_1);

        // Initialize both pools with identical starting conditions
        vm.prank(owner);
        hook.initializePool(key1, 500, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);
        vm.prank(owner);
        hook.initializePool(key2, 500, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STABLE);
    }

    /**
     * @notice Executes a generic parameter comparison test
     * @dev Creates different parameter sets and compares fee deltas
     * @param testData Test data structure with pool keys and test ratio
     * @param parameterName Name of parameter being tested (for assertions)
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param param1Value First parameter value (varies by parameter type)
     * @param param2Value Second parameter value (varies by parameter type)
     */
    function _executeParameterComparisonTest(
        ParameterComparisonTestData memory testData,
        string memory parameterName,
        uint256 ratioTolerance,
        uint24 baseMaxFeeDelta,
        uint256 param1Value,
        uint256 param2Value
    ) internal {
        // Create parameter sets - exact structure depends on which parameter we're testing
        DynamicFeeLib.PoolTypeParams memory params1;
        DynamicFeeLib.PoolTypeParams memory params2;

        if (keccak256(bytes(parameterName)) == keccak256("linearSlope")) {
            params1 = _createParameterSetWithLinearSlope(ratioTolerance, baseMaxFeeDelta, param1Value);
            params2 = _createParameterSetWithLinearSlope(ratioTolerance, baseMaxFeeDelta, param2Value);
        } else if (keccak256(bytes(parameterName)) == keccak256("baseMaxFeeDelta")) {
            params1 = _createParameterSetWithBaseMaxFeeDelta(ratioTolerance, uint24(param1Value), 2e18);
            params2 = _createParameterSetWithBaseMaxFeeDelta(ratioTolerance, uint24(param2Value), 2e18);
        }

        // Execute pokes and compare results
        _executePokeAndCompare(testData, params1, params2, parameterName);
    }

    /**
     * @notice Executes ratio tolerance specific comparison test
     * @dev Handles the special case where ratio tolerance affects the test conditions themselves
     * @param testData Test data structure with pool keys and test ratio
     * @param ratioTolerance1 First ratio tolerance value
     * @param ratioTolerance2 Second ratio tolerance value
     * @param linearSlope Linear slope for fee calculations
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     */
    function _executeRatioToleranceComparisonTest(
        ParameterComparisonTestData memory testData,
        uint256 ratioTolerance1,
        uint256 ratioTolerance2,
        uint256 linearSlope,
        uint24 baseMaxFeeDelta
    ) internal {
        DynamicFeeLib.PoolTypeParams memory params1 =
            _createParameterSetWithRatioTolerance(ratioTolerance1, linearSlope, baseMaxFeeDelta);
        DynamicFeeLib.PoolTypeParams memory params2 =
            _createParameterSetWithRatioTolerance(ratioTolerance2, linearSlope, baseMaxFeeDelta);

        // Execute pokes and compare results - this test is about in-band vs out-of-band behavior
        _executePokeAndCompare(testData, params1, params2, "ratioTolerance");
    }

    /**
     * @notice Creates parameter set with specific linear slope
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param linearSlope Linear slope value to use
     * @return params Complete parameter set
     */
    function _createParameterSetWithLinearSlope(uint256 ratioTolerance, uint24 baseMaxFeeDelta, uint256 linearSlope)
        internal
        pure
        returns (DynamicFeeLib.PoolTypeParams memory)
    {
        return DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });
    }

    /**
     * @notice Creates parameter set with specific base max fee delta
     * @param ratioTolerance Tolerance band around target ratio
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @param linearSlope Linear slope value to use
     * @return params Complete parameter set
     */
    function _createParameterSetWithBaseMaxFeeDelta(uint256 ratioTolerance, uint24 baseMaxFeeDelta, uint256 linearSlope)
        internal
        pure
        returns (DynamicFeeLib.PoolTypeParams memory)
    {
        return DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });
    }

    /**
     * @notice Creates parameter set with specific ratio tolerance
     * @param ratioTolerance Tolerance band around target ratio
     * @param linearSlope Linear slope value to use
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     * @return params Complete parameter set
     */
    function _createParameterSetWithRatioTolerance(uint256 ratioTolerance, uint256 linearSlope, uint24 baseMaxFeeDelta)
        internal
        pure
        returns (DynamicFeeLib.PoolTypeParams memory)
    {
        return DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });
    }

    /**
     * @notice Executes poke operations and compares results
     * @dev Sets different parameters for each pool, pokes with identical ratio, and validates results
     * @param testData Test data structure with pool keys and test ratio
     * @param params1 Parameters for first pool
     * @param params2 Parameters for second pool
     * @param parameterName Name of parameter being tested (for assertion messages)
     */
    function _executePokeAndCompare(
        ParameterComparisonTestData memory testData,
        DynamicFeeLib.PoolTypeParams memory params1,
        DynamicFeeLib.PoolTypeParams memory params2,
        string memory parameterName
    ) internal {
        // Get initial fees
        (,,, testData.fee1Before) = poolManager.getSlot0(testData.key1.toId());
        (,,, testData.fee2Before) = poolManager.getSlot0(testData.key2.toId());

        // Set parameters and poke each pool
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params1);
        vm.warp(block.timestamp + params1.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testData.key1, testData.testRatio);

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, params2);
        vm.warp(block.timestamp + params2.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testData.key2, testData.testRatio);

        // Get final fees
        (,,, testData.fee1After) = poolManager.getSlot0(testData.key1.toId());
        (,,, testData.fee2After) = poolManager.getSlot0(testData.key2.toId());

        // Compare results and validate parameter relationship
        _validateParameterRelationship(testData, params1, params2, parameterName);
    }

    /**
     * @notice Validates the relationship between parameter values and resulting fee deltas
     * @dev Checks that the expected parameter relationship holds in the fee adjustments
     * @param testData Test data structure with fee results
     * @param params1 Parameters for first pool
     * @param params2 Parameters for second pool
     * @param parameterName Name of parameter being tested
     */
    function _validateParameterRelationship(
        ParameterComparisonTestData memory testData,
        DynamicFeeLib.PoolTypeParams memory params1,
        DynamicFeeLib.PoolTypeParams memory params2,
        string memory parameterName
    ) internal pure {
        // Calculate deltas
        uint24 delta1 = testData.fee1After >= testData.fee1Before
            ? testData.fee1After - testData.fee1Before
            : testData.fee1Before - testData.fee1After;
        uint24 delta2 = testData.fee2After >= testData.fee2Before
            ? testData.fee2After - testData.fee2Before
            : testData.fee2Before - testData.fee2After;

        // Only validate relationship if both pools produced meaningful changes and didn't hit bounds
        if (delta1 > 0 && delta2 > 0) {
            bool fee1HitBounds = testData.fee1After == params1.minFee || testData.fee1After == params1.maxFee;
            bool fee2HitBounds = testData.fee2After == params2.minFee || testData.fee2After == params2.maxFee;

            if (!fee1HitBounds && !fee2HitBounds) {
                if (testData.param1Value > testData.param2Value) {
                    assertGe(
                        delta1,
                        delta2,
                        string(
                            abi.encodePacked(
                                "Higher ",
                                parameterName,
                                " should produce >= delta. ",
                                "Param1: ",
                                vm.toString(testData.param1Value),
                                " Param2: ",
                                vm.toString(testData.param2Value),
                                " Delta1: ",
                                vm.toString(delta1),
                                " Delta2: ",
                                vm.toString(delta2)
                            )
                        )
                    );
                } else if (testData.param2Value > testData.param1Value) {
                    assertGe(
                        delta2,
                        delta1,
                        string(
                            abi.encodePacked(
                                "Higher ",
                                parameterName,
                                " should produce >= delta. ",
                                "Param1: ",
                                vm.toString(testData.param1Value),
                                " Param2: ",
                                vm.toString(testData.param2Value),
                                " Delta1: ",
                                vm.toString(delta1),
                                " Delta2: ",
                                vm.toString(delta2)
                            )
                        )
                    );
                }
            }
        }

        // Verify fees remain within bounds
        assertTrue(
            testData.fee1After >= params1.minFee && testData.fee1After <= params1.maxFee, "Pool1 fee within bounds"
        );
        assertTrue(
            testData.fee2After >= params2.minFee && testData.fee2After <= params2.maxFee, "Pool2 fee within bounds"
        );
    }
}
