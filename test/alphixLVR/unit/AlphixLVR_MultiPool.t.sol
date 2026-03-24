// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {AlphixLVR} from "../../../src/AlphixLVR.sol";
import {BaseAlphixLVRTest} from "../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_MultiPool
 * @notice Unit tests verifying AlphixLVR handles multiple pools independently.
 */
contract AlphixLVR_MultiPool is BaseAlphixLVRTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    PoolKey public poolKey2;
    Currency public currency2;
    Currency public currency3;

    function setUp() public override {
        super.setUp();

        // Deploy a second pair of tokens
        (currency2, currency3) = deployCurrencyPair();

        // Create second pool key with different tick spacing
        poolKey2 = PoolKey({
            currency0: currency2,
            currency1: currency3,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });

        // Initialize both pools
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(poolKey2, TickMath.getSqrtPriceAtTick(0));
    }

    function test_multiPool_independentFees() public {
        vm.startPrank(feePoker);

        hook.poke(poolKey, 100);
        hook.poke(poolKey2, 5000);

        vm.stopPrank();

        assertEq(hook.getFee(poolKey.toId()), 100, "Pool 1 fee should be 100");
        assertEq(hook.getFee(poolKey2.toId()), 5000, "Pool 2 fee should be 5000");
    }

    function test_multiPool_updatingOneDoesNotAffectOther() public {
        vm.startPrank(feePoker);

        hook.poke(poolKey, 100);
        hook.poke(poolKey2, 200);

        // Update pool 1 only
        hook.poke(poolKey, 999);

        vm.stopPrank();

        assertEq(hook.getFee(poolKey.toId()), 999, "Pool 1 should be updated");
        assertEq(hook.getFee(poolKey2.toId()), 200, "Pool 2 should be unchanged");
    }

    function test_multiPool_bothFeesAppliedInPoolManager() public {
        vm.startPrank(feePoker);
        hook.poke(poolKey, 300);
        hook.poke(poolKey2, 7000);
        vm.stopPrank();

        (,, uint24 protocolFee1, uint24 lpFee1) = poolManager.getSlot0(poolKey.toId());
        (,, uint24 protocolFee2, uint24 lpFee2) = poolManager.getSlot0(poolKey2.toId());

        assertEq(lpFee1, 300, "Pool 1 PoolManager fee should be 300");
        assertEq(lpFee2, 7000, "Pool 2 PoolManager fee should be 7000");
    }
}
