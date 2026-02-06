// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Set Fee Poker Role
 * @notice Grants or updates the FEE_POKER_ROLE to a new address
 * @dev Use this script to change who can call poke() without reconfiguring the entire system
 *
 * DEPLOYMENT ORDER: 2b (After initial setup, can be run anytime)
 *
 * SENDER REQUIREMENTS: Must be run by AccessManager admin
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - FEE_POKER_{NETWORK}: New address to grant FEE_POKER_ROLE
 */
contract SetFeePokerScript is Script {
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

        envVar = string.concat("FEE_POKER_", network);
        address feePoker = vm.envAddress(envVar);
        require(feePoker != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("SETTING FEE POKER ROLE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("New Fee Poker:", feePoker);
        console.log("");

        Alphix alphix = Alphix(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Set up FEE_POKER_ROLE permissions on poke() function
        console.log("Step 1: Setting function permissions for FEE_POKER_ROLE...");
        bytes4[] memory feePokerSelectors = new bytes4[](1);
        feePokerSelectors[0] = alphix.poke.selector;
        accessManager.setTargetFunctionRole(hookAddr, feePokerSelectors, Roles.FEE_POKER_ROLE);
        console.log("  - poke() restricted to FEE_POKER_ROLE");

        // Grant FEE_POKER_ROLE to the new address
        console.log("Step 2: Granting FEE_POKER_ROLE...");
        accessManager.grantRole(Roles.FEE_POKER_ROLE, feePoker, 0);
        console.log("  - Granted to:", feePoker);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("FEE POKER ROLE SET SUCCESSFULLY");
        console.log("===========================================");
        console.log("FEE_POKER_ROLE (", Roles.FEE_POKER_ROLE, "):", feePoker);
        console.log("");
        console.log("NOTE: To revoke from a previous address, use AccessManager.revokeRole()");
        console.log("===========================================");
    }
}
