// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title MaxDepositTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky maxDeposit function.
 * @dev Tests the ERC4626 standard maxDeposit function.
 */
contract MaxDepositTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests maxDeposit returns max for authorized hook.
     */
    function test_maxDeposit_authorizedHook_returnsMax() public view {
        uint256 max = wrapper.maxDeposit(alphixHook);
        assertEq(max, type(uint256).max, "Should return max for authorized hook");
    }

    /**
     * @notice Tests maxDeposit returns max for owner.
     */
    function test_maxDeposit_owner_returnsMax() public view {
        uint256 max = wrapper.maxDeposit(owner);
        assertEq(max, type(uint256).max, "Should return max for owner");
    }

    /**
     * @notice Tests maxDeposit returns zero for unauthorized address.
     */
    function test_maxDeposit_unauthorized_returnsZero() public view {
        uint256 max = wrapper.maxDeposit(alice);
        assertEq(max, 0, "Should return 0 for unauthorized address");
    }

    /**
     * @notice Tests maxDeposit returns zero for zero address.
     */
    function test_maxDeposit_zeroAddress_returnsZero() public view {
        uint256 max = wrapper.maxDeposit(address(0));
        assertEq(max, 0, "Should return 0 for zero address");
    }

    /**
     * @notice Tests maxDeposit returns zero when paused.
     */
    function test_maxDeposit_whenPaused_returnsZero() public {
        vm.prank(owner);
        wrapper.pause();

        uint256 maxHook = wrapper.maxDeposit(alphixHook);
        uint256 maxOwner = wrapper.maxDeposit(owner);

        assertEq(maxHook, 0, "Should return 0 when paused for hook");
        assertEq(maxOwner, 0, "Should return 0 when paused for owner");
    }

    /**
     * @notice Tests maxDeposit returns max after unpause.
     */
    function test_maxDeposit_afterUnpause_returnsMax() public {
        vm.startPrank(owner);
        wrapper.pause();
        wrapper.unpause();
        vm.stopPrank();

        uint256 max = wrapper.maxDeposit(alphixHook);
        assertEq(max, type(uint256).max, "Should return max after unpause");
    }

    /**
     * @notice Tests maxDeposit returns zero after hook removal.
     */
    function test_maxDeposit_afterHookRemoval_returnsZero() public {
        vm.prank(owner);
        wrapper.removeAlphixHook(alphixHook);

        uint256 max = wrapper.maxDeposit(alphixHook);
        assertEq(max, 0, "Should return 0 after hook removal");
    }

    /**
     * @notice Tests maxDeposit does not revert.
     */
    function test_maxDeposit_doesNotRevert() public view {
        wrapper.maxDeposit(alphixHook);
        wrapper.maxDeposit(owner);
        wrapper.maxDeposit(alice);
        wrapper.maxDeposit(address(0));
    }
}
