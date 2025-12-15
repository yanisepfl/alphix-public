// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";

/**
 * @title AlphixPokeFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the poke function and fee adjustment behavior
 * @dev Comprehensive fuzz testing of ratio-based fee adjustments, cooldown logic,
 *      and boundary conditions for the dynamic fee algorithm
 */
contract AlphixPokeFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* FUZZING CONSTRAINTS */

    // Ratio bounds
    uint256 constant MIN_RATIO_FUZZ = 1e15; // 0.1%
    uint256 constant MAX_RATIO_FUZZ = AlphixGlobalConstants.MAX_CURRENT_RATIO;

    // Fee bounds
    uint24 constant MIN_FEE_FUZZ = AlphixGlobalConstants.MIN_FEE;
    uint24 constant MAX_FEE_FUZZ = LPFeeLibrary.MAX_LP_FEE;

    // Time bounds for cooldown testing
    uint256 constant MIN_TIME_ADVANCE_FUZZ = 1 seconds;
    uint256 constant MAX_TIME_ADVANCE_FUZZ = 365 days;

    // Ratio tolerance for testing in-band vs out-of-band behavior
    uint256 constant MIN_RATIO_TOLERANCE_FUZZ = AlphixGlobalConstants.MIN_RATIO_TOLERANCE;
    uint256 constant MAX_RATIO_TOLERANCE_FUZZ = AlphixGlobalConstants.TEN_WAD;

    /**
     * @notice Sets up the fuzz test environment
     * @dev Initializes a configured pool ready for poke testing
     */
    function setUp() public override {
        super.setUp();

        // Check if key is already configured, if so use it, otherwise initialize it
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        if (!cfg.isConfigured) {
            // Initialize the main test pool for poke testing
            vm.prank(owner);
            hook.initializePool(key, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
        }

        // Wait past initial cooldown
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params.minPeriod + 1);
    }

    /* ========================================================================== */
    /*                         RATIO VALIDATION TESTS                           */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that poke accepts valid ratio values
     * @dev Tests poke across the full range of valid ratios
     * @param currentRatio The current pool ratio to test
     */
    function testFuzz_poke_success_validRatio(uint256 currentRatio) public {
        // Get pool configuration and params
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(cfg.poolType);

        // Bound to valid range for the pool type
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio);

        // Get fee before poke
        (,,, uint24 feeBefore) = poolManager.getSlot0(poolId);

        // Poke with the ratio
        vm.prank(owner);
        hook.poke(key, currentRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

        // Verify fee is within bounds
        assertTrue(feeAfter >= params.minFee, "Fee should be >= minFee");
        assertTrue(feeAfter <= params.maxFee, "Fee should be <= maxFee");

        // Calculate tolerance bounds
        uint256 targetRatio = cfg.initialTargetRatio;
        uint256 upperBound = targetRatio + (targetRatio * params.ratioTolerance / 1e18);
        uint256 lowerBound = targetRatio - (targetRatio * params.ratioTolerance / 1e18);

        // Compare fee changes based on ratio position
        if (currentRatio > upperBound) {
            // Ratio above tolerance: fee should increase or stay at max
            if (feeBefore < params.maxFee) {
                assertTrue(feeAfter >= feeBefore, "Fee should increase when ratio above tolerance");
            }
        } else if (currentRatio < lowerBound) {
            // Ratio below tolerance: fee should decrease or stay at min
            if (feeBefore > params.minFee) {
                assertTrue(feeAfter <= feeBefore, "Fee should decrease when ratio below tolerance");
            }
        } else {
            // Ratio within tolerance: fee should remain unchanged
            assertEq(feeAfter, feeBefore, "Fee should not change when ratio within tolerance");
        }
    }

    /**
     * @notice Fuzz test that poke reverts on zero ratio
     * @dev Zero ratio should always be invalid
     */
    function testFuzz_poke_reverts_zeroRatio() public {
        // Get the actual pool type for the key
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        IAlphixLogic.PoolType actualPoolType = cfg.poolType;

        // Poke with zero ratio should revert
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, actualPoolType, 0));
        hook.poke(key, 0);
    }

    /**
     * @notice Fuzz test that poke reverts on excessive ratios
     * @dev Tests ratios above maxCurrentRatio for the pool type
     * @param excessiveRatio Ratio value above the maximum allowed
     */
    function testFuzz_poke_reverts_excessiveRatio(uint256 excessiveRatio) public {
        // Get the actual pool type for the key
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        IAlphixLogic.PoolType actualPoolType = cfg.poolType;

        // Get pool type params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(actualPoolType);

        // Bound to values above the maximum
        excessiveRatio = bound(excessiveRatio, params.maxCurrentRatio + 1, type(uint256).max / 2);

        // Should revert with InvalidRatioForPoolType
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, actualPoolType, excessiveRatio)
        );
        hook.poke(key, excessiveRatio);
    }

    /* ========================================================================== */
    /*                         COOLDOWN MECHANISM TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that poke succeeds when cooldown has elapsed
     * @dev Tests various time advances after cooldown period
     * @param timeAdvance Time to advance after cooldown
     * @param newRatio New ratio to poke with
     */
    function testFuzz_poke_success_afterCooldownElapsed(uint256 timeAdvance, uint256 newRatio) public {
        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Bound inputs
        timeAdvance = bound(timeAdvance, params.minPeriod + 1, MAX_TIME_ADVANCE_FUZZ);
        newRatio = bound(newRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio);

        // Do a first poke
        vm.prank(owner);
        hook.poke(key, INITIAL_TARGET_RATIO);

        // Advance time past cooldown
        vm.warp(block.timestamp + timeAdvance);

        // Second poke should succeed
        vm.prank(owner);
        hook.poke(key, newRatio);

        // Verify the poke succeeded by checking fee was updated
        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);
        assertTrue(feeAfter >= params.minFee && feeAfter <= params.maxFee, "Fee should be within bounds");
    }

    /**
     * @notice Fuzz test that poke reverts when cooldown has not elapsed
     * @dev Tests various time advances within the cooldown period
     * @param timeAdvance Time to advance (less than cooldown)
     */
    function testFuzz_poke_reverts_duringCooldown(uint256 timeAdvance) public {
        // Get the actual pool type for the key
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        IAlphixLogic.PoolType actualPoolType = cfg.poolType;

        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(actualPoolType);

        // Use target ratio to avoid ratio validation errors
        uint256 newRatio = cfg.initialTargetRatio;

        // Do a first poke
        vm.prank(owner);
        hook.poke(key, newRatio);

        // Bound time advance to be within cooldown period (but non-zero)
        if (params.minPeriod > 1) {
            timeAdvance = bound(timeAdvance, 1, params.minPeriod - 1);

            // Advance time but stay within cooldown
            vm.warp(block.timestamp + timeAdvance);

            // Second poke should revert with CooldownNotElapsed or any revert
            // (using expectRevert() without selector since ratio validation might happen first)
            vm.prank(owner);
            vm.expectRevert();
            hook.poke(key, newRatio);
        }
    }

    /* ========================================================================== */
    /*                      FEE ADJUSTMENT BEHAVIOR TESTS                       */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that fee increases when ratio is above tolerance
     * @dev Tests out-of-band upper behavior with various ratio deviations
     * @param ratioDeviation How far above tolerance to test
     * @param initialFee Starting fee for the test
     */
    function testFuzz_poke_increaseFee_ratioAboveTolerance(uint256 ratioDeviation, uint24 initialFee) public {
        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Bound initial fee to valid range
        initialFee = uint24(bound(initialFee, params.minFee, params.maxFee / 2)); // Use half max to allow room for increase

        // Bound ratio deviation
        ratioDeviation = bound(ratioDeviation, 1e15, 5e17); // 0.1% to 50% above tolerance

        // Create a fresh pool with the initial fee
        (PoolKey memory freshKey, PoolId freshPoolId) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            initialFee,
            INITIAL_TARGET_RATIO,
            18,
            18,
            _safeAddToTickSpacing(defaultTickSpacing, 20), // Unique tick spacing
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Wait past cooldown
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Calculate ratio above tolerance
        uint256 upperBound = INITIAL_TARGET_RATIO + (INITIAL_TARGET_RATIO * params.ratioTolerance / 1e18);
        uint256 aboveToleranceRatio = upperBound + ratioDeviation;

        // Ensure ratio is within max allowed
        if (aboveToleranceRatio > params.maxCurrentRatio) {
            aboveToleranceRatio = params.maxCurrentRatio;
        }

        // Poke with ratio above tolerance
        vm.prank(owner);
        hook.poke(freshKey, aboveToleranceRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(freshPoolId);

        // Fee should have increased or stayed at max
        if (initialFee < params.maxFee) {
            assertTrue(feeAfter >= initialFee, "Fee should increase or stay same when ratio above tolerance");
        }
        assertTrue(feeAfter <= params.maxFee, "Fee should not exceed maxFee");
    }

    /**
     * @notice Fuzz test that fee decreases when ratio is below tolerance
     * @dev Tests out-of-band lower behavior with various ratio deviations
     * @param ratioDeviation How far below tolerance to test
     * @param initialFee Starting fee for the test
     */
    function testFuzz_poke_decreaseFee_ratioBelowTolerance(uint256 ratioDeviation, uint24 initialFee) public {
        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Bound initial fee to valid range (use upper half to allow room for decrease)
        initialFee = uint24(bound(initialFee, params.minFee + (params.maxFee - params.minFee) / 2, params.maxFee));

        // Bound ratio deviation
        ratioDeviation = bound(ratioDeviation, 1e15, INITIAL_TARGET_RATIO / 2); // Don't go too low

        // Create a fresh pool with the initial fee
        (PoolKey memory freshKey, PoolId freshPoolId) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            initialFee,
            INITIAL_TARGET_RATIO,
            18,
            18,
            _safeAddToTickSpacing(defaultTickSpacing, 40), // Unique tick spacing
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Wait past cooldown
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Calculate ratio below tolerance
        uint256 lowerBound = INITIAL_TARGET_RATIO - (INITIAL_TARGET_RATIO * params.ratioTolerance / 1e18);
        uint256 belowToleranceRatio;

        if (lowerBound > ratioDeviation) {
            belowToleranceRatio = lowerBound - ratioDeviation;
        } else {
            belowToleranceRatio = lowerBound / 2;
        }

        // Ensure ratio is above minimum
        if (belowToleranceRatio < MIN_RATIO_FUZZ) {
            belowToleranceRatio = MIN_RATIO_FUZZ;
        }

        // Poke with ratio below tolerance
        vm.prank(owner);
        hook.poke(freshKey, belowToleranceRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(freshPoolId);

        // Fee should have decreased or stayed at min
        if (initialFee > params.minFee) {
            assertTrue(feeAfter <= initialFee, "Fee should decrease or stay same when ratio below tolerance");
        }
        assertTrue(feeAfter >= params.minFee, "Fee should not go below minFee");
    }

    /**
     * @notice Fuzz test that fee remains unchanged when ratio is within tolerance
     * @dev Tests in-band behavior where no fee adjustment should occur
     * @param inBandOffset Small offset within the tolerance band
     * @param initialFee Starting fee for the test
     */
    function testFuzz_poke_noChange_ratioWithinTolerance(uint256 inBandOffset, uint24 initialFee) public {
        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Bound initial fee to valid range
        initialFee = uint24(bound(initialFee, params.minFee, params.maxFee));

        // Bound in-band offset to stay well within tolerance
        uint256 maxOffset = (INITIAL_TARGET_RATIO * params.ratioTolerance / 1e18) / 3;
        inBandOffset = bound(inBandOffset, 0, maxOffset);

        // Create a fresh pool with the initial fee
        (PoolKey memory freshKey, PoolId freshPoolId) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            initialFee,
            INITIAL_TARGET_RATIO,
            18,
            18,
            _safeAddToTickSpacing(defaultTickSpacing, 60), // Unique tick spacing
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Wait past cooldown
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Calculate ratio within tolerance (test both above and below target)
        uint256 inBandRatio;
        if (inBandOffset % 2 == 0) {
            // Test above target but within tolerance
            inBandRatio = INITIAL_TARGET_RATIO + inBandOffset;
        } else {
            // Test below target but within tolerance
            if (INITIAL_TARGET_RATIO > inBandOffset) {
                inBandRatio = INITIAL_TARGET_RATIO - inBandOffset;
            } else {
                inBandRatio = INITIAL_TARGET_RATIO;
            }
        }

        // Poke with in-band ratio
        vm.prank(owner);
        hook.poke(freshKey, inBandRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(freshPoolId);

        // Fee should remain unchanged for in-band ratios
        assertEq(feeAfter, initialFee, "Fee should not change when ratio is within tolerance");
    }

    /* ========================================================================== */
    /*                      MULTIPLE POKE SEQUENCE TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that multiple pokes converge fee toward appropriate level
     * @dev Tests that repeated pokes with same ratio produce consistent behavior
     * @param targetRatio The ratio to repeatedly poke with
     * @param numPokes Number of pokes to perform (2-5)
     */
    function testFuzz_poke_multiplePokes_convergeBehavior(uint256 targetRatio, uint8 numPokes) public {
        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Bound inputs
        targetRatio = bound(targetRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio);
        numPokes = uint8(bound(numPokes, 2, 5));

        // Create a fresh pool
        (PoolKey memory freshKey, PoolId freshPoolId) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            _safeAddToTickSpacing(defaultTickSpacing, 80), // Unique tick spacing
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Wait past initial cooldown
        vm.warp(block.timestamp + params.minPeriod + 1);

        uint24 previousFee = INITIAL_FEE;

        // Perform multiple pokes with same ratio
        for (uint256 i = 0; i < numPokes; i++) {
            vm.prank(owner);
            hook.poke(freshKey, targetRatio);

            (,,, uint24 currentFee) = poolManager.getSlot0(freshPoolId);

            // Fee should always be within bounds
            assertTrue(currentFee >= params.minFee, "Fee should be >= minFee");
            assertTrue(currentFee <= params.maxFee, "Fee should be <= maxFee");

            // If not at a bound, fee changes should be monotonic in the expected direction
            if (targetRatio > INITIAL_TARGET_RATIO && currentFee < params.maxFee) {
                // For high ratios, fee should increase or stay same
                assertTrue(currentFee >= previousFee || currentFee == params.maxFee, "Fee should trend upward");
            } else if (targetRatio < INITIAL_TARGET_RATIO && currentFee > params.minFee) {
                // For low ratios, fee should decrease or stay same
                assertTrue(currentFee <= previousFee || currentFee == params.minFee, "Fee should trend downward");
            }

            previousFee = currentFee;

            // Advance time for next poke
            if (i < numPokes - 1) {
                vm.warp(block.timestamp + params.minPeriod + 1);
            }
        }
    }

    /* ========================================================================== */
    /*                    CROSS-POOL TYPE BEHAVIOR TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that poke behaves correctly across different pool types
     * @dev Tests that STABLE, STANDARD, and VOLATILE pools respond appropriately to same ratio
     * @param poolTypeIndex Index to select pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     * @param testRatio Ratio to test across all pool types
     */
    function testFuzz_poke_success_acrossPoolTypes(uint8 poolTypeIndex, uint256 testRatio) public {
        // Bound pool type index
        poolTypeIndex = uint8(bound(poolTypeIndex, 0, 2));

        // Map to pool type
        IAlphixLogic.PoolType poolType;
        if (poolTypeIndex == 0) poolType = IAlphixLogic.PoolType.STABLE;
        else if (poolTypeIndex == 1) poolType = IAlphixLogic.PoolType.STANDARD;
        else poolType = IAlphixLogic.PoolType.VOLATILE;

        // Get pool type params and bound ratio
        DynamicFeeLib.PoolTypeParams memory poolParams = logic.getPoolTypeParams(poolType);
        testRatio = bound(testRatio, MIN_RATIO_FUZZ, poolParams.maxCurrentRatio);

        // Get valid initial fee for pool type
        uint24 validFee = uint24(bound(INITIAL_FEE, poolParams.minFee, poolParams.maxFee));

        // Create pool with specific type
        (PoolKey memory freshKey, PoolId freshPoolId) = _initPoolWithHook(
            poolType,
            validFee,
            INITIAL_TARGET_RATIO,
            18,
            18,
            _safeAddToTickSpacing(defaultTickSpacing, int24(100) + int24(uint24(poolTypeIndex)) * int24(20)), // Unique tick spacing per pool type
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Wait past cooldown
        vm.warp(block.timestamp + poolParams.minPeriod + 1);

        // Poke with test ratio
        vm.prank(owner);
        hook.poke(freshKey, testRatio);

        // Verify fee is within pool type bounds
        (,,, uint24 feeAfter) = poolManager.getSlot0(freshPoolId);
        assertTrue(feeAfter >= poolParams.minFee, "Fee should be >= pool type minFee");
        assertTrue(feeAfter <= poolParams.maxFee, "Fee should be <= pool type maxFee");
    }

    /* ========================================================================== */
    /*                         EXTREME VALUE TESTS                              */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that poke handles extreme ratio values safely
     * @dev Tests behavior at the edges of valid ratio ranges
     * @param useMinimum Whether to test minimum (true) or maximum (false) ratio
     */
    function testFuzz_poke_extremeRatios_safeHandling(bool useMinimum) public {
        // Get pool params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Use either minimum or maximum valid ratio
        uint256 extremeRatio = useMinimum ? MIN_RATIO_FUZZ : params.maxCurrentRatio;

        // Poke with extreme ratio
        vm.prank(owner);
        hook.poke(key, extremeRatio);

        // Get fee after poke
        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

        // Fee should be within bounds even with extreme ratios
        assertTrue(feeAfter >= params.minFee, "Fee should be >= minFee");
        assertTrue(feeAfter <= params.maxFee, "Fee should be <= maxFee");

        // Verify we can poke again after cooldown
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, INITIAL_TARGET_RATIO);

        (,,, uint24 feeAfterSecond) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterSecond >= params.minFee && feeAfterSecond <= params.maxFee, "Second poke should also work");
    }

    /* ========================================================================== */
    /*                    COMPUTE FEE UPDATE TESTS (DRY RUN)                   */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that computeFeeUpdate returns consistent results with poke
     * @dev Verifies that the view function produces the same fee computations as poke
     * @param currentRatio The ratio to test
     */
    function testFuzz_computeFeeUpdate_matchesPoke(uint256 currentRatio) public {
        // Get pool configuration and params
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(cfg.poolType);

        // Bound to valid range for the pool type
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio);

        // Call computeFeeUpdate (view function)
        (
            uint24 computedNewFee,
            uint24 computedOldFee,
            uint256 computedOldTargetRatio,
            uint256 computedNewTargetRatio,
        ) = logic.computeFeeUpdate(key, currentRatio);

        // Now execute the actual poke
        vm.prank(owner);
        hook.poke(key, currentRatio);

        // Get actual new fee from pool
        (,,, uint24 actualNewFee) = poolManager.getSlot0(poolId);

        // Verify computeFeeUpdate predicted correctly
        assertEq(computedNewFee, actualNewFee, "computeFeeUpdate newFee should match poke result");
        assertEq(computedOldFee, INITIAL_FEE, "computeFeeUpdate oldFee should match initial fee");

        // Verify target ratio was computed
        assertTrue(computedOldTargetRatio > 0, "Old target ratio should be non-zero");
        assertTrue(computedNewTargetRatio > 0, "New target ratio should be non-zero");
    }

    /**
     * @notice Fuzz test that computeFeeUpdate does not modify state
     * @dev Verifies that calling computeFeeUpdate multiple times has no side effects
     * @param currentRatio The ratio to test
     * @param numCalls Number of times to call computeFeeUpdate (2-10)
     */
    function testFuzz_computeFeeUpdate_noStateChange(uint256 currentRatio, uint8 numCalls) public view {
        // Get pool configuration and params
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(cfg.poolType);

        // Bound inputs
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio);
        numCalls = uint8(bound(numCalls, 2, 10));

        // Get initial state
        (,,, uint24 initialFee) = poolManager.getSlot0(poolId);

        // Call computeFeeUpdate multiple times
        for (uint256 i = 0; i < numCalls; i++) {
            (uint24 newFee, uint24 oldFee, uint256 oldTargetRatio,,) = logic.computeFeeUpdate(key, currentRatio);

            // All calls should return the same values (since no state changed)
            if (i == 0) {
                // First call establishes baseline
                assertTrue(newFee >= params.minFee && newFee <= params.maxFee, "Fee should be in bounds");
            }

            // oldFee should always match current pool fee (unchanged)
            assertEq(oldFee, initialFee, "oldFee should remain constant across calls");

            // oldTargetRatio should remain constant (no state change)
            assertEq(oldTargetRatio, cfg.initialTargetRatio, "oldTargetRatio should match initial");
        }

        // Verify pool fee hasn't changed
        (,,, uint24 finalFee) = poolManager.getSlot0(poolId);
        assertEq(finalFee, initialFee, "Pool fee should not change from computeFeeUpdate calls");
    }

    /**
     * @notice Fuzz test that computeFeeUpdate can be called during cooldown
     * @dev Unlike poke, computeFeeUpdate should not enforce cooldown
     * @param currentRatio The ratio to test
     */
    function testFuzz_computeFeeUpdate_succeedsDuringCooldown(uint256 currentRatio) public {
        // Get pool configuration and params
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(cfg.poolType);

        // Bound to valid range
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio);

        // Execute a poke first
        vm.prank(owner);
        hook.poke(key, currentRatio);

        // DON'T advance time - we're still in cooldown

        // computeFeeUpdate should still work (no cooldown check)
        (uint24 newFee, uint24 oldFee, uint256 oldTargetRatio, uint256 newTargetRatio,) =
            logic.computeFeeUpdate(key, currentRatio);

        // Verify it returned valid results
        assertTrue(newFee >= params.minFee && newFee <= params.maxFee, "Fee should be in bounds");
        assertTrue(oldFee >= params.minFee && oldFee <= params.maxFee, "Old fee should be in bounds");
        assertTrue(oldTargetRatio > 0, "Old target ratio should be non-zero");
        assertTrue(newTargetRatio > 0, "New target ratio should be non-zero");

        // But poke should still revert during cooldown
        vm.prank(owner);
        vm.expectRevert();
        hook.poke(key, currentRatio);
    }

    /**
     * @notice Fuzz test that computeFeeUpdate validates ratio bounds
     * @dev Should revert on invalid ratios just like poke does
     * @param invalidRatio A ratio outside valid bounds
     */
    function testFuzz_computeFeeUpdate_revertsOnInvalidRatio(uint256 invalidRatio) public {
        // Get pool configuration
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(poolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(cfg.poolType);

        // Test with ratio above max
        invalidRatio = bound(invalidRatio, params.maxCurrentRatio + 1, type(uint256).max / 2);

        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, cfg.poolType, invalidRatio)
        );
        logic.computeFeeUpdate(key, invalidRatio);

        // Test with zero ratio
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, cfg.poolType, 0));
        logic.computeFeeUpdate(key, 0);
    }

    /**
     * @notice Fuzz test computeFeeUpdate across pool types
     * @dev Verifies computeFeeUpdate works correctly for all pool types
     * @param poolTypeIndex Index to select pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     * @param testRatio Ratio to test
     */
    function testFuzz_computeFeeUpdate_acrossPoolTypes(uint8 poolTypeIndex, uint256 testRatio) public {
        // Bound pool type index
        poolTypeIndex = uint8(bound(poolTypeIndex, 0, 2));

        // Map to pool type
        IAlphixLogic.PoolType poolType;
        if (poolTypeIndex == 0) poolType = IAlphixLogic.PoolType.STABLE;
        else if (poolTypeIndex == 1) poolType = IAlphixLogic.PoolType.STANDARD;
        else poolType = IAlphixLogic.PoolType.VOLATILE;

        // Get pool type params and bound ratio
        DynamicFeeLib.PoolTypeParams memory poolParams = logic.getPoolTypeParams(poolType);
        testRatio = bound(testRatio, MIN_RATIO_FUZZ, poolParams.maxCurrentRatio);

        // Get valid initial fee for pool type
        uint24 validFee = uint24(bound(INITIAL_FEE, poolParams.minFee, poolParams.maxFee));

        // Create pool with specific type
        (PoolKey memory freshKey, PoolId freshPoolId) = _initPoolWithHook(
            poolType,
            validFee,
            INITIAL_TARGET_RATIO,
            18,
            18,
            _safeAddToTickSpacing(defaultTickSpacing, int24(200) + int24(uint24(poolTypeIndex)) * int24(20)),
            Constants.SQRT_PRICE_1_1,
            hook
        );

        // Wait past cooldown for poke comparison
        vm.warp(block.timestamp + poolParams.minPeriod + 1);

        // Call computeFeeUpdate
        (uint24 computedNewFee, uint24 computedOldFee,,,) = logic.computeFeeUpdate(freshKey, testRatio);

        // Execute actual poke
        vm.prank(owner);
        hook.poke(freshKey, testRatio);

        // Get actual fee
        (,,, uint24 actualNewFee) = poolManager.getSlot0(freshPoolId);

        // Verify match
        assertEq(computedNewFee, actualNewFee, "computeFeeUpdate should match poke for all pool types");
        assertEq(computedOldFee, validFee, "Old fee should match initial fee");
    }

    /**
     * @notice Fuzz test that computeFeeUpdate clamps newTargetRatio to maxCurrentRatio
     * @dev Verifies the clamping logic: if (newTargetRatio > pp.maxCurrentRatio) newTargetRatio = pp.maxCurrentRatio
     * @param highRatio A high current ratio that would push EMA above maxCurrentRatio
     */
    function testFuzz_computeFeeUpdate_clampsNewTargetRatioToMax(uint256 highRatio) public {
        // Create a pool with a lower maxCurrentRatio to make clamping easier to trigger
        DynamicFeeLib.PoolTypeParams memory customParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Set maxCurrentRatio to a moderate value so we can exceed it with EMA
        uint256 lowerMax = 5e20; // 500:1 ratio
        customParams.maxCurrentRatio = lowerMax;

        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, customParams);

        // Get updated params
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Use a ratio at the max - EMA should produce newTargetRatio that gets clamped
        // Start with initial target ratio lower, then push with max current ratio
        highRatio = bound(highRatio, params.maxCurrentRatio - 1e19, params.maxCurrentRatio);

        // Call computeFeeUpdate
        (,,, uint256 newTargetRatio,) = logic.computeFeeUpdate(key, highRatio);

        // The newTargetRatio should be clamped to maxCurrentRatio
        assertTrue(newTargetRatio <= params.maxCurrentRatio, "newTargetRatio should be clamped to maxCurrentRatio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }

    /**
     * @notice Test that computeFeeUpdate properly clamps newTargetRatio when EMA would exceed max
     * @dev This is a concrete test to ensure the clamping branch is hit
     */
    function test_computeFeeUpdate_clampsNewTargetRatioExplicit() public {
        // Setup: Create a fresh pool with high initial target ratio
        (PoolKey memory freshKey,) = _newUninitializedPoolWithHook(
            18, 18, _safeAddToTickSpacing(defaultTickSpacing, int24(300)), Constants.SQRT_PRICE_1_1, hook
        );

        // Get params for VOLATILE (has highest default maxCurrentRatio)
        DynamicFeeLib.PoolTypeParams memory volParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.VOLATILE);

        // Activate pool with target ratio at 90% of max
        uint256 highInitialTarget = (volParams.maxCurrentRatio * 90) / 100;
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, highInitialTarget, IAlphixLogic.PoolType.VOLATILE);

        // Now lower the maxCurrentRatio to force clamping
        DynamicFeeLib.PoolTypeParams memory newParams = volParams;
        newParams.maxCurrentRatio = (highInitialTarget * 80) / 100; // 80% of initial target

        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.VOLATILE, newParams);

        // Wait for cooldown
        vm.warp(block.timestamp + newParams.minPeriod + 1);

        // Call computeFeeUpdate with currentRatio at new max
        // EMA will try to blend highInitialTarget with currentRatio, but both will be clamped
        (,, uint256 oldTargetRatio, uint256 newTargetRatio,) =
            logic.computeFeeUpdate(freshKey, newParams.maxCurrentRatio);

        // oldTargetRatio should be clamped (it was highInitialTarget > newParams.maxCurrentRatio)
        assertEq(oldTargetRatio, newParams.maxCurrentRatio, "oldTargetRatio should be clamped to new maxCurrentRatio");

        // newTargetRatio should also be clamped or at max
        assertTrue(newTargetRatio <= newParams.maxCurrentRatio, "newTargetRatio should not exceed maxCurrentRatio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }

    /**
     * @notice Fuzz test computeFeeUpdate with extreme ratio differences to stress EMA
     * @dev Tests edge cases where currentRatio is much smaller than oldTargetRatio
     * @param currentRatio The current ratio (will be bounded to valid range)
     */
    function testFuzz_computeFeeUpdate_extremeRatioDifference(uint256 currentRatio) public {
        // Create pool with high initial target
        (PoolKey memory freshKey,) = _newUninitializedPoolWithHook(
            18, 18, _safeAddToTickSpacing(defaultTickSpacing, int24(400)), Constants.SQRT_PRICE_1_1, hook
        );

        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        // Set high initial target ratio (90% of max)
        uint256 highTarget = (params.maxCurrentRatio * 90) / 100;
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, highTarget, IAlphixLogic.PoolType.STANDARD);

        // Wait for cooldown
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Use a very small currentRatio (but valid)
        currentRatio = bound(currentRatio, MIN_RATIO_FUZZ, params.maxCurrentRatio / 100);

        // computeFeeUpdate should handle this gracefully
        (uint24 newFee,, uint256 oldTargetRatio, uint256 newTargetRatio,) =
            logic.computeFeeUpdate(freshKey, currentRatio);

        // Verify constraints
        assertTrue(newFee >= params.minFee && newFee <= params.maxFee, "Fee should be in bounds");
        assertEq(oldTargetRatio, highTarget, "oldTargetRatio should match initial");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
        assertTrue(newTargetRatio <= params.maxCurrentRatio, "newTargetRatio should not exceed max");

        // newTargetRatio should be between currentRatio and oldTargetRatio (EMA smoothing)
        assertTrue(newTargetRatio <= oldTargetRatio, "newTargetRatio should decrease towards currentRatio");
        assertTrue(newTargetRatio >= currentRatio, "newTargetRatio should not go below currentRatio");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                            */
    /* ========================================================================== */

    /**
     * @notice Safely adds an offset to a tick spacing value
     * @dev Performs overflow checks before casting back to int24
     * @param base The base tick spacing value
     * @param offset The offset to add (must be positive)
     * @return The new tick spacing value
     */
    function _safeAddToTickSpacing(int24 base, int24 offset) private pure returns (int24) {
        int256 result = int256(base) + int256(offset);
        require(result >= type(int24).min && result <= type(int24).max, "tick spacing overflow");
        // Casting to int24 is safe because we checked the range above
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(result);
    }
}
