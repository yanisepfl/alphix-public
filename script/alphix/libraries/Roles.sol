// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title Roles
 * @notice Library containing all role identifiers used in AccessManager
 * @dev Centralizes role IDs to ensure consistency across deployment and management scripts
 *
 * Role Definitions:
 * - ADMIN_ROLE (0): Default admin role in OpenZeppelin AccessManager, can manage all other roles
 * - FEE_POKER_ROLE (1): Can call Alphix.poke() to manually update dynamic fees
 * - YIELD_MANAGER_ROLE (2): Can manage rehypothecation settings (yield sources, tax rates, treasury)
 * - PAUSER_ROLE (3): Can pause and unpause the contract
 */
library Roles {
    /**
     * @dev OpenZeppelin AccessManager admin role
     * This is the default admin role that can manage all other roles
     */
    uint64 internal constant ADMIN_ROLE = 0;

    /**
     * @dev Fee poker role - can manually trigger fee updates
     */
    uint64 internal constant FEE_POKER_ROLE = 1;

    /**
     * @dev Yield manager role - can manage rehypothecation settings
     * (yield sources, tax rates, treasury)
     */
    uint64 internal constant YIELD_MANAGER_ROLE = 2;

    /**
     * @dev Pauser role - can pause and unpause the contract
     */
    uint64 internal constant PAUSER_ROLE = 3;
}
