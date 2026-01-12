// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockYieldVault
 * @notice A mock ERC-4626 vault that allows simulating yield generation and losses.
 * @dev Used for testing ReHypothecation functionality.
 */
contract MockYieldVault is ERC4626 {
    using SafeERC20 for IERC20;

    address private admin;

    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Mock Yield Vault", "MYV") {
        admin = msg.sender;
    }

    /**
     * @notice Simulate yield generation by minting underlying tokens to the vault.
     * @dev This increases the value of all shares proportionally.
     * @param amount Amount of underlying tokens to add as yield.
     */
    function simulateYield(uint256 amount) external {
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Simulate a loss by burning underlying tokens from the vault.
     * @dev This decreases the value of all shares proportionally.
     * @param amount Amount of underlying tokens to remove.
     */
    function simulateLoss(uint256 amount) external {
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        require(amount <= balance, "Cannot lose more than balance");
        // Transfer tokens out to simulate loss (in real scenarios this would be a slashing event)
        IERC20(asset()).safeTransfer(admin, amount);
    }

    // Exclude from coverage report
    function test() public {}
}
