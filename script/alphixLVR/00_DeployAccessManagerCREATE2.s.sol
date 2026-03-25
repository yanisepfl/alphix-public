// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/**
 * @title Deploy AccessManager via CREATE2
 * @notice Deploys the OpenZeppelin AccessManager deterministically for same-address cross-chain deployment
 * @dev Uses the universal CREATE2 deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) to ensure
 *      the same AccessManager address is deployed on all chains when using the same admin and salt.
 *
 * DEPLOYMENT ORDER: 0 (First)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., ETH, BASE, ARB)
 * - ACCESS_MANAGER_ADMIN_LVR_{NETWORK}: Initial admin address (same across all chains for same address)
 * - ACCESS_MANAGER_SALT_LVR: Fixed bytes32 salt (same across all chains)
 * - CREATE2_DEPLOYER_{NETWORK}: CREATE2 factory address (usually 0x4e59b44847b379578588920cA78FbF26c0B4956C)
 *
 * After Deployment:
 * - Copy the deployed address to ACCESS_MANAGER_LVR_{NETWORK} in .env
 * - Verify the address matches across all chains
 */
contract DeployAccessManagerCREATE2Script is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ACCESS_MANAGER_ADMIN_LVR_", network);
        address initialAdmin = vm.envAddress(envVar);
        require(initialAdmin != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("CREATE2_DEPLOYER_", network);
        address create2Deployer = vm.envAddress(envVar);
        require(create2Deployer != address(0), string.concat(envVar, " not set"));

        bytes32 salt = vm.envBytes32("ACCESS_MANAGER_SALT_LVR");

        console.log("===========================================");
        console.log("DEPLOYING ACCESS MANAGER (CREATE2)");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Initial Admin:", initialAdmin);
        console.log("CREATE2 Deployer:", create2Deployer);
        console.log("Salt:", vm.toString(salt));
        console.log("");

        // Predict the address using the deployer
        bytes memory creationCode = abi.encodePacked(type(AccessManager).creationCode, abi.encode(initialAdmin));
        address predicted = vm.computeCreate2Address(salt, keccak256(creationCode), create2Deployer);
        console.log("Predicted address:", predicted);

        vm.startBroadcast();
        AccessManager accessManager = new AccessManager{salt: salt}(initialAdmin);
        vm.stopBroadcast();

        require(address(accessManager) == predicted, "Address mismatch - check salt and admin");

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("AccessManager deployed at:", address(accessManager));
        console.log("");
        console.log("Add to .env:");
        console.log("  ACCESS_MANAGER_LVR_%s=%s", network, address(accessManager));
        console.log("");
        console.log("IMPORTANT: Use the SAME admin and salt on all chains for same address.");
        console.log("Next: Run 01_DeployAlphixLVR.s.sol");
        console.log("===========================================");
    }
}
