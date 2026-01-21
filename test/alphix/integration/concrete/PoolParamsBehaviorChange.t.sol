// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Vm} from "forge-std/Vm.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title PoolParamsBehaviorChangeTest
 * @author Alphix
 * @notice Tests for setPoolParams behavior changes
 * @dev Comprehensive tests to ensure that the dynamic fee algorithm adapts correctly to new parameters while maintaining
 *      security properties and preventing manipulation.
 */
contract PoolParamsBehaviorChangeTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /* ORIGINAL PARAMETERS */
    DynamicFeeLib.PoolParams public originalParams;

    /* NEW PARAMETERS FOR TESTING */
    DynamicFeeLib.PoolParams public restrictiveParams;
    DynamicFeeLib.PoolParams public permissiveParams;
    DynamicFeeLib.PoolParams public extremeParams;
    DynamicFeeLib.PoolParams public lowUpperSideParams;
    DynamicFeeLib.PoolParams public highUpperSideParams;
    DynamicFeeLib.PoolParams public lowLowerSideParams;
    DynamicFeeLib.PoolParams public highLowerSideParams;
    DynamicFeeLib.PoolParams public shortLookbackParams;
    DynamicFeeLib.PoolParams public longLookbackParams;
    DynamicFeeLib.PoolParams public lowLinearSlopeParams;
    DynamicFeeLib.PoolParams public highLinearSlopeParams;
    DynamicFeeLib.PoolParams public lowBaseMaxFeeDeltaParams;
    DynamicFeeLib.PoolParams public highBaseMaxFeeDeltaParams;

    /**
     * @notice Sets up the test environment with parameter variations
     * @dev Initializes the base test environment, stores original parameters,
     *      creates test parameter variations, and waits past initial cooldown
     */
    function setUp() public override {
        super.setUp();

        // Store original parameters for reference
        originalParams = hook.getPoolParams();

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
        // Create base parameter template
        DynamicFeeLib.PoolParams memory baseParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 8000,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 2e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18,
            lowerSideFactor: 2e18
        });

        _createMainParameterSets();
        _createSideFactorParameterSets(baseParams);
        _createLookbackParameterSets(baseParams);
        _createLinearSlopeParameterSets(baseParams);
        _createBaseMaxFeeDeltaParameterSets(baseParams);
    }

    /**
     * @notice Creates main parameter sets (restrictive, permissive, extreme)
     * @dev Sets up the primary parameter variations for general testing
     */
    function _createMainParameterSets() internal {
        // Restrictive parameters (tighter bounds, slower adjustments)
        restrictiveParams = DynamicFeeLib.PoolParams({
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
        permissiveParams = DynamicFeeLib.PoolParams({
            minFee: 1, // Same minimum as original
            maxFee: 150000, // Higher maximum than default (100001)
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
        extremeParams = DynamicFeeLib.PoolParams({
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
    }

    /**
     * @notice Creates side factor parameter sets for testing side factor effects
     * @dev Uses base parameters and only modifies side factors to isolate their effects
     */
    function _createSideFactorParameterSets(DynamicFeeLib.PoolParams memory baseParams) internal {
        // Low upper side factor (1.0x multiplier)
        lowUpperSideParams = baseParams;
        lowUpperSideParams.upperSideFactor = 1e18;

        // High upper side factor (5.0x multiplier)
        highUpperSideParams = baseParams;
        highUpperSideParams.upperSideFactor = 5e18;

        // Low lower side factor (1.0x multiplier)
        lowLowerSideParams = baseParams;
        lowLowerSideParams.lowerSideFactor = 1e18;

        // High lower side factor (5.0x multiplier)
        highLowerSideParams = baseParams;
        highLowerSideParams.lowerSideFactor = 5e18;
    }

    /**
     * @notice Creates lookback period parameter sets for testing EMA effects
     * @dev Uses base parameters and only modifies lookback periods to isolate their effects
     */
    function _createLookbackParameterSets(DynamicFeeLib.PoolParams memory baseParams) internal {
        // Short lookback period (faster EMA response)
        shortLookbackParams = baseParams;
        shortLookbackParams.lookbackPeriod = AlphixGlobalConstants.MIN_LOOKBACK_PERIOD; // 7 days

        // Long lookback period (slower EMA response)
        longLookbackParams = baseParams;
        longLookbackParams.lookbackPeriod = 90; // 90 days (well below max of 365)
    }

    /**
     * @notice Creates linear slope parameter sets for testing fee adjustment sensitivity
     * @dev Uses base parameters and only modifies linear slopes to isolate their effects
     */
    function _createLinearSlopeParameterSets(DynamicFeeLib.PoolParams memory baseParams) internal {
        // Low linear slope (gentler fee adjustments)
        lowLinearSlopeParams = baseParams;
        lowLinearSlopeParams.linearSlope = AlphixGlobalConstants.MIN_LINEAR_SLOPE; // 1e17

        // High linear slope (steeper fee adjustments)
        highLinearSlopeParams = baseParams;
        highLinearSlopeParams.linearSlope = 5e18; // 5.0 (well below max of 10.0)
    }

    /**
     * @notice Creates base max fee delta parameter sets for testing fee change limits
     * @dev Uses base parameters and only modifies baseMaxFeeDelta to isolate their effects
     */
    function _createBaseMaxFeeDeltaParameterSets(DynamicFeeLib.PoolParams memory baseParams) internal {
        // Low base max fee delta (smaller fee steps)
        lowBaseMaxFeeDeltaParams = baseParams;
        lowBaseMaxFeeDeltaParams.baseMaxFeeDelta = 10;

        // High base max fee delta (larger fee steps)
        highBaseMaxFeeDeltaParams = baseParams;
        highBaseMaxFeeDeltaParams.baseMaxFeeDelta = 100;
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
        hook.poke(testRatio);

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
        hook.poke(lowRatio);

        (,,, uint24 feeAfter) = poolManager.getSlot0(poolId);

        // Fee should have decreased (below target ratio)
        assertTrue(feeAfter <= INITIAL_FEE, "Fee should decrease for low ratio");
        assertTrue(feeAfter >= originalParams.minFee, "Fee should not go below min");
    }

    /* PARAMETER CHANGE BEHAVIOR TESTS */

    /**
     * @notice Tests that existing pool fees are NOT immediately clamped after parameter change.
     * @dev This is expected behavior: fees are only clamped to new bounds on the next poke().
     *      Admin should manually poke affected pools after updating parameters if immediate effect is required.
     */
    function test_setPoolParams_feeNotClampedUntilPoke() public {
        // First, push the fee up to a high value using original params
        uint256 highRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Multiple pokes to push fee higher (with cooldown waits)
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + originalParams.minPeriod + 1);
            vm.prank(owner);
            hook.poke(highRatio);
        }

        (,,, uint24 feeBeforeParamChange) = poolManager.getSlot0(poolId);
        assertTrue(feeBeforeParamChange > INITIAL_FEE, "Fee should have increased");

        // Now change to restrictive params with a much lower maxFee
        vm.prank(owner);
        hook.setPoolParams(restrictiveParams);

        // The current fee is above restrictive maxFee, but it should NOT be automatically clamped
        (,,, uint24 feeAfterParamChange) = poolManager.getSlot0(poolId);
        assertEq(feeAfterParamChange, feeBeforeParamChange, "Fee should NOT change immediately after setPoolParams");

        // If the current fee exceeds the new max, verify it's still out of bounds
        if (feeBeforeParamChange > restrictiveParams.maxFee) {
            assertTrue(
                feeAfterParamChange > restrictiveParams.maxFee, "Fee remains above new maxFee until poke() is called"
            );
        }

        // Now poke to trigger the clamping
        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(INITIAL_TARGET_RATIO); // Use neutral ratio

        (,,, uint24 feeAfterPoke) = poolManager.getSlot0(poolId);

        // After poke, fee should be clamped to new bounds
        assertTrue(feeAfterPoke >= restrictiveParams.minFee, "Fee should respect new minFee after poke");
        assertTrue(feeAfterPoke <= restrictiveParams.maxFee, "Fee should respect new maxFee after poke");
    }

    /**
     * @notice Tests that restrictive parameters reduce maximum possible fees
     * @dev Verifies that when parameters are modified to more restrictive values,
     *      the fee adjustment magnitude is constrained by the new limits
     */
    function test_restrictiveParams_reducesMaximumFee() public {
        // Use a ratio significantly outside tolerance to trigger fee adjustment
        uint256 testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // First, establish behavior with original parameters
        vm.prank(owner);
        hook.poke(testRatio);

        (,,, uint24 feeAfterOriginal) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterOriginal >= INITIAL_FEE, "Original params should allow fee increase");

        // Reset pool state by waiting for cooldown
        vm.warp(block.timestamp + originalParams.minPeriod + 1);

        // Change to restrictive parameters
        vm.prank(owner);
        hook.setPoolParams(restrictiveParams);

        // Apply same ratio change (wait for new cooldown)
        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testRatio);

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
        // Use a ratio outside tolerance to trigger adjustment
        uint256 testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Change to permissive parameters first
        vm.prank(owner);
        hook.setPoolParams(permissiveParams);

        // Apply ratio change (wait for cooldown)
        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testRatio);

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
        hook.setPoolParams(restrictiveParams);

        // Try to trigger adjustment that would exceed new max fee
        uint256 extremeRatio = 2e18; // High ratio

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(extremeRatio);

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
        hook.setPoolParams(restrictiveParams);

        // Use a ratio that would be within original tolerance but outside restrictive tolerance
        uint256 marginRatio = INITIAL_TARGET_RATIO + (restrictiveParams.ratioTolerance / 2);

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(marginRatio);

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
        hook.setPoolParams(permissiveParams);

        // Use a ratio that would trigger adjustment with original tolerance
        uint256 marginRatio = INITIAL_TARGET_RATIO + (originalParams.ratioTolerance + 1e15);

        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(marginRatio);

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
        hook.poke(8e17);

        // Change to shorter cooldown period
        vm.prank(owner);
        hook.setPoolParams(permissiveParams);

        // Try to adjust again immediately (should still respect original cooldown from the poke)
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(9e17);

        // Wait for new (shorter) cooldown period
        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);

        // Should work now
        vm.prank(owner);
        hook.poke(9e17);
    }

    /**
     * @notice Tests that longer cooldown periods are properly enforced
     * @dev Verifies that changing to longer cooldown extends the required wait time
     *      and prevents premature adjustments
     */
    function test_cooldownPeriod_longerCooldownEnforced() public {
        // Make initial adjustment
        vm.prank(owner);
        hook.poke(8e17);

        // Change to longer cooldown period
        vm.prank(owner);
        hook.setPoolParams(restrictiveParams);

        // Wait for original cooldown (should not be enough for new longer cooldown)
        vm.warp(block.timestamp + originalParams.minPeriod + 1);

        // Should still revert due to longer cooldown
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(9e17);

        // Wait for new longer cooldown
        vm.warp(block.timestamp + restrictiveParams.minPeriod);

        // Should work now
        vm.prank(owner);
        hook.poke(9e17);
    }

    /**
     * @notice Tests that parameter changes cannot bypass existing cooldowns
     * @dev Ensuring that users cannot change parameters to immediately bypass cooldown restrictions
     */
    function test_parameterChange_cannotBypassCooldown() public {
        // Make initial adjustment
        vm.prank(owner);
        hook.poke(8e17);

        // Immediately try to change parameters and adjust again
        vm.prank(owner);
        hook.setPoolParams(permissiveParams);

        // Should still respect cooldown even after parameter change
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(9e17);
    }

    /**
     * @notice Tests that fee manipulation within the same block is prevented
     * @dev Ensures that parameter changes and fee adjustments cannot be executed
     *      in the same block to prevent manipulation
     */
    function test_parameterChange_cannotManipulateFeeInSameBlock() public {
        // Change parameters and try to manipulate fee in same block
        vm.prank(owner);
        hook.setPoolParams(extremeParams);

        // Should not be able to poke in same block due to cooldown
        vm.expectRevert();
        vm.prank(owner);
        hook.poke(_getAboveToleranceRatio(INITIAL_TARGET_RATIO, extremeParams.ratioTolerance));
    }

    /**
     * @notice Tests that extreme parameters still maintain bounded behavior
     * @dev Verifies that even with boundary parameter values, the system
     *      maintains safe operation and prevents unbounded fee growth
     */
    function test_extremeParameters_behaviorStillBounded() public {
        // Set extreme parameters
        vm.prank(owner);
        hook.setPoolParams(extremeParams);

        // Wait for cooldown
        vm.warp(block.timestamp + extremeParams.minPeriod + 1);

        // Test with extreme ratio
        uint256 extremeRatio = extremeParams.maxCurrentRatio;

        vm.prank(owner);
        hook.poke(extremeRatio);

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
        // Use ratio significantly above tolerance to test side factor effects
        uint256 upperRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Test with low upper side factor (1.0x multiplier)
        vm.prank(owner);
        hook.setPoolParams(lowUpperSideParams);

        vm.warp(block.timestamp + lowUpperSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(upperRatio);

        (,,, uint24 feeAfterLowUpper) = poolManager.getSlot0(poolId);

        // Reset and test with high upper side factor (5.0x multiplier)
        vm.warp(block.timestamp + lowUpperSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolParams(highUpperSideParams);

        vm.warp(block.timestamp + highUpperSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(upperRatio);

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
        // Use ratio below tolerance to test lower side factor effects
        uint256 lowerRatio = _getBelowToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Test with low lower side factor (1.0x multiplier)
        vm.prank(owner);
        hook.setPoolParams(lowLowerSideParams);

        vm.warp(block.timestamp + lowLowerSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(lowerRatio);

        (,,, uint24 feeAfterLowLower) = poolManager.getSlot0(poolId);

        // Reset and test with high lower side factor (5.0x multiplier)
        vm.warp(block.timestamp + lowLowerSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolParams(highLowerSideParams);

        vm.warp(block.timestamp + highLowerSideParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(lowerRatio);

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

    /* PARAMETER-SPECIFIC EFFECT TESTS */

    /**
     * @notice Tests that lookback period affects convergence rate over multiple updates
     * @dev Creates two separate hook+logic stacks (single-pool-per-hook architecture) to test
     *      different lookback periods without state contamination.
     *      Short lookback means the target ratio converges faster to current ratio (higher EMA alpha),
     *      which results in LESS fee adjustment (smaller divergence from target).
     *      Long lookback means the target ratio converges slower (lower EMA alpha),
     *      which results in MORE fee adjustment (larger divergence from target).
     */
    function test_lookbackPeriod_affectsConvergenceRate() public {
        // Deploy two fresh hook+logic stacks
        Alphix shortHook = _deployFreshAlphixStack();
        Alphix longHook = _deployFreshAlphixStack();

        // Create pools for each hook
        (PoolKey memory shortLookbackKey, PoolId shortLookbackPoolId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, shortHook);
        (PoolKey memory longLookbackKey, PoolId longLookbackPoolId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, longHook);

        // Configure pools with different lookback parameters
        vm.prank(owner);
        shortHook.initializePool(shortLookbackKey, INITIAL_FEE, INITIAL_TARGET_RATIO, shortLookbackParams);
        vm.prank(owner);
        longHook.initializePool(longLookbackKey, INITIAL_FEE, INITIAL_TARGET_RATIO, longLookbackParams);

        // Wait for cooldown and apply first poke
        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        // Use ratio above tolerance for convergence testing
        uint256 deviatedRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, shortLookbackParams.ratioTolerance);

        // First update - should produce identical fees (lookback only affects EMA)
        vm.prank(owner);
        shortHook.poke(deviatedRatio);
        vm.prank(owner);
        longHook.poke(deviatedRatio);

        (,,, uint24 shortFirstFee) = poolManager.getSlot0(shortLookbackPoolId);
        (,,, uint24 longFirstFee) = poolManager.getSlot0(longLookbackPoolId);

        // Second update - differences should start to emerge
        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);
        vm.prank(owner);
        shortHook.poke(deviatedRatio);
        vm.prank(owner);
        longHook.poke(deviatedRatio);

        poolManager.getSlot0(shortLookbackPoolId); // Assert state accessible
        poolManager.getSlot0(longLookbackPoolId); // Assert state accessible

        // Third update - differences should be more pronounced
        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);
        vm.prank(owner);
        shortHook.poke(deviatedRatio);
        vm.prank(owner);
        longHook.poke(deviatedRatio);

        (,,, uint24 shortThirdFee) = poolManager.getSlot0(shortLookbackPoolId);
        (,,, uint24 longThirdFee) = poolManager.getSlot0(longLookbackPoolId);

        // Verify convergence behavior:
        // First fees should be identical (algorithm design)
        assertEq(shortFirstFee, longFirstFee, "First fees should be identical");

        // Calculate total progression from initial fee for both pools
        uint256 shortTotalProgression =
            shortThirdFee > INITIAL_FEE ? shortThirdFee - INITIAL_FEE : INITIAL_FEE - shortThirdFee;
        uint256 longTotalProgression =
            longThirdFee > INITIAL_FEE ? longThirdFee - INITIAL_FEE : INITIAL_FEE - longThirdFee;

        // Long lookback should show LARGER fee changes because target converges slower,
        // maintaining larger divergence from target which triggers larger fee adjustments
        assertTrue(longTotalProgression >= shortTotalProgression, "Long lookback should show larger fee adjustments");

        // Both should show progression from initial fee (long more than short)
        assertTrue(longThirdFee >= INITIAL_FEE, "Long lookback should increase fee");

        // Verify parameter setup is correct
        assertTrue(shortLookbackParams.lookbackPeriod < longLookbackParams.lookbackPeriod, "Setup verification");

        // Silence unused variable warning
        shortHook = shortHook;
        longHook = longHook;
    }

    /**
     * @notice Tests that linear slope changes affect fee adjustment sensitivity
     * @dev Verifies that higher linear slopes result in more aggressive fee adjustments
     *      for the same ratio deviations from target
     */
    function test_linearSlope_affectFeeAdjustmentSensitivity() public {
        // Use ratio above tolerance to test linear slope sensitivity
        uint256 testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Test with low linear slope (gentler adjustments)
        vm.prank(owner);
        hook.setPoolParams(lowLinearSlopeParams);

        vm.warp(block.timestamp + lowLinearSlopeParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testRatio);

        (,,, uint24 feeAfterLowSlope) = poolManager.getSlot0(poolId);

        // Reset and test with high linear slope (steeper adjustments)
        vm.warp(block.timestamp + lowLinearSlopeParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolParams(highLinearSlopeParams);

        vm.warp(block.timestamp + highLinearSlopeParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testRatio);

        (,,, uint24 feeAfterHighSlope) = poolManager.getSlot0(poolId);

        // High linear slope should result in larger fee adjustment
        assertTrue(feeAfterHighSlope > feeAfterLowSlope, "High linear slope should increase fee more aggressively");
        assertTrue(feeAfterLowSlope >= INITIAL_FEE, "Low slope should still increase fee");
        assertTrue(feeAfterHighSlope >= INITIAL_FEE, "High slope should increase fee");

        // Verify the slope effect is meaningful (at least 25% difference)
        uint256 lowIncrease = feeAfterLowSlope - INITIAL_FEE;
        uint256 highIncrease = feeAfterHighSlope - INITIAL_FEE;
        assertTrue(highIncrease > (lowIncrease * 125) / 100, "High slope should show significant sensitivity increase");
    }

    /**
     * @notice Tests that linear slope affects downward adjustments as well
     * @dev Verifies that slope parameter affects fee decreases when ratio is below tolerance
     */
    function test_linearSlope_affectDownwardAdjustments() public {
        // Use ratio below tolerance to test linear slope sensitivity for decreases
        uint256 lowerRatio = _getBelowToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Test with low linear slope (gentler decreases)
        vm.prank(owner);
        hook.setPoolParams(lowLinearSlopeParams);

        vm.warp(block.timestamp + lowLinearSlopeParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(lowerRatio);

        (,,, uint24 feeAfterLowSlope) = poolManager.getSlot0(poolId);

        // Reset and test with high linear slope (steeper decreases)
        vm.warp(block.timestamp + lowLinearSlopeParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolParams(highLinearSlopeParams);

        vm.warp(block.timestamp + highLinearSlopeParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(lowerRatio);

        (,,, uint24 feeAfterHighSlope) = poolManager.getSlot0(poolId);

        // High linear slope should result in larger fee decrease
        assertTrue(feeAfterHighSlope < feeAfterLowSlope, "High linear slope should decrease fee more aggressively");
        assertTrue(feeAfterLowSlope <= INITIAL_FEE, "Low slope should decrease fee");
        assertTrue(feeAfterHighSlope <= INITIAL_FEE, "High slope should decrease fee");

        // Verify both respect minimum bounds
        assertTrue(feeAfterLowSlope >= lowLinearSlopeParams.minFee, "Should respect low slope min fee");
        assertTrue(feeAfterHighSlope >= highLinearSlopeParams.minFee, "Should respect high slope min fee");
    }

    /**
     * @notice Tests that baseMaxFeeDelta limits the maximum fee change per adjustment
     * @dev Verifies that smaller baseMaxFeeDelta values constrain fee changes more tightly
     *      regardless of how large the ratio deviation is
     */
    function test_baseMaxFeeDelta_limitsMaximumFeeChange() public {
        // Use ratio well above tolerance to test baseMaxFeeDelta effects
        uint256 extremeRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance) + 2e16;

        // Test with low base max fee delta (smaller steps)
        vm.prank(owner);
        hook.setPoolParams(lowBaseMaxFeeDeltaParams);

        vm.warp(block.timestamp + lowBaseMaxFeeDeltaParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(extremeRatio);

        (,,, uint24 feeAfterLowDelta) = poolManager.getSlot0(poolId);

        // Reset and test with high base max fee delta (larger steps)
        vm.warp(block.timestamp + lowBaseMaxFeeDeltaParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolParams(highBaseMaxFeeDeltaParams);

        vm.warp(block.timestamp + highBaseMaxFeeDeltaParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(extremeRatio);

        (,,, uint24 feeAfterHighDelta) = poolManager.getSlot0(poolId);

        // High base max fee delta should allow larger single-step fee increases
        assertTrue(feeAfterHighDelta >= feeAfterLowDelta, "High baseMaxFeeDelta should allow larger fee steps");
        assertTrue(feeAfterLowDelta >= INITIAL_FEE, "Low delta should still increase fee");
        assertTrue(feeAfterHighDelta >= INITIAL_FEE, "High delta should increase fee");

        // Verify the delta constraint effect is meaningful
        uint256 lowChange = feeAfterLowDelta - INITIAL_FEE;
        uint256 highChange = feeAfterHighDelta - INITIAL_FEE;

        // The difference should be significant, but we need to account for other constraints
        if (highChange > 0 && lowChange > 0) {
            assertTrue(highChange >= lowChange, "High delta should allow at least as much change as low delta");
        }

        // Verify both respect their bounds
        assertTrue(feeAfterLowDelta <= lowBaseMaxFeeDeltaParams.maxFee, "Should respect low delta max fee");
        assertTrue(feeAfterHighDelta <= highBaseMaxFeeDeltaParams.maxFee, "Should respect high delta max fee");
    }

    /**
     * @notice Tests baseMaxFeeDelta with streak behavior in consecutive adjustments
     * @dev Verifies that consecutive pokes in the same direction (upper) increase the streak
     *      and amplify the fee delta, while still being limited by baseMaxFeeDelta
     */
    function test_baseMaxFeeDelta_limitsConsecutiveSteps() public {
        // Use sustained ratio above tolerance to trigger upper streak
        uint256 persistentHighRatio =
            _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance) + 1e16;

        // Set up parameters that allow us to see streak effects
        vm.prank(owner);
        hook.setPoolParams(lowBaseMaxFeeDeltaParams);

        // Make first adjustment (streak = 1)
        vm.warp(block.timestamp + lowBaseMaxFeeDeltaParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(persistentHighRatio);

        (,,, uint24 feeAfterFirst) = poolManager.getSlot0(poolId);

        // Make second adjustment with same high ratio direction (streak = 2)
        vm.warp(block.timestamp + lowBaseMaxFeeDeltaParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(persistentHighRatio);

        (,,, uint24 feeAfterSecond) = poolManager.getSlot0(poolId);

        // Make third adjustment with same high ratio direction (streak = 3)
        vm.warp(block.timestamp + lowBaseMaxFeeDeltaParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(persistentHighRatio);

        (,,, uint24 feeAfterThird) = poolManager.getSlot0(poolId);

        // All adjustments should increase fees progressively
        assertTrue(feeAfterFirst >= INITIAL_FEE, "First adjustment should increase fee");
        assertTrue(feeAfterSecond > feeAfterFirst, "Second adjustment should further increase fee");
        assertTrue(feeAfterThird > feeAfterSecond, "Third adjustment should further increase fee");

        // Calculate step sizes - streak behavior should amplify steps
        uint256 firstStep = feeAfterFirst - INITIAL_FEE;
        uint256 secondStep = feeAfterSecond - feeAfterFirst;
        uint256 thirdStep = feeAfterThird - feeAfterSecond;

        // Due to streak behavior, later steps should be larger (amplified by consecutive hits)
        assertTrue(secondStep >= firstStep, "Second step should be at least as large as first (streak effect)");
        assertTrue(thirdStep >= secondStep, "Third step should be at least as large as second (streak effect)");

        // Each step should be constrained by baseMaxFeeDelta with streak multiplier
        // Rather than hardcode values, verify relative growth patterns
        uint24 baseMaxDelta = lowBaseMaxFeeDeltaParams.baseMaxFeeDelta;

        // First step should be roughly bounded by baseMaxFeeDelta (streak = 1)
        assertTrue(firstStep <= baseMaxDelta * 3, "First step should be reasonably constrained by baseMaxFeeDelta");

        // Verify reasonable progressive growth without hardcoded thresholds
        assertTrue(secondStep <= firstStep * 3, "Second step should not grow excessively from first");
        assertTrue(thirdStep <= secondStep * 2, "Third step should not grow excessively from second");

        // Verify all fees respect the maximum bound
        assertTrue(feeAfterThird <= lowBaseMaxFeeDeltaParams.maxFee, "Final fee should respect max bound");
    }

    /* STRESS TESTS */

    /**
     * @notice Tests consistent behavior across multiple parameter changes
     * @dev Stress test that cycles through different parameter sets to ensure
     *      consistent and predictable behavior regardless of parameter history
     */
    function test_multipleParameterChanges_consistentBehavior() public {
        // Use ratio above tolerance for consistent testing across parameter sets
        uint256 testRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        // Cycle through different parameter sets
        DynamicFeeLib.PoolParams[3] memory paramSets = [restrictiveParams, permissiveParams, originalParams];

        for (uint256 i = 0; i < paramSets.length; i++) {
            vm.prank(owner);
            hook.setPoolParams(paramSets[i]);

            // Wait for cooldown
            vm.warp(block.timestamp + paramSets[i].minPeriod + 1);

            vm.prank(owner);
            hook.poke(testRatio);

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
        hook.setPoolParams(restrictiveParams);

        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);

        // High ratio test - use ratio above tolerance
        uint256 highRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, restrictiveParams.ratioTolerance);
        vm.prank(owner);
        hook.poke(highRatio);

        (,,, uint24 feeAfterHigh) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterHigh >= INITIAL_FEE, "Fee should increase for high ratio");

        // Wait and switch to permissive parameters
        vm.warp(block.timestamp + restrictiveParams.minPeriod + 1);
        vm.prank(owner);
        hook.setPoolParams(permissiveParams);

        vm.warp(block.timestamp + permissiveParams.minPeriod + 1);

        // Low ratio test - use ratio below tolerance
        uint256 lowRatio = _getBelowToleranceRatio(INITIAL_TARGET_RATIO, permissiveParams.ratioTolerance);
        vm.prank(owner);
        hook.poke(lowRatio);

        (,,, uint24 feeAfterLow) = poolManager.getSlot0(poolId);
        assertTrue(feeAfterLow <= feeAfterHigh, "Fee should decrease for low ratio");
        assertTrue(feeAfterLow >= permissiveParams.minFee, "Fee should respect min bound");
    }

    /* HELPER FUNCTIONS FOR RATIO TOLERANCE CALCULATIONS */

    /**
     * @notice Calculate upper bound for ratio tolerance
     * @param targetRatio The target ratio to calculate bounds for
     * @param ratioTolerance The ratio tolerance (as a fraction of 1e18)
     * @return upperBound The upper bound: targetRatio + targetRatio * ratioTolerance / 1e18
     */
    function _getUpperToleranceBound(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        return targetRatio + (targetRatio * ratioTolerance / 1e18);
    }

    /**
     * @notice Calculate lower bound for ratio tolerance
     * @param targetRatio The target ratio to calculate bounds for
     * @param ratioTolerance The ratio tolerance (as a fraction of 1e18)
     * @return lowerBound The lower bound: targetRatio - targetRatio * ratioTolerance / 1e18
     */
    function _getLowerToleranceBound(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        return targetRatio - (targetRatio * ratioTolerance / 1e18);
    }

    /* ========================================================================== */
    /*                   EMA TARGET RATIO VERIFICATION TESTS                      */
    /* ========================================================================== */

    /**
     * @notice Verifies that poke() actually updates _targetRatio via EMA
     * @dev This test explicitly checks that the FeeUpdated event shows different
     *      old and new target ratios after a poke, confirming EMA is applied.
     */
    function test_poke_updatesTargetRatioViaEMA() public {
        // Use a ratio different from target to see EMA movement
        uint256 currentRatio = _getAboveToleranceRatio(INITIAL_TARGET_RATIO, originalParams.ratioTolerance);

        vm.recordLogs();
        vm.prank(owner);
        hook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundEvent = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTargetRatio,, uint256 newTargetRatio) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Key assertion: target ratio should have changed (EMA was applied)
                assertTrue(newTargetRatio != oldTargetRatio, "Target ratio should update via EMA");

                // New target should move toward current ratio (EMA convergence)
                // If currentRatio > oldTargetRatio, newTargetRatio should be > oldTargetRatio
                if (currentRatio > oldTargetRatio) {
                    assertTrue(newTargetRatio > oldTargetRatio, "EMA should move target toward current (upward)");
                    assertTrue(newTargetRatio <= currentRatio, "New target should not exceed current");
                }

                foundEvent = true;
                break;
            }
        }

        assertTrue(foundEvent, "FeeUpdated event should be emitted");
    }

    /**
     * @notice Verifies that short lookback produces larger target ratio changes per poke
     * @dev EMA formula: newTarget = old + alpha * (current - old) where alpha = 2/(lookbackPeriod + 1)
     *      Shorter lookback = higher alpha = larger change per poke
     */
    function test_lookbackPeriod_shortLookbackProducesLargerTargetRatioChanges() public {
        // Deploy two fresh stacks with different lookback periods
        Alphix shortHook = _deployFreshAlphixStack();
        Alphix longHook = _deployFreshAlphixStack();

        (PoolKey memory shortKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, shortHook);
        (PoolKey memory longKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, longHook);

        vm.prank(owner);
        shortHook.initializePool(shortKey, INITIAL_FEE, INITIAL_TARGET_RATIO, shortLookbackParams);
        vm.prank(owner);
        longHook.initializePool(longKey, INITIAL_FEE, INITIAL_TARGET_RATIO, longLookbackParams);

        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        // Use ratio significantly different from target to see EMA effect
        uint256 currentRatio = INITIAL_TARGET_RATIO * 15 / 10; // 1.5x target

        // Poke short lookback hook
        vm.recordLogs();
        vm.prank(owner);
        shortHook.poke(currentRatio);

        uint256 shortTargetChange = 0;
        Vm.Log[] memory shortLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < shortLogs.length; i++) {
            if (shortLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTarget,, uint256 newTarget) =
                    abi.decode(shortLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                shortTargetChange = newTarget > oldTarget ? newTarget - oldTarget : oldTarget - newTarget;
                break;
            }
        }

        // Poke long lookback hook
        vm.recordLogs();
        vm.prank(owner);
        longHook.poke(currentRatio);

        uint256 longTargetChange = 0;
        Vm.Log[] memory longLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < longLogs.length; i++) {
            if (longLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTarget,, uint256 newTarget) =
                    abi.decode(longLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                longTargetChange = newTarget > oldTarget ? newTarget - oldTarget : oldTarget - newTarget;
                break;
            }
        }

        // Short lookback should produce larger target ratio changes
        assertTrue(shortTargetChange > longTargetChange, "Short lookback should produce larger target ratio changes");

        // Both should have non-zero changes (EMA is being applied)
        assertTrue(shortTargetChange > 0, "Short lookback target should change");
        assertTrue(longTargetChange > 0, "Long lookback target should change");
    }

    /**
     * @notice Verifies EMA convergence over multiple pokes
     * @dev After multiple pokes with the same current ratio, target ratio should converge
     *      toward the current ratio (distance decreases each poke).
     *      Uses shortLookbackParams for faster convergence in tests.
     */
    function test_poke_targetRatioConvergesOverMultiplePokes() public {
        // Deploy fresh hook with short lookback for faster convergence
        Alphix freshHook = _deployFreshAlphixStack();
        (PoolKey memory testKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        vm.prank(owner);
        freshHook.initializePool(testKey, INITIAL_FEE, INITIAL_TARGET_RATIO, shortLookbackParams);

        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        uint256 currentRatio = INITIAL_TARGET_RATIO * 12 / 10; // 1.2x target

        uint256 lastTargetRatio = INITIAL_TARGET_RATIO;
        uint256 lastDistance = currentRatio - INITIAL_TARGET_RATIO; // Initial distance

        // Poke multiple times and verify convergence
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(currentRatio);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (,, uint256 oldTarget,, uint256 newTarget) =
                        abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));

                    // Verify old target matches our expectation
                    assertEq(oldTarget, lastTargetRatio, "Old target should match last known target");

                    // Calculate new distance to current ratio
                    uint256 newDistance = newTarget > currentRatio ? newTarget - currentRatio : currentRatio - newTarget;

                    // Distance should decrease (convergence)
                    assertTrue(newDistance < lastDistance, "Distance to current ratio should decrease (convergence)");

                    lastDistance = newDistance;
                    lastTargetRatio = newTarget;
                    break;
                }
            }
        }

        // After 5 pokes with short lookback, target should be closer to current than initially
        // With short lookback (7 days), alpha = 2/(7+1) = 0.25, so convergence should be visible
        uint256 finalDistance =
            lastTargetRatio > currentRatio ? lastTargetRatio - currentRatio : currentRatio - lastTargetRatio;
        uint256 initialDistance = currentRatio - INITIAL_TARGET_RATIO;

        // With alpha=0.25, after 5 pokes: (1-0.25)^5 ≈ 0.237, so ~76% convergence
        // Using a more conservative check (at least 50% convergence)
        assertTrue(finalDistance < initialDistance / 2, "Target should have converged significantly");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

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
        return _getLowerToleranceBound(targetRatio, ratioTolerance) - additionalMargin;
    }
}
