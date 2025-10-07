// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";

/**
 * @title Configure Alphix System
 * @notice Connects all deployed components and initializes the system
 * @dev This script must be run after all contracts are deployed
 *
 * DEPLOYMENT ORDER: 6/11
 *
 * IMPORTANT: This script must be run by the ALPHIX_MANAGER address (contract owner)
 * Function called requires owner privileges:
 * - alphix.initialize() - onlyOwner
 *
 * Prerequisites:
 * - Script 04 (DeployAlphix) completed
 * - Script 05 (DeployAlphixLogic) completed
 * - AlphixLogic already initialized with Alphix Hook address
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ALPHIX_LOGIC_PROXY_{NETWORK}: AlphixLogic proxy address
 * - ACCOUNT_PRIVATE_KEY: Must correspond to ALPHIX_MANAGER address
 *
 * Actions Performed:
 * 1. Set AlphixLogic proxy address in Alphix Hook (initializes hook)
 * 2. Unpause the Alphix Hook (activates the system)
 *
 * Note: AlphixLogic was already initialized with the hook address in script 05,
 * so we don't need to call setAlphixHook() here.
 *
 * After this script:
 * - The system is fully configured and operational
 * - Users can create pools with the Alphix Hook
 */
contract ConfigureSystemScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get Alphix Hook address
        string memory hookEnvVar = string.concat("ALPHIX_HOOK_", network);
        address alphixHookAddr = vm.envAddress(hookEnvVar);
        require(alphixHookAddr != address(0), string.concat(hookEnvVar, " not set"));

        // Get AlphixLogic proxy address
        string memory logicEnvVar = string.concat("ALPHIX_LOGIC_PROXY_", network);
        address alphixLogicAddr = vm.envAddress(logicEnvVar);
        require(alphixLogicAddr != address(0), string.concat(logicEnvVar, " not set"));

        console.log("===========================================");
        console.log("CONFIGURING ALPHIX SYSTEM");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", alphixHookAddr);
        console.log("AlphixLogic Proxy:", alphixLogicAddr);
        console.log("");

        Alphix alphix = Alphix(alphixHookAddr);
        AlphixLogic logic = AlphixLogic(alphixLogicAddr);

        vm.startBroadcast();

        // Step 1: Initialize Alphix Hook with AlphixLogic proxy address
        console.log("Step 1: Setting AlphixLogic in Alphix Hook...");
        alphix.initialize(alphixLogicAddr);
        console.log("  - AlphixLogic set successfully");
        console.log("  - Hook unpaused automatically");
        console.log("");

        vm.stopBroadcast();

        // Verify configuration
        console.log("===========================================");
        console.log("VERIFYING CONFIGURATION");
        console.log("===========================================");

        bool isPaused = alphix.paused();
        console.log("Hook paused:", isPaused);
        require(!isPaused, "Hook should be unpaused");

        address configuredLogic = alphix.getLogic();
        console.log("Logic in Hook:", configuredLogic);
        require(configuredLogic == alphixLogicAddr, "Logic address mismatch");

        address configuredHook = logic.getAlphixHook();
        console.log("Hook in Logic:", configuredHook);
        require(configuredHook == alphixHookAddr, "Hook address mismatch");

        console.log("");
        console.log("===========================================");
        console.log("CONFIGURATION SUCCESSFUL");
        console.log("===========================================");
        console.log("The Alphix system is now fully configured and operational!");
        console.log("");
        console.log("SYSTEM ARCHITECTURE:");
        console.log("  Users interact with -> Alphix Hook:", alphixHookAddr);
        console.log("  Hook delegates to   -> AlphixLogic Proxy:", alphixLogicAddr);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Create pools using the Alphix Hook address");
        console.log("2. To upgrade logic: use script 07_UpgradeAlphixLogic.s.sol");
        console.log("3. To transfer ownership: use script 08_TransferOwnership.s.sol");
        console.log("===========================================");
    }
}
