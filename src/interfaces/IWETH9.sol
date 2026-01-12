// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH9
 * @notice Interface for WETH9 (Wrapped Ether) contract.
 * @dev Standard interface for wrapping and unwrapping native ETH to ERC20 WETH.
 */
interface IWETH9 is IERC20 {
    /**
     * @notice Wrap ETH into WETH.
     * @dev msg.value is the amount of ETH to wrap.
     */
    function deposit() external payable;

    /**
     * @notice Unwrap WETH back to ETH.
     * @dev The unwrapped ETH is sent to msg.sender.
     * @param amount The amount of WETH to unwrap.
     */
    function withdraw(uint256 amount) external;
}
