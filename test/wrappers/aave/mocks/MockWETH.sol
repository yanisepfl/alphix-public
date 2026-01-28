// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IWETH} from "@aave-v3-core/misc/interfaces/IWETH.sol";
import {MockERC20} from "./MockERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockWETH
 * @author Alphix
 * @notice Mock WETH contract for testing ETH wrap/unwrap functionality.
 * @dev Implements IWETH interface with standard WETH9 behavior.
 */
contract MockWETH is MockERC20, IWETH {
    /**
     * @notice Override approve to satisfy both IWETH and ERC20.
     */
    function approve(address guy, uint256 wad) public override(ERC20, IWETH) returns (bool) {
        return super.approve(guy, wad);
    }

    /**
     * @notice Override transferFrom to satisfy both IWETH and ERC20.
     */
    function transferFrom(address src, address dst, uint256 wad) public override(ERC20, IWETH) returns (bool) {
        return super.transferFrom(src, dst, wad);
    }

    /**
     * @notice Emitted when ETH is wrapped to WETH.
     * @param dst The address that received WETH.
     * @param wad The amount of WETH minted.
     */
    event Deposit(address indexed dst, uint256 wad);

    /**
     * @notice Emitted when WETH is unwrapped to ETH.
     * @param src The address that burned WETH.
     * @param wad The amount of WETH burned.
     */
    event Withdrawal(address indexed src, uint256 wad);

    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    /**
     * @notice Wrap ETH to WETH.
     * @dev Mints WETH 1:1 for ETH sent.
     */
    function deposit() external payable override {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Unwrap WETH to ETH.
     * @param wad The amount of WETH to unwrap.
     * @dev Burns WETH and sends ETH to caller.
     */
    function withdraw(uint256 wad) external override {
        require(balanceOf(msg.sender) >= wad, "MockWETH: insufficient balance");
        _burn(msg.sender, wad);
        (bool success,) = msg.sender.call{value: wad}(new bytes(0));
        require(success, "MockWETH: ETH transfer failed");
        emit Withdrawal(msg.sender, wad);
    }

    /**
     * @notice Receive ETH and mint WETH (same as deposit).
     */
    receive() external payable {
        _mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }
}
