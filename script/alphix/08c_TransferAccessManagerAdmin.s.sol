// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/**
 * @title Transfer AccessManager Admin Role
 * @notice Transfers AccessManager admin role from deployer to multisig
 * @dev Uses role-based access control, not Ownable2Step pattern
 *
 * DEPLOYMENT ORDER: 8c/11 (run after 08b_AcceptOwnership.s.sol)
 *
 * IMPORTANT: This script MUST be run in TWO PARTS:
 *
 * PART 1 (this script): Grant admin role to multisig
 * - Run by current admin (deployer)
 * - Grants ADMIN_ROLE to FUTURE_MANAGER
 * - Does NOT revoke old admin yet (safety measure)
 *
 * PART 2 (manual or separate script): Revoke old admin role
 * - After verifying multisig admin works correctly
 * - Run script 08d_RevokeOldAdmin.s.sol
 * - Or manually: accessManager.revokeRole(ADMIN_ROLE, OLD_ADMIN, 0)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - ALPHIX_MANAGER_{NETWORK}: Current admin address (deployer)
 * - FUTURE_MANAGER_{NETWORK}: New admin address (multisig)
 * - ACCOUNT_PRIVATE_KEY: Must correspond to ALPHIX_MANAGER (current admin)
 *
 * AccessManager Roles:
 * - ADMIN_ROLE = 0 (uint64) - Default admin role with full permissions
 * - Admin can grant/revoke all roles including other admins
 *
 * After Execution:
 * - Multisig has admin role (can manage all roles)
 * - Deployer still has admin role (not revoked yet - safety)
 * - Test multisig admin functionality before revoking old admin
 */
contract TransferAccessManagerAdminScript is Script {
    // Default admin role ID in AccessManager
    uint64 constant ADMIN_ROLE = 0;

    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get AccessManager address
        string memory accessManagerEnvVar = string.concat("ACCESS_MANAGER_", network);
        address accessManagerAddr = vm.envAddress(accessManagerEnvVar);
        require(accessManagerAddr != address(0), string.concat(accessManagerEnvVar, " not set"));

        // Get current admin (deployer)
        string memory currentAdminEnvVar = string.concat("ALPHIX_MANAGER_", network);
        address currentAdmin = vm.envAddress(currentAdminEnvVar);
        require(currentAdmin != address(0), string.concat(currentAdminEnvVar, " not set"));

        // Get new admin (multisig)
        string memory newAdminEnvVar = string.concat("FUTURE_MANAGER_", network);
        address newAdmin = vm.envAddress(newAdminEnvVar);
        require(newAdmin != address(0), string.concat(newAdminEnvVar, " not set"));

        console.log("===========================================");
        console.log("TRANSFERRING ACCESS MANAGER ADMIN ROLE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Current Admin:", currentAdmin);
        console.log("New Admin (Multisig):", newAdmin);
        console.log("");

        AccessManager accessManager = AccessManager(accessManagerAddr);

        // Check current admin status
        (bool currentAdminHasRole,) = accessManager.hasRole(ADMIN_ROLE, currentAdmin);
        (bool newAdminHasRole,) = accessManager.hasRole(ADMIN_ROLE, newAdmin);

        console.log("Current Admin Role Status:");
        console.log("  - %s has ADMIN_ROLE: %s", currentAdmin, currentAdminHasRole ? "YES" : "NO");
        console.log("  - %s has ADMIN_ROLE: %s", newAdmin, newAdminHasRole ? "YES" : "NO");
        console.log("");

        if (!currentAdminHasRole) {
            console.log("ERROR: Current admin does not have ADMIN_ROLE");
            console.log("Cannot proceed - verify ALPHIX_MANAGER is correct");
            revert("Current admin lacks ADMIN_ROLE");
        }

        if (newAdminHasRole) {
            console.log("INFO: New admin already has ADMIN_ROLE");
            console.log("Skipping grant to avoid revert (role already granted)");
            console.log("");
        } else {
            vm.startBroadcast();

            console.log("Granting ADMIN_ROLE to multisig...");
            console.log("  - Role ID: %s (ADMIN_ROLE)", ADMIN_ROLE);
            console.log("  - Recipient: %s", newAdmin);
            console.log("  - Execution delay: 0 (immediate effect)");
            console.log("");

            try accessManager.grantRole(ADMIN_ROLE, newAdmin, 0) {
                console.log("  - ADMIN_ROLE granted successfully");
            } catch Error(string memory reason) {
                console.log("  - FAILED:", reason);
                revert(reason);
            }

            vm.stopBroadcast();
        }

        // Re-fetch and verify role status
        (bool verified,) = accessManager.hasRole(ADMIN_ROLE, newAdmin);

        console.log("");
        console.log("===========================================");
        console.log("ADMIN ROLE GRANT COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Admin Role Status (after grant):");
        console.log("  - %s: %s", currentAdmin, currentAdminHasRole ? "ADMIN (old)" : "NO ROLE");
        console.log("  - %s: %s", newAdmin, verified ? "ADMIN (new)" : "FAILED");
        console.log("");

        require(verified, "Admin role grant verification failed");

        console.log("IMPORTANT: Both old and new admin have ADMIN_ROLE now");
        console.log("This is intentional for safety - test before revoking old admin");
        console.log("");
        console.log("===========================================");
        console.log("NEXT STEPS - CRITICAL");
        console.log("===========================================");
        console.log("");
        console.log("STEP 1: Test multisig admin functionality");
        console.log("  - Use multisig to grant a test role");
        console.log("  - Verify multisig can call AccessManager functions");
        console.log("  - Example:");
        console.log("    accessManager.grantRole(TEST_ROLE, TEST_ADDRESS, 0)");
        console.log("");
        console.log("STEP 2: After verification, revoke old admin");
        console.log("  - Option A: Run script 08d_RevokeOldAdmin.s.sol");
        console.log("  - Option B: Manual from multisig:");
        console.log("    accessManager.revokeRole(0, %s, 0)", currentAdmin);
        console.log("");
        console.log("STEP 3: Verify final state");
        console.log("  - Only multisig should have ADMIN_ROLE");
        console.log("  - Old admin should have NO roles");
        console.log("");
        console.log("WARNING: Do NOT revoke old admin until multisig is verified!");
        console.log("===========================================");
    }
}
