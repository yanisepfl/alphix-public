// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";

import {AlphixLVR} from "../../../../src/AlphixLVR.sol";
import {BaseAlphixLVRTest} from "../../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_Initialization
 * @notice Tests for pool initialization behavior.
 */
contract AlphixLVR_Initialization is BaseAlphixLVRTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function test_afterInitialize_setsZeroFee() public {
        _initializePool();

        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolKey.toId());
        assertEq(lpFee, 0, "Initial fee should be 0");
    }

    function test_afterInitialize_revertsNonDynamicFee() public {
        // Create pool key without dynamic fee flag
        PoolKey memory staticKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // Static fee, not DYNAMIC_FEE_FLAG
            tickSpacing: 60,
            hooks: IHooks(hook)
        });

        vm.expectRevert(); // PoolManager wraps the hook revert
        poolManager.initialize(staticKey, TickMath.getSqrtPriceAtTick(0));
    }

    function test_getHookPermissions_onlyAfterInitialize() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        assertFalse(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeSwap);
        assertFalse(perms.afterSwap);
        assertFalse(perms.beforeDonate);
        assertFalse(perms.afterDonate);
        assertFalse(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.afterAddLiquidityReturnDelta);
        assertFalse(perms.afterRemoveLiquidityReturnDelta);
    }

    function test_poolManager_isSetCorrectly() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
    }

    function test_multiplePoolsCanInitialize() public {
        _initializePool();

        // Create and init a second pool with different tick spacing
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });
        poolManager.initialize(key2, TickMath.getSqrtPriceAtTick(100));

        (uint160 sqrtPrice,,, ) = poolManager.getSlot0(key2.toId());
        assertTrue(sqrtPrice > 0, "Second pool should be initialized");
    }

    function test_poke_revertsForUninitializedPool() public {
        // Pool not initialized — poke should revert in PoolManager
        vm.prank(feePoker);
        vm.expectRevert();
        hook.poke(poolKey, 500);
    }

    function test_initializePool_worksWhilePaused() public {
        // Pause the hook
        vm.prank(admin);
        hook.pause();

        // Pool initialization should still work (afterInitialize has no pause check)
        _initializePool();

        (uint160 sqrtPrice,,, ) = poolManager.getSlot0(poolKey.toId());
        assertTrue(sqrtPrice > 0, "Pool should initialize even while paused");
    }

    function test_poke_revertsForWrongHookAddress() public {
        _initializePool();

        // Create a pool key pointing to a different hook address
        PoolKey memory wrongKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(0x1234))
        });

        vm.prank(feePoker);
        vm.expectRevert();
        hook.poke(wrongKey, 500);
    }
}
