// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */

/* UNISWAP V4 IMPORTS */
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {Alphix} from "../../../../src/Alphix.sol";

/**
 * @title AlphixLogicPoolManagementFuzzTest
 * @author Alphix
 * @notice Fuzz tests for pool parameter validation and boundary conditions
 * @dev Comprehensive fuzz testing of setPoolParams validation logic across all parameter ranges
 *      to ensure robust boundary checking and prevent invalid configurations
 */
contract AlphixLogicPoolManagementFuzzTest is BaseAlphixTest {
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

    // Ratio tolerance bounds
    uint256 constant MIN_RATIO_TOLERANCE_FUZZ = AlphixGlobalConstants.MIN_RATIO_TOLERANCE;
    uint256 constant MAX_RATIO_TOLERANCE_FUZZ = AlphixGlobalConstants.TEN_WAD;

    // Linear slope bounds
    uint256 constant MIN_LINEAR_SLOPE_FUZZ = AlphixGlobalConstants.MIN_LINEAR_SLOPE;
    uint256 constant MAX_LINEAR_SLOPE_FUZZ = AlphixGlobalConstants.TEN_WAD;

    // Side factor bounds (min 0.1x to allow dampening, max 10x)
    uint256 constant MIN_SIDE_FACTOR_FUZZ = AlphixGlobalConstants.ONE_TENTH_WAD;
    uint256 constant MAX_SIDE_FACTOR_FUZZ = AlphixGlobalConstants.TEN_WAD;

    // BaseMaxFeeDelta bounds
    uint24 constant MIN_BASE_MAX_FEE_DELTA_FUZZ = 1;
    uint24 constant MAX_BASE_MAX_FEE_DELTA_FUZZ = 1000;

    // Max current ratio bounds
    uint256 constant MIN_MAX_CURRENT_RATIO_FUZZ = 1; // Must be > 0
    uint256 constant MAX_MAX_CURRENT_RATIO_FUZZ = AlphixGlobalConstants.MAX_CURRENT_RATIO;

    /**
     * @notice Sets up the fuzz test environment
     * @dev Initializes the base test environment for fuzz testing
     */
    function setUp() public override {
        super.setUp();
    }

    /* ========================================================================== */
    /*                      POOL ACTIVATION & CONFIGURATION TESTS                */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that activateAndConfigurePool succeeds with valid fee and target ratio values
     * @dev Tests pool activation across full range of valid initial fees and target ratios
     * @param initialFee Initial fee for the pool (in basis points)
     * @param targetRatio Initial target ratio for the pool
     */
    function testFuzz_activateAndConfigurePool_success_withValidParams(uint24 initialFee, uint256 targetRatio) public {
        // Deploy fresh hook + logic stack for this test (single-pool-per-hook architecture)
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Use defaultPoolParams for bounds (freshLogic.getPoolParams() returns zeros before pool configured)
        DynamicFeeLib.PoolParams memory standardParams = defaultPoolParams;

        // Bound to valid ranges for STANDARD pool type
        initialFee = uint24(bound(initialFee, standardParams.minFee, standardParams.maxFee));
        targetRatio = bound(targetRatio, 1e15, standardParams.maxCurrentRatio);

        // Create a fresh pool with fresh hook
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        // Ensure pool is unconfigured
        IAlphixLogic.PoolConfig memory pre = freshLogic.getPoolConfig();
        assertFalse(pre.isConfigured, "fresh pool should be unconfigured");

        // Configure + activate via hook
        vm.prank(address(freshHook));
        freshLogic.activateAndConfigurePool(freshKey, initialFee, targetRatio, defaultPoolParams);

        // Validate configuration
        IAlphixLogic.PoolConfig memory config = freshLogic.getPoolConfig();
        assertEq(config.initialFee, initialFee, "initialFee mismatch");
        assertEq(config.initialTargetRatio, targetRatio, "initialTargetRatio mismatch");
        assertTrue(config.isConfigured, "isConfigured should be true");

        // Validate pool is active
        vm.prank(address(freshHook));
        freshLogic.beforeAddLiquidity(
            user1, freshKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
        );
    }

    /**
     * @notice Fuzz test that activateAndConfigurePool works across all pool types
     * @dev Tests pool activation with STABLE, STANDARD, and VOLATILE pool types
     * @dev Removed: poolType parameter (single-pool architecture)
     * @param initialFee Initial fee for the pool
     */
    function testFuzz_activateAndConfigurePool_success_acrossPoolTypes(uint24 initialFee) public {
        // Deploy fresh hook + logic stack for this test (single-pool-per-hook architecture)
        (Alphix freshHook, IAlphixLogic freshLogic) = _deployFreshAlphixStack();

        // Use defaultPoolParams for bounds (freshLogic.getPoolParams() returns zeros before pool configured)
        DynamicFeeLib.PoolParams memory poolParams = defaultPoolParams;
        initialFee = uint24(bound(initialFee, poolParams.minFee, poolParams.maxFee));

        // Create and configure pool with fresh hook
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        vm.prank(address(freshHook));
        freshLogic.activateAndConfigurePool(freshKey, initialFee, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Verify configuration
        IAlphixLogic.PoolConfig memory config = freshLogic.getPoolConfig();
        assertTrue(config.isConfigured, "pool should be configured");
    }

    /* ========================================================================== */
    /*                     FEE BOUNDS VALIDATION TESTS                          */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid fee ranges
     * @dev Tests fee validation across the full valid range
     * @param minFee Minimum fee boundary
     * @param maxFee Maximum fee boundary
     */
    function testFuzz_setPoolParams_success_validFeeBounds(uint24 minFee, uint24 maxFee) public {
        // Bound to valid ranges
        minFee = uint24(bound(minFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ / 2));
        maxFee = uint24(bound(maxFee, minFee, MAX_FEE_FUZZ));

        // Ensure minFee <= maxFee
        vm.assume(minFee <= maxFee);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.minFee = minFee;
        params.maxFee = maxFee;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.minFee, minFee, "minFee should match");
        assertEq(retrieved.maxFee, maxFee, "maxFee should match");
    }

    /**
     * @notice Fuzz test that setPoolParams reverts when minFee > maxFee
     * @dev Tests that fee bounds are properly validated
     * @param minFee Minimum fee boundary
     * @param maxFee Maximum fee boundary
     */
    function testFuzz_setPoolParams_reverts_minFeeGreaterThanMaxFee(uint24 minFee, uint24 maxFee) public {
        // Bound to valid individual ranges but ensure minFee > maxFee
        minFee = uint24(bound(minFee, MIN_FEE_FUZZ + 1, MAX_FEE_FUZZ));
        maxFee = uint24(bound(maxFee, MIN_FEE_FUZZ, minFee - 1));

        // Ensure minFee > maxFee
        vm.assume(minFee > maxFee);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.minFee = minFee;
        params.maxFee = maxFee;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, minFee, maxFee));
        logic.setPoolParams(params);
    }

    /**
     * @notice Fuzz test that setPoolParams rejects excessive maxFee values
     * @dev Tests upper bound validation for maxFee
     * @param excessiveFee Fee value above the maximum allowed
     */
    function testFuzz_setPoolParams_reverts_excessiveMaxFee(uint24 excessiveFee) public {
        // Bound to values above the maximum
        excessiveFee = uint24(bound(excessiveFee, MAX_FEE_FUZZ + 1, type(uint24).max));

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        uint24 minFee = params.minFee;
        params.maxFee = excessiveFee;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, minFee, excessiveFee));
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                   BASE MAX FEE DELTA VALIDATION TESTS                    */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid baseMaxFeeDelta values
     * @dev Tests baseMaxFeeDelta validation across valid range
     * @param baseMaxFeeDelta Base maximum fee delta per streak
     */
    function testFuzz_setPoolParams_success_validBaseMaxFeeDelta(uint24 baseMaxFeeDelta) public {
        // Bound to valid range
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.baseMaxFeeDelta = baseMaxFeeDelta;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.baseMaxFeeDelta, baseMaxFeeDelta, "baseMaxFeeDelta should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid baseMaxFeeDelta values
     * @dev Tests both zero and excessive baseMaxFeeDelta values
     * @param baseMaxFeeDelta Base maximum fee delta to test
     * @param testZero Whether to test zero (true) or excessive values (false)
     */
    function testFuzz_setPoolParams_reverts_invalidBaseMaxFeeDelta(uint24 baseMaxFeeDelta, bool testZero) public {
        if (testZero) {
            baseMaxFeeDelta = 0;
        } else {
            // Test values above MAX_LP_FEE (the actual contract bound)
            baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MAX_FEE_FUZZ + 1, type(uint24).max));
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.baseMaxFeeDelta = baseMaxFeeDelta;

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                    MIN PERIOD VALIDATION TESTS                           */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid minPeriod values
     * @dev Tests minPeriod validation across the full valid range
     * @param minPeriod Minimum period between fee adjustments
     */
    function testFuzz_setPoolParams_success_validMinPeriod(uint256 minPeriod) public {
        // Bound to valid range
        minPeriod = bound(minPeriod, MIN_PERIOD_FUZZ, MAX_PERIOD_FUZZ);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.minPeriod = minPeriod;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.minPeriod, minPeriod, "minPeriod should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid minPeriod values
     * @dev Tests minPeriod validation at boundaries
     * @param minPeriod Minimum period to test
     * @param testLower Whether to test lower bound (true) or upper bound (false)
     */
    function testFuzz_setPoolParams_reverts_invalidMinPeriod(uint256 minPeriod, bool testLower) public {
        if (testLower) {
            // Test below minimum
            minPeriod = bound(minPeriod, 0, MIN_PERIOD_FUZZ - 1);
        } else {
            // Test above maximum
            minPeriod = bound(minPeriod, MAX_PERIOD_FUZZ + 1, type(uint256).max / 2);
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.minPeriod = minPeriod;

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                  LOOKBACK PERIOD VALIDATION TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid lookbackPeriod values
     * @dev Tests lookbackPeriod validation across the full valid range
     * @param lookbackPeriod Lookback period in days for EMA calculations
     */
    function testFuzz_setPoolParams_success_validLookbackPeriod(uint24 lookbackPeriod) public {
        // Bound to valid range
        lookbackPeriod = uint24(bound(lookbackPeriod, MIN_LOOKBACK_FUZZ, MAX_LOOKBACK_FUZZ));

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.lookbackPeriod = lookbackPeriod;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.lookbackPeriod, lookbackPeriod, "lookbackPeriod should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid lookbackPeriod values
     * @dev Tests lookbackPeriod validation at boundaries
     * @param lookbackPeriod Lookback period to test
     * @param testLower Whether to test lower bound (true) or upper bound (false)
     */
    function testFuzz_setPoolParams_reverts_invalidLookbackPeriod(uint24 lookbackPeriod, bool testLower) public {
        if (testLower) {
            // Test below minimum
            lookbackPeriod = uint24(bound(lookbackPeriod, 0, MIN_LOOKBACK_FUZZ - 1));
        } else {
            // Test above maximum
            lookbackPeriod = uint24(bound(lookbackPeriod, MAX_LOOKBACK_FUZZ + 1, type(uint24).max));
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.lookbackPeriod = lookbackPeriod;

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                  RATIO TOLERANCE VALIDATION TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid ratioTolerance values
     * @dev Tests ratioTolerance validation across the full valid range
     * @param ratioTolerance Tolerance band around target ratio
     */
    function testFuzz_setPoolParams_success_validRatioTolerance(uint256 ratioTolerance) public {
        // Bound to valid range
        ratioTolerance = bound(ratioTolerance, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.ratioTolerance = ratioTolerance;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.ratioTolerance, ratioTolerance, "ratioTolerance should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid ratioTolerance values
     * @dev Tests ratioTolerance validation at boundaries
     * @param ratioTolerance Ratio tolerance to test
     * @param testLower Whether to test lower bound (true) or upper bound (false)
     */
    function testFuzz_setPoolParams_reverts_invalidRatioTolerance(uint256 ratioTolerance, bool testLower) public {
        if (testLower) {
            // Test below minimum
            ratioTolerance = bound(ratioTolerance, 0, MIN_RATIO_TOLERANCE_FUZZ - 1);
        } else {
            // Test above maximum
            ratioTolerance = bound(ratioTolerance, MAX_RATIO_TOLERANCE_FUZZ + 1, type(uint256).max / 2);
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.ratioTolerance = ratioTolerance;

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                    LINEAR SLOPE VALIDATION TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid linearSlope values
     * @dev Tests linearSlope validation across the full valid range
     * @param linearSlope Linear slope factor for fee calculations
     */
    function testFuzz_setPoolParams_success_validLinearSlope(uint256 linearSlope) public {
        // Bound to valid range
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.linearSlope = linearSlope;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.linearSlope, linearSlope, "linearSlope should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid linearSlope values
     * @dev Tests linearSlope validation at boundaries
     * @param linearSlope Linear slope to test
     * @param testLower Whether to test lower bound (true) or upper bound (false)
     */
    function testFuzz_setPoolParams_reverts_invalidLinearSlope(uint256 linearSlope, bool testLower) public {
        if (testLower) {
            // Test below minimum
            linearSlope = bound(linearSlope, 0, MIN_LINEAR_SLOPE_FUZZ - 1);
        } else {
            // Test above maximum
            linearSlope = bound(linearSlope, MAX_LINEAR_SLOPE_FUZZ + 1, type(uint256).max / 2);
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.linearSlope = linearSlope;

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                    SIDE FACTOR VALIDATION TESTS                          */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid side factor values
     * @dev Tests side factor validation across the full valid range for both upper and lower sides
     * @param upperSideFactor Upper side multiplier factor
     * @param lowerSideFactor Lower side multiplier factor
     */
    function testFuzz_setPoolParams_success_validSideFactors(uint256 upperSideFactor, uint256 lowerSideFactor) public {
        // Bound to valid ranges
        upperSideFactor = bound(upperSideFactor, MIN_SIDE_FACTOR_FUZZ, MAX_SIDE_FACTOR_FUZZ);
        lowerSideFactor = bound(lowerSideFactor, MIN_SIDE_FACTOR_FUZZ, MAX_SIDE_FACTOR_FUZZ);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.upperSideFactor = upperSideFactor;
        params.lowerSideFactor = lowerSideFactor;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.upperSideFactor, upperSideFactor, "upperSideFactor should match");
        assertEq(retrieved.lowerSideFactor, lowerSideFactor, "lowerSideFactor should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid side factor values
     * @dev Tests side factor validation at boundaries
     * @param sideFactor Side factor to test
     * @param testUpper Whether to test upper side factor (true) or lower side factor (false)
     * @param testLower Whether to test lower bound (true) or upper bound (false)
     */
    function testFuzz_setPoolParams_reverts_invalidSideFactors(uint256 sideFactor, bool testUpper, bool testLower)
        public
    {
        if (testLower) {
            // Test below minimum
            sideFactor = bound(sideFactor, 0, MIN_SIDE_FACTOR_FUZZ - 1);
        } else {
            // Test above maximum
            sideFactor = bound(sideFactor, MAX_SIDE_FACTOR_FUZZ + 1, type(uint256).max / 2);
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();

        if (testUpper) {
            params.upperSideFactor = sideFactor;
        } else {
            params.lowerSideFactor = sideFactor;
        }

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                  MAX CURRENT RATIO VALIDATION TESTS                      */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts valid maxCurrentRatio values
     * @dev Tests maxCurrentRatio validation across the full valid range
     * @param maxCurrentRatio Maximum allowed current ratio
     */
    function testFuzz_setPoolParams_success_validMaxCurrentRatio(uint256 maxCurrentRatio) public {
        // Bound to valid range
        maxCurrentRatio = bound(maxCurrentRatio, MIN_MAX_CURRENT_RATIO_FUZZ, MAX_MAX_CURRENT_RATIO_FUZZ);

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.maxCurrentRatio = maxCurrentRatio;

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify params were set
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.maxCurrentRatio, maxCurrentRatio, "maxCurrentRatio should match");
    }

    /**
     * @notice Fuzz test that setPoolParams rejects invalid maxCurrentRatio values
     * @dev Tests maxCurrentRatio validation at boundaries
     * @param maxCurrentRatio Max current ratio to test
     * @param testLower Whether to test lower bound (true) or upper bound (false)
     */
    function testFuzz_setPoolParams_reverts_invalidMaxCurrentRatio(uint256 maxCurrentRatio, bool testLower) public {
        if (testLower) {
            // Test below minimum
            maxCurrentRatio = bound(maxCurrentRatio, 0, MIN_MAX_CURRENT_RATIO_FUZZ - 1);
        } else {
            // Test above maximum
            maxCurrentRatio = bound(maxCurrentRatio, MAX_MAX_CURRENT_RATIO_FUZZ + 1, type(uint256).max / 2);
        }

        DynamicFeeLib.PoolParams memory params = _createValidParams();
        params.maxCurrentRatio = maxCurrentRatio;

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolParams(params);
    }

    /* ========================================================================== */
    /*                      COMBINED PARAMETER TESTS                            */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that setPoolParams accepts all valid parameter combinations
     * @dev Tests that valid parameter combinations across all dimensions are accepted
     * @param minFee Minimum fee boundary
     * @param maxFee Maximum fee boundary
     * @param baseMaxFeeDelta Base maximum fee delta
     * @param lookbackPeriod Lookback period in days
     * @param minPeriod Minimum period between adjustments
     * @param ratioTolerance Tolerance band around target ratio
     * @param linearSlope Linear slope factor
     * @param upperSideFactor Upper side multiplier
     * @param lowerSideFactor Lower side multiplier
     * @param maxCurrentRatio Maximum allowed current ratio
     */
    function testFuzz_setPoolParams_success_allValidCombinations(
        uint24 minFee,
        uint24 maxFee,
        uint24 baseMaxFeeDelta,
        uint24 lookbackPeriod,
        uint256 minPeriod,
        uint256 ratioTolerance,
        uint256 linearSlope,
        uint256 upperSideFactor,
        uint256 lowerSideFactor,
        uint256 maxCurrentRatio
    ) public {
        // Bound all parameters to valid ranges
        minFee = uint24(bound(minFee, MIN_FEE_FUZZ, MAX_FEE_FUZZ / 2));
        maxFee = uint24(bound(maxFee, minFee, MAX_FEE_FUZZ));
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, MIN_BASE_MAX_FEE_DELTA_FUZZ, MAX_BASE_MAX_FEE_DELTA_FUZZ));
        lookbackPeriod = uint24(bound(lookbackPeriod, MIN_LOOKBACK_FUZZ, MAX_LOOKBACK_FUZZ));
        minPeriod = bound(minPeriod, MIN_PERIOD_FUZZ, MAX_PERIOD_FUZZ);
        ratioTolerance = bound(ratioTolerance, MIN_RATIO_TOLERANCE_FUZZ, MAX_RATIO_TOLERANCE_FUZZ);
        linearSlope = bound(linearSlope, MIN_LINEAR_SLOPE_FUZZ, MAX_LINEAR_SLOPE_FUZZ);
        upperSideFactor = bound(upperSideFactor, MIN_SIDE_FACTOR_FUZZ, MAX_SIDE_FACTOR_FUZZ);
        lowerSideFactor = bound(lowerSideFactor, MIN_SIDE_FACTOR_FUZZ, MAX_SIDE_FACTOR_FUZZ);
        maxCurrentRatio = bound(maxCurrentRatio, MIN_MAX_CURRENT_RATIO_FUZZ, MAX_MAX_CURRENT_RATIO_FUZZ);

        // Ensure minFee <= maxFee
        vm.assume(minFee <= maxFee);

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: minFee,
            maxFee: maxFee,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: lookbackPeriod,
            minPeriod: minPeriod,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: maxCurrentRatio,
            upperSideFactor: upperSideFactor,
            lowerSideFactor: lowerSideFactor
        });

        vm.prank(owner);
        logic.setPoolParams(params);

        // Verify all params were set correctly
        DynamicFeeLib.PoolParams memory retrieved = logic.getPoolParams();
        assertEq(retrieved.minFee, minFee, "minFee mismatch");
        assertEq(retrieved.maxFee, maxFee, "maxFee mismatch");
        assertEq(retrieved.baseMaxFeeDelta, baseMaxFeeDelta, "baseMaxFeeDelta mismatch");
        assertEq(retrieved.lookbackPeriod, lookbackPeriod, "lookbackPeriod mismatch");
        assertEq(retrieved.minPeriod, minPeriod, "minPeriod mismatch");
        assertEq(retrieved.ratioTolerance, ratioTolerance, "ratioTolerance mismatch");
        assertEq(retrieved.linearSlope, linearSlope, "linearSlope mismatch");
        assertEq(retrieved.maxCurrentRatio, maxCurrentRatio, "maxCurrentRatio mismatch");
        assertEq(retrieved.upperSideFactor, upperSideFactor, "upperSideFactor mismatch");
        assertEq(retrieved.lowerSideFactor, lowerSideFactor, "lowerSideFactor mismatch");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                             */
    /* ========================================================================== */

    /**
     * @notice Creates a valid set of pool type parameters
     * @dev Helper function to generate baseline valid parameters for testing
     * @return params Valid PoolParams struct
     */
    function _createValidParams() internal pure returns (DynamicFeeLib.PoolParams memory) {
        // Use declared fuzz bounds to prevent drift when constants change
        return DynamicFeeLib.PoolParams({
            minFee: MIN_FEE_FUZZ,
            maxFee: MAX_FEE_FUZZ / 2, // Mid-range value
            baseMaxFeeDelta: (MIN_BASE_MAX_FEE_DELTA_FUZZ + MAX_BASE_MAX_FEE_DELTA_FUZZ) / 2,
            lookbackPeriod: MIN_LOOKBACK_FUZZ,
            minPeriod: MIN_PERIOD_FUZZ,
            ratioTolerance: MIN_RATIO_TOLERANCE_FUZZ * 5, // 5x minimum for safety
            linearSlope: MIN_LINEAR_SLOPE_FUZZ,
            maxCurrentRatio: MAX_MAX_CURRENT_RATIO_FUZZ,
            upperSideFactor: MIN_SIDE_FACTOR_FUZZ,
            lowerSideFactor: MIN_SIDE_FACTOR_FUZZ
        });
    }
}
