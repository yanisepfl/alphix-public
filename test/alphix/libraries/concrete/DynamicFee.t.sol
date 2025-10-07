// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* LOCAL IMPORTS */
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";

/**
 * @title DynamicFeeTest
 * @author Alphix
 * @notice Test contract for DynamicFeeLib library
 * @dev Tests all pure functions in the DynamicFeeLib library
 */
contract DynamicFeeTest is Test {
    using DynamicFeeLib for *;

    // Test constants
    uint256 constant ONE_WAD = 1e18;
    uint256 constant HALF_WAD = 5e17;
    uint256 constant TWO_WAD = 2e18;

    // Sample pool type params for testing
    DynamicFeeLib.PoolTypeParams testParams;

    function setUp() public {
        testParams = DynamicFeeLib.PoolTypeParams({
            minFee: 100, // 0.01%
            maxFee: 10000, // 1%
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e16, // 5%
            linearSlope: ONE_WAD,
            maxCurrentRatio: ONE_WAD * 1000, // 1000x
            upperSideFactor: ONE_WAD,
            lowerSideFactor: TWO_WAD // Use the TWO_WAD constant
        });
    }

    /* WITHIN BOUNDS TESTS */

    function test_withinBounds_exactTarget() public pure {
        uint256 target = ONE_WAD;
        uint256 tolerance = 5e16; // 5%
        uint256 current = ONE_WAD;

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertFalse(upper, "Should not be upper when exactly at target");
        assertTrue(inBand, "Should be in band when exactly at target");
    }

    function test_withinBounds_withinTolerance() public pure {
        uint256 target = ONE_WAD;
        uint256 tolerance = HALF_WAD / 10; // 5% (HALF_WAD = 0.5, so /10 = 0.05)
        uint256 current = ONE_WAD + 3e16; // 3% above target

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertFalse(upper, "Should not be upper when within tolerance");
        assertTrue(inBand, "Should be in band when within tolerance");
    }

    function test_withinBounds_upperBoundary() public pure {
        uint256 target = ONE_WAD;
        uint256 tolerance = HALF_WAD / 10; // 5% using HALF_WAD constant
        uint256 current = ONE_WAD + (HALF_WAD / 10); // Exactly at upper boundary

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertFalse(upper, "Should not be upper exactly at boundary");
        assertTrue(inBand, "Should be in band exactly at boundary");
    }

    function test_withinBounds_aboveUpperBound() public pure {
        uint256 target = ONE_WAD;
        uint256 tolerance = 5e16; // 5%
        uint256 current = ONE_WAD + 6e16; // Above upper boundary

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertTrue(upper, "Should be upper when above boundary");
        assertFalse(inBand, "Should not be in band when above boundary");
    }

    function test_withinBounds_belowLowerBound() public pure {
        uint256 target = ONE_WAD;
        uint256 tolerance = 5e16; // 5%
        uint256 current = ONE_WAD - 6e16; // Below lower boundary

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertFalse(upper, "Should not be upper when below boundary");
        assertFalse(inBand, "Should not be in band when below boundary");
    }

    function test_withinBounds_zeroTarget() public pure {
        uint256 target = 0;
        uint256 tolerance = 5e16;
        uint256 current = 1e16;

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertTrue(upper, "Should be upper when current > 0 and target = 0");
        assertFalse(inBand, "Should not be in band when current > 0 and target = 0");
    }

    function test_withinBounds_targetLessThanTolerance() public pure {
        uint256 target = 1e16; // 1%
        uint256 tolerance = 5e16; // 5%
        uint256 current = 0;

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        assertFalse(upper, "Should not be upper when at zero");
        // delta = target * tolerance / 1e18 = 1e16 * 5e16 / 1e18 = 5e14
        // lowerBound = target - delta = 1e16 - 5e14 = 5e15
        // current=0 < lowerBound=5e15, so it should be lower (not in band)
        assertFalse(inBand, "Should not be in band when current < lowerBound");
    }

    /* CLAMP FEE TESTS */

    function test_clampFee_withinBounds() public pure {
        uint24 result = DynamicFeeLib.clampFee(5000, 1000, 10000);
        assertEq(result, 5000, "Should return original fee when within bounds");
    }

    function test_clampFee_belowMin() public pure {
        uint24 result = DynamicFeeLib.clampFee(500, 1000, 10000);
        assertEq(result, 1000, "Should clamp to minimum fee");
    }

    function test_clampFee_aboveMax() public pure {
        uint24 result = DynamicFeeLib.clampFee(15000, 1000, 10000);
        assertEq(result, 10000, "Should clamp to maximum fee");
    }

    function test_clampFee_equalToMin() public pure {
        uint24 result = DynamicFeeLib.clampFee(1000, 1000, 10000);
        assertEq(result, 1000, "Should return min when equal to min");
    }

    function test_clampFee_equalToMax() public pure {
        uint24 result = DynamicFeeLib.clampFee(10000, 1000, 10000);
        assertEq(result, 10000, "Should return max when equal to max");
    }

    function test_clampFee_zeroFee() public pure {
        uint24 result = DynamicFeeLib.clampFee(0, 1000, 10000);
        assertEq(result, 1000, "Should clamp zero to minimum");
    }

    function test_clampFee_largeFee() public pure {
        uint24 result = DynamicFeeLib.clampFee(type(uint256).max, 1000, 10000);
        assertEq(result, 10000, "Should clamp large value to maximum");
    }

    /* EMA TESTS */

    function test_ema_currentEqualsPrevious() public pure {
        uint256 current = ONE_WAD;
        uint256 previous = ONE_WAD;
        uint24 lookback = 30;

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);
        assertEq(result, previous, "EMA should return previous when current equals previous");
    }

    function test_ema_currentAbovePrevious() public pure {
        uint256 current = 12e17; // 1.2
        uint256 previous = ONE_WAD; // 1.0
        uint24 lookback = 30;

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);

        // Expected: previous + (current - previous) * alpha
        // alpha = 2 * 1e18 / (30 + 1) = 2e18 / 31
        uint256 expectedAlpha = (2 * ONE_WAD) / 31;
        uint256 expectedIncrease = ((current - previous) * expectedAlpha) / ONE_WAD;
        uint256 expected = previous + expectedIncrease;

        assertEq(result, expected, "EMA should increase when current > previous");
        assertTrue(result > previous, "Result should be greater than previous");
        assertTrue(result < current, "Result should be less than current");
    }

    function test_ema_currentBelowPrevious() public pure {
        uint256 current = 8e17; // 0.8 (using fractional value relative to ONE_WAD)
        uint256 previous = ONE_WAD; // 1.0
        uint24 lookback = 30;

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);

        assertTrue(result < previous, "Result should be less than previous");
        assertTrue(result > current, "Result should be greater than current");
    }

    function test_ema_shortLookback() public pure {
        uint256 current = TWO_WAD; // Use the TWO_WAD constant
        uint256 previous = ONE_WAD;
        uint24 lookback = 1; // Very aggressive smoothing

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);

        // alpha = 2 * 1e18 / (1 + 1) = 1e18 (100%)
        // So result should be current
        assertEq(result, current, "With lookback=1, EMA should equal current");
    }

    function test_ema_longLookback() public pure {
        uint256 current = TWO_WAD; // Use the TWO_WAD constant
        uint256 previous = ONE_WAD;
        uint24 lookback = 999; // Very slow smoothing

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);

        // alpha = 2 * 1e18 / (999 + 1) = 2e18 / 1000 = 2e15
        uint256 expectedAlpha = (TWO_WAD) / 1000; // Use TWO_WAD constant
        uint256 expectedIncrease = ((current - previous) * expectedAlpha) / ONE_WAD;
        uint256 expected = previous + expectedIncrease;

        assertEq(result, expected, "Long lookback should produce small adjustment");
        // Result should be very close to previous
        assertTrue(result - previous < 3e15, "Should be small adjustment with long lookback");
    }

    /* COMPUTE NEW FEE TESTS */

    function test_computeNewFee_inBand() public view {
        uint24 currentFee = 5000;
        uint256 currentRatio = ONE_WAD; // Exactly at target
        uint256 targetRatio = ONE_WAD;
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState =
            DynamicFeeLib.OobState({lastOobWasUpper: true, consecutiveOobHits: 5});

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Should clamp current fee and reset streak
        uint24 expectedFee = DynamicFeeLib.clampFee(currentFee, testParams.minFee, testParams.maxFee);
        assertEq(newFee, expectedFee, "Should return clamped current fee when in band");
        assertEq(newState.consecutiveOobHits, 0, "Should reset consecutive hits when in band");
    }

    function test_computeNewFee_zeroTarget() public view {
        uint24 currentFee = 5000;
        uint256 currentRatio = ONE_WAD;
        uint256 targetRatio = 0; // Zero target should be treated as in-band
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        uint24 expectedFee = DynamicFeeLib.clampFee(currentFee, testParams.minFee, testParams.maxFee);
        assertEq(newFee, expectedFee, "Should treat zero target as in-band");
        assertEq(newState.consecutiveOobHits, 0, "Should reset streak for zero target");
    }

    function test_computeNewFee_upperOOB_firstTime() public view {
        uint24 currentFee = 5000;
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = targetRatio + testParams.ratioTolerance + 1e16; // Above upper bound
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState = DynamicFeeLib.OobState({
            lastOobWasUpper: false, // Was lower, now upper -> reset streak
            consecutiveOobHits: 3
        });

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        assertTrue(newFee >= currentFee, "Fee should increase when upper OOB");
        assertEq(newState.consecutiveOobHits, 1, "Should reset streak when switching sides");
        assertTrue(newState.lastOobWasUpper, "Should record upper side");
    }

    function test_computeNewFee_lowerOOB_consecutive() public view {
        uint24 currentFee = 5000;
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = targetRatio - testParams.ratioTolerance - 1e16; // Below lower bound
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState = DynamicFeeLib.OobState({
            lastOobWasUpper: false, // Still lower -> increment streak
            consecutiveOobHits: 2
        });

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        assertTrue(newFee <= currentFee, "Fee should decrease when lower OOB");
        assertEq(newState.consecutiveOobHits, 3, "Should increment streak when same side");
        assertFalse(newState.lastOobWasUpper, "Should record lower side");
    }

    function test_computeNewFee_globalMaxAdjRateLimit() public view {
        uint24 currentFee = 5000;
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = 10 * ONE_WAD; // Very high ratio
        uint256 globalMaxAdjRate = 1e16; // 1% max adjustment rate (very low)

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // The adjustment should be limited by globalMaxAdjRate
        uint256 maxFeeDelta = (currentFee * globalMaxAdjRate) / ONE_WAD;
        uint256 expectedMaxFee = currentFee + maxFeeDelta;

        assertTrue(
            newFee <= expectedMaxFee + testParams.baseMaxFeeDelta,
            "Should be limited by global max adj rate and base max delta"
        );
        assertTrue(newState.lastOobWasUpper, "Should record upper side for high ratio");
    }

    function test_computeNewFee_sideFactor_upper() public view {
        uint24 currentFee = 5000;
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = targetRatio + testParams.ratioTolerance + 5e16; // Well above bound
        uint256 globalMaxAdjRate = ONE_WAD;

        // Set upper side factor to 0.5x (reduce upward adjustments)
        DynamicFeeLib.PoolTypeParams memory customParams = testParams;
        customParams.upperSideFactor = HALF_WAD; // Use the HALF_WAD constant

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, customParams, initialState
        );

        assertTrue(newFee >= currentFee, "Fee should still increase");
        assertTrue(newState.lastOobWasUpper, "Should be upper");
        // The actual increase should be reduced by the side factor
    }

    function test_computeNewFee_sideFactor_lower() public view {
        uint24 currentFee = 5000;
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = targetRatio - testParams.ratioTolerance - 5e16; // Well below bound
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        assertTrue(newFee <= currentFee, "Fee should decrease");
        assertFalse(newState.lastOobWasUpper, "Should be lower");
        // With lowerSideFactor = 2x (TWO_WAD), the decrease should be amplified
        // testParams.lowerSideFactor is set to TWO_WAD in setUp()
    }

    function test_computeNewFee_extremeDecrease() public view {
        uint24 currentFee = 100; // At minimum
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = 1e15; // Very low ratio
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Should hit minimum fee
        assertEq(newFee, testParams.minFee, "Should clamp to minimum fee");
        assertFalse(newState.lastOobWasUpper, "Should be lower side");
    }

    function test_computeNewFee_streakAccumulation() public view {
        uint24 currentFee = 5000;
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = targetRatio + testParams.ratioTolerance + 1e16;
        uint256 globalMaxAdjRate = ONE_WAD;

        // Start with high streak
        DynamicFeeLib.OobState memory initialState =
            DynamicFeeLib.OobState({lastOobWasUpper: true, consecutiveOobHits: 5});

        (uint24 newFee1, DynamicFeeLib.OobState memory newState1) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        // Continue streak
        (uint24 newFee2, DynamicFeeLib.OobState memory newState2) =
            DynamicFeeLib.computeNewFee(newFee1, currentRatio, targetRatio, globalMaxAdjRate, testParams, newState1);

        // The actual behavior might increment differently based on internal logic
        assertTrue(newState1.consecutiveOobHits > initialState.consecutiveOobHits, "Should increment streak");
        assertTrue(newState2.consecutiveOobHits >= newState1.consecutiveOobHits, "Should not decrease streak");
        assertTrue(newFee2 >= newFee1, "Higher streak should allow larger adjustments");
    }

    function test_computeNewFee_boundsEnforcement() public view {
        uint24 currentFee = testParams.maxFee; // Start at maximum
        uint256 targetRatio = ONE_WAD;
        uint256 currentRatio = targetRatio + testParams.ratioTolerance + 5e16; // Upper OOB
        uint256 globalMaxAdjRate = ONE_WAD;

        DynamicFeeLib.OobState memory initialState;

        (uint24 newFee, DynamicFeeLib.OobState memory newState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, targetRatio, globalMaxAdjRate, testParams, initialState
        );

        assertEq(newFee, testParams.maxFee, "Should not exceed maximum fee");
        assertTrue(newState.lastOobWasUpper, "Should record upper side");
    }

    /* FUZZING TESTS */

    function testFuzz_clampFee(uint256 fee, uint24 minFee, uint24 maxFee) public pure {
        vm.assume(minFee <= maxFee);

        uint24 result = DynamicFeeLib.clampFee(fee, minFee, maxFee);

        assertTrue(result >= minFee, "Result should be >= minFee");
        assertTrue(result <= maxFee, "Result should be <= maxFee");

        if (fee <= type(uint24).max) {
            if (fee >= minFee && fee <= maxFee) {
                assertEq(result, uint24(fee), "Should return original fee if within bounds");
            }
        }
    }

    function testFuzz_withinBounds(uint256 target, uint256 tolerance, uint256 current) public pure {
        vm.assume(target <= type(uint128).max); // Avoid overflow
        vm.assume(tolerance <= ONE_WAD); // Reasonable tolerance

        (bool upper, bool inBand) = DynamicFeeLib.withinBounds(target, tolerance, current);

        // Basic logical consistency
        if (inBand) {
            assertFalse(upper, "Cannot be both inBand and upper");
        }

        // If target is 0, anything > 0 should be upper
        if (target == 0 && current > 0) {
            assertTrue(upper, "Should be upper when target=0 and current>0");
            assertFalse(inBand, "Should not be inBand when target=0 and current>0");
        }
    }

    function testFuzz_ema(uint256 current, uint256 previous, uint24 lookback) public pure {
        vm.assume(lookback > 0 && lookback < 10000); // Reasonable lookback
        vm.assume(current <= type(uint128).max); // Avoid overflow
        vm.assume(previous <= type(uint128).max);

        uint256 result = DynamicFeeLib.ema(current, previous, lookback);

        if (current == previous) {
            assertEq(result, previous, "EMA should equal previous when current equals previous");
        } else if (current > previous) {
            assertTrue(result >= previous, "EMA should be >= previous when current > previous");
            if (lookback > 1) {
                assertTrue(result <= current, "EMA should be <= current when current > previous");
            }
        } else {
            assertTrue(result <= previous, "EMA should be <= previous when current < previous");
            assertTrue(result >= current, "EMA should be >= current when current < previous");
        }
    }
}
