// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AlphixLVR} from "../../../src/AlphixLVR.sol";
import {BaseAlphixLVRTest} from "../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVR_Access
 * @notice Unit tests for AlphixLVR access control and pausability.
 */
contract AlphixLVR_Access is BaseAlphixLVRTest {
    function setUp() public override {
        super.setUp();
        _initializePool();
    }

    function test_poke_revertsUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.poke(poolKey, 500);
    }

    function test_poke_revertsWhenPaused() public {
        // Pause
        vm.prank(admin);
        hook.pause();

        // Try to poke
        vm.prank(feePoker);
        vm.expectRevert();
        hook.poke(poolKey, 500);
    }

    function test_poke_worksAfterUnpause() public {
        // Pause then unpause
        vm.startPrank(admin);
        hook.pause();
        hook.unpause();
        vm.stopPrank();

        // Should work now
        vm.prank(feePoker);
        hook.poke(poolKey, 500);
        assertEq(hook.getFee(poolKey.toId()), 500);
    }

    function test_pause_revertsUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.pause();
    }

    function test_unpause_revertsUnauthorized() public {
        vm.prank(admin);
        hook.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        hook.unpause();
    }

    function test_feePoker_cannotPause() public {
        vm.prank(feePoker);
        vm.expectRevert();
        hook.pause();
    }
}
