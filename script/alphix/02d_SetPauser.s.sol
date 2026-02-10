// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Set Pauser Role
 * @notice Grants or updates the PAUSER_ROLE to a new address
 * @dev Use this script to change who can call pause()/unpause() without reconfiguring the entire system
 *
 * DEPLOYMENT ORDER: 2d (After initial setup, can be run anytime)
 *
 * SENDER REQUIREMENTS: Must be run by AccessManager admin
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - PAUSER_{NETWORK}: New address to grant PAUSER_ROLE
 */
contract SetPauserScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_", network);
        address accessManagerAddr = vm.envAddress(envVar);
        require(accessManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("PAUSER_", network);
        address pauser = vm.envAddress(envVar);
        require(pauser != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("SETTING PAUSER ROLE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("New Pauser:", pauser);
        console.log("");

        Alphix alphix = Alphix(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Set up PAUSER_ROLE permissions on pause()/unpause() functions
        console.log("Step 1: Setting function permissions for PAUSER_ROLE...");
        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = alphix.pause.selector;
        pauserSelectors[1] = alphix.unpause.selector;
        accessManager.setTargetFunctionRole(hookAddr, pauserSelectors, Roles.PAUSER_ROLE);
        console.log("  - pause() restricted to PAUSER_ROLE");
        console.log("  - unpause() restricted to PAUSER_ROLE");

        // Grant PAUSER_ROLE to the new address
        console.log("Step 2: Granting PAUSER_ROLE...");
        accessManager.grantRole(Roles.PAUSER_ROLE, pauser, 0);
        console.log("  - Granted to:", pauser);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("PAUSER ROLE SET SUCCESSFULLY");
        console.log("===========================================");
        console.log("PAUSER_ROLE (", Roles.PAUSER_ROLE, "):", pauser);
        console.log("");
        console.log("NOTE: To revoke from a previous address, use AccessManager.revokeRole()");
        console.log("===========================================");
    }
}
