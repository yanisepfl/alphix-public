// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";

/**
 * @title AlphixLogicPoolManagementTest
 * @author Alphix
 * @notice Tests for pool activation, configuration, unified params management and related access control
 * @dev Updated to unified PoolTypeParams and ratio-aware hook/logic flow
 */
contract AlphixLogicPoolManagementTest is BaseAlphixTest {
    // Constants for boundary testing
    uint24 constant MIN_FEE = 1;
    uint256 constant MIN_PERIOD = 1 hours;
    uint24 constant MIN_LOOKBACK_PERIOD = 7;
    uint24 constant MAX_LOOKBACK_PERIOD = 365;
    uint256 constant MIN_RATIO_TOLERANCE = 1e15;
    uint256 constant MIN_LINEAR_SLOPE = 1e17;
    uint256 constant ONE_WAD = 1e18;
    uint256 constant TEN_WAD = 1e19;
    uint256 constant MAX_CURRENT_RATIO = 1e24;

    /* TESTS */

    /**
     * @notice activateAndConfigurePool succeeds on a fresh pool and writes config + activates pool
     */
    function test_activateAndConfigurePool_success_onFreshPool() public {
        // Create a brand-new pool bound to the same hook, unconfigured on Alphix side
        (PoolKey memory freshKey, PoolId freshPoolId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        // Ensure Alphix did not configure that new pool yet
        IAlphixLogic.PoolConfig memory pre = logic.getPoolConfig(freshPoolId);
        assertFalse(pre.isConfigured, "fresh pool should be unconfigured");

        // Configure + activate via logic (hook caller)
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Validate config is written
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(freshPoolId);
        assertEq(config.initialFee, INITIAL_FEE, "initialFee mismatch");
        assertEq(config.initialTargetRatio, INITIAL_TARGET_RATIO, "initialTargetRatio mismatch");
        assertEq(uint8(config.poolType), uint8(IAlphixLogic.PoolType.STANDARD), "poolType mismatch");
        assertTrue(config.isConfigured, "isConfigured false");

        // Validate pool is active by invoking a guarded path that requires activation (no revert expected)
        vm.prank(address(hook));
        logic.beforeAddLiquidity(
            user1, freshKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
        );
    }

    /**
     * @notice activateAndConfigurePool reverts for non-hook callers
     */
    function test_activateAndConfigurePool_revertsOnNonHook() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice activateAndConfigurePool reverts when logic is paused
     */
    function test_activateAndConfigurePool_revertsWhenPaused() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice activateAndConfigurePool reverts if pool is already configured
     */
    function test_activateAndConfigurePool_revertsOnAlreadyConfigured() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolAlreadyConfigured.selector);
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice activatePool succeeds after prior configuration and deactivation
     */
    function test_activatePool_success() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(address(hook));
        logic.deactivatePool(freshKey);

        vm.prank(address(hook));
        logic.activatePool(freshKey);

        vm.prank(address(hook));
        logic.beforeAddLiquidity(
            user1, freshKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
        );
    }

    /**
     * @notice activatePool reverts for non-hook callers
     */
    function test_activatePool_revertsOnNonHook() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.activatePool(freshKey);
    }

    /**
     * @notice activatePool reverts when logic is paused
     */
    function test_activatePool_revertsWhenPaused() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        logic.activatePool(freshKey);
    }

    /**
     * @notice activatePool reverts when pool was never configured
     */
    function test_activatePool_revertsOnUnconfiguredPool() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolNotConfigured.selector);
        logic.activatePool(freshKey);
    }

    /**
     * @notice deactivatePool succeeds and guarded paths revert with PoolPaused afterwards
     */
    function test_deactivatePool_success() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(address(hook));
        logic.deactivatePool(freshKey);

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        logic.beforeAddLiquidity(
            user1, freshKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
        );

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        logic.beforeRemoveLiquidity(
            user1, freshKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1000, salt: 0}), ""
        );
    }

    /**
     * @notice deactivatePool reverts for non-hook callers
     */
    function test_deactivatePool_revertsOnNonHook() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.deactivatePool(freshKey);
    }

    /**
     * @notice deactivatePool reverts when logic is paused
     */
    function test_deactivatePool_revertsWhenPaused() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        logic.deactivatePool(freshKey);
    }

    /* Unified Params: setter/getter and validation */

    /**
     * @notice setPoolTypeParams updates unified params and emits event for STANDARD type
     */
    function test_setPoolTypeParams_success() public {
        DynamicFeeLib.PoolTypeParams memory newP = standardParams;
        newP.minFee = 600;
        newP.maxFee = 12000;

        vm.prank(address(hook));
        // Event content depends on interface; here we assert post-state
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newP);

        DynamicFeeLib.PoolTypeParams memory got = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minFee, newP.minFee, "minFee mismatch");
        assertEq(got.maxFee, newP.maxFee, "maxFee mismatch");
        assertEq(got.baseMaxFeeDelta, newP.baseMaxFeeDelta, "baseMaxFeeDelta mismatch");
        assertEq(got.lookbackPeriod, newP.lookbackPeriod, "lookbackPeriod mismatch");
        assertEq(got.minPeriod, newP.minPeriod, "minPeriod mismatch");
        assertEq(got.ratioTolerance, newP.ratioTolerance, "ratioTolerance mismatch");
        assertEq(got.linearSlope, newP.linearSlope, "linearSlope mismatch");
        assertEq(got.upperSideFactor, newP.upperSideFactor, "upperSideFactor mismatch");
        assertEq(got.lowerSideFactor, newP.lowerSideFactor, "lowerSideFactor mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when minFee > maxFee
     */
    function test_setPoolTypeParams_revertsOnMinGtMax() public {
        DynamicFeeLib.PoolTypeParams memory bad = standardParams;
        bad.minFee = bad.maxFee + 1;

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, bad.minFee, bad.maxFee));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, bad);
    }

    /**
     * @notice setPoolTypeParams succeeds when minFee == maxFee (edge case)
     */
    function test_setPoolTypeParams_successOnMinEqMax() public {
        DynamicFeeLib.PoolTypeParams memory edge = standardParams;
        edge.minFee = 5000;
        edge.maxFee = 5000;

        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, edge);

        DynamicFeeLib.PoolTypeParams memory got = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minFee, edge.minFee, "minFee mismatch");
        assertEq(got.maxFee, edge.maxFee, "maxFee mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when maxFee exceeds LPFeeLibrary.MAX_LP_FEE
     */
    function test_setPoolTypeParams_revertsOnExcessiveMaxFee() public {
        DynamicFeeLib.PoolTypeParams memory bad = standardParams;
        bad.maxFee = uint24(LPFeeLibrary.MAX_LP_FEE + 1);

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, bad.minFee, bad.maxFee));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, bad);
    }

    /**
     * @notice setPoolTypeParams succeeds when maxFee == LPFeeLibrary.MAX_LP_FEE (edge case)
     */
    function test_setPoolTypeParams_successOnMaxFeeAtLimit() public {
        DynamicFeeLib.PoolTypeParams memory edge = standardParams;
        edge.maxFee = uint24(LPFeeLibrary.MAX_LP_FEE);

        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, edge);

        DynamicFeeLib.PoolTypeParams memory got = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.maxFee, edge.maxFee, "maxFee mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when baseMaxFeeDelta is out of range
     */
    function test_setPoolTypeParams_revertsOnBaseMaxFeeDeltaBounds() public {
        // Too low
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.baseMaxFeeDelta = 0;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.baseMaxFeeDelta = uint24(LPFeeLibrary.MAX_LP_FEE + 1);
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at baseMaxFeeDelta boundary values (edge cases)
     */
    function test_setPoolTypeParams_successOnBaseMaxFeeDeltaBounds() public {
        // At minimum
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.baseMaxFeeDelta = MIN_FEE;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.baseMaxFeeDelta, minEdge.baseMaxFeeDelta, "min baseMaxFeeDelta mismatch");

        // At maximum
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.baseMaxFeeDelta = uint24(LPFeeLibrary.MAX_LP_FEE);
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.baseMaxFeeDelta, maxEdge.baseMaxFeeDelta, "max baseMaxFeeDelta mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when minPeriod < 1 hour
     */
    function test_setPoolTypeParams_revertsOnMinPeriod() public {
        DynamicFeeLib.PoolTypeParams memory bad = standardParams;
        bad.minPeriod = 1 hours - 1; // must be >= 1 hour

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, bad);
    }

    /**
     * @notice setPoolTypeParams succeeds when minPeriod == 1 hour (edge case)
     */
    function test_setPoolTypeParams_successOnMinPeriodAtBoundary() public {
        DynamicFeeLib.PoolTypeParams memory edge = standardParams;
        edge.minPeriod = MIN_PERIOD; // exactly at minimum

        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, edge);

        DynamicFeeLib.PoolTypeParams memory got = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minPeriod, edge.minPeriod, "minPeriod mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when lookbackPeriod not in [7, 365]
     */
    function test_setPoolTypeParams_revertsOnLookbackPeriod() public {
        // Too low
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.lookbackPeriod = 6; // must be > 6
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.lookbackPeriod = 366; // must be < 366
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at lookbackPeriod boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnLookbackPeriodBounds() public {
        // At minimum boundary
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.lookbackPeriod = MIN_LOOKBACK_PERIOD;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.lookbackPeriod, minEdge.lookbackPeriod, "min lookbackPeriod mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.lookbackPeriod = MAX_LOOKBACK_PERIOD;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.lookbackPeriod, maxEdge.lookbackPeriod, "max lookbackPeriod mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when ratioTolerance not in [1e15, 1e19]
     */
    function test_setPoolTypeParams_revertsOnRatioTolerance() public {
        // Too low
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.ratioTolerance = 1e14;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.ratioTolerance = 1e20;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at ratioTolerance boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnRatioToleranceBounds() public {
        // At minimum boundary
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.ratioTolerance = MIN_RATIO_TOLERANCE;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.ratioTolerance, minEdge.ratioTolerance, "min ratioTolerance mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.ratioTolerance = TEN_WAD;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.ratioTolerance, maxEdge.ratioTolerance, "max ratioTolerance mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when linearSlope not in [1e17, 1e19]
     */
    function test_setPoolTypeParams_revertsOnLinearSlope() public {
        // Too low
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.linearSlope = 1e16;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.linearSlope = 1e20;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at linearSlope boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnLinearSlopeBounds() public {
        // At minimum boundary
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.linearSlope = MIN_LINEAR_SLOPE;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.linearSlope, minEdge.linearSlope, "min linearSlope mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.linearSlope = TEN_WAD;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.linearSlope, maxEdge.linearSlope, "max linearSlope mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when side factors not in [1e18, 1e19]
     */
    function test_setPoolTypeParams_revertsOnSideFactors() public {
        // Too low
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.upperSideFactor = 1e18 - 1;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.lowerSideFactor = 1e19 + 1;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at side factor boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnSideFactorBounds() public {
        // At minimum boundaries
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.upperSideFactor = ONE_WAD;
        minEdge.lowerSideFactor = ONE_WAD;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.upperSideFactor, minEdge.upperSideFactor, "min upperSideFactor mismatch");
        assertEq(gotMin.lowerSideFactor, minEdge.lowerSideFactor, "min lowerSideFactor mismatch");

        // At maximum boundaries
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.upperSideFactor = TEN_WAD;
        maxEdge.lowerSideFactor = TEN_WAD;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.upperSideFactor, maxEdge.upperSideFactor, "max upperSideFactor mismatch");
        assertEq(gotMax.lowerSideFactor, maxEdge.lowerSideFactor, "max lowerSideFactor mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when maxCurrentRatio is out of bounds
     */
    function test_setPoolTypeParams_revertsOnMaxCurrentRatioBounds() public {
        // Too low (zero)
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.maxCurrentRatio = 0;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.maxCurrentRatio = MAX_CURRENT_RATIO + 1;
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at maxCurrentRatio boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnMaxCurrentRatioBounds() public {
        // At minimum boundary (1 wei above 0)
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.maxCurrentRatio = 1;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.maxCurrentRatio, minEdge.maxCurrentRatio, "min maxCurrentRatio mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.maxCurrentRatio = MAX_CURRENT_RATIO;
        vm.prank(address(hook));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.maxCurrentRatio, maxEdge.maxCurrentRatio, "max maxCurrentRatio mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts for non-hook callers
     */
    function test_setPoolTypeParams_revertsOnNonHook() public {
        DynamicFeeLib.PoolTypeParams memory newP = standardParams;
        newP.minFee = 700;

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newP);
    }

    /**
     * @notice setPoolTypeParams reverts when logic is paused
     */
    function test_setPoolTypeParams_revertsWhenPaused() public {
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        DynamicFeeLib.PoolTypeParams memory newP = standardParams;
        newP.minFee = 700;

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newP);
    }

    /* GETTERS */

    /**
     * @notice getPoolConfig returns the configured values for a pool
     */
    function test_getPoolConfig() public {
        (PoolKey memory freshKey, PoolId freshId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.VOLATILE);

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(freshId);
        assertEq(config.initialFee, INITIAL_FEE, "initialFee mismatch");
        assertEq(config.initialTargetRatio, INITIAL_TARGET_RATIO, "initialTargetRatio mismatch");
        assertEq(uint8(config.poolType), uint8(IAlphixLogic.PoolType.VOLATILE), "poolType mismatch");
        assertTrue(config.isConfigured, "isConfigured false");
    }

    /**
     * @notice getPoolConfig returns zeroed config for an unconfigured pool
     */
    function test_getPoolConfig_unconfiguredPool() public {
        (, PoolId freshId) = _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(freshId);
        assertEq(config.initialFee, 0, "initialFee should be 0");
        assertEq(config.initialTargetRatio, 0, "initialTargetRatio should be 0");
        assertEq(uint8(config.poolType), uint8(IAlphixLogic.PoolType.STABLE), "default poolType should be STABLE");
        assertFalse(config.isConfigured, "isConfigured should be false");
    }

    /* CURRENT RATIO CHECKING LOGIC TESTS */

    /**
     * @notice computeFeeAndTargetRatio succeeds when currentRatio is within pool's maxCurrentRatio limit
     */
    function test_computeFeeAndTargetRatio_successOnValidCurrentRatio() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time past cooldown period
        vm.warp(block.timestamp + 2 days);

        // Derive a safe in-bounds currentRatio from configured params
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        uint256 validCurrentRatio = pp.maxCurrentRatio > 1 ? pp.maxCurrentRatio - 1 : 1;

        // Should succeed
        vm.prank(address(hook));
        (uint24 newFee, uint256 oldTargetRatio, uint256 newTargetRatio,) =
            logic.computeFeeAndTargetRatio(freshKey, validCurrentRatio);

        // Verify reasonable values are returned
        assertGe(uint256(newFee), uint256(pp.minFee), "newFee below minFee");
        assertLe(uint256(newFee), uint256(pp.maxFee), "newFee above maxFee");
        assertEq(oldTargetRatio, INITIAL_TARGET_RATIO, "oldTargetRatio should equal initial target ratio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }

    /**
     * @notice computeFeeAndTargetRatio reverts when currentRatio exceeds pool's maxCurrentRatio limit
     */
    function test_computeFeeAndTargetRatio_revertsOnExcessiveCurrentRatio() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time past cooldown period
        vm.warp(block.timestamp + 2 days);

        // Get the pool's maxCurrentRatio limit
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        uint256 excessiveCurrentRatio = pp.maxCurrentRatio + 1;

        // Should revert
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.InvalidRatioForPoolType.selector, IAlphixLogic.PoolType.STANDARD, excessiveCurrentRatio
            )
        );
        logic.computeFeeAndTargetRatio(freshKey, excessiveCurrentRatio);
    }

    /**
     * @notice computeFeeAndTargetRatio succeeds at maxCurrentRatio boundary
     */
    function test_computeFeeAndTargetRatio_successAtMaxCurrentRatioBoundary() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time past cooldown period
        vm.warp(block.timestamp + 2 days);

        // Get the pool's maxCurrentRatio limit and use exactly that value
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        uint256 boundaryCurrentRatio = pp.maxCurrentRatio;

        // Should succeed
        vm.prank(address(hook));
        (uint24 newFee, uint256 oldTargetRatio, uint256 newTargetRatio,) =
            logic.computeFeeAndTargetRatio(freshKey, boundaryCurrentRatio);

        // Verify reasonable values are returned
        assertGe(uint256(newFee), uint256(pp.minFee), "newFee below minFee");
        assertLe(uint256(newFee), uint256(pp.maxFee), "newFee above maxFee");
        assertEq(oldTargetRatio, INITIAL_TARGET_RATIO, "oldTargetRatio should equal initial target ratio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }
}
