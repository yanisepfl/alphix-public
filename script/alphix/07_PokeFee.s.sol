// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Poke Fee
 * @notice Updates the dynamic fee based on current pool ratio
 * @dev Anyone can call this to trigger a fee update (if cooldown has passed)
 *
 * DEPLOYMENT ORDER: 7 (Operational script - run anytime)
 *
 * How Dynamic Fees Work:
 * 1. The fee adjusts based on pool ratio vs target ratio
 * 2. If ratio is above target: fee increases (discourage buys)
 * 3. If ratio is below target: fee decreases (encourage buys)
 * 4. A cooldown period prevents too-frequent updates
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - CURRENT_RATIO_{NETWORK}: Current pool ratio (from oracle or calculation)
 *
 * Note: The current ratio should be provided by an off-chain oracle or
 * calculated based on current market conditions.
 */
contract PokeFeeScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("CURRENT_RATIO_", network);
        uint256 currentRatio = vm.envUint(envVar);
        require(currentRatio > 0, "CURRENT_RATIO must be > 0");

        Alphix alphix = Alphix(hookAddr);

        // Get current fee
        uint24 currentFee = alphix.getFee();

        console.log("===========================================");
        console.log("POKING FEE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Hook:", hookAddr);
        console.log("");
        console.log("Current State:");
        console.log("  - Current Fee:", currentFee, "bps");
        console.log("  - New Ratio:", currentRatio);
        console.log("");

        // Preview the update
        (uint24 newFee,, bool wouldUpdate) = alphix.computeFeeUpdate(currentRatio);

        if (!wouldUpdate) {
            console.log("Fee update would NOT occur:");
            console.log("  - Cooldown not passed, or");
            console.log("  - Ratio within tolerance");
        } else {
            console.log("Fee WILL be updated:");
            console.log("  - New Fee:", newFee, "bps");
        }
        console.log("");

        vm.startBroadcast();

        console.log("Calling poke...");
        alphix.poke(currentRatio);
        console.log("  - Done");

        vm.stopBroadcast();

        // Get updated fee
        uint24 updatedFee = alphix.getFee();

        console.log("");
        console.log("===========================================");
        console.log("FEE UPDATE COMPLETE");
        console.log("===========================================");
        console.log("Previous Fee:", currentFee, "bps");
        console.log("Updated Fee:", updatedFee, "bps");
        console.log("");
        if (updatedFee > currentFee) {
            console.log("Fee INCREASED (ratio above target)");
        } else if (updatedFee < currentFee) {
            console.log("Fee DECREASED (ratio below target)");
        } else {
            console.log("Fee unchanged (within tolerance or cooldown)");
        }
        console.log("===========================================");
    }
}
