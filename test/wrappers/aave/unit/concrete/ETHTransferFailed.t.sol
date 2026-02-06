// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperWethAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperWethAave.sol";

/**
 * @title RejectETH
 * @notice Contract that rejects all ETH transfers.
 * @dev Used to test the ETHTransferFailed error branch.
 */
contract RejectETH {
    receive() external payable {
        revert("ETH rejected");
    }

    fallback() external payable {
        revert("ETH rejected");
    }
}

/**
 * @title ETHTransferFailedTest
 * @author Alphix
 * @notice Unit tests for ETH transfer failure scenarios in Alphix4626WrapperWethAave.
 * @dev Tests the branch at line 204: `if (!success) revert ETHTransferFailed()`
 */
contract ETHTransferFailedTest is BaseAlphix4626WrapperWethAave {
    /* STATE */

    RejectETH internal rejectEth;

    /* SETUP */

    function setUp() public override {
        super.setUp();
        // Deploy a contract that rejects ETH
        rejectEth = new RejectETH();
        // Deposit some ETH first so we have shares to withdraw/redeem
        _depositETHAsHook(10 ether);
    }

    /* TEST CASES */

    /**
     * @notice Test withdrawETH reverts if ETH transfer to receiver fails.
     * @dev This tests the branch: `if (!success) revert ETHTransferFailed()`
     *      in the _safeTransferETH function called by withdrawETH.
     */
    function test_withdrawETH_toContractThatRejects_reverts() public {
        uint256 withdrawAmount = 1 ether;

        // Try to withdraw ETH to a contract that rejects ETH
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperWethAave.ETHTransferFailed.selector);
        wethWrapper.withdrawETH(withdrawAmount, address(rejectEth), alphixHook);
    }

    /**
     * @notice Test redeemETH reverts if ETH transfer to receiver fails.
     * @dev This tests the same branch in redeemETH.
     */
    function test_redeemETH_toContractThatRejects_reverts() public {
        uint256 sharesToRedeem = wethWrapper.balanceOf(alphixHook) / 2;

        // Try to redeem shares for ETH to a contract that rejects ETH
        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperWethAave.ETHTransferFailed.selector);
        wethWrapper.redeemETH(sharesToRedeem, address(rejectEth), alphixHook);
    }
}
