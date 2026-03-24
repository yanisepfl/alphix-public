// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {AlphixLVR} from "../../src/AlphixLVR.sol";
import {Roles} from "../alphix/libraries/Roles.sol";

/**
 * @title Configure AlphixLVR Roles
 * @notice Sets up AccessManager roles for the AlphixLVR hook
 * @dev Configures FEE_POKER_ROLE and PAUSER_ROLE permissions
 *
 * DEPLOYMENT ORDER: 2 (After AlphixLVR deployment)
 *
 * SENDER REQUIREMENTS: Must be run by AccessManager admin
 *
 * Actions Performed:
 * 1. Grant FEE_POKER_ROLE permissions on poke() function
 * 2. Grant FEE_POKER_ROLE to specified address
 * 3. Grant PAUSER_ROLE permissions on pause()/unpause() functions
 * 4. Grant PAUSER_ROLE to specified address
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LVR_HOOK_{NETWORK}: AlphixLVR Hook contract address
 * - ACCESS_MANAGER_LVR_{NETWORK}: LVR-specific AccessManager contract address
 * - FEE_POKER_LVR_{NETWORK}: Address to grant FEE_POKER_ROLE (LVR-specific, compartmentalized)
 * - PAUSER_LVR_{NETWORK}: Address to grant PAUSER_ROLE (LVR-specific, compartmentalized)
 */
contract ConfigureRolesLVRScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_LVR_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_LVR_", network);
        address accessManagerAddr = vm.envAddress(envVar);
        require(accessManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("FEE_POKER_LVR_", network);
        address feePoker = vm.envAddress(envVar);
        require(feePoker != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("PAUSER_LVR_", network);
        address pauser = vm.envAddress(envVar);
        require(pauser != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("CONFIGURING ALPHIX LVR ROLES");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AlphixLVR Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Fee Poker:", feePoker);
        console.log("Pauser:", pauser);
        console.log("");

        AlphixLVR hook = AlphixLVR(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Step 1: Grant FEE_POKER_ROLE
        console.log("Step 1: Setting up FEE_POKER_ROLE...");
        bytes4[] memory feePokerSelectors = new bytes4[](1);
        feePokerSelectors[0] = hook.poke.selector;
        accessManager.setTargetFunctionRole(hookAddr, feePokerSelectors, Roles.FEE_POKER_ROLE);
        accessManager.grantRole(Roles.FEE_POKER_ROLE, feePoker, 0);
        console.log("  - Granted to:", feePoker);

        // Step 2: Grant PAUSER_ROLE
        console.log("Step 2: Setting up PAUSER_ROLE...");
        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = hook.pause.selector;
        pauserSelectors[1] = hook.unpause.selector;
        accessManager.setTargetFunctionRole(hookAddr, pauserSelectors, Roles.PAUSER_ROLE);
        accessManager.grantRole(Roles.PAUSER_ROLE, pauser, 0);
        console.log("  - Granted to:", pauser);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("ROLES CONFIGURED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Roles configured:");
        console.log("  - FEE_POKER_ROLE (", Roles.FEE_POKER_ROLE, "):", feePoker);
        console.log("  - PAUSER_ROLE (", Roles.PAUSER_ROLE, "):", pauser);
        console.log("");
        console.log("Next: Run 03_CreatePool.s.sol to create a pool");
        console.log("===========================================");
    }
}
