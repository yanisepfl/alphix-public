// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/**
 * @title Transfer Ownership
 * @notice Transfers ownership of all Alphix contracts to a multisig
 * @dev Uses OpenZeppelin Ownable2Step for safe ownership transfer
 *
 * USAGE: Run this script before production to transfer to multisig
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - FUTURE_MANAGER_{NETWORK}: New owner address (multisig)
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - ALPHIX_LOGIC_PROXY_{NETWORK}: AlphixLogic proxy address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 *
 * Process (2-step transfer):
 * 1. Current owner calls transferOwnership(newOwner) - initiates transfer
 * 2. New owner must call acceptOwnership() to complete transfer
 *
 * This script performs STEP 1 for all contracts.
 * The multisig must then perform STEP 2 by calling acceptOwnership() on each contract.
 *
 * Contracts to transfer:
 * - Alphix Hook
 * - AlphixLogic (proxy)
 * - AccessManager
 */
contract TransferOwnershipScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get new owner (multisig) address
        string memory newOwnerEnvVar = string.concat("FUTURE_MANAGER_", network);
        address newOwner = vm.envAddress(newOwnerEnvVar);
        require(newOwner != address(0), string.concat(newOwnerEnvVar, " not set"));

        // Get contract addresses
        string memory hookEnvVar = string.concat("ALPHIX_HOOK_", network);
        address alphixHookAddr = vm.envAddress(hookEnvVar);
        require(alphixHookAddr != address(0), string.concat(hookEnvVar, " not set"));

        string memory logicEnvVar = string.concat("ALPHIX_LOGIC_PROXY_", network);
        address alphixLogicAddr = vm.envAddress(logicEnvVar);
        require(alphixLogicAddr != address(0), string.concat(logicEnvVar, " not set"));

        string memory accessManagerEnvVar = string.concat("ACCESS_MANAGER_", network);
        address accessManagerAddr = vm.envAddress(accessManagerEnvVar);
        require(accessManagerAddr != address(0), string.concat(accessManagerEnvVar, " not set"));

        console.log("===========================================");
        console.log("TRANSFERRING OWNERSHIP (STEP 1/2)");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("New Owner (Multisig):", newOwner);
        console.log("");
        console.log("Contracts to transfer:");
        console.log("  - Alphix Hook:", alphixHookAddr);
        console.log("  - AlphixLogic Proxy:", alphixLogicAddr);
        console.log("  - AccessManager:", accessManagerAddr);
        console.log("");

        Alphix alphix = Alphix(alphixHookAddr);
        AlphixLogic logic = AlphixLogic(alphixLogicAddr);

        // Get current owners for verification
        address currentHookOwner = alphix.owner();
        address currentLogicOwner = logic.owner();
        // Note: AccessManager doesn't have a single owner, it has roles

        console.log("Current owners:");
        console.log("  - Alphix Hook:", currentHookOwner);
        console.log("  - AlphixLogic:", currentLogicOwner);
        console.log("");

        vm.startBroadcast();

        // Verify broadcaster is current owner (must be after startBroadcast)
        require(currentHookOwner == msg.sender, "Broadcaster is not current Alphix Hook owner");
        require(currentLogicOwner == msg.sender, "Broadcaster is not current AlphixLogic owner");
        console.log("Verification: Broadcaster is current owner of both contracts");
        console.log("");

        // Transfer Alphix Hook ownership
        console.log("Initiating ownership transfer for Alphix Hook...");
        alphix.transferOwnership(newOwner);
        console.log("  - Ownership transfer initiated");
        console.log("");

        // Transfer AlphixLogic ownership
        console.log("Initiating ownership transfer for AlphixLogic...");
        logic.transferOwnership(newOwner);
        console.log("  - Ownership transfer initiated");
        console.log("");

        // Note: AccessManager has a different ownership model
        // It uses role-based access, not Ownable2Step
        // The admin role must be transferred separately using grantRole/revokeRole

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("STEP 1 COMPLETE - PENDING ACCEPTANCE");
        console.log("===========================================");
        console.log("");
        console.log("IMPORTANT: Ownership transfer is NOT complete!");
        console.log("");
        console.log("The multisig (%s) must now:", newOwner);
        console.log("execute STEP 2 by calling acceptOwnership() on each contract:");
        console.log("");
        console.log("1. Alphix Hook (%s):", alphixHookAddr);
        console.log("   alphix.acceptOwnership()");
        console.log("");
        console.log("2. AlphixLogic Proxy (%s):", alphixLogicAddr);
        console.log("   logic.acceptOwnership()");
        console.log("");
        console.log("3. AccessManager (%s):", accessManagerAddr);
        console.log("   [Manual role transfer required - see below]");
        console.log("");
        console.log("===========================================");
        console.log("ACCESS MANAGER ROLE TRANSFER");
        console.log("===========================================");
        console.log("AccessManager uses role-based access control.");
        console.log("To transfer admin rights:");
        console.log("");
        console.log("From current admin address, execute:");
        console.log("1. accessManager.grantRole(ADMIN_ROLE, %s, 0)", newOwner);
        console.log("2. Verify new admin has access");
        console.log("3. accessManager.revokeRole(ADMIN_ROLE, %s)", currentHookOwner);
        console.log("");
        console.log("ADMIN_ROLE = 0 (default admin role)");
        console.log("===========================================");
        console.log("");
        console.log("VERIFICATION:");
        console.log("After multisig accepts ownership:");
        console.log("- Check alphix.owner() == %s", newOwner);
        console.log("- Check logic.owner() == %s", newOwner);
        console.log("- Check accessManager hasRole for multisig");
        console.log("===========================================");
    }
}
