// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Set Yield Manager Role
 * @notice Grants or updates the YIELD_MANAGER_ROLE to a new address
 * @dev Use this script to change who can call setYieldSource()
 *
 * DEPLOYMENT ORDER: 2c (After initial setup, can be run anytime)
 *
 * SENDER REQUIREMENTS: Must be run by AccessManager admin
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - YIELD_MANAGER_{NETWORK}: New address to grant YIELD_MANAGER_ROLE
 */
contract SetYieldManagerScript is Script {
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

        envVar = string.concat("YIELD_MANAGER_", network);
        address yieldManager = vm.envAddress(envVar);
        require(yieldManager != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("SETTING YIELD MANAGER ROLE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("New Yield Manager:", yieldManager);
        console.log("");

        Alphix alphix = Alphix(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Set up YIELD_MANAGER_ROLE permissions on setYieldSource()
        console.log("Step 1: Setting function permissions for YIELD_MANAGER_ROLE...");
        bytes4[] memory yieldManagerSelectors = new bytes4[](1);
        yieldManagerSelectors[0] = alphix.setYieldSource.selector;
        accessManager.setTargetFunctionRole(hookAddr, yieldManagerSelectors, Roles.YIELD_MANAGER_ROLE);
        console.log("  - setYieldSource() restricted to YIELD_MANAGER_ROLE");

        // Grant YIELD_MANAGER_ROLE to the new address
        console.log("Step 2: Granting YIELD_MANAGER_ROLE...");
        accessManager.grantRole(Roles.YIELD_MANAGER_ROLE, yieldManager, 0);
        console.log("  - Granted to:", yieldManager);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("YIELD MANAGER ROLE SET SUCCESSFULLY");
        console.log("===========================================");
        console.log("YIELD_MANAGER_ROLE (", Roles.YIELD_MANAGER_ROLE, "):", yieldManager);
        console.log("");
        console.log("NOTE: To revoke from a previous address, use AccessManager.revokeRole()");
        console.log("===========================================");
    }
}
