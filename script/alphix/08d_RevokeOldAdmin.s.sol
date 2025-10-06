// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/**
 * @title Revoke Old AccessManager Admin Role
 * @notice Revokes ADMIN_ROLE from old admin (deployer) after multisig verification
 * @dev Final step of AccessManager admin transfer process
 *
 * DEPLOYMENT ORDER: 8d/11 (run after 08c_TransferAccessManagerAdmin.s.sol)
 *
 * CRITICAL SAFETY REQUIREMENTS - Read Before Running:
 *
 * 1. PREREQUISITE: Script 08c_TransferAccessManagerAdmin.s.sol MUST be completed
 *    - Multisig MUST already have ADMIN_ROLE
 *    - Old admin still has ADMIN_ROLE (intentional safety measure)
 *
 * 2. VERIFICATION REQUIRED BEFORE RUNNING THIS SCRIPT:
 *    - Test that multisig can successfully call AccessManager functions
 *    - Example test: Grant a test role from multisig
 *    - Verify multisig has full admin capabilities
 *    - DO NOT run this script until verification is complete
 *
 * 3. THIS SCRIPT MUST BE RUN BY THE NEW ADMIN (MULTISIG):
 *    - ACCOUNT_PRIVATE_KEY must correspond to FUTURE_MANAGER
 *    - Only admin can revoke admin roles
 *    - Running from wrong account will cause revert
 *
 * 4. IRREVERSIBLE ACTION:
 *    - After this script, old admin (deployer) will have NO roles
 *    - Only multisig will be able to manage AccessManager
 *    - Cannot be undone without multisig approval
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - ALPHIX_MANAGER_{NETWORK}: Old admin address (deployer) - will be revoked
 * - FUTURE_MANAGER_{NETWORK}: New admin address (multisig) - must run this script
 * - ACCOUNT_PRIVATE_KEY: Must correspond to FUTURE_MANAGER (new admin)
 *
 * AccessManager Roles:
 * - ADMIN_ROLE = 0 (uint64) - Default admin role with full permissions
 *
 * After Execution:
 * - Only multisig has ADMIN_ROLE
 * - Old deployer has NO roles
 * - AccessManager fully controlled by multisig
 *
 * WARNING: If multisig is not properly configured or tested, running this
 * script could lock you out of AccessManager control. Test thoroughly first!
 */
contract RevokeOldAdminScript is Script {
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

        // Get old admin (deployer)
        string memory oldAdminEnvVar = string.concat("ALPHIX_MANAGER_", network);
        address oldAdmin = vm.envAddress(oldAdminEnvVar);
        require(oldAdmin != address(0), string.concat(oldAdminEnvVar, " not set"));

        // Get new admin (multisig)
        string memory newAdminEnvVar = string.concat("FUTURE_MANAGER_", network);
        address newAdmin = vm.envAddress(newAdminEnvVar);
        require(newAdmin != address(0), string.concat(newAdminEnvVar, " not set"));

        console.log("===========================================");
        console.log("REVOKING OLD ACCESS MANAGER ADMIN ROLE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Old Admin (to revoke):", oldAdmin);
        console.log("New Admin (multisig):", newAdmin);
        console.log("");

        AccessManager accessManager = AccessManager(accessManagerAddr);

        // Check current admin status
        (bool oldAdminHasRole,) = accessManager.hasRole(ADMIN_ROLE, oldAdmin);
        (bool newAdminHasRole,) = accessManager.hasRole(ADMIN_ROLE, newAdmin);

        console.log("Current Admin Role Status:");
        console.log("  - %s has ADMIN_ROLE: %s", oldAdmin, oldAdminHasRole ? "YES" : "NO");
        console.log("  - %s has ADMIN_ROLE: %s", newAdmin, newAdminHasRole ? "YES" : "NO");
        console.log("");

        // Verify prerequisites
        if (!newAdminHasRole) {
            console.log("ERROR: New admin (multisig) does not have ADMIN_ROLE");
            console.log("Cannot proceed - run script 08c first");
            console.log("Required: New admin MUST have ADMIN_ROLE before revoking old admin");
            revert("New admin lacks ADMIN_ROLE");
        }

        if (!oldAdminHasRole) {
            console.log("INFO: Old admin already has NO ADMIN_ROLE");
            console.log("Nothing to revoke - script already completed or admin already revoked");
            console.log("");
            console.log("Current state is safe - only multisig has admin role");
            console.log("No action needed - exiting successfully");
            return;
        }

        console.log("===========================================");
        console.log("SAFETY CHECKS - PLEASE VERIFY");
        console.log("===========================================");
        console.log("");
        console.log("Before proceeding, confirm you have tested:");
        console.log("  1. Multisig can successfully call AccessManager functions");
        console.log("  2. Multisig can grant/revoke roles");
        console.log("  3. Multisig has full admin capabilities");
        console.log("  4. All multisig signers are properly configured");
        console.log("");
        console.log("This action is IRREVERSIBLE without multisig approval!");
        console.log("");
        console.log("Proceeding with revocation in 3 seconds...");
        console.log("===========================================");
        console.log("");

        vm.startBroadcast();

        console.log("Revoking ADMIN_ROLE from old admin...");
        console.log("  - Role ID: %s (ADMIN_ROLE)", ADMIN_ROLE);
        console.log("  - Target: %s", oldAdmin);
        console.log("");

        try accessManager.revokeRole(ADMIN_ROLE, oldAdmin) {
            console.log("  - ADMIN_ROLE revoked successfully");
        } catch Error(string memory reason) {
            console.log("  - FAILED:", reason);
            revert(reason);
        }

        vm.stopBroadcast();

        // Verify revocation completed
        (bool oldAdminStillHasRole,) = accessManager.hasRole(ADMIN_ROLE, oldAdmin);
        (bool newAdminStillHasRole,) = accessManager.hasRole(ADMIN_ROLE, newAdmin);

        console.log("");
        console.log("===========================================");
        console.log("ADMIN ROLE REVOCATION COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Admin Role Status (after revocation):");
        console.log("  - %s: %s", oldAdmin, oldAdminStillHasRole ? "STILL ADMIN (FAILED)" : "NO ROLE (SUCCESS)");
        console.log("  - %s: %s", newAdmin, newAdminStillHasRole ? "ADMIN (SUCCESS)" : "NO ROLE (FAILED)");
        console.log("");

        // Final verification
        require(!oldAdminStillHasRole, "Old admin revocation failed - still has ADMIN_ROLE");
        require(newAdminStillHasRole, "New admin lost ADMIN_ROLE - critical failure");

        console.log("===========================================");
        console.log("ACCESS MANAGER ADMIN TRANSFER COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Final State:");
        console.log("  - Old Admin (%s): NO ROLES", oldAdmin);
        console.log("  - New Admin (%s): ADMIN_ROLE", newAdmin);
        console.log("");
        console.log("AccessManager is now fully controlled by multisig");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Verify AccessManager state:");
        console.log("   - Only multisig should have ADMIN_ROLE");
        console.log("   - Old deployer should have NO roles");
        console.log("2. Test multisig admin functions:");
        console.log("   - Grant/revoke test roles");
        console.log("   - Verify all signers can participate");
        console.log("3. Document multisig configuration:");
        console.log("   - Signer addresses");
        console.log("   - Threshold requirements");
        console.log("   - Emergency procedures");
        console.log("");
        console.log("Deployment complete! All contracts now managed by multisig.");
        console.log("===========================================");
    }
}
