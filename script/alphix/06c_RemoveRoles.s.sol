// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/**
 * @title Remove AccessManager Roles (Optional)
 * @notice Revokes roles from specific addresses for access-controlled functions
 * @dev OPTIONAL: Run this to remove previously granted roles
 *
 * DEPLOYMENT ORDER: 6c/11 (OPTIONAL - only if you want to revoke roles)
 *
 * Environment Variables (ALL OPTIONAL):
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - FEE_POKER_{NETWORK}: Address to revoke fee poker role from (optional)
 * - REGISTRAR_{NETWORK}: Address to revoke registrar role from (optional)
 *
 * Optional Role Removals:
 * 1. FEE_POKER (optional) - Revoke ability to call Alphix.poke()
 * 2. REGISTRAR (optional) - Revoke ability to register pools/contracts
 */
contract RemoveRolesScript is Script {
    // Role IDs (must match those used in 06b_ConfigureRoles.s.sol)
    uint64 constant FEE_POKER_ROLE = 1;
    uint64 constant REGISTRAR_ROLE = 2;

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

        vm.startBroadcast();

        // Optional: Remove Fee Poker Role
        if (feePoker != address(0)) {
            console.log("Removing Fee Poker Role...");

            // Revoke FEE_POKER_ROLE from the fee poker address
            accessManager.revokeRole(FEE_POKER_ROLE, feePoker);

            console.log("  - Fee Poker role revoked from:", feePoker);
            console.log("  - Can no longer call poke() on Alphix Hook");
            console.log("");
        }

        // Optional: Revoke REGISTRAR role
        if (registrar != address(0)) {
            console.log("Removing Registrar role...");

            // Revoke REGISTRAR_ROLE from the registrar address
            accessManager.revokeRole(REGISTRAR_ROLE, registrar);

            console.log("  - REGISTRAR role revoked from:", registrar);
            console.log("  - Can no longer call registerContract() and registerPool() on Registry");
            console.log("");
        }

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("ROLE REMOVAL COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Revoked Roles:");
        if (feePoker != address(0)) {
            console.log("  - FEE_POKER (ID %s): %s", FEE_POKER_ROLE, feePoker);
        }
        if (registrar != address(0)) {
            console.log("  - REGISTRAR (ID %s): %s", REGISTRAR_ROLE, registrar);
        }
        console.log("");
        console.log("NOTE:");
        console.log("Role assignments have been revoked. Addresses no longer have");
        console.log("permissions to call the restricted functions.");
        console.log("===========================================");
    }
}
