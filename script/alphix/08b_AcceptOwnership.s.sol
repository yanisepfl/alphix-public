// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Accept Ownership (Step 2)
 * @notice Completes ownership transfer by having the new owner accept
 * @dev Uses OpenZeppelin Ownable2Step for safe two-step ownership transfer
 *
 * DEPLOYMENT ORDER: 8b (Run after 08_TransferOwnership.s.sol)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 *
 * SENDER REQUIREMENTS: Must be the pending owner (the address specified in step 1)
 */
contract AcceptOwnershipScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        Alphix alphix = Alphix(hookAddr);
        address currentOwner = alphix.owner();
        address pendingOwner = alphix.pendingOwner();

        console.log("===========================================");
        console.log("ACCEPTING OWNERSHIP (STEP 2/2)");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("");
        console.log("Current Owner:", currentOwner);
        console.log("Pending Owner:", pendingOwner);
        console.log("");

        require(pendingOwner != address(0), "No pending ownership transfer");

        vm.startBroadcast();

        require(pendingOwner == msg.sender, "Caller is not pending owner");
        console.log("Accepting ownership...");
        alphix.acceptOwnership();
        console.log("  - Done");

        vm.stopBroadcast();

        // Verify
        address newOwner = alphix.owner();
        require(newOwner == msg.sender, "Ownership transfer failed");

        console.log("");
        console.log("===========================================");
        console.log("OWNERSHIP TRANSFER COMPLETE");
        console.log("===========================================");
        console.log("New Owner:", newOwner);
        console.log("");
        console.log("The new owner now controls:");
        console.log("  - Pausing/unpausing the hook");
        console.log("  - Setting pool parameters");
        console.log("  - Transferring ownership again");
        console.log("");
        console.log("AccessManager roles are separate - manage via AccessManager.");
        console.log("===========================================");
    }
}
