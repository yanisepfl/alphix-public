// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import "../../BaseAlphix.t.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
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
            int24(int256(uint256(int256(defaultTickSpacing)) + 20)), // Unique tick spacing
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
            int24(int256(uint256(int256(defaultTickSpacing)) + 40)), // Unique tick spacing
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
            int24(int256(uint256(int256(defaultTickSpacing)) + 60)), // Unique tick spacing
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
            int24(int256(uint256(int256(defaultTickSpacing)) + 80)), // Unique tick spacing
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
            int24(int256(uint256(int256(defaultTickSpacing)) + 100 + uint256(poolTypeIndex) * 20)), // Unique tick spacing per pool type
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
}
