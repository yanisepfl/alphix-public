// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";
import {Roles} from "./libraries/Roles.sol";

/**
 * @title Configure ReHypothecation
 * @notice Sets up yield sources, treasury, tick range, and yield tax for rehypothecation
 * @dev This script configures the rehypothecation infrastructure for a specific AlphixLogic deployment
 *
 * DEPLOYMENT ORDER: 6d/11 (Run after 06_ConfigureSystem.s.sol)
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each AlphixLogic manages ONE pool's rehypothecation. Run this script for each pool.
 *
 * SENDER REQUIREMENTS: Must be run by an address with YIELD_MANAGER_ROLE.
 * The YIELD_MANAGER_ROLE must first be granted via 06b_ConfigureRoles.s.sol or AccessManager.
 *
 * Prerequisites:
 * - Script 06 (ConfigureSystem) completed
 * - Pool must be created (script 09) before yield sources can be set
 * - YIELD_MANAGER_ROLE must be granted to the caller
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LOGIC_PROXY_{NETWORK}: AlphixLogic proxy address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - YIELD_MANAGER_{NETWORK}: Address with YIELD_MANAGER_ROLE (the caller)
 *
 * Optional (set what you want to configure):
 * - YIELD_TREASURY_{NETWORK}: Treasury address for tax collection
 * - YIELD_SOURCE_0_{NETWORK}: ERC-4626 vault for currency0
 * - YIELD_SOURCE_1_{NETWORK}: ERC-4626 vault for currency1
 * - JIT_TICK_LOWER_{NETWORK}: Lower tick for JIT liquidity range
 * - JIT_TICK_UPPER_{NETWORK}: Upper tick for JIT liquidity range
 * - YIELD_TAX_PIPS_{NETWORK}: Yield tax in pips (1e6 = 100%, e.g., 100000 = 10%)
 *
 * Configuration Steps:
 * 1. First grant YIELD_MANAGER_ROLE to desired address (06b or manually)
 * 2. Set function permissions on AlphixLogic for YIELD_MANAGER_ROLE
 * 3. Configure: treasury, yield sources, tick range, tax rate
 *
 * Note: Yield sources can only be set AFTER the pool is created and activated.
 */
