// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Configure and Unpause Alphix System
 * @notice Sets up roles and activates the Alphix hook
 * @dev This script configures YIELD_MANAGER_ROLE permissions and unpauses the hook
 *
 * DEPLOYMENT ORDER: 2 (After Alphix/AlphixETH deployment)
 *
 * SENDER REQUIREMENTS: Must be run by ALPHIX_MANAGER (hook owner and AccessManager admin)
 *
 * Actions Performed:
 * 1. Grant YIELD_MANAGER_ROLE permissions on Alphix functions
 * 2. Grant YIELD_MANAGER_ROLE to specified address
 * 3. Optionally grant FEE_POKER_ROLE for fee updates
 * 4. Unpause the Alphix Hook (activates the system)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - YIELD_MANAGER_{NETWORK}: Address to grant YIELD_MANAGER_ROLE (optional, defaults to caller)
 * - FEE_POKER_{NETWORK}: Address to grant FEE_POKER_ROLE (optional)
 *
 * After this script:
 * - System is fully configured and operational
 * - Users can create the pool using script 03
 */
contract ConfigureAndUnpauseScript is Script {
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

        // Optional: yield manager address (defaults to caller if not set)
        address yieldManager;
        envVar = string.concat("YIELD_MANAGER_", network);
        try vm.envAddress(envVar) returns (address addr) {
            yieldManager = addr;
        } catch {
            yieldManager = address(0); // Will use msg.sender
        }

        // Optional: fee poker address
        address feePoker;
        envVar = string.concat("FEE_POKER_", network);
        try vm.envAddress(envVar) returns (address addr) {
            feePoker = addr;
        } catch {
            feePoker = address(0);
        }

        console.log("===========================================");
        console.log("CONFIGURING ALPHIX SYSTEM");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("AccessManager:", accessManagerAddr);
        if (yieldManager != address(0)) {
            console.log("Yield Manager:", yieldManager);
        } else {
            console.log("Yield Manager: (will use caller)");
        }
        if (feePoker != address(0)) {
            console.log("Fee Poker:", feePoker);
        }
        console.log("");

        Alphix alphix = Alphix(hookAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Use caller as yield manager if not specified
        if (yieldManager == address(0)) {
            yieldManager = msg.sender;
        }

        // Step 1: Set up YIELD_MANAGER_ROLE permissions
        console.log("Step 1: Setting up YIELD_MANAGER_ROLE permissions...");
        bytes4[] memory yieldManagerSelectors = new bytes4[](2);
        yieldManagerSelectors[0] = alphix.setYieldSource.selector;
        yieldManagerSelectors[1] = alphix.setTickRange.selector;
        accessManager.setTargetFunctionRole(hookAddr, yieldManagerSelectors, Roles.YIELD_MANAGER_ROLE);
        console.log("  - Function permissions set");

        // Step 2: Grant YIELD_MANAGER_ROLE
        console.log("Step 2: Granting YIELD_MANAGER_ROLE...");
        accessManager.grantRole(Roles.YIELD_MANAGER_ROLE, yieldManager, 0);
        console.log("  - Granted to:", yieldManager);

        // Step 3: Optionally grant FEE_POKER_ROLE
        if (feePoker != address(0)) {
            console.log("Step 3: Setting up FEE_POKER_ROLE...");
            bytes4[] memory feePokerSelectors = new bytes4[](1);
            feePokerSelectors[0] = alphix.poke.selector;
            accessManager.setTargetFunctionRole(hookAddr, feePokerSelectors, Roles.FEE_POKER_ROLE);
            accessManager.grantRole(Roles.FEE_POKER_ROLE, feePoker, 0);
            console.log("  - Granted to:", feePoker);
        }

        // Step 4: Unpause the hook
        console.log("Step 4: Unpausing Alphix Hook...");
        alphix.unpause();
        console.log("  - Hook unpaused");

        vm.stopBroadcast();

        // Verify
        require(!alphix.paused(), "Hook should be unpaused");

        console.log("");
        console.log("===========================================");
        console.log("CONFIGURATION SUCCESSFUL");
        console.log("===========================================");
        console.log("Alphix system is now operational!");
        console.log("");
        console.log("Roles configured:");
        console.log("  - YIELD_MANAGER_ROLE (", Roles.YIELD_MANAGER_ROLE, "):", yieldManager);
        if (feePoker != address(0)) {
            console.log("  - FEE_POKER_ROLE (", Roles.FEE_POKER_ROLE, "):", feePoker);
        }
        console.log("");
        console.log("Next: Run 03_CreatePool.s.sol");
        console.log("===========================================");
    }
}
