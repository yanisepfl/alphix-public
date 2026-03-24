// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {AlphixLVR} from "../../../src/AlphixLVR.sol";
import {IAlphixLVR} from "../../../src/interfaces/IAlphixLVR.sol";
import {BaseAlphixLVRTest} from "../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_Poke
 * @notice Unit tests for AlphixLVR poke functionality.
 */
contract AlphixLVR_Poke is BaseAlphixLVRTest {
    using PoolIdLibrary for *;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _initializePool();
    }

    function test_poke_setsFee() public {
        vm.prank(feePoker);
        hook.poke(poolKey, 500);

        assertEq(hook.getFee(poolKey.toId()), 500, "Stored fee should be 500");
    }

    function test_poke_updatesPoolManagerFee() public {
        vm.prank(feePoker);
        hook.poke(poolKey, 3000);

        (,, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolKey.toId());
        assertEq(lpFee, 3000, "PoolManager LP fee should be 3000");
    }

    function test_poke_emitsEvent() public {
        vm.prank(feePoker);
        vm.expectEmit(true, false, false, true);
        emit IAlphixLVR.FeePoked(poolKey.toId(), 1000);
        hook.poke(poolKey, 1000);
    }

    function test_poke_canSetToZero() public {
        // First set a non-zero fee
        vm.prank(feePoker);
        hook.poke(poolKey, 500);

        // Then set to zero
        vm.prank(feePoker);
        hook.poke(poolKey, 0);

        assertEq(hook.getFee(poolKey.toId()), 0, "Fee should be 0");
    }

    function test_poke_canSetToMaxFee() public {
        vm.prank(feePoker);
        hook.poke(poolKey, LPFeeLibrary.MAX_LP_FEE);

        assertEq(hook.getFee(poolKey.toId()), LPFeeLibrary.MAX_LP_FEE, "Fee should be MAX_LP_FEE");
    }

    function test_poke_revertsAboveMaxFee() public {
        vm.prank(feePoker);
        vm.expectRevert();
        hook.poke(poolKey, LPFeeLibrary.MAX_LP_FEE + 1);
    }

    function test_poke_canUpdateMultipleTimes() public {
        vm.startPrank(feePoker);

        hook.poke(poolKey, 100);
        assertEq(hook.getFee(poolKey.toId()), 100);

        hook.poke(poolKey, 5000);
        assertEq(hook.getFee(poolKey.toId()), 5000);

        hook.poke(poolKey, 1);
        assertEq(hook.getFee(poolKey.toId()), 1);

        vm.stopPrank();
    }

    function test_getFee_returnsZeroForUninitialized() public view {
        assertEq(hook.getFee(poolKey.toId()), 0, "Default fee should be 0");
    }

    function testFuzz_poke_anyValidFee(uint24 fee) public {
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));

        vm.prank(feePoker);
        hook.poke(poolKey, fee);

        assertEq(hook.getFee(poolKey.toId()), fee, "Fee should match input");
    }
}
