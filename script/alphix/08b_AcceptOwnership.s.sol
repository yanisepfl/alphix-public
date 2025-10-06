// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";

/**
 * @title Accept Ownership (Step 2 of 2)
 * @notice Multisig accepts ownership of Alphix contracts using Ownable2Step pattern
 * @dev This script completes the ownership transfer initiated by 08_TransferOwnership.s.sol
 *
 * DEPLOYMENT ORDER: 8b/11 (run after 08_TransferOwnership.s.sol)
 *
 * CRITICAL: This script MUST be run by the FUTURE_MANAGER address (multisig)
 * - The private key used must correspond to FUTURE_MANAGER
 * - If wrong address is used, transaction will revert
 *
 * Ownable2Step Pattern:
 * - Step 1 (script 08): Current owner calls transferOwnership(newOwner)
 * - Step 2 (this script): New owner calls acceptOwnership()
 * - This two-step process prevents accidental transfers to wrong addresses
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ALPHIX_LOGIC_PROXY_{NETWORK}: AlphixLogic proxy address
 * - FUTURE_MANAGER_{NETWORK}: New owner address (multisig)
 * - ACCOUNT_PRIVATE_KEY: Must correspond to FUTURE_MANAGER address
 *
 * After Execution:
 * - Alphix Hook ownership transferred to FUTURE_MANAGER
 * - AlphixLogic ownership transferred to FUTURE_MANAGER
 * - Run 08c_TransferAccessManagerAdmin.s.sol for AccessManager admin transfer
 */
contract AcceptOwnershipScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get contract addresses
        string memory hookEnvVar = string.concat("ALPHIX_HOOK_", network);
        address alphixHookAddr = vm.envAddress(hookEnvVar);
        require(alphixHookAddr != address(0), string.concat(hookEnvVar, " not set"));

        string memory logicEnvVar = string.concat("ALPHIX_LOGIC_PROXY_", network);
        address alphixLogicAddr = vm.envAddress(logicEnvVar);
        require(alphixLogicAddr != address(0), string.concat(logicEnvVar, " not set"));

        // Get expected new owner (multisig)
        string memory newOwnerEnvVar = string.concat("FUTURE_MANAGER_", network);
        address expectedNewOwner = vm.envAddress(newOwnerEnvVar);
        require(expectedNewOwner != address(0), string.concat(newOwnerEnvVar, " not set"));

        console.log("===========================================");
        console.log("ACCEPTING OWNERSHIP (STEP 2/2)");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", alphixHookAddr);
        console.log("AlphixLogic Proxy:", alphixLogicAddr);
        console.log("Expected New Owner:", expectedNewOwner);
        console.log("");

        Alphix alphix = Alphix(alphixHookAddr);
        AlphixLogic logic = AlphixLogic(alphixLogicAddr);

        // Get current ownership state
        address currentHookOwner = alphix.owner();
        address pendingHookOwner = alphix.pendingOwner();
        address currentLogicOwner = logic.owner();
        address pendingLogicOwner = logic.pendingOwner();

        console.log("Current Ownership State:");
        console.log("  Alphix Hook:");
        console.log("    - Current Owner:", currentHookOwner);
        console.log("    - Pending Owner:", pendingHookOwner);
        console.log("  AlphixLogic:");
        console.log("    - Current Owner:", currentLogicOwner);
        console.log("    - Pending Owner:", pendingLogicOwner);
        console.log("");

        // Verify pending owners match expected new owner
        if (pendingHookOwner != expectedNewOwner) {
            console.log("WARNING: Alphix Hook pending owner does not match FUTURE_MANAGER");
            console.log("Expected:", expectedNewOwner);
            console.log("Actual:", pendingHookOwner);
            revert("Pending owner mismatch - run script 08 first");
        }

        if (pendingLogicOwner != expectedNewOwner) {
            console.log("WARNING: AlphixLogic pending owner does not match FUTURE_MANAGER");
            console.log("Expected:", expectedNewOwner);
            console.log("Actual:", pendingLogicOwner);
            revert("Pending owner mismatch - run script 08 first");
        }

        console.log("Verification passed - pending owners match FUTURE_MANAGER");
        console.log("");

        vm.startBroadcast();

        // Accept Alphix Hook ownership
        console.log("Accepting Alphix Hook ownership...");
        try alphix.acceptOwnership() {
            console.log("  - Alphix Hook ownership accepted successfully");
        } catch Error(string memory reason) {
            console.log("  - FAILED:", reason);
            revert(reason);
        }
        console.log("");

        // Accept AlphixLogic ownership
        console.log("Accepting AlphixLogic ownership...");
        try logic.acceptOwnership() {
            console.log("  - AlphixLogic ownership accepted successfully");
        } catch Error(string memory reason) {
            console.log("  - FAILED:", reason);
            revert(reason);
        }
        console.log("");

        vm.stopBroadcast();

        // Verify ownership transfer completed
        address newHookOwner = alphix.owner();
        address newLogicOwner = logic.owner();

        console.log("===========================================");
        console.log("OWNERSHIP ACCEPTANCE COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("New Ownership State:");
        console.log("  Alphix Hook:");
        console.log("    - Old Owner:", currentHookOwner);
        console.log("    - New Owner:", newHookOwner);
        console.log("    - Status:", newHookOwner == expectedNewOwner ? "SUCCESS" : "FAILED");
        console.log("");
        console.log("  AlphixLogic:");
        console.log("    - Old Owner:", currentLogicOwner);
        console.log("    - New Owner:", newLogicOwner);
        console.log("    - Status:", newLogicOwner == expectedNewOwner ? "SUCCESS" : "FAILED");
        console.log("");

        // Final verification
        require(newHookOwner == expectedNewOwner, "Alphix Hook ownership transfer failed");
        require(newLogicOwner == expectedNewOwner, "AlphixLogic ownership transfer failed");

        console.log("===========================================");
        console.log("ALL OWNERSHIPS TRANSFERRED SUCCESSFULLY");
        console.log("===========================================");
        console.log("");
        console.log("Multisig (%s) now owns:", expectedNewOwner);
        console.log("  - Alphix Hook");
        console.log("  - AlphixLogic Proxy");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Run script 08c_TransferAccessManagerAdmin.s.sol");
        console.log("   to transfer AccessManager admin role to multisig");
        console.log("2. Verify all contract ownerships:");
        console.log("   alphix.owner() == %s", expectedNewOwner);
        console.log("   logic.owner() == %s", expectedNewOwner);
        console.log("3. Test multisig can call owner-only functions");
        console.log("===========================================");
    }
}
