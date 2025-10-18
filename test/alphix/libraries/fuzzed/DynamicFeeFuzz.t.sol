// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* LOCAL IMPORTS */
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title DynamicFeeFuzzTest
 * @author Alphix
 * @notice Comprehensive fuzz tests for DynamicFeeLib library functions
 * @dev Tests all pure functions across their full input ranges with extensive edge case coverage
 */
contract DynamicFeeFuzzTest is Test {
    using DynamicFeeLib for *;

    /* FUZZING CONSTRAINTS */

    // Ratio bounds
    uint256 constant MIN_RATIO_FUZZ = 1e12; // 0.0001%
    uint256 constant MAX_RATIO_FUZZ = 1e24; // 1,000,000x

    // Fee bounds
    uint24 constant MIN_FEE_FUZZ = 1;
    uint24 constant MAX_FEE_FUZZ = 1000000; // 100%

    // Tolerance bounds
    uint256 constant MIN_TOLERANCE_FUZZ = 1e15; // 0.1%
    uint256 constant MAX_TOLERANCE_FUZZ = AlphixGlobalConstants.TEN_WAD; // 1000%

    // Lookback period bounds
    uint24 constant MIN_LOOKBACK_FUZZ = 1;
    uint24 constant MAX_LOOKBACK_FUZZ = 10000;

    // Test constants
    uint256 constant ONE_WAD = 1e18;
    uint256 constant HALF_WAD = 5e17;
    uint256 constant TWO_WAD = 2e18;

    // Sample pool type params for testing
    DynamicFeeLib.PoolTypeParams testParams;

    /**
     * @notice Sets up test parameters
     * @dev Initializes baseline pool type parameters for testing
     */
    function setUp() public {
        testParams = DynamicFeeLib.PoolTypeParams({
            minFee: 100, // 0.01%
            maxFee: 10000, // 1%
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e16, // 5%
            linearSlope: ONE_WAD,
            maxCurrentRatio: ONE_WAD * 1000,
            upperSideFactor: ONE_WAD,
            lowerSideFactor: TWO_WAD
        });
    }

    /* ========================================================================== */
    /*                         CLAMP FEE FUZZ TESTS                             */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that clampFee always returns value within bounds
     * @dev Tests clamping behavior across full uint256 range
     * @param fee Fee value to clamp
     * @param minFee Minimum fee bound
     * @param maxFee Maximum fee bound
     */
    function testFuzz_clampFee_alwaysWithinBounds(uint256 fee, uint24 minFee, uint24 maxFee) public pure {
        // Ensure minFee <= maxFee
        vm.assume(minFee <= maxFee);

        uint24 result = DynamicFeeLib.clampFee(fee, minFee, maxFee);

        // Result must always be within bounds
        assertTrue(result >= minFee, "Result should be >= minFee");
        assertTrue(result <= maxFee, "Result should be <= maxFee");

        // If fee is within bounds and fits in uint24, it should be returned as-is
        if (fee <= type(uint24).max && fee >= minFee && fee <= maxFee) {
            // Casting to uint24 is safe because we verified fee <= type(uint24).max
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(result, uint24(fee), "Should return original fee if within bounds");
        }
    }

    /**
     * @notice Fuzz test that clampFee handles boundary values correctly
     * @dev Tests exact boundary conditions
     * @param minFee Minimum fee bound
     * @param maxFee Maximum fee bound
     * @param belowAmount Amount below minFee to test
     * @param aboveAmount Amount above maxFee to test
     */
    function testFuzz_clampFee_boundaryBehavior(uint24 minFee, uint24 maxFee, uint24 belowAmount, uint24 aboveAmount)
        public
        pure
    {
        vm.assume(minFee <= maxFee);

        // Test below minFee
        if (minFee > belowAmount) {
            uint256 belowFee = uint256(minFee) - uint256(belowAmount);
            uint24 result = DynamicFeeLib.clampFee(belowFee, minFee, maxFee);
            assertEq(result, minFee, "Should clamp to minFee when below");
        }

        // Test above maxFee
        uint256 aboveFee = uint256(maxFee) + uint256(aboveAmount);
        if (aboveFee <= type(uint256).max) {
            uint24 result = DynamicFeeLib.clampFee(aboveFee, minFee, maxFee);
            assertEq(result, maxFee, "Should clamp to maxFee when above");
        }

        // Test exactly at boundaries
        assertEq(DynamicFeeLib.clampFee(minFee, minFee, maxFee), minFee, "Should return minFee at boundary");
        assertEq(DynamicFeeLib.clampFee(maxFee, minFee, maxFee), maxFee, "Should return maxFee at boundary");
    }

    /**
     * @notice Fuzz test that clampFee is idempotent
     * @dev Clamping twice should produce the same result as clamping once
     * @param fee Fee value to clamp
     * @param minFee Minimum fee bound
     * @param maxFee Maximum fee bound
     */
    function testFuzz_clampFee_idempotent(uint256 fee, uint24 minFee, uint24 maxFee) public pure {
        vm.assume(minFee <= maxFee);

        uint24 result1 = DynamicFeeLib.clampFee(fee, minFee, maxFee);
        uint24 result2 = DynamicFeeLib.clampFee(result1, minFee, maxFee);

        assertEq(result1, result2, "Clamping should be idempotent");
    }

    /* ========================================================================== */
    /*                       WITHIN BOUNDS FUZZ TESTS                           */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that withinBounds maintains logical consistency
     * @dev Tests that upper and inBand are mutually exclusive
     * @param target Target ratio
     * @param tolerance Tolerance band
     * @param current Current ratio
     */
    function testFuzz_withinBounds_logicalConsistency(uint256 target, uint256 tolerance, uint256 current) public pure {
        // Bound to prevent overflow
        target = bound(target, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        tolerance = bound(tolerance, MIN_TOLERANCE_FUZZ, MAX_TOLERANCE_FUZZ);
        current = bound(current, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        // Upper and inBand must be mutually exclusive
        if (inBand) {
            assertFalse(upper, "Cannot be both inBand and upper");
        }
    }

    /**
     * @notice Fuzz test that withinBounds handles zero target correctly
     * @dev Zero target is a special case that should be handled properly
     * @param tolerance Tolerance band
     * @param current Current ratio
     */
    function testFuzz_withinBounds_zeroTarget(uint256 tolerance, uint256 current) public pure {
        tolerance = bound(tolerance, MIN_TOLERANCE_FUZZ, MAX_TOLERANCE_FUZZ);
        current = bound(current, 0, MAX_RATIO_FUZZ);

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(0, tolerance, current);

        if (current > 0) {
            assertTrue(upper, "Should be upper when target=0 and current>0");
            assertFalse(inBand, "Should not be inBand when target=0 and current>0");
        } else {
            assertFalse(upper, "Should not be upper when both are zero");
            assertTrue(inBand, "Should be inBand when both are zero");
        }
    }

    /**
     * @notice Fuzz test that withinBounds correctly identifies boundary positions
     * @dev Tests exact tolerance boundaries
     * @param target Target ratio
     * @param tolerance Tolerance band
     */
    function testFuzz_withinBounds_exactBoundaries(uint256 target, uint256 tolerance) public pure {
        target = bound(target, ONE_WAD, MAX_RATIO_FUZZ / 2);
        tolerance = bound(tolerance, MIN_TOLERANCE_FUZZ, MAX_TOLERANCE_FUZZ / 10);

        // Calculate bounds
        uint256 delta = (target * tolerance) / ONE_WAD;
        uint256 upperBound = target + delta;

        // Test exact target
        (bool upperTarget, bool inBandTarget) = DynamicFeeLib.withinBounds(target, tolerance, target);
        assertFalse(upperTarget, "Should not be upper at exact target");
        assertTrue(inBandTarget, "Should be inBand at exact target");

        // Test at upper boundary (should be in band)
        (bool upperAtBound, bool inBandAtBound) = DynamicFeeLib.withinBounds(target, tolerance, upperBound);
        assertFalse(upperAtBound, "Should not be upper at boundary");
        assertTrue(inBandAtBound, "Should be inBand at exact upper boundary");

        // Test just above upper boundary
        if (upperBound < type(uint256).max - 1) {
            (bool upperAbove, bool inBandAbove) = DynamicFeeLib.withinBounds(target, tolerance, upperBound + 1);
            assertTrue(upperAbove, "Should be upper just above boundary");
            assertFalse(inBandAbove, "Should not be inBand just above boundary");
        }
    }

    /**
     * @notice Fuzz test that withinBounds is symmetric around target
     * @dev Tests that equidistant points above and below target have consistent behavior
     * @param target Target ratio
     * @param tolerance Tolerance band
     * @param offset Distance from target
     */
    function testFuzz_withinBounds_symmetry(uint256 target, uint256 tolerance, uint256 offset) public pure {
        target = bound(target, ONE_WAD * 10, MAX_RATIO_FUZZ / 2);
        tolerance = bound(tolerance, MIN_TOLERANCE_FUZZ, MAX_TOLERANCE_FUZZ / 10);
        uint256 delta = (target * tolerance) / ONE_WAD;
        offset = bound(offset, 0, delta / 2);

        uint256 above = target + offset;
        uint256 below = target - offset;

        (bool upperAbove, bool inBandAbove) = DynamicFeeLib.withinBounds(target, tolerance, above);
        (bool upperBelow, bool inBandBelow) = DynamicFeeLib.withinBounds(target, tolerance, below);

        // Both should be in band if within tolerance
        if (offset <= delta) {
            assertTrue(inBandAbove, "Above should be in band");
            assertTrue(inBandBelow, "Below should be in band");
            assertFalse(upperAbove, "Above should not be flagged as upper within band");
            assertFalse(upperBelow, "Below should not be flagged as upper within band");
        }
    }

    /* ========================================================================== */
    /*                            EMA FUZZ TESTS                                */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that EMA produces values between current and previous
     * @dev For lookback > 1, result should be between the two values
     * @param current Current value
     * @param previous Previous value
     * @param lookback Lookback period
     */
    function testFuzz_ema_boundedBetweenValues(uint256 current, uint256 previous, uint24 lookback) public pure {
        // Bound to prevent overflow
        current = bound(current, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        previous = bound(previous, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        lookback = uint24(bound(lookback, MIN_LOOKBACK_FUZZ, MAX_LOOKBACK_FUZZ));

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);

        if (current == previous) {
            assertEq(result, previous, "EMA should equal previous when values are equal");
        } else if (current > previous) {
            assertTrue(result >= previous, "EMA should be >= previous when current > previous");
            if (lookback > 1) {
                assertTrue(result <= current, "EMA should be <= current when current > previous (lookback > 1)");
            }
        } else {
            assertTrue(result <= previous, "EMA should be <= previous when current < previous");
            assertTrue(result >= current, "EMA should be >= current when current < previous");
        }
    }

    /**
     * @notice Fuzz test that EMA with lookback=1 equals current value
     * @dev Alpha becomes 1.0 when lookback=1, so EMA should equal current
     * @param current Current value
     * @param previous Previous value
     */
    function testFuzz_ema_lookbackOne(uint256 current, uint256 previous) public pure {
        current = bound(current, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        previous = bound(previous, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);

        uint256 result = DynamicFeeLib.ema(current, previous, 1);

        // With lookback=1, alpha = 2/(1+1) = 1.0, so result should equal current
        assertEq(result, current, "EMA with lookback=1 should equal current");
    }

    /**
     * @notice Fuzz test that EMA smoothing increases with lookback period
     * @dev Longer lookback should produce results closer to previous value
     * @param current Current value
     * @param previous Previous value
     * @param shortLookback Short lookback period
     * @param longLookback Long lookback period
     */
    function testFuzz_ema_lookbackEffect(uint256 current, uint256 previous, uint24 shortLookback, uint24 longLookback)
        public
        pure
    {
        current = bound(current, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        previous = bound(previous, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        shortLookback = uint24(bound(shortLookback, 2, 100));
        longLookback = uint24(bound(longLookback, shortLookback + 100, MAX_LOOKBACK_FUZZ));

        // Skip if values are equal (no difference to measure)
        vm.assume(current != previous);

        uint256 resultShort = DynamicFeeLib.ema(current, previous, shortLookback);
        uint256 resultLong = DynamicFeeLib.ema(current, previous, longLookback);

        // Longer lookback should produce result closer to previous
        if (current > previous) {
            assertTrue(resultLong <= resultShort, "Longer lookback should produce smaller increase");
            assertTrue(resultLong >= previous, "Long lookback result should still be >= previous");
        } else {
            assertTrue(resultLong >= resultShort, "Longer lookback should produce smaller decrease");
            assertTrue(resultLong <= previous, "Long lookback result should still be <= previous");
        }
    }

    /**
     * @notice Fuzz test that EMA is monotonic with respect to current value
     * @dev Increasing current should increase EMA (for fixed previous and lookback)
     * @param previous Previous value
     * @param current1 First current value
     * @param current2 Second current value (higher)
     * @param lookback Lookback period
     */
    function testFuzz_ema_monotonic(uint256 previous, uint256 current1, uint256 current2, uint24 lookback) public pure {
        previous = bound(previous, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ);
        current1 = bound(current1, MIN_RATIO_FUZZ, MAX_RATIO_FUZZ - 1);
        current2 = bound(current2, current1 + 1, MAX_RATIO_FUZZ);
        lookback = uint24(bound(lookback, MIN_LOOKBACK_FUZZ, MAX_LOOKBACK_FUZZ));

        uint256 result1 = DynamicFeeLib.ema(current1, previous, lookback);
        uint256 result2 = DynamicFeeLib.ema(current2, previous, lookback);

        assertTrue(result2 >= result1, "EMA should be monotonic: higher current produces higher or equal result");
    }

    /* ========================================================================== */
    /*                       COMPUTE NEW FEE FUZZ TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that computeNewFee always returns fee within bounds
     * @dev Fee must always be clamped to minFee and maxFee
     * @param currentFee Current fee
     * @param currentRatio Current ratio
     * @param targetRatio Target ratio
     * @param globalMaxAdjRate Global max adjustment rate
     */
    function testFuzz_computeNewFee_alwaysWithinBounds(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate
    ) public view {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee, testParams.maxFee));
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, testParams.maxCurrentRatio);
        targetRatio = bound(targetRatio, MIN_RATIO_FUZZ, testParams.maxCurrentRatio);
        globalMaxAdjRate = bound(globalMaxAdjRate, 1e15, ONE_WAD);

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee,) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        assertTrue(newFee >= testParams.minFee, "New fee should be >= minFee");
        assertTrue(newFee <= testParams.maxFee, "New fee should be <= maxFee");
    }

    /**
     * @notice Fuzz test that computeNewFee with in-band ratio preserves current fee
     * @dev When ratio is within tolerance, fee should not change
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param inBandOffset Small offset within tolerance
     */
    function testFuzz_computeNewFee_inBandPreservesFee(uint24 currentFee, uint256 targetRatio, uint256 inBandOffset)
        public
        view
    {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee, testParams.maxFee));
        targetRatio = bound(targetRatio, ONE_WAD, testParams.maxCurrentRatio / 2);

        // Calculate in-band offset (within tolerance)
        uint256 maxOffset = (targetRatio * testParams.ratioTolerance / ONE_WAD) / 2;
        inBandOffset = bound(inBandOffset, 0, maxOffset);

        uint256 currentRatio = targetRatio + inBandOffset;
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Fee should be clamped but not adjusted
        uint24 expectedFee = DynamicFeeLib.clampFee(currentFee, testParams.minFee, testParams.maxFee);
        assertEq(newFee, expectedFee, "Fee should not change when in band");
        assertEq(newState.consecutiveOobHits, 0, "Streak should reset when in band");
    }

    /**
     * @notice Fuzz test that computeNewFee increases fee for upper OOB
     * @dev When ratio is above tolerance, fee should increase (or stay at max)
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param excessRatio Amount above upper tolerance
     */
    function testFuzz_computeNewFee_upperOOBIncreasesFee(uint24 currentFee, uint256 targetRatio, uint256 excessRatio)
        public
        view
    {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee, testParams.maxFee / 2)); // Leave room for increase
        targetRatio = bound(targetRatio, ONE_WAD, testParams.maxCurrentRatio / 3);
        excessRatio = bound(excessRatio, 1e16, targetRatio / 2);

        // Calculate ratio above upper tolerance
        uint256 delta = (targetRatio * testParams.ratioTolerance / ONE_WAD);
        uint256 currentRatio = targetRatio + delta + excessRatio;

        // Ensure within max current ratio
        if (currentRatio > testParams.maxCurrentRatio) {
            currentRatio = testParams.maxCurrentRatio;
        }

        uint256 globalMaxAdjRate = ONE_WAD;
        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        if (currentFee < testParams.maxFee) {
            assertTrue(newFee >= currentFee, "Fee should increase when upper OOB");
        }
        assertTrue(newState.lastOobWasUpper, "Should record upper side");
        assertTrue(newState.consecutiveOobHits > 0, "Should have positive streak");
    }

    /**
     * @notice Fuzz test that computeNewFee decreases fee for lower OOB
     * @dev When ratio is below tolerance, fee should decrease (or stay at min)
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param deficitRatio Amount below lower tolerance
     */
    function testFuzz_computeNewFee_lowerOOBDecreasesFee(uint24 currentFee, uint256 targetRatio, uint256 deficitRatio)
        public
        view
    {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee * 2, testParams.maxFee)); // Leave room for decrease
        targetRatio = bound(targetRatio, ONE_WAD * 2, testParams.maxCurrentRatio / 2);
        uint256 delta = (targetRatio * testParams.ratioTolerance / ONE_WAD);
        deficitRatio = bound(deficitRatio, 1e15, delta);

        // Calculate ratio below lower tolerance
        uint256 lowerBound = targetRatio - delta;
        uint256 currentRatio = lowerBound > deficitRatio ? lowerBound - deficitRatio : MIN_RATIO_FUZZ;

        uint256 globalMaxAdjRate = ONE_WAD;
        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        if (currentFee > testParams.minFee) {
            assertTrue(newFee <= currentFee, "Fee should decrease when lower OOB");
        }
        assertFalse(newState.lastOobWasUpper, "Should record lower side");
        assertTrue(newState.consecutiveOobHits > 0, "Should have positive streak");
    }

    /**
     * @notice Fuzz test that consecutive OOB hits accumulate properly
     * @dev Streak should increment when staying on same side
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param currentRatio Current ratio (above tolerance)
     * @param initialStreak Initial consecutive hits
     */
    function testFuzz_computeNewFee_streakAccumulation(
        uint24 currentFee,
        uint256 targetRatio,
        uint256 currentRatio,
        uint256 initialStreak
    ) public view {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee, testParams.maxFee / 2));
        targetRatio = bound(targetRatio, ONE_WAD, testParams.maxCurrentRatio / 3);
        initialStreak = bound(initialStreak, 0, 10);

        // Make ratio above tolerance
        uint256 delta = (targetRatio * testParams.ratioTolerance / ONE_WAD);
        currentRatio = bound(currentRatio, targetRatio + delta + 1e16, testParams.maxCurrentRatio);

        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState = DynamicFeeLib.OobState({
            lastOobWasUpper: true,
            // Casting to uint24 is safe because initialStreak is bounded to 0-10
            // forge-lint: disable-next-line(unsafe-typecast)
            consecutiveOobHits: uint24(initialStreak)
        });

        (, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Streak should increment when staying on same side
        assertTrue(newState.consecutiveOobHits > initialStreak, "Streak should increment on same side");
        assertTrue(newState.lastOobWasUpper, "Should remain upper side");
    }

    /**
     * @notice Fuzz test that streak resets when switching sides
     * @dev Changing from upper to lower or vice versa should reset streak
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param wasUpper Whether previous OOB was upper
     * @param initialStreak Initial consecutive hits
     */
    function testFuzz_computeNewFee_streakResetsOnSwitch(
        uint24 currentFee,
        uint256 targetRatio,
        bool wasUpper,
        uint256 initialStreak
    ) public view {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee, testParams.maxFee));
        targetRatio = bound(targetRatio, ONE_WAD * 2, testParams.maxCurrentRatio / 3);
        initialStreak = bound(initialStreak, 1, 10);

        uint256 delta = (targetRatio * testParams.ratioTolerance / ONE_WAD);

        // Set current ratio to opposite side of what initial state indicates
        uint256 currentRatio;
        if (wasUpper) {
            // Was upper, now go lower
            currentRatio = targetRatio - delta - 1e16;
        } else {
            // Was lower, now go upper
            currentRatio = targetRatio + delta + 1e16;
        }

        // Ensure within valid range
        if (currentRatio > testParams.maxCurrentRatio) {
            currentRatio = testParams.maxCurrentRatio;
        }
        if (currentRatio < MIN_RATIO_FUZZ) {
            currentRatio = MIN_RATIO_FUZZ;
        }

        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState = DynamicFeeLib.OobState({
            lastOobWasUpper: wasUpper,
            // Casting to uint24 is safe because initialStreak is bounded to 1-10
            // forge-lint: disable-next-line(unsafe-typecast)
            consecutiveOobHits: uint24(initialStreak)
        });

        (, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Streak should reset to 1 when switching sides
        assertEq(newState.consecutiveOobHits, 1, "Streak should reset to 1 when switching sides");
        assertEq(newState.lastOobWasUpper, !wasUpper, "Side should switch");
    }

    /**
     * @notice Fuzz test that globalMaxAdjRate limits fee changes
     * @dev Fee delta should respect the global adjustment rate limit
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param globalMaxAdjRate Global max adjustment rate (low value)
     */
    function testFuzz_computeNewFee_globalMaxAdjRateLimit(
        uint24 currentFee,
        uint256 targetRatio,
        uint256 globalMaxAdjRate
    ) public view {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee * 10, testParams.maxFee / 2));
        targetRatio = bound(targetRatio, ONE_WAD, testParams.maxCurrentRatio / 10);
        globalMaxAdjRate = bound(globalMaxAdjRate, 1e15, 5e16); // 0.1% to 5%

        // Use very high ratio to trigger large adjustment
        uint256 currentRatio = testParams.maxCurrentRatio;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee,) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Calculate maximum allowed delta from globalMaxAdjRate
        uint256 maxDeltaFromRate = (currentFee * globalMaxAdjRate) / ONE_WAD;

        // The fee change should be limited
        if (newFee > currentFee) {
            uint256 actualDelta = uint256(newFee) - uint256(currentFee);
            // Should be limited by either globalMaxAdjRate or baseMaxFeeDelta (considering streak)
            assertTrue(
                actualDelta <= maxDeltaFromRate + testParams.baseMaxFeeDelta * 2, "Fee increase should respect limits"
            );
        }
    }

    /* ========================================================================== */
    /*                          SIDE FACTOR FUZZ TESTS                          */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that side factors affect adjustment magnitude
     * @dev Different side factors should produce different fee adjustments
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param upperSideFactor Upper side factor
     * @param lowerSideFactor Lower side factor
     */
    function testFuzz_computeNewFee_sideFactorEffect(
        uint24 currentFee,
        uint256 targetRatio,
        uint256 upperSideFactor,
        uint256 lowerSideFactor
    ) public view {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee * 4, testParams.maxFee / 4));
        targetRatio = bound(targetRatio, ONE_WAD, testParams.maxCurrentRatio / 10);
        upperSideFactor = bound(upperSideFactor, HALF_WAD, TWO_WAD * 2);
        lowerSideFactor = bound(lowerSideFactor, HALF_WAD, TWO_WAD * 2);

        // Create custom params with different side factors
        DynamicFeeLib.PoolTypeParams memory customParams = testParams;
        customParams.upperSideFactor = upperSideFactor;
        customParams.lowerSideFactor = lowerSideFactor;

        uint256 delta = (targetRatio * customParams.ratioTolerance / ONE_WAD);
        uint256 upperRatio = targetRatio + delta + 1e17;
        uint256 lowerRatio = targetRatio - delta - 1e16;

        // Ensure within bounds
        if (upperRatio > customParams.maxCurrentRatio) {
            upperRatio = customParams.maxCurrentRatio;
        }
        if (lowerRatio < MIN_RATIO_FUZZ) {
            lowerRatio = MIN_RATIO_FUZZ;
        }

        uint256 globalMaxAdjRate = ONE_WAD;
        DynamicFeeLib.OobState memory initialState;

        // Test upper side
        (uint24 upperFee,) = DynamicFeeLib.computeNewFee(
            currentFee, upperRatio, targetRatio, globalMaxAdjRate, customParams, initialState
        );

        // Test lower side
        (uint24 lowerFee,) = DynamicFeeLib.computeNewFee(
            currentFee, lowerRatio, targetRatio, globalMaxAdjRate, customParams, initialState
        );

        // Upper side should increase fee (unless at max)
        if (currentFee < customParams.maxFee) {
            assertTrue(upperFee >= currentFee, "Upper OOB should increase or maintain fee");
        }

        // Lower side should decrease fee (unless at min)
        if (currentFee > customParams.minFee) {
            assertTrue(lowerFee <= currentFee, "Lower OOB should decrease or maintain fee");
        }
    }

    /* ========================================================================== */
    /*                      EXTREME VALUE FUZZ TESTS                            */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that library handles extreme ratios safely
     * @dev Tests behavior at boundaries of valid ratio range
     * @param currentFee Current fee
     * @param targetRatio Target ratio
     * @param useMinRatio Whether to use minimum or maximum ratio
     */
    function testFuzz_computeNewFee_extremeRatios(uint24 currentFee, uint256 targetRatio, bool useMinRatio)
        public
        view
    {
        // Bound inputs
        currentFee = uint24(bound(currentFee, testParams.minFee, testParams.maxFee));
        targetRatio = bound(targetRatio, ONE_WAD, testParams.maxCurrentRatio / 2);

        uint256 currentRatio = useMinRatio ? MIN_RATIO_FUZZ : testParams.maxCurrentRatio;
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee,) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Should not revert and should be within bounds
        assertTrue(newFee >= testParams.minFee, "Fee should be >= minFee");
        assertTrue(newFee <= testParams.maxFee, "Fee should be <= maxFee");
    }
}
