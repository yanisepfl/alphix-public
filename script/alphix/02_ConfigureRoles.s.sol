// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Configure Alphix Roles
 * @notice Sets up AccessManager roles for the Alphix hook
 * @dev Configures YIELD_MANAGER_ROLE and FEE_POKER_ROLE permissions
 *
 * DEPLOYMENT ORDER: 2 (After Alphix/AlphixETH deployment)
 *
 * SENDER REQUIREMENTS: Must be run by AccessManager admin
 *
 * Actions Performed:
 * 1. Grant YIELD_MANAGER_ROLE permissions on Alphix functions (setYieldSource)
 * 2. Grant YIELD_MANAGER_ROLE to specified address
 * 3. Grant FEE_POKER_ROLE permissions on poke() function
 * 4. Grant FEE_POKER_ROLE to specified address
 * 5. Grant PAUSER_ROLE permissions on pause()/unpause() functions
 * 6. Grant PAUSER_ROLE to specified address
 *
 * NOTE: The hook is unpaused automatically by initializePool() in script 03.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - YIELD_MANAGER_{NETWORK}: Address to grant YIELD_MANAGER_ROLE (REQUIRED)
 * - FEE_POKER_{NETWORK}: Address to grant FEE_POKER_ROLE (REQUIRED)
 * - PAUSER_{NETWORK}: Address to grant PAUSER_ROLE (REQUIRED)
 *
 * After this script:
 * - Roles are configured
 * - Run 03_CreatePool.s.sol to initialize the pool (which also unpauses the hook)
 */
contract ConfigureRolesScript is Script {
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

        // Required: yield manager address
        envVar = string.concat("YIELD_MANAGER_", network);
        address yieldManager = vm.envAddress(envVar);
        require(yieldManager != address(0), string.concat(envVar, " not set"));

        // Required: fee poker address
        envVar = string.concat("FEE_POKER_", network);
        address feePoker = vm.envAddress(envVar);
        require(feePoker != address(0), string.concat(envVar, " not set"));

        // Required: pauser address
        envVar = string.concat("PAUSER_", network);
        address pauser = vm.envAddress(envVar);
        require(pauser != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("CONFIGURING ALPHIX ROLES");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Yield Manager:", yieldManager);
        console.log("Fee Poker:", feePoker);
        console.log("Pauser:", pauser);
        console.log("");

        Alphix alphix = Alphix(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Step 1: Set up YIELD_MANAGER_ROLE permissions
        console.log("Step 1: Setting up YIELD_MANAGER_ROLE permissions...");
        bytes4[] memory yieldManagerSelectors = new bytes4[](1);
        yieldManagerSelectors[0] = alphix.setYieldSource.selector;
        accessManager.setTargetFunctionRole(hookAddr, yieldManagerSelectors, Roles.YIELD_MANAGER_ROLE);
        console.log("  - Function permissions set");

        // Step 2: Grant YIELD_MANAGER_ROLE
        console.log("Step 2: Granting YIELD_MANAGER_ROLE...");
        accessManager.grantRole(Roles.YIELD_MANAGER_ROLE, yieldManager, 0);
        console.log("  - Granted to:", yieldManager);

        // Step 3: Grant FEE_POKER_ROLE
        console.log("Step 3: Setting up FEE_POKER_ROLE...");
        bytes4[] memory feePokerSelectors = new bytes4[](1);
        feePokerSelectors[0] = alphix.poke.selector;
        accessManager.setTargetFunctionRole(hookAddr, feePokerSelectors, Roles.FEE_POKER_ROLE);
        accessManager.grantRole(Roles.FEE_POKER_ROLE, feePoker, 0);
        console.log("  - Granted to:", feePoker);

        // Step 4: Grant PAUSER_ROLE
        console.log("Step 4: Setting up PAUSER_ROLE...");
        bytes4[] memory pauserSelectors = new bytes4[](2);
        pauserSelectors[0] = alphix.pause.selector;
        pauserSelectors[1] = alphix.unpause.selector;
        accessManager.setTargetFunctionRole(hookAddr, pauserSelectors, Roles.PAUSER_ROLE);
        accessManager.grantRole(Roles.PAUSER_ROLE, pauser, 0);
        console.log("  - Granted to:", pauser);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("ROLES CONFIGURED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Roles configured:");
        console.log("  - YIELD_MANAGER_ROLE (", Roles.YIELD_MANAGER_ROLE, "):", yieldManager);
        console.log("  - FEE_POKER_ROLE (", Roles.FEE_POKER_ROLE, "):", feePoker);
        console.log("  - PAUSER_ROLE (", Roles.PAUSER_ROLE, "):", pauser);
        console.log("");
        console.log("NOTE: Hook is still PAUSED. It will be unpaused");
        console.log("      automatically when initializePool() is called.");
        console.log("");
        console.log("Next: Run 03_CreatePool.s.sol");
        console.log("===========================================");
    }
}
