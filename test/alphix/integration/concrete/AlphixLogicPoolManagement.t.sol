// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

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
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title AlphixLogicPoolManagementTest
 * @author Alphix
 * @notice Tests for pool activation, configuration, unified params management and related access control
 * @dev Updated to unified PoolTypeParams and ratio-aware hook/logic flow
 */
contract AlphixLogicPoolManagementTest is BaseAlphixTest {
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

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            newP.minFee,
            newP.maxFee,
            newP.baseMaxFeeDelta,
            newP.lookbackPeriod,
            newP.minPeriod,
            newP.ratioTolerance,
            newP.linearSlope,
            newP.maxCurrentRatio,
            newP.lowerSideFactor,
            newP.upperSideFactor
        );
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newP);

        DynamicFeeLib.PoolTypeParams memory got = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minFee, newP.minFee, "minFee mismatch");
        assertEq(got.maxFee, newP.maxFee, "maxFee mismatch");
        assertEq(got.baseMaxFeeDelta, newP.baseMaxFeeDelta, "baseMaxFeeDelta mismatch");
        assertEq(got.lookbackPeriod, newP.lookbackPeriod, "lookbackPeriod mismatch");
        assertEq(got.minPeriod, newP.minPeriod, "minPeriod mismatch");
        assertEq(got.ratioTolerance, newP.ratioTolerance, "ratioTolerance mismatch");
        assertEq(got.linearSlope, newP.linearSlope, "linearSlope mismatch");
        assertEq(got.maxCurrentRatio, newP.maxCurrentRatio, "maxCurrentRatio mismatch");
        assertEq(got.upperSideFactor, newP.upperSideFactor, "upperSideFactor mismatch");
        assertEq(got.lowerSideFactor, newP.lowerSideFactor, "lowerSideFactor mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when minFee > maxFee
     */
    function test_setPoolTypeParams_revertsOnMinGtMax() public {
        DynamicFeeLib.PoolTypeParams memory bad = standardParams;
        bad.minFee = bad.maxFee + 1;

        vm.prank(owner);
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

        vm.prank(owner);
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

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, bad.minFee, bad.maxFee));
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, bad);
    }

    /**
     * @notice setPoolTypeParams succeeds when maxFee == LPFeeLibrary.MAX_LP_FEE (edge case)
     */
    function test_setPoolTypeParams_successOnMaxFeeAtLimit() public {
        DynamicFeeLib.PoolTypeParams memory edge = standardParams;
        edge.maxFee = uint24(LPFeeLibrary.MAX_LP_FEE);

        vm.prank(owner);
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
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.baseMaxFeeDelta = uint24(LPFeeLibrary.MAX_LP_FEE + 1);
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at baseMaxFeeDelta boundary values (edge cases)
     */
    function test_setPoolTypeParams_successOnBaseMaxFeeDeltaBounds() public {
        // At minimum
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.baseMaxFeeDelta = AlphixGlobalConstants.MIN_FEE;
        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.baseMaxFeeDelta, minEdge.baseMaxFeeDelta, "min baseMaxFeeDelta mismatch");

        // At maximum
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.baseMaxFeeDelta = uint24(LPFeeLibrary.MAX_LP_FEE);
        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.baseMaxFeeDelta, maxEdge.baseMaxFeeDelta, "max baseMaxFeeDelta mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when minPeriod < 1 hour or > 30 days
     */
    function test_setPoolTypeParams_revertsOnMinPeriod() public {
        // Too low
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.minPeriod = 1 hours - 1; // must be >= 1 hour

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.minPeriod = AlphixGlobalConstants.MAX_PERIOD + 1; // must be <= 30 days

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds when minPeriod == 1 hour (minimum edge case)
     */
    function test_setPoolTypeParams_successOnMinPeriodAtBoundary() public {
        DynamicFeeLib.PoolTypeParams memory edge = standardParams;
        edge.minPeriod = AlphixGlobalConstants.MIN_PERIOD; // exactly at minimum

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            edge.minFee,
            edge.maxFee,
            edge.baseMaxFeeDelta,
            edge.lookbackPeriod,
            edge.minPeriod,
            edge.ratioTolerance,
            edge.linearSlope,
            edge.maxCurrentRatio,
            edge.lowerSideFactor,
            edge.upperSideFactor
        );
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, edge);

        DynamicFeeLib.PoolTypeParams memory got = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minPeriod, edge.minPeriod, "minPeriod mismatch");
    }

    /**
     * @notice setPoolTypeParams succeeds when minPeriod == 30 days (maximum edge case)
     */
    function test_setPoolTypeParams_successOnMaxPeriodAtBoundary() public {
        DynamicFeeLib.PoolTypeParams memory edge = standardParams;
        edge.minPeriod = AlphixGlobalConstants.MAX_PERIOD; // exactly at maximum

        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            edge.minFee,
            edge.maxFee,
            edge.baseMaxFeeDelta,
            edge.lookbackPeriod,
            edge.minPeriod,
            edge.ratioTolerance,
            edge.linearSlope,
            edge.maxCurrentRatio,
            edge.lowerSideFactor,
            edge.upperSideFactor
        );
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
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.lookbackPeriod = 366; // must be < 366
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at lookbackPeriod boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnLookbackPeriodBounds() public {
        // At minimum boundary
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.lookbackPeriod = AlphixGlobalConstants.MIN_LOOKBACK_PERIOD;
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            minEdge.minFee,
            minEdge.maxFee,
            minEdge.baseMaxFeeDelta,
            minEdge.lookbackPeriod,
            minEdge.minPeriod,
            minEdge.ratioTolerance,
            minEdge.linearSlope,
            minEdge.maxCurrentRatio,
            minEdge.lowerSideFactor,
            minEdge.upperSideFactor
        );
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.lookbackPeriod, minEdge.lookbackPeriod, "min lookbackPeriod mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.lookbackPeriod = AlphixGlobalConstants.MAX_LOOKBACK_PERIOD;
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            maxEdge.minFee,
            maxEdge.maxFee,
            maxEdge.baseMaxFeeDelta,
            maxEdge.lookbackPeriod,
            maxEdge.minPeriod,
            maxEdge.ratioTolerance,
            maxEdge.linearSlope,
            maxEdge.maxCurrentRatio,
            maxEdge.lowerSideFactor,
            maxEdge.upperSideFactor
        );
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
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.ratioTolerance = 1e20;
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at ratioTolerance boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnRatioToleranceBounds() public {
        // At minimum boundary
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.ratioTolerance = AlphixGlobalConstants.MIN_RATIO_TOLERANCE;
        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.ratioTolerance, minEdge.ratioTolerance, "min ratioTolerance mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.ratioTolerance = AlphixGlobalConstants.TEN_WAD;
        vm.prank(owner);
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
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.linearSlope = 1e20;
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at linearSlope boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnLinearSlopeBounds() public {
        // At minimum boundary
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.linearSlope = AlphixGlobalConstants.MIN_LINEAR_SLOPE;
        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.linearSlope, minEdge.linearSlope, "min linearSlope mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.linearSlope = AlphixGlobalConstants.TEN_WAD;
        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.linearSlope, maxEdge.linearSlope, "max linearSlope mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts when side factors not in [1e17, 1e19]
     */
    function test_setPoolTypeParams_revertsOnSideFactors() public {
        // Too low (below ONE_TENTH_WAD = 1e17)
        DynamicFeeLib.PoolTypeParams memory low = standardParams;
        low.upperSideFactor = 1e17 - 1;
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.lowerSideFactor = 1e19 + 1;
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, high);
    }

    /**
     * @notice setPoolTypeParams succeeds at side factor boundaries (edge cases)
     */
    function test_setPoolTypeParams_successOnSideFactorBounds() public {
        // At minimum boundaries (ONE_TENTH_WAD = 1e17)
        DynamicFeeLib.PoolTypeParams memory minEdge = standardParams;
        minEdge.upperSideFactor = AlphixGlobalConstants.ONE_TENTH_WAD;
        minEdge.lowerSideFactor = AlphixGlobalConstants.ONE_TENTH_WAD;
        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.upperSideFactor, minEdge.upperSideFactor, "min upperSideFactor mismatch");
        assertEq(gotMin.lowerSideFactor, minEdge.lowerSideFactor, "min lowerSideFactor mismatch");

        // At maximum boundaries
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.upperSideFactor = AlphixGlobalConstants.TEN_WAD;
        maxEdge.lowerSideFactor = AlphixGlobalConstants.TEN_WAD;
        vm.prank(owner);
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
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, low);

        // Too high
        DynamicFeeLib.PoolTypeParams memory high = standardParams;
        high.maxCurrentRatio = AlphixGlobalConstants.MAX_CURRENT_RATIO + 1;
        vm.prank(owner);
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
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            minEdge.minFee,
            minEdge.maxFee,
            minEdge.baseMaxFeeDelta,
            minEdge.lookbackPeriod,
            minEdge.minPeriod,
            minEdge.ratioTolerance,
            minEdge.linearSlope,
            minEdge.maxCurrentRatio,
            minEdge.lowerSideFactor,
            minEdge.upperSideFactor
        );
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, minEdge);

        DynamicFeeLib.PoolTypeParams memory gotMin = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMin.maxCurrentRatio, minEdge.maxCurrentRatio, "min maxCurrentRatio mismatch");

        // At maximum boundary
        DynamicFeeLib.PoolTypeParams memory maxEdge = standardParams;
        maxEdge.maxCurrentRatio = AlphixGlobalConstants.MAX_CURRENT_RATIO;
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(logic));
        emit IAlphixLogic.PoolTypeParamsUpdated(
            IAlphixLogic.PoolType.STANDARD,
            maxEdge.minFee,
            maxEdge.maxFee,
            maxEdge.baseMaxFeeDelta,
            maxEdge.lookbackPeriod,
            maxEdge.minPeriod,
            maxEdge.ratioTolerance,
            maxEdge.linearSlope,
            maxEdge.maxCurrentRatio,
            maxEdge.lowerSideFactor,
            maxEdge.upperSideFactor
        );
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, maxEdge);

        DynamicFeeLib.PoolTypeParams memory gotMax = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(gotMax.maxCurrentRatio, maxEdge.maxCurrentRatio, "max maxCurrentRatio mismatch");
    }

    /**
     * @notice setPoolTypeParams reverts for non-owner callers
     */
    function test_setPoolTypeParams_revertsOnNonOwner() public {
        DynamicFeeLib.PoolTypeParams memory newP = standardParams;
        newP.minFee = 700;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user1));
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

        vm.prank(owner);
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

    /* POKE TESTS - UNIFIED API */

    /**
     * @notice poke reverts when called by non-hook address
     */
    function test_poke_revertsOnNonHook() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time to bypass cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        // Try to call from non-hook address (user1)
        uint256 validCurrentRatio = 1e18;

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.poke(freshKey, validCurrentRatio);
    }

    /**
     * @notice poke reverts when currentRatio exceeds pool's maxCurrentRatio limit
     */
    function test_poke_revertsOnExcessiveCurrentRatio() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Get the pool's maxCurrentRatio limit
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        uint256 excessiveCurrentRatio = pp.maxCurrentRatio + 1;

        // Advance time to bypass cooldown
        vm.warp(block.timestamp + pp.minPeriod);

        // Should revert
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.InvalidRatioForPoolType.selector, IAlphixLogic.PoolType.STANDARD, excessiveCurrentRatio
            )
        );
        logic.poke(freshKey, excessiveCurrentRatio);
    }

    /**
     * @notice poke succeeds at maxCurrentRatio boundary
     */
    function test_poke_successAtMaxCurrentRatioBoundary() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Get the pool's maxCurrentRatio limit and use exactly that value
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        uint256 boundaryCurrentRatio = pp.maxCurrentRatio;

        // Advance time to bypass cooldown
        vm.warp(block.timestamp + pp.minPeriod);

        // Should succeed
        vm.prank(address(hook));
        (uint24 newFee,, uint256 oldTargetRatio, uint256 newTargetRatio) = logic.poke(freshKey, boundaryCurrentRatio);

        // Verify reasonable values are returned
        assertGe(uint256(newFee), uint256(pp.minFee), "newFee below minFee");
        assertLe(uint256(newFee), uint256(pp.maxFee), "newFee above maxFee");
        assertEq(oldTargetRatio, INITIAL_TARGET_RATIO, "oldTargetRatio should equal initial target ratio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }

    /**
     * @notice poke clamps both oldTargetRatio and newTargetRatio to maxCurrentRatio
     */
    function test_poke_clampsTargetRatios() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        // Set an initial target ratio that's at the current limit
        uint256 initialRatio = 8e20; // 800:1 ratio, within current 1e21 limit
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, initialRatio, IAlphixLogic.PoolType.STANDARD);

        // Now lower the maxCurrentRatio significantly for the pool type
        DynamicFeeLib.PoolTypeParams memory newParams = standardParams;
        newParams.maxCurrentRatio = 3e20; // 300:1 ratio (much lower than stored target of 8e20)

        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newParams);

        // Advance time to bypass cooldown
        vm.warp(block.timestamp + newParams.minPeriod);

        // Call poke - the old stored target will be clamped
        uint256 validCurrentRatio = 2e20; // 200:1 ratio (well within the new 3e20 limit)
        vm.prank(address(hook));
        (,, uint256 oldTargetRatio, uint256 newTargetRatio) = logic.poke(freshKey, validCurrentRatio);

        // Verify oldTargetRatio is clamped to the new maxCurrentRatio
        assertEq(oldTargetRatio, newParams.maxCurrentRatio, "oldTargetRatio should be clamped to maxCurrentRatio");
        assertTrue(oldTargetRatio < initialRatio, "oldTargetRatio should be less than original stored value");

        // For newTargetRatio, it should be within bounds since EMA with the clamped oldTargetRatio and lower currentRatio
        // should produce a reasonable result, but verify it doesn't exceed the cap
        assertTrue(newTargetRatio <= newParams.maxCurrentRatio, "newTargetRatio should not exceed maxCurrentRatio");
    }

    /**
     * @notice poke succeeds when currentRatio is within pool's maxCurrentRatio limit
     */
    function test_poke_successOnValidCurrentRatio() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Derive a safe in-bounds currentRatio from configured params
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        uint256 validCurrentRatio = pp.maxCurrentRatio > 1 ? pp.maxCurrentRatio - 1 : 1;

        // Advance time to bypass cooldown
        vm.warp(block.timestamp + pp.minPeriod);

        // Should succeed
        vm.prank(address(hook));
        (uint24 newFee,, uint256 oldTargetRatio, uint256 newTargetRatio) = logic.poke(freshKey, validCurrentRatio);

        // Verify reasonable values are returned
        assertGe(uint256(newFee), uint256(pp.minFee), "newFee below minFee");
        assertLe(uint256(newFee), uint256(pp.maxFee), "newFee above maxFee");
        assertEq(oldTargetRatio, INITIAL_TARGET_RATIO, "oldTargetRatio should equal initial target ratio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }

    /**
     * @notice poke reverts before cooldown and succeeds after advancing time by pp.minPeriod
     */
    function test_poke_cooldownEnforcement() public {
        (PoolKey memory freshKey, PoolId freshPoolId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Get pool params to know the minPeriod
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        uint256 currentRatio = 1e18;

        // Should revert immediately after pool activation (cooldown not elapsed)
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.CooldownNotElapsed.selector, freshPoolId, block.timestamp + pp.minPeriod, pp.minPeriod
            )
        );
        logic.poke(freshKey, currentRatio);

        // Advance time by exactly pp.minPeriod
        vm.warp(block.timestamp + pp.minPeriod);

        // Should succeed now
        vm.prank(address(hook));
        (uint24 newFee,, uint256 oldTargetRatio, uint256 newTargetRatio) = logic.poke(freshKey, currentRatio);

        // Verify reasonable values
        assertGe(uint256(newFee), uint256(pp.minFee), "newFee below minFee");
        assertLe(uint256(newFee), uint256(pp.maxFee), "newFee above maxFee");
        assertEq(oldTargetRatio, INITIAL_TARGET_RATIO, "oldTargetRatio should equal initial target ratio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");
    }

    /**
     * @notice poke reverts when called by non-hook address (access control)
     */
    function test_poke_accessControlRevertsOnNonHook() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time to bypass cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        uint256 currentRatio = 1e18;

        // Should revert when called by non-hook (user1)
        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.poke(freshKey, currentRatio);
    }

    /**
     * @notice poke reverts when pool is not activated
     */
    function test_poke_revertsOnInactivePool() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Deactivate the pool
        vm.prank(address(hook));
        logic.deactivatePool(freshKey);

        // Advance time to bypass cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        uint256 currentRatio = 1e18;

        // Should revert due to pool being inactive
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        logic.poke(freshKey, currentRatio);
    }

    /**
     * @notice poke reverts when contract is paused
     */
    function test_poke_revertsWhenPaused() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Pause the contract (as owner)
        vm.prank(owner);
        AlphixLogic(address(logic)).pause();

        // Advance time to bypass cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        uint256 currentRatio = 1e18;

        // Should revert due to contract being paused
        vm.prank(address(hook));
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        logic.poke(freshKey, currentRatio);
    }

    /**
     * @notice poke reverts when currentRatio is zero
     */
    function test_poke_revertsOnZeroCurrentRatio() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time past cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        // Attempt to poke with zero currentRatio should revert
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, IAlphixLogic.PoolType.STANDARD, 0)
        );
        logic.poke(freshKey, 0);
    }

    /**
     * @notice poke updates all state correctly on success
     */
    function test_poke_updatesStateCorrectly() public {
        (PoolKey memory freshKey, PoolId freshPoolId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time to bypass cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        uint256 currentRatio = 2e18; // Different from initial to trigger target update

        // Execute poke
        vm.prank(address(hook));
        (uint24 newFee,, uint256 oldTargetRatio, uint256 newTargetRatio) = logic.poke(freshKey, currentRatio);

        // Verify reasonable values
        assertGe(uint256(newFee), uint256(pp.minFee), "newFee below minFee");
        assertLe(uint256(newFee), uint256(pp.maxFee), "newFee above maxFee");
        assertEq(oldTargetRatio, INITIAL_TARGET_RATIO, "oldTargetRatio should equal initial target ratio");
        assertTrue(newTargetRatio > 0, "newTargetRatio should be positive");

        // Verify cooldown is reset by trying another immediate call (should fail)
        vm.prank(address(hook));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.CooldownNotElapsed.selector, freshPoolId, block.timestamp + pp.minPeriod, pp.minPeriod
            )
        );
        logic.poke(freshKey, currentRatio);

        // Verify cooldown works after advancing time again
        vm.warp(block.timestamp + pp.minPeriod);
        vm.prank(address(hook));
        (uint24 newFee2,,, uint256 newTargetRatio2) = logic.poke(freshKey, currentRatio);

        // Second poke should also succeed with valid values
        assertGe(uint256(newFee2), uint256(pp.minFee), "second newFee below minFee");
        assertLe(uint256(newFee2), uint256(pp.maxFee), "second newFee above maxFee");
        assertTrue(newTargetRatio2 > 0, "second newTargetRatio should be positive");
    }

    /**
     * @notice Test that lowering maxCurrentRatio post-activation clamps newTargetRatio to the new cap
     */
    function test_poke_clampsNewTargetRatioToNewCap() public {
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Advance time to bypass cooldown
        DynamicFeeLib.PoolTypeParams memory pp = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + pp.minPeriod);

        // First poke with high current ratio to establish a high target
        uint256 highCurrentRatio = pp.maxCurrentRatio; // Use current max (1e21)
        vm.prank(address(hook));
        (,,, uint256 firstNewTargetRatio) = logic.poke(freshKey, highCurrentRatio);

        // Verify first target was set
        assertTrue(firstNewTargetRatio > 0, "first newTargetRatio should be positive");

        // Now lower the maxCurrentRatio cap for this pool type
        DynamicFeeLib.PoolTypeParams memory newParams = pp;
        newParams.maxCurrentRatio = 5e20; // Lower cap: 500:1 ratio (down from 1000:1)

        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newParams);

        // Advance time again for another update
        vm.warp(block.timestamp + newParams.minPeriod);

        // Poke with a current ratio at the new cap - should work
        vm.prank(address(hook));
        (,, uint256 oldTargetRatio2, uint256 newTargetRatio2) = logic.poke(freshKey, newParams.maxCurrentRatio);

        // Verify the old target was clamped to the new cap
        assertTrue(oldTargetRatio2 <= newParams.maxCurrentRatio, "oldTargetRatio should be clamped to maxCurrentRatio");
        assertTrue(newTargetRatio2 <= newParams.maxCurrentRatio, "newTargetRatio should be clamped to maxCurrentRatio");
    }
}
