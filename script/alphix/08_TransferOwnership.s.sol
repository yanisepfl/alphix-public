// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Transfer Ownership (Step 1)
 * @notice Initiates ownership transfer of the Alphix hook to a new owner (e.g., multisig)
 * @dev Uses OpenZeppelin Ownable2Step for safe two-step ownership transfer
 *
 * DEPLOYMENT ORDER: 8 (Production handoff - run when ready to transfer to multisig)
 *
 * Two-Step Transfer Process:
 * 1. Current owner calls transferOwnership(newOwner) - THIS SCRIPT
 * 2. New owner calls acceptOwnership() - Script 08b
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - NEW_OWNER_{NETWORK}: New owner address (multisig)
 *
 * SENDER REQUIREMENTS: Must be current owner of Alphix Hook
 */
contract TransferOwnershipScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("NEW_OWNER_", network);
        address newOwner = vm.envAddress(envVar);
        require(newOwner != address(0), string.concat(envVar, " not set"));

        Alphix alphix = Alphix(hookAddr);
        address currentOwner = alphix.owner();

        // Get the broadcaster address from the private key
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);

        console.log("===========================================");
        console.log("TRANSFERRING OWNERSHIP (STEP 1/2)");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("");
        console.log("Current Owner:", currentOwner);
        console.log("Broadcaster:", broadcaster);
        console.log("New Owner:", newOwner);
        console.log("");

        require(currentOwner == broadcaster, "Broadcaster is not current owner");

        vm.startBroadcast(privateKey);
        console.log("Initiating ownership transfer...");
        alphix.transferOwnership(newOwner);
        console.log("  - Done");

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("STEP 1 COMPLETE - PENDING ACCEPTANCE");
        console.log("===========================================");
        console.log("");
        console.log("IMPORTANT: Ownership transfer is NOT complete!");
        console.log("");
        console.log("The new owner must now call acceptOwnership():");
        console.log("  - Address:", newOwner);
        console.log("  - Contract:", hookAddr);
        console.log("");
        console.log("Run script 08b_AcceptOwnership.s.sol from the new owner address.");
        console.log("===========================================");
    }
}
