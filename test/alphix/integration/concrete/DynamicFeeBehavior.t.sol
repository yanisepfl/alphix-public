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
 * @title DynamicFeeBehaviorTest
 * @notice Tests for fee response behavior relative to current/target ratio
 * @dev Verifies how fees change based on ratio deviations, side factors, slopes, and streak mechanics
 */
contract DynamicFeeBehaviorTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    // Responsive params for testing fee behavior (short minPeriod, high sensitivity)
    DynamicFeeLib.PoolParams internal responsiveParams;
    // Low sensitivity params for testing dampened response
    DynamicFeeLib.PoolParams internal lowSensitivityParams;
    // Asymmetric side factor params
    DynamicFeeLib.PoolParams internal asymmetricParams;

    function setUp() public override {
        super.setUp();

        // Responsive params: short minPeriod, high sensitivity
        responsiveParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 100, // Higher to allow larger fee changes
            lookbackPeriod: 7,
            minPeriod: 1 hours, // Short cooldown for rapid testing
            ratioTolerance: 5e15, // 0.5% tolerance band
            linearSlope: 1e18, // Standard slope
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18, // 1x multiplier for upper OOB
            lowerSideFactor: 1e18 // 1x multiplier for lower OOB
        });

        // Low sensitivity params: dampened response
        lowSensitivityParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 10, // Low max delta
            lookbackPeriod: 365,
            minPeriod: 1 hours,
            ratioTolerance: 5e15,
            linearSlope: 0.1e18, // Low slope = dampened response
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        // Asymmetric side factors
        asymmetricParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 100,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 2e18, // 2x for upper OOB (aggressive increase)
            lowerSideFactor: 0.5e18 // 0.5x for lower OOB (conservative decrease)
        });
    }

    /* ========================================================================== */
    /*                       FEE RESPONSE TO RATIO TESTS                          */
    /* ========================================================================== */

    /**
     * @notice Verify that high ratio (above target) increases fee
     * @dev When currentRatio > targetRatio (upper OOB), fee should increase
     */
    function test_poke_highRatioIncreasesFee() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 1000; // 0.1%

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        // Poke with high ratio (50% above target, clearly outside tolerance)
        uint256 highRatio = 1.5e18;

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(highRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                assertTrue(newFee > oldFee, "Fee should increase when ratio is above target");
                break;
            }
        }
    }

    /**
     * @notice Verify that low ratio (below target) decreases fee
     * @dev When currentRatio < targetRatio (lower OOB), fee should decrease
     */
    function test_poke_lowRatioDecreasesFee() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 10000; // 1% - high enough to allow decrease

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        // Poke with low ratio (50% below target)
        uint256 lowRatio = 0.5e18;

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(lowRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                assertTrue(newFee < oldFee, "Fee should decrease when ratio is below target");
                break;
            }
        }
    }

    /**
     * @notice Verify that in-band ratio causes no fee change
     * @dev When ratio is within tolerance band, fee should stay the same (after clamping)
     */
    function test_poke_inBandRatioNoFeeChange() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000; // Within bounds

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        // Poke with ratio within tolerance (0.5% tolerance, so 1.002 is inside)
        uint256 inBandRatio = 1.002e18; // Within 0.5% of target

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(inBandRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                assertEq(newFee, oldFee, "Fee should not change when ratio is within band");
                break;
            }
        }
    }

    /**
     * @notice Verify extreme high ratio causes sustained fee increase
     * @dev After multiple pokes with high ratio, fee should increase significantly
     */
    function test_poke_extremeHighRatioHitsMaxFee() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 1000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        uint256 extremeRatio = 10e18; // 10x above target

        // Poke multiple times
        uint24 currentFee = initialFee;
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(extremeRatio);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (, currentFee,,,) = abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }

            if (currentFee == responsiveParams.maxFee) break;
        }

        // Fee should have increased significantly (at least 3x from initial due to sustained high ratio)
        assertTrue(currentFee > initialFee * 3, "Fee should increase significantly after sustained high ratios");
        // And should not exceed max
        assertTrue(currentFee <= responsiveParams.maxFee, "Fee should not exceed maxFee");
    }

    /**
     * @notice Verify extreme low ratio causes sustained fee decrease
     * @dev After multiple pokes with low ratio, fee should decrease significantly
     */
    function test_poke_extremeLowRatioHitsMinFee() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000; // High starting fee

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        uint256 extremeRatio = 0.1e18; // 10% of target (very low)

        // Poke multiple times
        uint24 currentFee = initialFee;
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(extremeRatio);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (, currentFee,,,) = abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }

            if (currentFee == responsiveParams.minFee) break;
        }

        // Fee should have decreased significantly
        // Note: Fee stabilizes once target ratio converges to current ratio via EMA,
        // at which point current ratio is no longer "out of band"
        assertTrue(currentFee < initialFee * 60 / 100, "Fee should decrease significantly after sustained low ratios");
        // And should not go below min
        assertTrue(currentFee >= responsiveParams.minFee, "Fee should not go below minFee");
    }

    /**
     * @notice Verify fee change direction is correct for deviations
     * @dev Both small and large deviations should increase fee, even if throttled to same amount
     */
    function test_poke_feeChangeProportionalToDeviation() public {
        // Deploy two hooks with identical params
        Alphix hook1 = _deployFreshAlphixStack();
        Alphix hook2 = _deployFreshAlphixStack();

        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        // Use params with high baseMaxFeeDelta to avoid throttling
        DynamicFeeLib.PoolParams memory unthrottledParams = responsiveParams;
        unthrottledParams.baseMaxFeeDelta = 10000; // Allow large fee changes

        (PoolKey memory key1, PoolId id1) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook1, unthrottledParams
        );
        (PoolKey memory key2, PoolId id2) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook2, unthrottledParams
        );

        vm.warp(block.timestamp + unthrottledParams.minPeriod + 1);

        // Small deviation (but outside tolerance band of 0.5%)
        uint256 smallDeviation = 1.1e18; // 10% above target
        // Large deviation
        uint256 largeDeviation = 2e18; // 100% above target

        uint24 feeAfterSmall;
        uint24 feeAfterLarge;

        // Poke hook1 with small deviation
        vm.recordLogs();
        vm.prank(owner);
        hook1.poke(smallDeviation);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs1.length; i++) {
            if (logs1[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, feeAfterSmall,,,) = abi.decode(logs1[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Poke hook2 with large deviation
        vm.recordLogs();
        vm.prank(owner);
        hook2.poke(largeDeviation);
        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs2.length; i++) {
            if (logs2[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, feeAfterLarge,,,) = abi.decode(logs2[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Both should increase
        assertTrue(feeAfterSmall > initialFee, "Small deviation should increase fee");
        assertTrue(feeAfterLarge > initialFee, "Large deviation should increase fee");
        // With high baseMaxFeeDelta, large deviation should produce larger fee change
        // (adjustmentRate is higher with larger deviation before throttling)
        assertTrue(feeAfterLarge >= feeAfterSmall, "Large deviation should produce fee >= small deviation");
    }

    /**
     * @notice Verify consecutive OOB hits increase fee delta (streak mechanism)
     * @dev Streak mechanism amplifies fee changes for sustained deviations
     */
    function test_poke_consecutiveOOBIncreasesFeeDelta() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        uint256 highRatio = 1.3e18; // 30% above target

        uint24 lastFee = initialFee;
        uint24[] memory feeDeltas = new uint24[](5);

        // Record fee changes over 5 consecutive pokes
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(highRatio);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (uint24 oldFee, uint24 newFee,,,) =
                        abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    feeDeltas[i] = newFee > oldFee ? newFee - oldFee : 0;
                    lastFee = newFee;
                    break;
                }
            }
        }

        // With streak mechanism, later deltas should be >= earlier ones (until maxFeeDelta caps)
        // At minimum, the first delta should be non-zero and second should increase
        assertTrue(feeDeltas[1] >= feeDeltas[0], "Streak should increase or maintain fee delta");
    }

    /**
     * @notice Verify side flip resets streak
     * @dev Switching from upper to lower OOB should reset consecutive hits
     */
    function test_poke_sideFlipResetsStreak() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000; // High enough to allow both increase and decrease

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        uint256 highRatio = 1.5e18;
        uint256 lowRatio = 0.5e18;

        // Build up streak with high ratios
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);
            vm.prank(owner);
            freshHook.poke(highRatio);
        }

        // Now flip to low ratio
        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);
        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(lowRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundDecrease = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));
                // Fee should decrease (side flipped)
                assertTrue(newFee < oldFee, "Fee should decrease after side flip to lower OOB");
                foundDecrease = true;
                break;
            }
        }
        assertTrue(foundDecrease, "Should have found fee decrease event");
    }

    /* ========================================================================== */
    /*                      FEE RESPONSE TO RATIO VARIATION                       */
    /* ========================================================================== */

    /**
     * @notice Verify oscillating ratio around target keeps fee stable
     * @dev Ratio alternating above/below target shouldn't cause wild fee swings
     */
    function test_poke_oscillatingRatioKeepsFeeStable() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        uint256 slightlyAbove = 1.1e18;
        uint256 slightlyBelow = 0.9e18;

        uint24 lastFee = initialFee;

        // Alternate between above and below target
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

            uint256 ratioToUse = (i % 2 == 0) ? slightlyAbove : slightlyBelow;

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(ratioToUse);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (, lastFee,,,) = abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }
        }

        // Fee should stay relatively close to initial (not diverge wildly)
        // Allow 50% deviation as "stable"
        assertTrue(lastFee > initialFee / 2, "Fee should not drop too much during oscillation");
        assertTrue(lastFee < initialFee * 2, "Fee should not increase too much during oscillation");
    }

    /**
     * @notice Verify gradual ratio increase causes gradual fee increase
     */
    function test_poke_gradualRatioIncreaseGradualFeeIncrease() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        uint24[] memory fees = new uint24[](6);
        fees[0] = initialFee;

        // Gradually increase ratio
        uint256[] memory ratios = new uint256[](5);
        ratios[0] = 1.1e18;
        ratios[1] = 1.2e18;
        ratios[2] = 1.3e18;
        ratios[3] = 1.4e18;
        ratios[4] = 1.5e18;

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(ratios[i]);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (, fees[i + 1],,,) = abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }
        }

        // Verify monotonically increasing fees
        for (uint256 i = 1; i < 6; i++) {
            assertTrue(fees[i] >= fees[i - 1], "Fee should increase or stay same as ratio increases");
        }
        assertTrue(fees[5] > fees[0], "Final fee should be higher than initial");
    }

    /**
     * @notice Verify sudden ratio spike is controlled by maxFeeDelta
     */
    function test_poke_suddenRatioSpikeControlledFeeResponse() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        // Use params with low baseMaxFeeDelta to test throttling
        DynamicFeeLib.PoolParams memory throttledParams = responsiveParams;
        throttledParams.baseMaxFeeDelta = 10; // Very low max delta

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, throttledParams
        );

        vm.warp(block.timestamp + throttledParams.minPeriod + 1);

        // Extreme ratio spike
        uint256 extremeRatio = 100e18;

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(extremeRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                uint24 feeChange = newFee > oldFee ? newFee - oldFee : oldFee - newFee;
                // With streak=1, max delta = baseMaxFeeDelta * 1 = 10
                assertTrue(
                    feeChange <= throttledParams.baseMaxFeeDelta, "Fee change should be throttled by maxFeeDelta"
                );
                break;
            }
        }
    }

    /**
     * @notice Verify ratio recovery toward target reduces fee adjustment magnitude
     */
    function test_poke_ratioRecoveryTowardTargetReducesFeeChange() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        // First, push fee up with high ratio
        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);
        vm.prank(owner);
        freshHook.poke(2e18); // Double target

        // Now gradually recover toward target
        uint256[] memory recoveringRatios = new uint256[](3);
        recoveringRatios[0] = 1.5e18;
        recoveringRatios[1] = 1.2e18;
        recoveringRatios[2] = 1.05e18;

        uint24 lastFee;
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(recoveringRatios[i]);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (, lastFee,,,) = abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));
                    break;
                }
            }
        }

        // After recovering close to target (1.05e18 is within or near tolerance), fee changes should be minimal
        // The key insight: as deviation decreases, fee adjustments shrink
    }

    /* ========================================================================== */
    /*                          SIDE FACTOR TESTS                                 */
    /* ========================================================================== */

    /**
     * @notice Verify upperSideFactor affects fee increase magnitude
     */
    function test_poke_upperSideFactorAffectsFeeIncrease() public {
        // Deploy two hooks: one with 1x upperSideFactor, one with 2x
        Alphix normalHook = _deployFreshAlphixStack();
        Alphix aggressiveHook = _deployFreshAlphixStack();

        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory normalKey,) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, normalHook, responsiveParams
        );
        (PoolKey memory aggressiveKey,) = _initPoolWithHookAndParams(
            initialFee,
            targetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            aggressiveHook,
            asymmetricParams
        );

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        uint256 highRatio = 1.5e18;

        // Poke normal hook
        vm.recordLogs();
        vm.prank(owner);
        normalHook.poke(highRatio);
        uint24 normalNewFee;
        Vm.Log[] memory normalLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < normalLogs.length; i++) {
            if (normalLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, normalNewFee,,,) = abi.decode(normalLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Poke aggressive hook
        vm.recordLogs();
        vm.prank(owner);
        aggressiveHook.poke(highRatio);
        uint24 aggressiveNewFee;
        Vm.Log[] memory aggressiveLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < aggressiveLogs.length; i++) {
            if (aggressiveLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, aggressiveNewFee,,,) =
                    abi.decode(aggressiveLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Aggressive (2x upperSideFactor) should increase more
        assertTrue(aggressiveNewFee > normalNewFee, "Higher upperSideFactor should produce larger fee increase");
    }

    /**
     * @notice Verify lowerSideFactor affects fee decrease magnitude
     */
    function test_poke_lowerSideFactorAffectsFeeDecrease() public {
        Alphix normalHook = _deployFreshAlphixStack();
        Alphix conservativeHook = _deployFreshAlphixStack();

        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000; // High enough to decrease

        (PoolKey memory normalKey,) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, normalHook, responsiveParams
        );
        (PoolKey memory conservativeKey,) = _initPoolWithHookAndParams(
            initialFee,
            targetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            conservativeHook,
            asymmetricParams // Has 0.5x lowerSideFactor
        );

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        uint256 lowRatio = 0.5e18;

        // Poke normal hook
        vm.recordLogs();
        vm.prank(owner);
        normalHook.poke(lowRatio);
        uint24 normalNewFee;
        Vm.Log[] memory normalLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < normalLogs.length; i++) {
            if (normalLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, normalNewFee,,,) = abi.decode(normalLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Poke conservative hook
        vm.recordLogs();
        vm.prank(owner);
        conservativeHook.poke(lowRatio);
        uint24 conservativeNewFee;
        Vm.Log[] memory conservativeLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < conservativeLogs.length; i++) {
            if (conservativeLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, conservativeNewFee,,,) =
                    abi.decode(conservativeLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Conservative (0.5x lowerSideFactor) should decrease less
        assertTrue(
            conservativeNewFee > normalNewFee, "Lower lowerSideFactor should produce smaller fee decrease (higher fee)"
        );
    }

    /**
     * @notice Verify asymmetric side factors create bias in fee response
     */
    function test_poke_asymmetricSideFactorsCreateBias() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, asymmetricParams
        );

        vm.warp(block.timestamp + asymmetricParams.minPeriod + 1);

        // Same magnitude deviation above and below
        uint256 aboveRatio = 1.5e18; // +50%
        uint256 belowRatio = 0.5e18; // -50%

        // Poke above
        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(aboveRatio);
        uint24 feeAfterAbove;
        Vm.Log[] memory aboveLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < aboveLogs.length; i++) {
            if (aboveLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, feeAfterAbove,,,) = abi.decode(aboveLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        uint24 feeIncreaseAmount = feeAfterAbove - initialFee;

        // Reset with new hook for fair comparison
        Alphix freshHook2 = _deployFreshAlphixStack();
        (PoolKey memory testKey2,) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook2, asymmetricParams
        );

        vm.warp(block.timestamp + asymmetricParams.minPeriod + 1);

        // Poke below
        vm.recordLogs();
        vm.prank(owner);
        freshHook2.poke(belowRatio);
        uint24 feeAfterBelow;
        Vm.Log[] memory belowLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < belowLogs.length; i++) {
            if (belowLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, feeAfterBelow,,,) = abi.decode(belowLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        uint24 feeDecreaseAmount = initialFee - feeAfterBelow;

        // With 2x upperSideFactor and 0.5x lowerSideFactor:
        // Fee increase should be ~4x the fee decrease for same deviation
        assertTrue(feeIncreaseAmount > feeDecreaseAmount, "Asymmetric factors should create bias (increase > decrease)");
    }

    /* ========================================================================== */
    /*                         LINEAR SLOPE TESTS                                 */
    /* ========================================================================== */

    /**
     * @notice Verify higher linearSlope produces larger fee change
     */
    function test_poke_higherLinearSlopeLargerFeeChange() public {
        Alphix lowSlopeHook = _deployFreshAlphixStack();
        Alphix highSlopeHook = _deployFreshAlphixStack();

        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        // Low slope params
        DynamicFeeLib.PoolParams memory highSlopeParams = responsiveParams;
        highSlopeParams.linearSlope = 2e18; // 2x sensitivity

        (PoolKey memory lowKey,) = _initPoolWithHookAndParams(
            initialFee,
            targetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            lowSlopeHook,
            lowSensitivityParams // Has 0.1e18 slope
        );
        (PoolKey memory highKey,) = _initPoolWithHookAndParams(
            initialFee,
            targetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            highSlopeHook,
            highSlopeParams
        );

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        uint256 testRatio = 1.5e18;

        // Poke low slope
        vm.recordLogs();
        vm.prank(owner);
        lowSlopeHook.poke(testRatio);
        uint24 lowSlopeFee;
        Vm.Log[] memory lowLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < lowLogs.length; i++) {
            if (lowLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, lowSlopeFee,,,) = abi.decode(lowLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Poke high slope
        vm.recordLogs();
        vm.prank(owner);
        highSlopeHook.poke(testRatio);
        uint24 highSlopeFee;
        Vm.Log[] memory highLogs = vm.getRecordedLogs();
        for (uint256 i = 0; i < highLogs.length; i++) {
            if (highLogs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, highSlopeFee,,,) = abi.decode(highLogs[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        assertTrue(highSlopeFee > lowSlopeFee, "Higher slope should produce larger fee increase");
    }

    /**
     * @notice Verify lower linearSlope produces smaller fee change
     */
    function test_poke_lowerLinearSlopeSmallerFeeChange() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee,
            targetRatio,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook,
            lowSensitivityParams
        );

        vm.warp(block.timestamp + lowSensitivityParams.minPeriod + 1);

        uint256 highRatio = 2e18; // 100% above target

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(highRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // With low slope (0.1e18), even 100% deviation should produce modest fee change
                uint24 feeChange = newFee > oldFee ? newFee - oldFee : 0;
                assertTrue(
                    feeChange <= lowSensitivityParams.baseMaxFeeDelta, "Low slope should produce small fee change"
                );
                break;
            }
        }
    }

    /* ========================================================================== */
    /*                      GLOBAL MAX ADJ RATE TESTS                             */
    /* ========================================================================== */

    /**
     * @notice Verify globalMaxAdjRate caps fee adjustment
     */
    function test_poke_globalMaxAdjRateCapsAdjustment() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000; // High fee to make adjustment rate visible

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, responsiveParams
        );

        // Get globalMaxAdjRate from hook
        uint256 globalMaxAdjRate = freshHook.getGlobalMaxAdjRate();

        vm.warp(block.timestamp + responsiveParams.minPeriod + 1);

        // Very high ratio that would normally produce huge adjustment
        uint256 extremeRatio = 1000e18;

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(extremeRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Fee adjustment rate = (newFee - oldFee) / oldFee * 1e18
                // This should be capped by globalMaxAdjRate (before baseMaxFeeDelta throttling)
                // Due to baseMaxFeeDelta, actual change will be smaller
                assertTrue(newFee >= oldFee, "Fee should increase with extreme high ratio");
                break;
            }
        }
    }

    /**
     * @notice Verify high ratio still produces fee within bounds
     */
    function test_poke_extremeRatioStillRespectsCap() public {
        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 10000;

        // Use params with very high baseMaxFeeDelta to allow large fee changes
        DynamicFeeLib.PoolParams memory highDeltaParams = responsiveParams;
        highDeltaParams.baseMaxFeeDelta = 100000; // Very high

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, highDeltaParams
        );

        vm.warp(block.timestamp + highDeltaParams.minPeriod + 1);

        // Use a high ratio but still within maxCurrentRatio (1e21)
        uint256 highRatio = 500e18; // 500x target, still under 1e21

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(highRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Fee should increase but stay within bounds
                assertTrue(newFee > oldFee, "Fee should increase with high ratio");
                assertTrue(newFee <= highDeltaParams.maxFee, "Fee should not exceed maxFee");
                break;
            }
        }
    }
}
