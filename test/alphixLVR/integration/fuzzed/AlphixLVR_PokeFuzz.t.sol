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

import {AlphixLVR} from "../../../../src/AlphixLVR.sol";
import {IAlphixLVR} from "../../../../src/interfaces/IAlphixLVR.sol";
import {BaseAlphixLVRTest} from "../../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_PokeFuzz
 * @notice Fuzz tests for AlphixLVR poke behavior.
 */
contract AlphixLVR_PokeFuzz is BaseAlphixLVRTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function setUp() public override {
        super.setUp();
        _initializePool();
    }

    function testFuzz_poke_storedFeeMatchesPoolManager(uint24 fee) public {
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));

        vm.prank(feePoker);
        hook.poke(poolKey, fee);

        // Stored fee
        assertEq(hook.getFee(poolKey.toId()), fee);

        // PoolManager fee
        (,,, uint24 lpFee) = poolManager.getSlot0(poolKey.toId());
        assertEq(lpFee, fee);
    }

    function testFuzz_poke_emitsCorrectEvent(uint24 fee) public {
        fee = uint24(bound(fee, 0, LPFeeLibrary.MAX_LP_FEE));

        vm.prank(feePoker);
        vm.expectEmit(true, false, false, true);
        emit IAlphixLVR.FeePoked(poolKey.toId(), fee);
        hook.poke(poolKey, fee);
    }

    function testFuzz_poke_revertsAboveMax(uint24 fee) public {
        fee = uint24(bound(fee, LPFeeLibrary.MAX_LP_FEE + 1, type(uint24).max));

        vm.prank(feePoker);
        vm.expectRevert();
        hook.poke(poolKey, fee);
    }

    function testFuzz_poke_consecutiveUpdates(uint24 fee1, uint24 fee2) public {
        fee1 = uint24(bound(fee1, 0, LPFeeLibrary.MAX_LP_FEE));
        fee2 = uint24(bound(fee2, 0, LPFeeLibrary.MAX_LP_FEE));

        vm.startPrank(feePoker);
        hook.poke(poolKey, fee1);
        hook.poke(poolKey, fee2);
        vm.stopPrank();

        assertEq(hook.getFee(poolKey.toId()), fee2, "Should reflect latest poke");
    }

    function testFuzz_poke_multiPoolIsolation(uint24 fee1, uint24 fee2, int24 tickSpacing2) public {
        fee1 = uint24(bound(fee1, 0, LPFeeLibrary.MAX_LP_FEE));
        fee2 = uint24(bound(fee2, 0, LPFeeLibrary.MAX_LP_FEE));
        tickSpacing2 = int24(bound(int256(tickSpacing2), 1, 16383));

        // Skip if same tick spacing (would be same pool)
        vm.assume(tickSpacing2 != poolKey.tickSpacing);

        // Create second pool
        PoolKey memory key2 = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing2,
            hooks: IHooks(hook)
        });
        poolManager.initialize(key2, TickMath.getSqrtPriceAtTick(0));

        vm.startPrank(feePoker);
        hook.poke(poolKey, fee1);
        hook.poke(key2, fee2);
        vm.stopPrank();

        assertEq(hook.getFee(poolKey.toId()), fee1);
        assertEq(hook.getFee(key2.toId()), fee2);
    }
}
