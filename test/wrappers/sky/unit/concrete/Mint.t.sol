// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title MintTest
 * @author Alphix
 * @notice Unit tests for the disabled mint functionality.
 * @dev mint is not implemented - these tests verify correct ERC4626 behavior for disabled functions.
 */
contract MintTest is BaseAlphix4626WrapperSky {
    /* MINT TESTS */

    /**
     * @notice Tests that mint reverts with NotImplemented.
     */
    function test_mint_reverts() public {
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.mint(100e18, alphixHook);
    }

    /**
     * @notice Tests that mint reverts even for owner.
     */
    function test_mint_revertsForOwner() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.mint(100e18, owner);
    }

    /**
     * @notice Tests that mint reverts for any caller.
     */
    function test_mint_revertsForAnyCaller() public {
        vm.prank(alice);
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.mint(100e18, alice);
    }

    /**
     * @notice Tests that mint reverts with zero shares.
     */
    function test_mint_revertsWithZeroShares() public {
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.mint(0, alphixHook);
    }

    /* MAX MINT TESTS */

    /**
     * @notice Tests that maxMint returns 0 for hook.
     */
    function test_maxMint_returnsZeroForHook() public view {
        assertEq(wrapper.maxMint(alphixHook), 0, "maxMint should return 0");
    }

    /**
     * @notice Tests that maxMint returns 0 for owner.
     */
    function test_maxMint_returnsZeroForOwner() public view {
        assertEq(wrapper.maxMint(owner), 0, "maxMint should return 0");
    }

    /**
     * @notice Tests that maxMint returns 0 for any address.
     */
    function test_maxMint_returnsZeroForAnyAddress() public view {
        assertEq(wrapper.maxMint(alice), 0, "maxMint should return 0");
        assertEq(wrapper.maxMint(bob), 0, "maxMint should return 0");
        assertEq(wrapper.maxMint(address(0)), 0, "maxMint should return 0");
    }

    /* PREVIEW MINT TESTS */

    /**
     * @notice Tests that previewMint reverts with NotImplemented.
     */
    function test_previewMint_reverts() public {
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.previewMint(100e18);
    }

    /**
     * @notice Tests that previewMint reverts with zero shares.
     */
    function test_previewMint_revertsWithZeroShares() public {
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.previewMint(0);
    }

    /**
     * @notice Tests that previewMint reverts with large amount.
     */
    function test_previewMint_revertsWithLargeAmount() public {
        vm.expectRevert(IAlphix4626WrapperSky.NotImplemented.selector);
        wrapper.previewMint(type(uint256).max);
    }
}
