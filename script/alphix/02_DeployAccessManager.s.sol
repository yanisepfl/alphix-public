// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/**
 * @title Deploy AccessManager
 * @notice Deploys the OpenZeppelin AccessManager for role-based access control
 * @dev This must be deployed first as other contracts depend on it
 *
 * DEPLOYMENT ORDER: 1/6
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., BASE_SEPOLIA)
 * - ALPHIX_MANAGER_{NETWORK}: Initial admin address
 *
 * After Deployment:
 * - Copy the deployed address to ACCESS_MANAGER_{NETWORK} in .env
 */
contract DeployAccessManagerScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get initial admin address
        string memory adminEnvVar = string.concat("ALPHIX_MANAGER_", network);
        address initialAdmin = vm.envAddress(adminEnvVar);
        require(initialAdmin != address(0), string.concat(adminEnvVar, " not set or invalid"));

        console.log("===========================================");
        console.log("DEPLOYING ACCESS MANAGER");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Initial Admin:", initialAdmin);
        console.log("");

        // Deploy AccessManager
        vm.startBroadcast();
        AccessManager accessManager = new AccessManager(initialAdmin);
        vm.stopBroadcast();

        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("AccessManager deployed at:", address(accessManager));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Add this to your .env file:");
        console.log("   ACCESS_MANAGER_%s=%s", network, address(accessManager));
        console.log("2. Run script 03_DeployRegistry.s.sol");
        console.log("===========================================");
    }
}
