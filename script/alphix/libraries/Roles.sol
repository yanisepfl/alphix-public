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
 * - REGISTRAR_ROLE (2): Can call registerContract() and registerPool() on Registry
 */
library Roles {
    /**
     * @dev OpenZeppelin AccessManager admin role
     * This is the default admin role that can manage all other roles
     */
    uint64 internal constant ADMIN_ROLE = 0;

    /**
     * @dev Fee poker role - can manually trigger fee updates
     * Granted in: 06b_ConfigureRoles.s.sol
     * Revoked in: 06c_RemoveRoles.s.sol
     */
    uint64 internal constant FEE_POKER_ROLE = 1;

    /**
     * @dev Registrar role - can register pools and contracts in the Registry
     * Granted in: 06b_ConfigureRoles.s.sol
     * Revoked in: 06c_RemoveRoles.s.sol
     */
    uint64 internal constant REGISTRAR_ROLE = 2;
}
