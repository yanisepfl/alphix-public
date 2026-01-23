// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Configure ReHypothecation
 * @notice Sets up yield sources for rehypothecation
 * @dev This script configures the rehypothecation infrastructure for an Alphix hook
 *
 * DEPLOYMENT ORDER: 4 (Optional - after pool creation)
 *
 * SENDER REQUIREMENTS: Must have YIELD_MANAGER_ROLE (granted in step 02)
 *
 * Actions Performed:
 * 1. Set yield source for currency0 (ERC-4626 vault)
 * 2. Set yield source for currency1 (ERC-4626 vault)
 *
 * NOTE: JIT tick range is now set immutably during initializePool() in script 03.
 *       It cannot be changed after pool initialization.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook address
 *
 * Optional (set what you want to configure):
 * - YIELD_SOURCE_0_{NETWORK}: ERC-4626 vault for currency0
 * - YIELD_SOURCE_1_{NETWORK}: ERC-4626 vault for currency1
 *
 * Note for ETH Pools:
 * - YIELD_SOURCE_0 must implement IAlphix4626WrapperWeth (with depositETH/withdrawETH)
 *
 * After this script:
 * - Users can add rehypothecated liquidity via addReHypothecatedLiquidity()
 * - JIT liquidity will be provided during swaps
 */
contract ConfigureReHypothecationScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        // Get optional configuration values
        address yieldSource0;
        envVar = string.concat("YIELD_SOURCE_0_", network);
        try vm.envAddress(envVar) returns (address addr) {
            yieldSource0 = addr;
        } catch {}

        address yieldSource1;
        envVar = string.concat("YIELD_SOURCE_1_", network);
        try vm.envAddress(envVar) returns (address addr) {
            yieldSource1 = addr;
        } catch {}

        // Check if there's anything to do
        if (yieldSource0 == address(0) && yieldSource1 == address(0)) {
            console.log("===========================================");
            console.log("NO CONFIGURATION SET");
            console.log("===========================================");
            console.log("Set at least one of:");
            console.log("  - YIELD_SOURCE_0_%s", network);
            console.log("  - YIELD_SOURCE_1_%s", network);
            console.log("===========================================");
            return;
        }

        console.log("===========================================");
        console.log("CONFIGURING REHYPOTHECATION");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("");
        console.log("Configuration to apply:");
        if (yieldSource0 != address(0)) {
            console.log("  - Yield Source 0:", yieldSource0);
        }
        if (yieldSource1 != address(0)) {
            console.log("  - Yield Source 1:", yieldSource1);
        }
        console.log("");

        Alphix alphix = Alphix(hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();

        vm.startBroadcast();

        // Set yield sources (if specified)
        if (yieldSource0 != address(0)) {
            console.log("Setting yield source for currency0...");
            alphix.setYieldSource(poolKey.currency0, yieldSource0);
            console.log("  - Done");
        }

        if (yieldSource1 != address(0)) {
            console.log("Setting yield source for currency1...");
            alphix.setYieldSource(poolKey.currency1, yieldSource1);
            console.log("  - Done");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("REHYPOTHECATION CONFIGURED");
        console.log("===========================================");
        console.log("");
        console.log("Users can now:");
        console.log("1. Call addReHypothecatedLiquidity(shares) to deposit");
        console.log("2. Call removeReHypothecatedLiquidity(shares) to withdraw");
        console.log("");
        console.log("JIT liquidity will be provided during swaps using vault funds.");
        console.log("");
        console.log("Next: Run 05_AddRHLiquidity.s.sol to add rehypothecated liquidity");
        console.log("===========================================");
    }
}
