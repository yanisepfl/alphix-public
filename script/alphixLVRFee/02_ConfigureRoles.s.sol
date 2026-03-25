// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {AlphixLVRFee} from "../../src/AlphixLVRFee.sol";
import {Roles} from "../alphix/libraries/Roles.sol";

/**
 * @title Configure AlphixLVRFee Roles
 * @notice Sets up AccessManager roles for the AlphixLVRFee hook
 * @dev Configures FEE_POKER_ROLE, Roles.HOOK_FEE_ROLE, and PAUSER_ROLE permissions
 *
 * DEPLOYMENT ORDER: 2 (After AlphixLVRFee deployment)
 *
 * SENDER REQUIREMENTS: Must be run by AccessManager admin
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LVR_FEE_HOOK_{NETWORK}: AlphixLVRFee Hook contract address
 * - ACCESS_MANAGER_LVR_{NETWORK}: AccessManager contract address
 * - FEE_POKER_LVR_{NETWORK}: Address to grant FEE_POKER_ROLE
 * - HOOK_FEE_MANAGER_LVR_{NETWORK}: Address to grant HOOK_FEE_ROLE (setHookFee, setTreasury)
 * - PAUSER_LVR_{NETWORK}: Address to grant PAUSER_ROLE
 */
contract ConfigureRolesLVRFeeScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_LVR_FEE_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_LVR_", network);
        address accessManagerAddr = vm.envAddress(envVar);
        require(accessManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("FEE_POKER_LVR_", network);
        address feePoker = vm.envAddress(envVar);
        require(feePoker != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("HOOK_FEE_MANAGER_LVR_", network);
        address hookFeeManager = vm.envAddress(envVar);
        require(hookFeeManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("PAUSER_LVR_", network);
        address pauser = vm.envAddress(envVar);
        require(pauser != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("CONFIGURING ALPHIX LVR FEE ROLES");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AlphixLVRFee Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Fee Poker:", feePoker);
        console.log("Hook Fee Manager:", hookFeeManager);
        console.log("Pauser:", pauser);
        console.log("");

        AlphixLVRFee hook = AlphixLVRFee(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Step 1: Grant FEE_POKER_ROLE for poke()
        console.log("Step 1: Setting up FEE_POKER_ROLE...");
        bytes4[] memory pokeSelectors = new bytes4[](1);
        pokeSelectors[0] = hook.poke.selector;
        accessManager.setTargetFunctionRole(hookAddr, pokeSelectors, Roles.FEE_POKER_ROLE);
        accessManager.grantRole(Roles.FEE_POKER_ROLE, feePoker, 0);
        console.log("  - Granted to:", feePoker);

        // Step 2: Grant HOOK_FEE_ROLE for setHookFee() and setTreasury()
        console.log("Step 2: Setting up HOOK_FEE_ROLE...");
        bytes4[] memory hookFeeSelectors = new bytes4[](2);
        hookFeeSelectors[0] = hook.setHookFee.selector;
        hookFeeSelectors[1] = hook.setTreasury.selector;
        accessManager.setTargetFunctionRole(hookAddr, hookFeeSelectors, Roles.HOOK_FEE_ROLE);
        accessManager.grantRole(Roles.HOOK_FEE_ROLE, hookFeeManager, 0);
        console.log("  - Granted to:", hookFeeManager);

        // Step 3: Grant PAUSER_ROLE for pause/unpause
        console.log("Step 3: Setting up PAUSER_ROLE...");
        bytes4[] memory pauseSelectors = new bytes4[](2);
        pauseSelectors[0] = hook.pause.selector;
        pauseSelectors[1] = hook.unpause.selector;
        accessManager.setTargetFunctionRole(hookAddr, pauseSelectors, Roles.PAUSER_ROLE);
        accessManager.grantRole(Roles.PAUSER_ROLE, pauser, 0);
        console.log("  - Granted to:", pauser);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("ROLES CONFIGURED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Roles configured:");
        console.log("  - FEE_POKER_ROLE (", Roles.FEE_POKER_ROLE, "):", feePoker);
        console.log("  - HOOK_FEE_ROLE (", Roles.HOOK_FEE_ROLE, "):", hookFeeManager);
        console.log("  - PAUSER_ROLE (", Roles.PAUSER_ROLE, "):", pauser);
        console.log("");
        console.log("Next: Run 03_CreatePool.s.sol");
        console.log("===========================================");
    }
}
