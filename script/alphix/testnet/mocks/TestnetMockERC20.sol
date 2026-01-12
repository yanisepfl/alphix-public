// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TestnetMockERC20
 * @notice A mock ERC20 token for testnet deployments
 * @dev Fully permissionless - anyone can mint or burn tokens
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Features:
 * - Configurable decimals (set at deployment)
 * - Anyone can mint tokens to any address
 * - Anyone can burn their own tokens
 * - Standard ERC20 functionality
 */
contract TestnetMockERC20 is ERC20 {
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    uint8 private immutable _decimals;

    /**
     * @notice Deploy a new mock ERC20 token
     * @param name_ Token name (e.g., "Alphix Testnet USDC")
     * @param symbol_ Token symbol (e.g., "atUSDC")
     * @param decimals_ Token decimals (e.g., 6 for USDC, 18 for most tokens)
     */
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    /**
     * @notice Returns the number of decimals for this token
     * @return The number of decimals
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /**
     * @notice Mint tokens to any address
     * @dev Permissionless - anyone can call this
     * @param to Address to mint tokens to
     * @param amount Amount of tokens to mint (in base units)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from the caller's balance
     * @dev Only burns from msg.sender
     * @param amount Amount of tokens to burn (in base units)
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Burn tokens from an address (requires approval)
     * @param from Address to burn tokens from
     * @param amount Amount of tokens to burn (in base units)
     */
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
