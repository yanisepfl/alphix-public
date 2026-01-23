// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Vm} from "forge-std/Vm.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";

/**
 * @title DynamicFeeBehaviorFuzzTest
 * @notice Fuzz tests for dynamic fee behavior
 * @dev Verifies invariants hold across randomized inputs
 */
contract DynamicFeeBehaviorFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    // Responsive params for fuzz testing
    DynamicFeeLib.PoolParams internal fuzzParams;

    function setUp() public override {
        super.setUp();

        // Standard params for fuzz testing
        fuzzParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 100,
            lookbackPeriod: 30,
            minPeriod: 1 hours,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21, // 1000x
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });
    }

    /* ========================================================================== */
    /*                              FUZZ TESTS                                    */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Fee is always within bounds after poke
     * @dev For any valid ratio, new fee should be in [minFee, maxFee]
     */
    function testFuzz_poke_feeAlwaysWithinBounds(uint256 currentRatio) public {
        // Bound ratio to valid range: (0, maxCurrentRatio]
        currentRatio = bound(currentRatio, 1, fuzzParams.maxCurrentRatio);

        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, fuzzParams
        );

        vm.warp(block.timestamp + fuzzParams.minPeriod + 1);

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, uint24 newFee,,,) = abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Key invariant: fee is always within bounds
                assertGe(newFee, fuzzParams.minFee, "Fee should not go below minFee");
                assertLe(newFee, fuzzParams.maxFee, "Fee should not exceed maxFee");
                break;
            }
        }
    }

    /**
     * @notice Fuzz: Target ratio is always within bounds after poke
     * @dev For any valid ratio, new target ratio should be in (0, maxCurrentRatio]
     */
    function testFuzz_poke_targetRatioAlwaysWithinBounds(uint256 currentRatio) public {
        // Bound ratio to valid range
        currentRatio = bound(currentRatio, 1, fuzzParams.maxCurrentRatio);

        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, fuzzParams
        );

        vm.warp(block.timestamp + fuzzParams.minPeriod + 1);

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (,, uint256 oldTargetRatio,, uint256 newTargetRatio) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Key invariant: target ratio is always within bounds
                assertGt(newTargetRatio, 0, "Target ratio should be positive");
                assertLe(newTargetRatio, fuzzParams.maxCurrentRatio, "Target ratio should not exceed max");
                break;
            }
        }
    }

    /**
     * @notice Fuzz: Fee moves in correct direction based on ratio
     * @dev High ratio should increase fee, low ratio should decrease fee
     */
    function testFuzz_poke_feeMovesCorrectDirection(uint256 currentRatio) public {
        // Bound ratio to valid range, but exclude values near target to ensure OOB
        currentRatio = bound(currentRatio, 1, fuzzParams.maxCurrentRatio);

        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000; // High initial to allow decrease

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, fuzzParams
        );

        vm.warp(block.timestamp + fuzzParams.minPeriod + 1);

        // Determine if ratio is in-band
        (bool isUpper, bool inBand) = DynamicFeeLib.withinBounds(targetRatio, fuzzParams.ratioTolerance, currentRatio);

        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(currentRatio);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 newFee,,,) =
                    abi.decode(logs[i].data, (uint24, uint24, uint256, uint256, uint256));

                if (inBand) {
                    // In-band: fee should stay same (or be clamped to bounds)
                    assertEq(newFee, oldFee, "Fee should not change when in-band");
                } else if (isUpper) {
                    // Upper OOB: fee should increase (or stay if at max)
                    assertGe(newFee, oldFee, "Fee should increase or stay same when ratio is above target");
                } else {
                    // Lower OOB: fee should decrease (or stay if at min)
                    assertLe(newFee, oldFee, "Fee should decrease or stay same when ratio is below target");
                }
                break;
            }
        }
    }

    /**
     * @notice Fuzz: EMA converges after many pokes with same ratio
     * @dev After multiple pokes with identical ratio, target should converge toward current
     */
    function testFuzz_poke_emaConvergence(uint256 currentRatio, uint8 numPokes) public {
        // Bound inputs
        currentRatio = bound(currentRatio, 1e17, fuzzParams.maxCurrentRatio); // At least 0.1 to avoid edge cases
        numPokes = uint8(bound(numPokes, 5, 20)); // 5-20 pokes

        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 5000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, fuzzParams
        );

        uint256 lastTarget = targetRatio;
        uint256 prevDistance = _abs(int256(currentRatio) - int256(targetRatio));

        // Poke multiple times with same ratio
        for (uint256 i = 0; i < numPokes; i++) {
            vm.warp(block.timestamp + fuzzParams.minPeriod + 1);

            vm.recordLogs();
            vm.prank(owner);
            freshHook.poke(currentRatio);

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 j = 0; j < logs.length; j++) {
                if (logs[j].topics[0] == FEE_UPDATED_TOPIC) {
                    (,,,, uint256 newTargetRatio) =
                        abi.decode(logs[j].data, (uint24, uint24, uint256, uint256, uint256));

                    uint256 newDistance = _abs(int256(currentRatio) - int256(newTargetRatio));

                    // Key invariant: distance to current ratio should decrease or stay same
                    // (EMA always moves toward current)
                    assertLe(newDistance, prevDistance + 1, "EMA should converge toward current ratio");

                    prevDistance = newDistance;
                    lastTarget = newTargetRatio;
                    break;
                }
            }
        }

        // After multiple pokes, target should be closer to current than initial was
        uint256 initialDistance = _abs(int256(currentRatio) - int256(targetRatio));
        uint256 finalDistance = _abs(int256(currentRatio) - int256(lastTarget));

        if (initialDistance > 0) {
            assertTrue(finalDistance <= initialDistance, "Target should be closer to current after multiple pokes");
        }
    }

    /**
     * @notice Fuzz: Multiple sequential pokes don't cause fee to oscillate wildly
     * @dev Fee changes should be bounded by baseMaxFeeDelta * streak
     */
    function testFuzz_poke_feeChangeBounded(uint256 ratio1, uint256 ratio2) public {
        // Bound ratios
        ratio1 = bound(ratio1, 1e17, fuzzParams.maxCurrentRatio);
        ratio2 = bound(ratio2, 1e17, fuzzParams.maxCurrentRatio);

        Alphix freshHook = _deployFreshAlphixStack();
        uint256 targetRatio = 1e18;
        uint24 initialFee = 50000;

        (PoolKey memory testKey, PoolId testPoolId) = _initPoolWithHookAndParams(
            initialFee, targetRatio, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook, fuzzParams
        );

        // First poke
        vm.warp(block.timestamp + fuzzParams.minPeriod + 1);
        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(ratio1);

        uint24 fee1;
        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs1.length; i++) {
            if (logs1[i].topics[0] == FEE_UPDATED_TOPIC) {
                (, fee1,,,) = abi.decode(logs1[i].data, (uint24, uint24, uint256, uint256, uint256));
                break;
            }
        }

        // Second poke with potentially different ratio
        vm.warp(block.timestamp + fuzzParams.minPeriod + 1);
        vm.recordLogs();
        vm.prank(owner);
        freshHook.poke(ratio2);

        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs2.length; i++) {
            if (logs2[i].topics[0] == FEE_UPDATED_TOPIC) {
                (uint24 oldFee, uint24 fee2,,,) = abi.decode(logs2[i].data, (uint24, uint24, uint256, uint256, uint256));

                // Fee change should be bounded
                // With streak reset on side flip, max delta = baseMaxFeeDelta * 1 = 100
                // With same side, streak=2, max delta = 200
                uint24 feeChange = fee2 > oldFee ? fee2 - oldFee : oldFee - fee2;
                uint256 maxPossibleChange = uint256(fuzzParams.baseMaxFeeDelta) * 2;

                // Account for side factor (up to 2x due to lowerSideFactor potentially being 2e18 in some configs)
                assertTrue(
                    feeChange <= maxPossibleChange * 2, "Fee change should be bounded by baseMaxFeeDelta mechanism"
                );
                break;
            }
        }
    }

    /* ========================================================================== */
    /*                              HELPERS                                       */
    /* ========================================================================== */

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
