// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

contract MockFaucet {
    // State variables
    MockERC20 public token0;
    MockERC20 public token1;
    MockERC20 public token2;
    MockERC20 public token3;
    MockERC20 public token4;
    uint256 public token0Amount;
    uint256 public token1Amount;
    uint256 public token2Amount;
    uint256 public token3Amount;
    uint256 public token4Amount;

    // Mapping to track the last withdrawal time for each address
    mapping(address => uint256) public lastCalled;

    // Events
    event TokensSent(
        address indexed user, uint256 amountToken0, uint256 amountToken1, uint256 amountToken2, uint256 amountToken3, uint256 amountToken4
    );

    // Constructor to set the token addresses
    constructor(MockERC20 _token0, MockERC20 _token1, MockERC20 _token2, MockERC20 _token3, MockERC20 _token4) {
        token0 = _token0;
        token1 = _token1;
        token2 = _token2;
        token3 = _token3;
        token4 = _token4;
        token0Amount = 100000 * 10 ** MockERC20(token0).decimals() / 1000; // 100 aUSDC
        token1Amount = 100000 * 10 ** MockERC20(token1).decimals() / 1000; // 100 aUSDT
        token2Amount = 50 * 10 ** MockERC20(token2).decimals() / 1000; // 0.05 aETH
        token3Amount = 10 ** MockERC20(token3).decimals() / 1000; // 0.001 aBTC
        token4Amount = 100000 * 10 ** MockERC20(token4).decimals() / 1000; // 100 aDAI
    }

    // Function to send tokens to caller
    function faucet() external {
        require(block.timestamp >= lastCalled[msg.sender] + 1 days, "Can only use the faucet once per day");

        // Update the last called timestamp
        lastCalled[msg.sender] = block.timestamp;

        // Transfer tokens to the caller
        token0.mint(msg.sender, token0Amount);
        token1.mint(msg.sender, token1Amount);
        token2.mint(msg.sender, token2Amount);
        token3.mint(msg.sender, token3Amount);
        token4.mint(msg.sender, token4Amount);

        // Emit an event
        emit TokensSent(msg.sender, token0Amount, token1Amount, token2Amount, token3Amount, token4Amount);
    }
}
