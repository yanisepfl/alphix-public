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

/**
 * @title AlphixLogicPoolManagementTest
 * @author Alphix
 * @notice Tests for pool activation, configuration, bounds management and related access control
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
        // Use a fresh pool to avoid the default pre-configured one
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
        // Use a fresh pool
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
        // Configure a fresh pool
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Try to configure again
        vm.prank(address(hook));
        vm.expectRevert(IAlphixLogic.PoolAlreadyConfigured.selector);
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice activatePool succeeds after prior configuration and deactivation
     */
    function test_activatePool_success() public {
        // Configure a fresh pool
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Deactivate then re-activate
        vm.prank(address(hook));
        logic.deactivatePool(freshKey);

        vm.prank(address(hook));
        logic.activatePool(freshKey);

        // Should not revert on guarded path when active
        vm.prank(address(hook));
        logic.beforeAddLiquidity(
            user1, freshKey, ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1000, salt: 0}), ""
        );
    }

    /**
     * @notice activatePool reverts for non-hook callers
     */
    function test_activatePool_revertsOnNonHook() public {
        // For a consistent revert path, ensure pool is configured first
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);
        vm.prank(address(hook));
        logic.activateAndConfigurePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Now non-hook tries to activate (even if active, the path remains onlyHook)
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
        // Use fresh pool and configure it to follow the normal path
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

    /**
     * @notice setPoolTypeBounds updates bounds and emits event for STANDARD type
     */
    function test_setPoolTypeBounds_success() public {
        IAlphixLogic.PoolTypeBounds memory newBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: 5000});

        vm.prank(address(hook));
        vm.expectEmit(true, false, false, true);
        emit IAlphixLogic.PoolTypeBoundsUpdated(IAlphixLogic.PoolType.STANDARD, 1000, 5000);
        logic.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, newBounds);

        IAlphixLogic.PoolTypeBounds memory retrieved = logic.getPoolTypeBounds(IAlphixLogic.PoolType.STANDARD);
        assertEq(retrieved.minFee, newBounds.minFee, "minFee mismatch");
        assertEq(retrieved.maxFee, newBounds.maxFee, "maxFee mismatch");
    }

    /**
     * @notice setPoolTypeBounds reverts when minFee > maxFee
     */
    function test_setPoolTypeBounds_revertsOnInvalidBounds() public {
        IAlphixLogic.PoolTypeBounds memory invalidBounds = IAlphixLogic.PoolTypeBounds({minFee: 5000, maxFee: 1000});

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, 5000, 1000));
        logic.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, invalidBounds);
    }

    /**
     * @notice setPoolTypeBounds reverts when maxFee exceeds LPFeeLibrary.MAX_LP_FEE
     */
    function test_setPoolTypeBounds_revertsOnExcessiveMaxFee() public {
        uint24 tooHigh = uint24(LPFeeLibrary.MAX_LP_FEE + 1);
        IAlphixLogic.PoolTypeBounds memory invalidBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: tooHigh});

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFeeBounds.selector, 1000, tooHigh));
        logic.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, invalidBounds);
    }

    /**
     * @notice setPoolTypeBounds reverts for non-hook callers
     */
    function test_setPoolTypeBounds_revertsOnNonHook() public {
        IAlphixLogic.PoolTypeBounds memory newBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: 5000});

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, newBounds);
    }

    /**
     * @notice setPoolTypeBounds reverts when logic is paused
     */
    function test_setPoolTypeBounds_revertsWhenPaused() public {
        vm.prank(owner);
        AlphixLogic(address(logicProxy)).pause();

        IAlphixLogic.PoolTypeBounds memory newBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: 5000});

        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(PausableUpgradeable.EnforcedPause.selector));
        logic.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, newBounds);
    }

    /**
     * @notice isValidFeeForPoolType returns true for fees within [min,max]
     */
    function test_isValidFeeForPoolType_success() public {
        vm.prank(address(hook));
        assertTrue(logic.isValidFeeForPoolType(IAlphixLogic.PoolType.STANDARD, 3000));

        vm.prank(address(hook));
        assertTrue(logic.isValidFeeForPoolType(IAlphixLogic.PoolType.STANDARD, standardBounds.minFee)); // min

        vm.prank(address(hook));
        assertTrue(logic.isValidFeeForPoolType(IAlphixLogic.PoolType.STANDARD, standardBounds.maxFee)); // max
    }

    /**
     * @notice isValidFeeForPoolType returns false for fees outside [min,max]
     */
    function test_isValidFeeForPoolType_returnsFalseForInvalidFees() public {
        vm.prank(address(hook));
        assertFalse(logic.isValidFeeForPoolType(IAlphixLogic.PoolType.STANDARD, standardBounds.minFee - 1)); // below

        vm.prank(address(hook));
        assertFalse(logic.isValidFeeForPoolType(IAlphixLogic.PoolType.STANDARD, standardBounds.maxFee + 1)); // above
    }

    /**
     * @notice isValidFeeForPoolType reverts for non-hook callers
     */
    function test_isValidFeeForPoolType_revertsOnNonHook() public {
        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        logic.isValidFeeForPoolType(IAlphixLogic.PoolType.STANDARD, 3000);
    }

    /**
     * @notice getPoolConfig returns the configured values for a pool
     */
    function test_getPoolConfig() public {
        // Use a fresh pool to avoid side effects from setUp default pool
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
        // Use a fresh pool to avoid side effects from setUp default pool
        (, PoolId freshId) = _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(freshId);
        assertEq(config.initialFee, 0, "initialFee should be 0");
        assertEq(config.initialTargetRatio, 0, "initialTargetRatio should be 0");
        assertEq(uint8(config.poolType), uint8(IAlphixLogic.PoolType.STABLE), "default poolType should be STABLE");
        assertFalse(config.isConfigured, "isConfigured should be false");
    }
}
