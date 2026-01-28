// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockERC20
 * @author Alphix
 * @notice Mock ERC20 token for testing purposes.
 * @dev Allows minting and burning by anyone for test flexibility.
 */
contract MockERC20 is ERC20 {
    uint8 private immutable TOKEN_DECIMALS;

    /**
     * @notice Constructs the mock token.
     * @param name_ The token name.
     * @param symbol_ The token symbol.
     * @param decimals_ The token decimals.
     */
    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        TOKEN_DECIMALS = decimals_;
    }

    /**
     * @notice Returns the token decimals.
     * @return The number of decimals.
     */
    function decimals() public view override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    /**
     * @notice Mints tokens to an address.
     * @param to The recipient address.
     * @param amount The amount to mint.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from an address.
     * @param from The address to burn from.
     * @param amount The amount to burn.
     */
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
