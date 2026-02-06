// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestnetMockWETH
 * @notice A mock WETH9 contract for testnet deployments
 * @dev Provides wrap/unwrap functionality for native ETH
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Features:
 * - Deposit ETH to receive WETH (wrap)
 * - Withdraw WETH to receive ETH (unwrap)
 * - Standard ERC20 functionality
 * - Compatible with real WETH9 interface
 */
contract TestnetMockWETH is IERC20 {
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
     * @dev Mints WETH 1:1 with deposited ETH
     */
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposit(msg.sender, msg.value);
        emit Transfer(address(0), msg.sender, msg.value);
    }

    /**
     * @notice Withdraw WETH and receive ETH
     * @dev Burns WETH 1:1 and sends ETH
     * @param wad Amount of WETH to withdraw (in wei)
     */
    function withdraw(uint256 wad) public {
        require(balanceOf[msg.sender] >= wad, "Insufficient balance");
        balanceOf[msg.sender] -= wad;
        totalSupply -= wad;
        payable(msg.sender).transfer(wad);
        emit Withdrawal(msg.sender, wad);
        emit Transfer(msg.sender, address(0), wad);
    }

    /**
     * @notice Transfer WETH to another address
     * @param dst Destination address
     * @param wad Amount to transfer (in wei)
     * @return success True if transfer succeeded
     */
    function transfer(address dst, uint256 wad) public override returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    /**
     * @notice Transfer WETH from one address to another
     * @param src Source address
     * @param dst Destination address
     * @param wad Amount to transfer (in wei)
     * @return success True if transfer succeeded
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
     * @param guy Spender address
     * @param wad Amount to approve (in wei)
     * @return success True if approval succeeded
     */
    function approve(address guy, uint256 wad) public override returns (bool) {
        allowance[msg.sender][guy] = wad;
        emit Approval(msg.sender, guy, wad);
        return true;
    }

    /**
     * @notice Receive ETH and wrap it automatically
     */
    receive() external payable {
        deposit();
    }
}
