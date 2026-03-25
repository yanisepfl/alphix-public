// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {BaseHookFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseHookFee.sol";
import {AlphixLVRFee} from "../../../../src/AlphixLVRFee.sol";
import {IAlphixLVRFee} from "../../../../src/interfaces/IAlphixLVRFee.sol";
import {BaseAlphixLVRFeeTest} from "../../BaseAlphixLVRFee.t.sol";

/**
 * @title AlphixLVRFee_Admin
 * @notice Tests for admin functions, access control, and edge cases to achieve 100% coverage.
 */
contract AlphixLVRFee_Admin is BaseAlphixLVRFeeTest {
    using PoolIdLibrary for PoolKey;

    function setUp() public override {
        super.setUp();
        _initializePool();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_revertsZeroTreasury() public {
        address hookAddr = address(
            uint160(Hooks.AFTER_INITIALIZE_FLAG) | uint160(Hooks.AFTER_SWAP_FLAG)
                | uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG) | uint160(0x9000) << 144
        );

        vm.expectRevert(AlphixLVRFee.TreasuryNotSet.selector);
        deployCodeTo(
            "src/AlphixLVRFee.sol:AlphixLVRFee", abi.encode(poolManager, address(accessManager), address(0)), hookAddr
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       SET TREASURY
    // ═══════════════════════════════════════════════════════════════════════

    function test_setTreasury_updatesAddress() public {
        address newTreasury = makeAddr("newTreasury");
        hook.setTreasury(newTreasury);
        assertEq(hook.treasury(), newTreasury);
    }

    function test_setTreasury_emitsEvent() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(false, false, false, true);
        emit IAlphixLVRFee.TreasurySet(newTreasury);
        hook.setTreasury(newTreasury);
    }

    function test_setTreasury_revertsZeroAddress() public {
        vm.expectRevert(AlphixLVRFee.TreasuryNotSet.selector);
        hook.setTreasury(address(0));
    }

    function test_setTreasury_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.setTreasury(makeAddr("newTreasury"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       SET HOOK FEE EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════

    function test_setHookFee_revertsAboveMax() public {
        vm.expectRevert(BaseHookFee.HookFeeTooLarge.selector);
        hook.setHookFee(poolKey, 1_000_001);
    }

    function test_setHookFee_maxValueAccepted() public {
        hook.setHookFee(poolKey, 1_000_000); // Exactly MAX_HOOK_FEE
        assertEq(hook.getHookFee(poolKey.toId()), 1_000_000);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       POKE EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════

    function test_poke_revertsAboveMaxLPFee() public {
        vm.prank(feePoker);
        vm.expectRevert(); // PoolManager reverts with LPFeeTooLarge
        hook.poke(poolKey, 1_000_001);
    }

    function test_poke_maxLPFeeAccepted() public {
        vm.prank(feePoker);
        hook.poke(poolKey, LPFeeLibrary.MAX_LP_FEE);
        assertEq(hook.getFee(poolKey.toId()), LPFeeLibrary.MAX_LP_FEE);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       UNLOCK CALLBACK
    // ═══════════════════════════════════════════════════════════════════════

    function test_unlockCallback_revertsNonPoolManager() public {
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = currency0;

        vm.expectRevert(AlphixLVRFee.OnlyPoolManager.selector);
        hook.unlockCallback(abi.encode(currencies));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       PAUSE / UNPAUSE
    // ═══════════════════════════════════════════════════════════════════════

    function test_pause_blocksSetHookFee() public {
        vm.prank(admin);
        hook.pause();

        vm.expectRevert();
        hook.setHookFee(poolKey, 10_000);
    }

    function test_unpause_allowsSetHookFee() public {
        vm.prank(admin);
        hook.pause();

        vm.prank(admin);
        hook.unpause();

        hook.setHookFee(poolKey, 10_000);
        assertEq(hook.getHookFee(poolKey.toId()), 10_000);
    }

    function test_pause_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.pause();
    }
}
