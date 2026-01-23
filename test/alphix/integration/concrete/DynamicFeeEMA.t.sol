// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Vm} from "forge-std/Vm.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title DynamicFeeEMATest
 * @notice Tests for EMA-based target ratio updates in the poke function
 * @dev Verifies that the target ratio converges properly using exponential moving average
 */
contract DynamicFeeEMATest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    // Short lookback for faster convergence
    DynamicFeeLib.PoolParams internal shortLookbackParams;
    // Long lookback for slower convergence
    DynamicFeeLib.PoolParams internal longLookbackParams;

    function setUp() public override {
        super.setUp();

        // Short lookback period (7 days) - faster EMA response
        shortLookbackParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });

        // Long lookback period (365 days) - slower EMA response
        longLookbackParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 365,
            minPeriod: 1 hours,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });
    }

    /* ========================================================================== */
    /*                           TARGET RATIO UPDATE TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Verify that poke updates _targetRatio via EMA when ratio is above target
     */
    function test_poke_updatesTargetRatioViaEMA_ratioAboveTarget() public {
        // Deploy fresh hook with short lookback for faster convergence
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 initialTargetRatio = 1e18;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTargetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            shortLookbackParams
        );

        // Advance time past cooldown
        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        // Get initial target ratio from event/state
        uint256 currentRatio = 1.5e18; // 50% above target

        // Calculate expected new target using EMA formula
        // alpha = 2 / (lookbackPeriod + 1) = 2 / 8 = 0.25
        uint256 alpha = (2 * AlphixGlobalConstants.ONE_WAD) / (uint256(shortLookbackParams.lookbackPeriod) + 1);
        uint256 expectedNewTarget =
            initialTargetRatio + ((currentRatio - initialTargetRatio) * alpha / AlphixGlobalConstants.ONE_WAD);

        // Record logs and verify target ratio update
        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTargetRatio, uint256 emittedCurrentRatio, uint256 newTargetRatio) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Verify old target equals initial
                assertEq(oldTargetRatio, initialTargetRatio, "Old target should equal initial");
                // Verify current ratio was passed correctly
                assertEq(emittedCurrentRatio, currentRatio, "Current ratio should match");
                // Verify new target calculated via EMA
                assertEq(newTargetRatio, expectedNewTarget, "New target should match EMA calculation");
                // Verify new target moved toward current (increased)
                assertTrue(newTargetRatio > oldTargetRatio, "Target should increase toward higher current ratio");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeUpdated event not found");
    }

    /**
     * @notice Verify that poke updates _targetRatio via EMA when ratio is below target
     */
    function test_poke_updatesTargetRatioViaEMA_ratioBelowTarget() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 initialTargetRatio = 1e18;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTargetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            shortLookbackParams
        );

        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        uint256 currentRatio = 0.5e18; // 50% below target

        // Calculate expected new target using EMA formula
        uint256 alpha = (2 * AlphixGlobalConstants.ONE_WAD) / (uint256(shortLookbackParams.lookbackPeriod) + 1);
        uint256 expectedNewTarget =
            initialTargetRatio - ((initialTargetRatio - currentRatio) * alpha / AlphixGlobalConstants.ONE_WAD);

        // Record logs and verify target ratio update
        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTargetRatio, uint256 emittedCurrentRatio, uint256 newTargetRatio) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Verify old target equals initial
                assertEq(oldTargetRatio, initialTargetRatio, "Old target should equal initial");
                // Verify current ratio was passed correctly
                assertEq(emittedCurrentRatio, currentRatio, "Current ratio should match");
                // Verify new target calculated via EMA
                assertEq(newTargetRatio, expectedNewTarget, "New target should match EMA calculation");
                // Verify new target moved toward current (decreased)
                assertTrue(newTargetRatio < oldTargetRatio, "Target should decrease toward lower current ratio");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeUpdated event not found");
    }

    /**
     * @notice Verify FeeUpdated event emits different old and new target ratios
     */
    function test_poke_emitsFeeUpdatedWithDifferentTargetRatios() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 initialTargetRatio = 1e18;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTargetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            shortLookbackParams
        );

        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        uint256 currentRatio = 2e18; // Double the target

        // Record logs to capture event
        vm.recordLogs();

        vm.prank(owner);
        freshHook.poke(currentRatio);

        // Get the emitted events
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find FeeUpdated event
        bool found = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                // Decode event data (oldFee, newFee, oldTargetRatio, currentRatio, newTargetRatio)
                (
                    uint24 oldFee,
                    uint24 newFee,
                    uint256 oldTargetRatio,
                    uint256 emittedCurrentRatio,
                    uint256 newTargetRatio
                ) = abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Key assertion: old and new target ratios must differ
                assertTrue(oldTargetRatio != newTargetRatio, "Old and new target ratios should differ");
                assertEq(oldTargetRatio, initialTargetRatio, "Old target ratio should be initial");
                assertTrue(newTargetRatio > oldTargetRatio, "New target should be higher (ratio above target)");
                assertEq(emittedCurrentRatio, currentRatio, "Current ratio should match");
                found = true;
                break;
            }
        }
        assertTrue(found, "FeeUpdated event not found");
    }

    /**
     * @notice Verify multiple pokes converge target ratio toward current ratio
     */
    function test_poke_multiplePokesConvergeTargetRatio() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 initialTarget = 1e18;
        uint256 constantCurrentRatio = 2e18; // Constant high ratio for all pokes

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTarget,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            shortLookbackParams
        );

        uint256 lastNewTarget = initialTarget;

        // Perform 10 pokes with the same current ratio
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(constantCurrentRatio);

            // Extract new target from event
            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (,, uint256 oldTargetRatio,, uint256 newTargetRatio) =
                        abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));

                    // Each poke should move target closer to current
                    assertTrue(newTargetRatio > oldTargetRatio, "Target should increase toward current");
                    assertTrue(newTargetRatio < constantCurrentRatio, "Target should not overshoot");

                    lastNewTarget = newTargetRatio;
                    break;
                }
            }
        }

        // After many pokes, target should be much closer to current
        // With short lookback (alpha = 0.25), after 10 iterations:
        // target approaches current asymptotically
        assertTrue(lastNewTarget > 1.8e18, "Target should have converged significantly");
    }

    /**
     * @notice Verify EMA returns same value when current equals target (no change)
     */
    function test_poke_sameRatioNoTargetChange() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 initialTarget = 1e18;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTarget,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            shortLookbackParams
        );

        vm.warp(block.timestamp + shortLookbackParams.minPeriod + 1);

        // Poke with same ratio as target
        uint256 currentRatio = initialTarget;

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTargetRatio,, uint256 newTargetRatio) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // When current == target, EMA produces no change
                assertEq(oldTargetRatio, newTargetRatio, "Target should not change when current equals target");
                break;
            }
        }
    }

    /* ========================================================================== */
    /*                       LOOKBACK PERIOD CONVERGENCE TESTS                    */
    /* ========================================================================== */

    /**
     * @notice Verify lookback period affects convergence speed
     * @dev Short lookback = faster convergence, Long lookback = slower convergence
     */
    function test_lookbackPeriod_affectsConvergenceSpeed() public {
        // Deploy two fresh hooks with different lookback periods
        Alphix shortHook = _deployFreshAlphixStack();
        Alphix longHook = _deployFreshAlphixStack();

        uint256 initialTarget = 1e18;
        uint256 constantCurrentRatio = 2e18;

        // Initialize both with same initial state but different lookback params
        (PoolKey memory shortKey, PoolId shortPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTarget,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            shortHook,
            shortLookbackParams
        );
        (PoolKey memory longKey, PoolId longPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            initialTarget,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            longHook,
            longLookbackParams
        );

        uint256 shortNewTarget = initialTarget;
        uint256 longNewTarget = initialTarget;

        // Perform 3 pokes on each
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + longLookbackParams.minPeriod + 1);

            // Poke short lookback hook
            vm.recordLogs();
            vm.prank(owner);
            shortHook.poke(constantCurrentRatio);
            Vm.Log[] memory shortLogs = vm.getRecordedLogs();
            for (uint256 j = 0; j < shortLogs.length; j++) {
                if (shortLogs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (,,,, shortNewTarget) = abi.decode(shortLogs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }

            // Poke long lookback hook
            vm.recordLogs();
            vm.prank(owner);
            longHook.poke(constantCurrentRatio);
            Vm.Log[] memory longLogs = vm.getRecordedLogs();
            for (uint256 j = 0; j < longLogs.length; j++) {
                if (longLogs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (,,,, longNewTarget) = abi.decode(longLogs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }
        }

        // Short lookback should have converged more than long lookback
        uint256 shortProgress = shortNewTarget - initialTarget;
        uint256 longProgress = longNewTarget - initialTarget;

        assertTrue(shortProgress > longProgress, "Short lookback should converge faster");
        // Short lookback (7) has alpha = 2/8 = 0.25
        // Long lookback (365) has alpha = 2/366 ≈ 0.0055
        // After 3 pokes, short should have made ~4x more progress
        assertTrue(shortProgress > longProgress * 3, "Short lookback should be significantly faster");
    }

    /* ========================================================================== */
    /*                           CLAMPING TESTS                                   */
    /* ========================================================================== */

    /**
     * @notice Verify target ratio is clamped to maxCurrentRatio
     * @dev Use short lookback and poke repeatedly at max ratio until target converges to max
     */
    function test_poke_clampsTargetRatioToMax() public {
        Alphix freshHook = _deployFreshAlphixStack();

        // Use short lookback (7 days = minimum) for faster convergence
        // alpha = 2/(7+1) = 0.25
        DynamicFeeLib.PoolParams memory clampParams = shortLookbackParams;
        clampParams.maxCurrentRatio = 2e18; // Max of 2x

        uint256 initialTarget = 1e18; // Start at 1x

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            INITIAL_FEE, initialTarget, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, clampParams
        );

        // Poke repeatedly at max ratio to push target toward max
        // With alpha=0.25 and starting at 1e18, poking with 2e18:
        // After 1 poke: 1e18 + 0.25*(2e18-1e18) = 1.25e18
        // After 2 pokes: 1.25e18 + 0.25*(2e18-1.25e18) = 1.4375e18
        // Continue until target approaches max
        uint256 currentRatio = clampParams.maxCurrentRatio; // Poke at max valid ratio

        uint256 lastTarget = initialTarget;
        for (uint256 i = 0; i < 20; i++) {
            vm.warp(block.timestamp + clampParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(currentRatio);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (,,,, uint256 newTargetRatio) =
                        abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    lastTarget = newTargetRatio;

                    // Key assertion: target should NEVER exceed maxCurrentRatio
                    assertLe(newTargetRatio, clampParams.maxCurrentRatio, "Target should be clamped to max");
                    break;
                }
            }
        }

        // After many pokes, target should be very close to (or equal to) max
        // Due to EMA asymptotic convergence, it may not hit exactly max
        // but should be clamped if it ever tries to exceed
        assertTrue(lastTarget >= 1.95e18, "Target should converge close to max");
        assertLe(lastTarget, clampParams.maxCurrentRatio, "Target should never exceed max");
    }

    /**
     * @notice Verify target ratio never becomes zero even with extreme low inputs
     * @dev Target ratio of 0 would break fee calculations, so it's clamped to 1
     */
    function test_poke_targetRatioNeverBecomesZero() public {
        Alphix freshHook = _deployFreshAlphixStack();

        // Use very small initial target ratio and short lookback for aggressive EMA
        DynamicFeeLib.PoolParams memory extremeParams = shortLookbackParams;

        // Start with a small but valid target ratio
        uint256 smallInitialTarget = 1e15; // 0.001 in WAD terms

        (PoolKey memory testKey,) = _initPoolWithHookAndParams(
            INITIAL_FEE,
            smallInitialTarget,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            extremeParams
        );

        vm.warp(block.timestamp + extremeParams.minPeriod + 1);

        // Poke with minimum valid ratio (1) to push target toward zero
        uint256 minRatio = 1;

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(minRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,,,, uint256 newTargetRatio) = abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Key assertion: target ratio should NEVER be zero
                assertTrue(newTargetRatio > 0, "Target ratio should never become zero");
                break;
            }
        }
    }

    /* ========================================================================== */
    /*                           EMA CALCULATION TESTS                            */
    /* ========================================================================== */

    /**
     * @notice Verify EMA calculation accuracy
     * @dev Tests the library function directly
     */
    function test_ema_calculationAccuracy() public pure {
        uint256 currentRatio = 2e18;
        uint256 oldTargetRatio = 1e18;
        uint24 lookbackPeriod = 7;

        // Expected: alpha = 2/(7+1) = 0.25
        // newTarget = old + alpha * (current - old)
        // newTarget = 1e18 + 0.25 * (2e18 - 1e18) = 1e18 + 0.25e18 = 1.25e18
        uint256 expectedNewTarget = 1.25e18;

        uint256 actualNewTarget = DynamicFeeLib.ema(currentRatio, oldTargetRatio, lookbackPeriod);

        assertEq(actualNewTarget, expectedNewTarget, "EMA calculation should match expected");
    }

    /**
     * @notice Verify EMA with lookback=1 equals current value
     * @dev Alpha becomes 1.0 when lookback=1, so EMA equals current
     */
    function test_ema_lookbackOneEqualsCurrent() public pure {
        uint256 currentRatio = 2e18;
        uint256 oldTargetRatio = 1e18;
        uint24 lookbackPeriod = 1;

        // Alpha = 2/(1+1) = 1.0, so new = old + 1.0 * (current - old) = current
        uint256 newTarget = DynamicFeeLib.ema(currentRatio, oldTargetRatio, lookbackPeriod);

        assertEq(newTarget, currentRatio, "EMA with lookback=1 should equal current");
    }

    /**
     * @notice Verify EMA is monotonic with respect to current value
     * @dev Higher current should produce higher EMA result
     */
    function test_ema_monotonicWithCurrent() public pure {
        uint256 oldTargetRatio = 1e18;
        uint24 lookbackPeriod = 30;

        uint256 current1 = 1.5e18;
        uint256 current2 = 2e18;

        uint256 result1 = DynamicFeeLib.ema(current1, oldTargetRatio, lookbackPeriod);
        uint256 result2 = DynamicFeeLib.ema(current2, oldTargetRatio, lookbackPeriod);

        assertTrue(result2 > result1, "Higher current should produce higher EMA");
    }
}
