// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Remove AccessManager Roles (Optional)
 * @notice Revokes roles from specific addresses for access-controlled functions
 * @dev OPTIONAL: Run this to remove previously granted roles
 *
 * DEPLOYMENT ORDER: 6c/11 (OPTIONAL - only if you want to revoke roles)
 *
 * Environment Variables:
 * Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., BASE_SEPOLIA)
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - ACCOUNT_PRIVATE_KEY: Private key of the broadcaster account
 *
 * Optional (at least one required for script to execute):
 * - FEE_POKER_{NETWORK}: Address to revoke fee poker role from
 * - REGISTRAR_{NETWORK}: Address to revoke registrar role from
 *
 * Optional Role Removals:
 * 1. FEE_POKER (optional) - Revoke ability to call Alphix.poke()
 * 2. REGISTRAR (optional) - Revoke ability to register pools/contracts
 *
 * Prerequisites:
 * - Broadcaster must have ADMIN_ROLE (role ID 0) in AccessManager
 * - Script will check permissions before broadcasting and revert if insufficient
 */
contract RemoveRolesScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get AccessManager address
        string memory accessManagerEnvVar = string.concat("ACCESS_MANAGER_", network);
        address accessManagerAddr = vm.envAddress(accessManagerEnvVar);
        require(accessManagerAddr != address(0), string.concat(accessManagerEnvVar, " not set"));

        // Get role addresses to revoke (optional)
        address feePoker;
        string memory feePokerEnvVar = string.concat("FEE_POKER_", network);
        try vm.envAddress(feePokerEnvVar) returns (address addr) {
            feePoker = addr;
        } catch {
            // Fee poker not configured for removal
        }

        address registrar;
        string memory registrarEnvVar = string.concat("REGISTRAR_", network);
        try vm.envAddress(registrarEnvVar) returns (address addr) {
            registrar = addr;
        } catch {
            // Registrar not configured for removal
        }

        // Check if there's anything to do
        if (feePoker == address(0) && registrar == address(0)) {
            console.log("===========================================");
            console.log("NO ROLES TO REMOVE");
            console.log("===========================================");
            console.log("FEE_POKER and REGISTRAR not set in .env");
            console.log("Script has nothing to do - exiting");
            console.log("");
            console.log("To use this script, set at least one of:");
            console.log("  - FEE_POKER_%s=<address>", network);
            console.log("  - REGISTRAR_%s=<address>", network);
            console.log("===========================================");
            return;
        }

        console.log("===========================================");
        console.log("REMOVING ACCESS MANAGER ROLES");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AccessManager:", accessManagerAddr);
        console.log("");

        if (feePoker != address(0)) {
            console.log("Removing Fee Poker from:", feePoker);
        }
        if (registrar != address(0)) {
            console.log("Removing Registrar from:", registrar);
        }
        console.log("");

        AccessManager accessManager = AccessManager(accessManagerAddr);

        // Check broadcaster permissions
        console.log("BROADCASTER PERMISSION CHECK");
        console.log("-------------------------------------------");

        // Get the broadcaster address
        uint256 deployerPrivateKey = vm.envUint("ACCOUNT_PRIVATE_KEY");
        address broadcaster = vm.addr(deployerPrivateKey);

        console.log("Broadcaster Address:", broadcaster);

        // Check if broadcaster has ADMIN_ROLE
        (bool hasAdminRole, uint32 executionDelay) = accessManager.hasRole(Roles.ADMIN_ROLE, broadcaster);

        console.log("Has ADMIN_ROLE (ID):", Roles.ADMIN_ROLE);
        console.log("Has ADMIN_ROLE:", hasAdminRole ? "YES" : "NO");

        if (executionDelay > 0) {
            console.log("Execution Delay (seconds):", executionDelay);
            console.log("");
            console.log("WARNING: Role operations will have a time delay!");
            console.log("The revocations will be scheduled, not immediate.");
        }

        if (!hasAdminRole) {
            console.log("");
            console.log("===========================================");
            console.log("ERROR: INSUFFICIENT PERMISSIONS");
            console.log("===========================================");
            console.log("The broadcaster does not have ADMIN_ROLE.");
            console.log("Role revocation requires admin permissions.");
            console.log("");
            console.log("Solutions:");
            console.log("1. Use an address with ADMIN_ROLE");
            console.log("2. Grant ADMIN_ROLE to this broadcaster:");
            console.log("   Address:", broadcaster);
            console.log("===========================================");
            revert("Broadcaster lacks ADMIN_ROLE - cannot revoke roles");
        }

        console.log("Permission check: PASSED");
        console.log("");

        // Pre-revocation verification
        console.log("PRE-REVOCATION VERIFICATION");
        console.log("-------------------------------------------");

        bool feePokerHadRole = false;
        bool registrarHadRole = false;

        if (feePoker != address(0)) {
            (bool isMember,) = accessManager.hasRole(Roles.FEE_POKER_ROLE, feePoker);
            feePokerHadRole = isMember;
            console.log("Fee Poker:", feePoker);
            console.log("  - Has FEE_POKER_ROLE (ID):", Roles.FEE_POKER_ROLE);
            console.log("  - Has FEE_POKER_ROLE:", isMember ? "YES" : "NO");
            if (!isMember) {
                console.log("  - WARNING: Address does not have role to revoke!");
            }
        }

        if (registrar != address(0)) {
            (bool isMember,) = accessManager.hasRole(Roles.REGISTRAR_ROLE, registrar);
            registrarHadRole = isMember;
            console.log("Registrar:", registrar);
            console.log("  - Has REGISTRAR_ROLE (ID):", Roles.REGISTRAR_ROLE);
            console.log("  - Has REGISTRAR_ROLE:", isMember ? "YES" : "NO");
            if (!isMember) {
                console.log("  - WARNING: Address does not have role to revoke!");
            }
        }
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Optional: Remove Fee Poker Role
        if (feePoker != address(0)) {
            console.log("Removing Fee Poker Role...");

            if (feePokerHadRole) {
                // Revoke FEE_POKER_ROLE from the fee poker address
                accessManager.revokeRole(Roles.FEE_POKER_ROLE, feePoker);
                console.log("  - Fee Poker role revoked from:", feePoker);
                console.log("  - Can no longer call poke() on Alphix Hook");
            } else {
                console.log("  - Skipping: address did not have FEE_POKER_ROLE");
            }
            console.log("");
        }

        // Optional: Revoke REGISTRAR role
        if (registrar != address(0)) {
            console.log("Removing Registrar role...");

            if (registrarHadRole) {
                // Revoke REGISTRAR_ROLE from the registrar address
                accessManager.revokeRole(Roles.REGISTRAR_ROLE, registrar);
                console.log("  - REGISTRAR role revoked from:", registrar);
                console.log("  - Can no longer call registerContract() and registerPool() on Registry");
            } else {
                console.log("  - Skipping: address did not have REGISTRAR_ROLE");
            }
            console.log("");
        }

        vm.stopBroadcast();

        // Post-revocation verification
        console.log("POST-REVOCATION VERIFICATION");
        console.log("-------------------------------------------");

        bool allRevocationsSuccessful = true;

        if (feePoker != address(0)) {
            (bool isMember,) = accessManager.hasRole(Roles.FEE_POKER_ROLE, feePoker);
            console.log("Fee Poker:", feePoker);
            console.log("  - Has FEE_POKER_ROLE (ID):", Roles.FEE_POKER_ROLE);
            console.log("  - Has FEE_POKER_ROLE:", isMember ? "YES" : "NO");

            if (feePokerHadRole && isMember) {
                console.log("  - ERROR: Role revocation FAILED!");
                allRevocationsSuccessful = false;
            } else if (feePokerHadRole && !isMember) {
                console.log("  - SUCCESS: Role successfully revoked");
            } else if (!feePokerHadRole && !isMember) {
                console.log("  - INFO: Role was not assigned (nothing to revoke)");
            }
        }

        if (registrar != address(0)) {
            (bool isMember,) = accessManager.hasRole(Roles.REGISTRAR_ROLE, registrar);
            console.log("Registrar:", registrar);
            console.log("  - Has REGISTRAR_ROLE (ID):", Roles.REGISTRAR_ROLE);
            console.log("  - Has REGISTRAR_ROLE:", isMember ? "YES" : "NO");

            if (registrarHadRole && isMember) {
                console.log("  - ERROR: Role revocation FAILED!");
                allRevocationsSuccessful = false;
            } else if (registrarHadRole && !isMember) {
                console.log("  - SUCCESS: Role successfully revoked");
            } else if (!registrarHadRole && !isMember) {
                console.log("  - INFO: Role was not assigned (nothing to revoke)");
            }
        }

        console.log("");

        require(allRevocationsSuccessful, "One or more role revocations failed verification");

        console.log("===========================================");
        console.log("ROLE REMOVAL COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Revoked Roles:");
        if (feePoker != address(0)) {
            console.log("  - FEE_POKER (ID):", Roles.FEE_POKER_ROLE);
            console.log("  - FEE_POKER:", feePoker);
        }
        if (registrar != address(0)) {
            console.log("  - REGISTRAR (ID):", Roles.REGISTRAR_ROLE);
            console.log("  - REGISTRAR:", registrar);
        }
        console.log("");
        console.log("NOTE:");
        console.log("Role assignments have been revoked. Addresses no longer have");
        console.log("permissions to call the restricted functions.");
        console.log("===========================================");
    }
}
