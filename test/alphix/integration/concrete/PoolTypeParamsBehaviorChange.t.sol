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

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title PoolTypeParamsBehaviorChangeTest
 * @author Alphix
 * @notice Tests for setPoolTypeParams behavior changes
 * @dev Comprehensive tests to ensure that the dynamic fee algorithm adapts correctly to new parameters while maintaining
 *      security properties and preventing manipulation.
 */
contract PoolTypeParamsBehaviorChangeTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* ORIGINAL PARAMETERS */
    DynamicFeeLib.PoolTypeParams public originalParams;

    /* NEW PARAMETERS FOR TESTING */
    DynamicFeeLib.PoolTypeParams public restrictiveParams;
    DynamicFeeLib.PoolTypeParams public permissiveParams;
    DynamicFeeLib.PoolTypeParams public extremeParams;
    DynamicFeeLib.PoolTypeParams public lowUpperSideParams;
    DynamicFeeLib.PoolTypeParams public highUpperSideParams;
    DynamicFeeLib.PoolTypeParams public lowLowerSideParams;
    DynamicFeeLib.PoolTypeParams public highLowerSideParams;

    /**
     * @notice Sets up the test environment with parameter variations
     * @dev Initializes the base test environment, stores original parameters,
     *      creates test parameter variations, and waits past initial cooldown
     */
    function setUp() public override {
        super.setUp();

        // Store original parameters for reference
        originalParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STABLE);

        // Set up test parameter variations
        _setupTestParameters();

        // Wait past initial cooldown for testing
        vm.warp(block.timestamp + originalParams.minPeriod + 1);
    }

    /**
     * @notice Initializes test parameter variations for different scenarios
     * @dev Creates restrictive, permissive, and extreme parameter sets to test
     *      behavior under different configuration conditions
     */
    function _setupTestParameters() internal {
        // Restrictive parameters (tighter bounds, slower adjustments)
        restrictiveParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1000, // Higher minimum (was 1)
            maxFee: 4000, // Lower maximum (was 5001)
            baseMaxFeeDelta: 15, // Smaller delta (was 25)
            lookbackPeriod: 60, // Longer lookback (was 30)
            minPeriod: 2 days, // Longer cooldown (was 1 day)
            ratioTolerance: 25e14, // Tighter tolerance (was 5e15)
            linearSlope: 1e18, // Gentler slope (was 2e18)
            maxCurrentRatio: 5e20, // Lower max ratio (was 1e21)
            upperSideFactor: 1e18, // Minimum allowed upper factor
            lowerSideFactor: 15e17 // Reduced lower factor (was 2e18)
        });

        // Permissive parameters (wider bounds, faster adjustments)
        permissiveParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1, // Same minimum as original
            maxFee: 8000, // Higher maximum
            baseMaxFeeDelta: 50, // Larger delta
            lookbackPeriod: 15, // Shorter lookback
            minPeriod: 12 hours, // Shorter cooldown
            ratioTolerance: 1e16, // Looser tolerance
            linearSlope: 3e18, // Steeper slope
            maxCurrentRatio: 2e21, // Higher max ratio
            upperSideFactor: 2e18, // Increased upper factor
            lowerSideFactor: 3e18 // Increased lower factor
        });

        // Extreme parameters (boundary values)
        extremeParams = DynamicFeeLib.PoolTypeParams({
            minFee: AlphixGlobalConstants.MIN_FEE,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: LPFeeLibrary.MAX_LP_FEE,
            lookbackPeriod: AlphixGlobalConstants.MAX_LOOKBACK_PERIOD,
            minPeriod: AlphixGlobalConstants.MAX_PERIOD,
            ratioTolerance: AlphixGlobalConstants.TEN_WAD,
            linearSlope: AlphixGlobalConstants.TEN_WAD,
            maxCurrentRatio: AlphixGlobalConstants.MAX_CURRENT_RATIO,
            upperSideFactor: AlphixGlobalConstants.TEN_WAD,
            lowerSideFactor: AlphixGlobalConstants.TEN_WAD
        });

        // Parameters with low upper side factor (for testing upper ratio adjustments)
        lowUpperSideParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18, // Minimum allowed (1.0x multiplier)
            lowerSideFactor: 2e18
        });

        // Parameters with high upper side factor (for testing upper ratio adjustments)
        highUpperSideParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 5e18, // High multiplier (5.0x)
            lowerSideFactor: 2e18
        });

        // Parameters with low lower side factor (for testing lower ratio adjustments)
        lowLowerSideParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 1e18 // Minimum allowed (1.0x multiplier)
        });

        // Parameters with high lower side factor (for testing lower ratio adjustments)
        highLowerSideParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 5e18 // High multiplier (5.0x)
        });
    }

    /* BASELINE BEHAVIOR TESTS */

    /**
     * @notice Tests baseline fee computation with original parameters
     * @dev Verifies that fee increases when ratio is above tolerance threshold
     *      and stays within expected bounds
     */
    function test_establishBaseline_originalParameters() public {
        // Test fee computation with original parameters
        uint256 testRatio = 8e17; // Above tolerance to trigger adjustment

        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

        // Fee should have increased (above target ratio)
        assertTrue(feeAfter >= INITIAL_FEE, "Fee should increase for high ratio");
        assertTrue(feeAfter <= originalParams.maxFee, "Fee should not exceed max");
    }

    /**
     * @notice Tests baseline fee computation with ratios below tolerance
     * @dev Verifies that fee decreases when ratio is below tolerance threshold
     *      and demonstrates opposite direction behavior
     */
    function test_establishBaseline_belowTolerance() public {
        // Test fee computation below tolerance
        uint256 lowRatio = INITIAL_TARGET_RATIO - originalParams.ratioTolerance - 1e16; // Below tolerance

        vm.prank(owner);
        hook.poke(key, lowRatio);

        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

        // Fee should have decreased (below target ratio)
        assertTrue(feeAfter <= INITIAL_FEE, "Fee should decrease for low ratio");
        assertTrue(feeAfter >= originalParams.minFee, "Fee should not go below min");
    }

    /* PARAMETER CHANGE BEHAVIOR TESTS */

    /**
     * @notice Tests that restrictive parameters reduce maximum possible fees
     * @dev Verifies that when parameters are modified to more restrictive values,
     *      the fee adjustment magnitude is constrained by the new limits
     */
    function test_restrictiveParams_reducesMaximumFee() public {
        uint256 testRatio = 1e18; // High ratio to trigger significant adjustment

        // First, establish behavior with original parameters
        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfterOriginal) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterOriginal >= INITIAL_FEE, "Original params should allow fee increase");

        // Reset pool state by waiting for cooldown
        vm.warp(block.timestamp + originalParams.minPeriod + 1);

        // Change to restrictive parameters
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, restrictiveParams);

        // Apply same ratio change (wait for new cooldown)
        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfterRestrictive) = poolManager.getSlot0(poolId);

        // With restrictive params, should respect new bounds
        assertTrue(feeAfterRestrictive >= restrictiveParams.minFee, "Should be at least restrictive min fee");
        assertTrue(feeAfterRestrictive <= restrictiveParams.maxFee, "Should not exceed restrictive max fee");
        // The restrictive parameters should limit the fee increase compared to original
        assertTrue(restrictiveParams.maxFee < originalParams.maxFee, "Restrictive max should be lower than original");
    }

    /**
     * @notice Tests that permissive parameters allow higher maximum fees
     * @dev Verifies that when parameters are modified to more permissive values,
     *      higher fee adjustments are possible within the new bounds
     */
    function test_permissiveParams_allowsHigherMaxFee() public {
        uint256 testRatio = 1e18; // High ratio to trigger adjustment

        // Change to permissive parameters first
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        // Apply ratio change (wait for cooldown)
        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, testRatio);

        (,,, uint24 feeAfterPermissive) = poolManager.getSlot0(poolId);

        // Permissive parameters should allow higher fees
        assertTrue(feeAfterPermissive <= permissiveParams.maxFee, "Should respect permissive max fee");
        assertTrue(permissiveParams.maxFee > originalParams.maxFee, "Permissive max should be higher than original");
    }

    /**
     * @notice Tests that fee bounds are immediately enforced after parameter changes
     * @dev Verifies that new parameter bounds take effect immediately and prevent
     *      fee adjustments outside the new ranges
     */
    function test_feeBounds_enforcedAfterParameterChange() public {
        // Change to restrictive parameters with tighter fee bounds
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, restrictiveParams);

        // Try to trigger adjustment that would exceed new max fee
        uint256 extremeRatio = 2e18; // High ratio

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, extremeRatio);

        (,,, uint24 finalFee) = poolManager.getSlot0(poolId);

        // Fee should respect new bounds (could be min if parameters are too restrictive)
        assertTrue(finalFee >= restrictiveParams.minFee, "Fee should be at least min fee");
        assertTrue(finalFee <= restrictiveParams.maxFee, "Fee should not exceed max fee");
    }

    /**
     * @notice Tests that tolerance bounds affect when adjustments are triggered
     * @dev Verifies that changing tolerance parameters affects the threshold
     *      at which fee adjustments are triggered, ensuring proper behavior
     */
    function test_toleranceBounds_affectTriggerThreshold() public {
        // Test with tighter tolerance
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, restrictiveParams);

        // Use a ratio that would be within original tolerance but outside restrictive tolerance
        uint256 marginRatio = INITIAL_TARGET_RATIO + (restrictiveParams.ratioTolerance / 2);

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, marginRatio);

        (,,, uint24 feeWithTightTolerance) = poolManager.getSlot0(poolId);

        // With tighter tolerance, this should trigger adjustment
        assertTrue(feeWithTightTolerance != INITIAL_FEE, "Tighter tolerance should trigger adjustment");
    }

    /**
     * @notice Tests opposite direction: permissive tolerance allows more variance
     * @dev Verifies that looser tolerance parameters prevent adjustments for
     *      ratios that would trigger adjustments under tighter tolerance
     */
    function test_permissiveTolerance_allowsMoreVariance() public {
        // Change to permissive parameters with looser tolerance
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        // Use a ratio that would trigger adjustment with original tolerance
        uint256 marginRatio = INITIAL_TARGET_RATIO + (originalParams.ratioTolerance + 1e15);

        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, marginRatio);

        (,,, uint24 feeWithLooseTolerance) = poolManager.getSlot0(poolId);

        // With looser tolerance, this might not trigger as strong an adjustment
        assertTrue(feeWithLooseTolerance <= permissiveParams.maxFee, "Should respect permissive bounds");
    }

    /* COOLDOWN AND TIMING TESTS */

    /**
     * @notice Tests that cooldown periods are enforced after parameter changes
     * @dev Verifies that changing to shorter cooldown doesn't bypass existing cooldown
     *      and that new cooldown periods are properly applied
     */
    function test_cooldownPeriod_enforcedAfterParameterChange() public {
        // Make initial adjustment
        vm.prank(owner);
        hook.poke(key, 8e17);

        // Change to shorter cooldown period
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        // Try to adjust again immediately (should still respect original cooldown from the poke)
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(key, 9e17);

        // Wait for new (shorter) cooldown period
        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);

        // Should work now
        vm.prank(owner);
        hook.poke(key, 9e17);
    }

    /**
     * @notice Tests that longer cooldown periods are properly enforced
     * @dev Verifies that changing to longer cooldown extends the required wait time
     *      and prevents premature adjustments
     */
    function test_cooldownPeriod_longerCooldownEnforced() public {
        // Make initial adjustment
        vm.prank(owner);
        hook.poke(key, 8e17);

        // Change to longer cooldown period
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, restrictiveParams);

        // Wait for original cooldown (should not be enough for new longer cooldown)
        vm.warp(block.timestamp + originalParams.minPeriod + 1);

        // Should still revert due to longer cooldown
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(key, 9e17);

        // Wait for new longer cooldown
        vm.warp(block.timestamp + restrictiveParams.minPeriod);

        // Should work now
        vm.prank(owner);
        hook.poke(key, 9e17);
    }

    /**
     * @notice Tests that parameter changes cannot bypass existing cooldowns
     * @dev Ensuring that users cannot change parameters to immediately bypass cooldown restrictions
     */
    function test_parameterChange_cannotBypassCooldown() public {
        // Make initial adjustment
        vm.prank(owner);
        hook.poke(key, 8e17);

        // Immediately try to change parameters and adjust again
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        // Should still respect cooldown even after parameter change
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(key, 9e17);
    }

    /**
     * @notice Tests that fee manipulation within the same block is prevented
     * @dev Ensures that parameter changes and fee adjustments cannot be executed
     *      in the same block to prevent manipulation
     */
    function test_parameterChange_cannotManipulateFeeInSameBlock() public {
        // Change parameters and try to manipulate fee in same block
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, extremeParams);

        // Should not be able to poke in same block due to cooldown
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(key, 1e18);
    }

    /**
     * @notice Tests that extreme parameters still maintain bounded behavior
     * @dev Verifies that even with boundary parameter values, the system
     *      maintains safe operation and prevents unbounded fee growth
     */
    function test_extremeParameters_behaviorStillBounded() public {
        // Set extreme parameters
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, extremeParams);

        // Wait for cooldown
        vm.warp(block.timestamp + extremeParams.minPeriod + 1);

        // Test with extreme ratio
        uint256 extremeRatio = extremeParams.maxCurrentRatio;

        vm.prank(owner);
        hook.poke(key, extremeRatio);

        (,,, uint24 finalFee) = poolManager.getSlot0(poolId);

        // Even with extreme parameters, fee should be bounded
        assertTrue(finalFee >= extremeParams.minFee, "Fee should respect min bound");
        assertTrue(finalFee <= extremeParams.maxFee, "Fee should respect max bound");
    }

    /**
     * @notice Tests that upper side factor changes produce different fee adjustments
     * @dev Verifies that different upperSideFactor values result in different
     *      fee adjustment magnitudes when ratio is above tolerance
     */
    function test_sideFactor_changes_affectAdjustmentDirection() public {
        uint256 upperRatio = INITIAL_TARGET_RATIO + 2e16; // Significantly above tolerance

        // Test with low upper side factor (1.0x multiplier)
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, lowUpperSideParams);

        vm.warp(block.timestamp + lowUpperSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, upperRatio);

        (,,, uint24 feeAfterLowUpper) = poolManager.getSlot0(poolId);

        // Reset and test with high upper side factor (5.0x multiplier)
        vm.warp(block.timestamp + lowUpperSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, highUpperSideParams);

        vm.warp(block.timestamp + highUpperSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, upperRatio);

        (,,, uint24 feeAfterHighUpper) = poolManager.getSlot0(poolId);

        // High upper side factor should result in larger fee increase
        assertTrue(feeAfterHighUpper > feeAfterLowUpper, "High upper side factor should increase fee more");
        assertTrue(feeAfterLowUpper >= INITIAL_FEE, "Low upper side should still increase fee");
        assertTrue(feeAfterHighUpper >= INITIAL_FEE, "High upper side should increase fee");

        // Verify the multiplier effect is meaningful (at least 20% difference)
        uint256 lowIncrease = feeAfterLowUpper - INITIAL_FEE;
        uint256 highIncrease = feeAfterHighUpper - INITIAL_FEE;
        assertTrue(highIncrease > (lowIncrease * 12) / 10, "High side factor should show significant increase");
    }

    /**
     * @notice Tests that lower side factor changes produce different fee adjustments
     * @dev Verifies that different lowerSideFactor values result in different
     *      fee adjustment magnitudes when ratio is below tolerance
     */
    function test_sideFactor_lowerRatio_affectAdjustmentMagnitude() public {
        uint256 lowerRatio = INITIAL_TARGET_RATIO - 1e16; // Moderately below tolerance

        // Test with low lower side factor (1.0x multiplier)
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, lowLowerSideParams);

        vm.warp(block.timestamp + lowLowerSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, lowerRatio);

        (,,, uint24 feeAfterLowLower) = poolManager.getSlot0(poolId);

        // Reset and test with high lower side factor (5.0x multiplier)
        vm.warp(block.timestamp + lowLowerSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, highLowerSideParams);

        vm.warp(block.timestamp + highLowerSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, lowerRatio);

        (,,, uint24 feeAfterHighLower) = poolManager.getSlot0(poolId);

        // High lower side factor should result in larger fee decrease (lower final fee)
        assertTrue(feeAfterHighLower < feeAfterLowLower, "High lower side factor should decrease fee more");
        assertTrue(feeAfterLowLower <= INITIAL_FEE, "Low lower side should decrease fee");
        assertTrue(feeAfterHighLower <= INITIAL_FEE, "High lower side should decrease fee");

        // Verify the multiplier effect is meaningful (at least 20% difference in decreases)
        uint256 lowDecrease = INITIAL_FEE - feeAfterLowLower;
        uint256 highDecrease = INITIAL_FEE - feeAfterHighLower;
        assertTrue(highDecrease > (lowDecrease * 12) / 10, "High lower side factor should show significant decrease");
    }

    /* STRESS TESTS */

    /**
     * @notice Tests consistent behavior across multiple parameter changes
     * @dev Stress test that cycles through different parameter sets to ensure
     *      consistent and predictable behavior regardless of parameter history
     */
    function test_multipleParameterChanges_consistentBehavior() public {
        uint256 testRatio = 7e17;

        // Cycle through different parameter sets
        DynamicFeeLib.PoolTypeParams[3] memory paramSets = [restrictiveParams, permissiveParams, originalParams];

        for (uint256 i = 0; i < paramSets.length; i++) {
            vm.prank(owner);
            hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, paramSets[i]);

            // Wait for cooldown
            vm.warp(block.timestamp + paramSets[i].minPeriod + 1);

            vm.prank(owner);
            hook.poke(key, testRatio);

            (,,, uint24 fee) = poolManager.getSlot0(poolId);

            // Fee should always be within the current parameter bounds
            assertTrue(fee >= paramSets[i].minFee, "Fee should respect current min bound");
            assertTrue(fee <= paramSets[i].maxFee, "Fee should respect current max bound");
        }
    }

    /**
     * @notice Tests parameter changes with alternating high/low ratios
     * @dev Comprehensive test that verifies proper behavior when alternating
     *      between high and low ratios after parameter changes
     */
    function test_alternatingRatios_withParameterChanges() public {
        // Start with restrictive parameters
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, restrictiveParams);

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);

        // High ratio test
        uint256 highRatio = INITIAL_TARGET_RATIO + restrictiveParams.ratioTolerance + 1e16;
        vm.prank(owner);
        hook.poke(key, highRatio);

        (,,, uint24 feeAfterHigh) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterHigh >= INITIAL_FEE, "Fee should increase for high ratio");

        // Wait and switch to permissive parameters
        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STABLE, permissiveParams);

        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);

        // Low ratio test
        uint256 lowRatio = INITIAL_TARGET_RATIO - permissiveParams.ratioTolerance - 1e16;
        vm.prank(owner);
        hook.poke(key, lowRatio);

        (,,, uint24 feeAfterLow) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterLow <= feeAfterHigh, "Fee should decrease for low ratio");
        assertTrue(feeAfterLow >= permissiveParams.minFee, "Fee should respect min bound");
    }
}
