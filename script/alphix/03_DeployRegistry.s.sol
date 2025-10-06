// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Registry} from "../../src/Registry.sol";

/**
 * @title Deploy Registry
 * @notice Deploys the Registry contract for tracking Alphix ecosystem contracts and pools
 * @dev Requires AccessManager to be deployed first
 *
 * DEPLOYMENT ORDER: 2/6
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address (from script 02)
 *
 * After Deployment:
 * - Copy the deployed address to REGISTRY_{NETWORK} in .env
 */
contract DeployRegistryScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get AccessManager address
        string memory accessManagerEnvVar = string.concat("ACCESS_MANAGER_", network);
        address accessManager = vm.envAddress(accessManagerEnvVar);
        require(accessManager != address(0), string.concat(accessManagerEnvVar, " not set or invalid"));

        console.log("===========================================");
        console.log("DEPLOYING REGISTRY");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AccessManager:", accessManager);
        console.log("");

        // Deploy Registry
        vm.startBroadcast();
        Registry registry = new Registry(accessManager);
        vm.stopBroadcast();

        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("Registry deployed at:", address(registry));
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Add this to your .env file:");
        console.log("   REGISTRY_%s=%s", network, address(registry));
        console.log("2. Run script 04_DeployAlphixLogic.s.sol");
        console.log("===========================================");
    }
}
