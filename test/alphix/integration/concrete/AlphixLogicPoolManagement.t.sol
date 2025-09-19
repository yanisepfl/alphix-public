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
     * @notice setPoolTypeParams reverts when minPeriod <= 1 hour
     */
    function test_setPoolTypeParams_revertsOnMinPeriod() public {
        DynamicFeeLib.PoolTypeParams memory bad = standardParams;
        bad.minPeriod = 1 hours - 1; // must be >= 1 hour

        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, bad);
    }

    /**
     * @notice setPoolTypeParams reverts when lookbackPeriod not in (7, 365)
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
     * @notice setPoolTypeParams reverts when ratioTolerance not in [1e15, 1e17]
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
}
