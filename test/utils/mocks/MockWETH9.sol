// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockWETH9
 * @notice Mock implementation of WETH9 for testing
 * @dev Provides wrap/unwrap functionality for ETH
 */
contract MockWETH9 is IERC20 {
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant name = "Wrapped Ether";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    string public constant symbol = "WETH";
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    uint256 public override totalSupply;

    event Deposit(address indexed dst, uint256 wad);
    event Withdrawal(address indexed src, uint256 wad);

    /**
     * @notice Deposit ETH and receive WETH
     */
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Withdraw WETH and receive ETH
     * @param wad Amount to withdraw
     */
    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "Insufficient balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
    }

    /**
     * @notice Transfer WETH to another address
     */
    function transfer(address dst, uint256 wad) public override returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    /**
     * @notice Transfer WETH from one address to another
     */
    function transferFrom(address src, address dst, uint256 wad) public override returns (bool) {
        require(balanceOf[src] >= wad, "Insufficient balance");

        if (src != msg.sender && allowance[src][msg.sender] != type(uint256).max) {
            require(allowance[src][msg.sender] >= wad, "Insufficient allowance");
            allowance[src][msg.sender] -= wad;
        }

        balanceOf[src] -= wad;
        balanceOf[dst] += wad;

        emit Transfer(src, dst, wad);
        return true;
    }

    /**
     * @notice Approve spender to transfer WETH
     */
    function approve(address guy, uint256 wad) public override returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    /**
     * @notice Receive ETH and wrap it
     */
    receive() external payable {
        deposit();
    }
}