contract ConfigureReHypothecationScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        // Get required addresses
        envVar = string.concat("ALPHIX_LOGIC_PROXY_", network);
        address logicAddr = vm.envAddress(envVar);
        require(logicAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_", network);
        address accessManagerAddr = vm.envAddress(envVar);
        require(accessManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("YIELD_MANAGER_", network);
        address yieldManager = vm.envAddress(envVar);
        require(yieldManager != address(0), string.concat(envVar, " not set"));

        // Get optional configuration values
        address treasury;
        envVar = string.concat("YIELD_TREASURY_", network);
        try vm.envAddress(envVar) returns (address addr) {
            treasury = addr;
        } catch {}

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

        int24 tickLower;
        int24 tickUpper;
        bool hasTickRange = false;
        envVar = string.concat("JIT_TICK_LOWER_", network);
        try vm.envInt(envVar) returns (int256 val) {
            // Safe: tick values are always within int24 range per Uniswap V4 spec
            // forge-lint: disable-next-line(unsafe-typecast)
            tickLower = int24(val);
            envVar = string.concat("JIT_TICK_UPPER_", network);
            try vm.envInt(envVar) returns (int256 val2) {
                // Safe: tick values are always within int24 range per Uniswap V4 spec
                // forge-lint: disable-next-line(unsafe-typecast)
                tickUpper = int24(val2);
                hasTickRange = true;
            } catch {}
        } catch {}

        uint24 yieldTaxPips;
        bool hasYieldTax = false;
        envVar = string.concat("YIELD_TAX_PIPS_", network);
        try vm.envUint(envVar) returns (uint256 val) {
            // Safe: yield tax pips is capped at 1e6 (100%) which fits in uint24
            // forge-lint: disable-next-line(unsafe-typecast)
            yieldTaxPips = uint24(val);
            hasYieldTax = true;
        } catch {}

        // Check if there's anything to do
        if (
            treasury == address(0) && yieldSource0 == address(0) && yieldSource1 == address(0) && !hasTickRange
                && !hasYieldTax
        ) {
            console.log("===========================================");
            console.log("NO REHYPOTHECATION CONFIG SET");
            console.log("===========================================");
            console.log("No configuration values found in .env");
            console.log("");
            console.log("Set at least one of:");
            console.log("  - YIELD_TREASURY_%s=<address>", network);
            console.log("  - YIELD_SOURCE_0_%s=<vault_address>", network);
            console.log("  - YIELD_SOURCE_1_%s=<vault_address>", network);
            console.log("  - JIT_TICK_LOWER_%s=<tick>", network);
            console.log("  - JIT_TICK_UPPER_%s=<tick>", network);
            console.log("  - YIELD_TAX_PIPS_%s=<pips>", network);
            console.log("===========================================");
            return;
        }

        console.log("===========================================");
        console.log("CONFIGURING REHYPOTHECATION");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("AlphixLogic:", logicAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Yield Manager:", yieldManager);
        console.log("");

        console.log("Configuration to apply:");
        if (treasury != address(0)) {
            console.log("  - Treasury:", treasury);
        }
        if (yieldSource0 != address(0)) {
            console.log("  - Yield Source 0:", yieldSource0);
        }
        if (yieldSource1 != address(0)) {
            console.log("  - Yield Source 1:", yieldSource1);
        }
        if (hasTickRange) {
            console.log("  - JIT Tick Lower:", tickLower);
            console.log("  - JIT Tick Upper:", tickUpper);
        }
        if (hasYieldTax) {
            console.log("  - Yield Tax Pips: %d (%d%%)", yieldTaxPips, yieldTaxPips * 100 / 1e6);
        }
        console.log("");

        AlphixLogic logic = AlphixLogic(logicAddr);
        AccessManager accessManager = AccessManager(accessManagerAddr);

        vm.startBroadcast();

        // Step 1: Set up YIELD_MANAGER_ROLE permissions on AlphixLogic (if not already done)
        console.log("Step 1: Setting up YIELD_MANAGER_ROLE permissions...");

        bytes4[] memory yieldManagerSelectors = new bytes4[](4);
        yieldManagerSelectors[0] = logic.setYieldSource.selector;
        yieldManagerSelectors[1] = logic.setTickRange.selector;
        yieldManagerSelectors[2] = logic.setYieldTaxPips.selector;
        yieldManagerSelectors[3] = logic.setYieldTreasury.selector;

        accessManager.setTargetFunctionRole(logicAddr, yieldManagerSelectors, Roles.YIELD_MANAGER_ROLE);
        console.log("  - Set target function roles for YIELD_MANAGER_ROLE");

        // Grant YIELD_MANAGER_ROLE to the yield manager address
        accessManager.grantRole(Roles.YIELD_MANAGER_ROLE, yieldManager, 0);
        console.log("  - Granted YIELD_MANAGER_ROLE to:", yieldManager);
        console.log("");

        // Step 2: Configure treasury (if set)
        if (treasury != address(0)) {
            console.log("Step 2: Setting yield treasury...");
            logic.setYieldTreasury(treasury);
            console.log("  - Treasury set to:", treasury);
            console.log("");
        }

        // Step 3: Configure tick range (if set)
        if (hasTickRange) {
            console.log("Step 3: Setting JIT tick range...");
            logic.setTickRange(tickLower, tickUpper);
            console.log("  - Tick range lower:");
            console.logInt(int256(tickLower));
            console.log("  - Tick range upper:");
            console.logInt(int256(tickUpper));
            console.log("");
        }

        // Step 4: Configure yield tax (if set)
        if (hasYieldTax) {
            console.log("Step 4: Setting yield tax...");
            logic.setYieldTaxPips(yieldTaxPips);
            console.log("  - Yield tax set to: %d pips", yieldTaxPips);
            console.log("");
        }

        // Step 5: Configure yield sources (if set)
        // NOTE: This requires the pool to be activated first
        if (yieldSource0 != address(0) || yieldSource1 != address(0)) {
            PoolKey memory poolKey = logic.getPoolKey();

            if (yieldSource0 != address(0)) {
                console.log("Step 5a: Setting yield source for currency0...");
                logic.setYieldSource(poolKey.currency0, yieldSource0);
                console.log("  - Yield source 0 set to:", yieldSource0);
                console.log("");
            }

            if (yieldSource1 != address(0)) {
                console.log("Step 5b: Setting yield source for currency1...");
                logic.setYieldSource(poolKey.currency1, yieldSource1);
                console.log("  - Yield source 1 set to:", yieldSource1);
                console.log("");
            }
        }

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("REHYPOTHECATION CONFIGURATION COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Configured:");
        if (treasury != address(0)) {
            console.log("  - Treasury: %s", treasury);
        }
        if (yieldSource0 != address(0)) {
            console.log("  - Yield Source 0: %s", yieldSource0);
        }
        if (yieldSource1 != address(0)) {
            console.log("  - Yield Source 1: %s", yieldSource1);
        }
        if (hasTickRange) {
            console.log("  - JIT Range: lower=", int256(tickLower));
            console.log("  - JIT Range: upper=", int256(tickUpper));
        }
        if (hasYieldTax) {
            console.log("  - Yield Tax: %d pips", yieldTaxPips);
        }
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Users can now add rehypothecated liquidity");
        console.log("2. JIT liquidity will be added on swaps");
        console.log("3. Tax will accumulate and can be collected via collectAccumulatedTax()");
        console.log("===========================================");
    }
}
