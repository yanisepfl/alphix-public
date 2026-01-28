// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperWethAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperWethAave.sol";

/**
 * @title ReceiveETHTest
 * @author Alphix
 * @notice Unit tests for Alphix4626WrapperWethAave receive() and fallback().
 */
contract ReceiveETHTest is BaseAlphix4626WrapperWethAave {
    /* RECEIVE TESTS */

    /**
     * @notice Test receive() reverts when called by non-WETH address.
     */
    function test_receive_revertsFromNonWETH() public {
        vm.prank(alice);
        vm.expectRevert(IAlphix4626WrapperWethAave.ReceiveNotAllowed.selector);
        (bool success,) = address(wethWrapper).call{value: 1 ether}("");
        // Silence unused variable warning - expectRevert handles the revert check
        success;
    }

    /**
     * @notice Test receive() reverts when called by unauthorized user.
     */
    function test_receive_revertsFromUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperWethAave.ReceiveNotAllowed.selector);
        (bool success,) = address(wethWrapper).call{value: 1 ether}("");
        success;
    }

    /**
     * @notice Test receive() reverts when called by owner.
     */
    function test_receive_revertsFromOwner() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperWethAave.ReceiveNotAllowed.selector);
        (bool success,) = address(wethWrapper).call{value: 1 ether}("");
        success;
    }

    /**
     * @notice Test receive() accepts ETH from WETH contract.
     * @dev This happens internally during WETH.withdraw() calls.
     */
    function test_receive_acceptsFromWETH() public {
        // This is tested implicitly through withdrawETH/redeemETH tests
        // The WETH contract sends ETH when unwrapping, and receive() accepts it

        // Deposit first
        _depositETHAsHook(5 ether);

        // Withdraw - this triggers WETH.withdraw() which sends ETH to wrapper
        // then wrapper sends it to receiver
        uint256 hookBalanceBefore = alphixHook.balance;

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(1 ether, alphixHook, alphixHook);

        // If receive() rejected WETH, this would have reverted
        assertEq(alphixHook.balance, hookBalanceBefore + 1 ether, "ETH not received");
    }

    /* FALLBACK TESTS */

    /**
     * @notice Test fallback() always reverts.
     */
    function test_fallback_alwaysReverts() public {
        // Call with data (triggers fallback, not receive)
        vm.prank(alice);
        vm.expectRevert(IAlphix4626WrapperWethAave.FallbackNotAllowed.selector);
        (bool success,) = address(wethWrapper).call{value: 1 ether}(abi.encodeWithSignature("nonExistentFunction()"));
        success;
    }

    /**
     * @notice Test fallback() reverts even without value.
     */
    function test_fallback_revertsWithoutValue() public {
        vm.prank(alice);
        vm.expectRevert(IAlphix4626WrapperWethAave.FallbackNotAllowed.selector);
        (bool success,) = address(wethWrapper).call(abi.encodeWithSignature("nonExistentFunction()"));
        success;
    }

    /**
     * @notice Test fallback() reverts even from WETH.
     */
    function test_fallback_revertsFromWETH() public {
        // Even WETH can't call fallback with data
        vm.prank(address(weth));
        vm.expectRevert(IAlphix4626WrapperWethAave.FallbackNotAllowed.selector);
        (bool success,) = address(wethWrapper).call{value: 1 ether}(abi.encodeWithSignature("someFunction()"));
        success;
    }
}
