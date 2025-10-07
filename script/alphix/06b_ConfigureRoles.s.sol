// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Configure Additional AccessManager Roles (Optional)
 * @notice Grants additional roles to specific addresses for access-controlled functions
 * @dev OPTIONAL: Run this after 06_ConfigureSystem.s.sol if you want additional role assignments
 *
 * DEPLOYMENT ORDER: 6b/11 (OPTIONAL - only if you want fee poker or additional registrar)
 *
 * NOTE: The Alphix Hook already has REGISTRAR role (granted in script 04).
 * This script is only for granting ADDITIONAL roles to OTHER addresses.
 *
 * Environment Variables (ALL OPTIONAL):
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address (for fee poker role)
 * - FEE_POKER_{NETWORK}: Address allowed to poke fees (optional)
 * - REGISTRAR_{NETWORK}: Additional address for registrar role (optional)
 *
 * Optional Roles:
 * 1. FEE_POKER (optional) - Can call Alphix.poke() to manually update dynamic fees
 * 2. REGISTRAR (additional, optional) - Additional address for pool/contract registration
 */
contract ConfigureRolesScript is Script {
    // Role IDs (arbitrary unique identifiers)
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

        // Get Alphix Hook address (only needed if configuring fee poker)
        address alphixHookAddr;
        string memory hookEnvVar = string.concat("ALPHIX_HOOK_", network);
        try vm.envAddress(hookEnvVar) returns (address addr) {
            alphixHookAddr = addr;
        } catch {
            // Hook address not needed if only configuring registrar
        }

        // Get role addresses (optional)
        address feePoker;
        string memory feePokerEnvVar = string.concat("FEE_POKER_", network);
        try vm.envAddress(feePokerEnvVar) returns (address addr) {
            feePoker = addr;
        } catch {
            // Fee poker not configured
        }

        address registrar;
        string memory registrarEnvVar = string.concat("REGISTRAR_", network);
        try vm.envAddress(registrarEnvVar) returns (address addr) {
            registrar = addr;
        } catch {
            // Additional registrar not configured
        }

        // Check if there's anything to do
        if (feePoker == address(0) && registrar == address(0)) {
            console.log("===========================================");
            console.log("NO OPTIONAL ROLES CONFIGURED");
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
        console.log("CONFIGURING OPTIONAL ACCESS MANAGER ROLES");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AccessManager:", accessManagerAddr);
        console.log("");

        if (feePoker != address(0)) {
            console.log("Fee Poker Address:", feePoker);
        }
        if (registrar != address(0)) {
            console.log("Additional Registrar Address:", registrar);
        }
        console.log("");

        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Optional: Configure Fee Poker Role (can call poke() on Alphix Hook)
        if (feePoker != address(0)) {
            require(alphixHookAddr != address(0), "ALPHIX_HOOK must be set to configure FEE_POKER role");

            console.log("Configuring Fee Poker Role (optional)...");

            Alphix alphix = Alphix(alphixHookAddr);

            // Get the function selector for poke(PoolKey,uint256)
            bytes4 pokeSelector = alphix.poke.selector;

            // Set function as restricted to FEE_POKER_ROLE
            bytes4[] memory pokeSelectors = new bytes4[](1);
            pokeSelectors[0] = pokeSelector;
            accessManager.setTargetFunctionRole(alphixHookAddr, pokeSelectors, FEE_POKER_ROLE);

            // Grant FEE_POKER_ROLE to the fee poker address
            accessManager.grantRole(FEE_POKER_ROLE, feePoker, 0); // 0 = immediate effect

            console.log("  - Fee Poker role granted to:", feePoker);
            console.log("  - Can now call poke() on Alphix Hook");
            console.log("");
        }

        // Optional: Grant additional REGISTRAR role
        if (registrar != address(0)) {
            console.log("Configuring additional Registrar role (optional)...");

            // Grant REGISTRAR_ROLE to additional registrar address
            accessManager.grantRole(REGISTRAR_ROLE, registrar, 0); // 0 = immediate effect

            console.log("  - REGISTRAR role granted to:", registrar);
            console.log("  - Can call registerContract() and registerPool() on Registry");
            console.log("");
        }

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("ROLE CONFIGURATION COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Configured Roles:");
        if (feePoker != address(0)) {
            console.log("  - FEE_POKER (ID %s): %s", FEE_POKER_ROLE, feePoker);
        }
        if (registrar != address(0)) {
            console.log("  - REGISTRAR (ID %s): %s", REGISTRAR_ROLE, registrar);
        }
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Test role permissions by calling restricted functions");
        console.log("2. Create pools using script 09_CreatePoolAndAddLiquidity.s.sol");
        console.log("===========================================");
    }
}
