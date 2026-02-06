// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {TestnetMockYieldVault} from "./mocks/TestnetMockYieldVault.sol";

/**
 * @title Simulate Yield on Mock Vault
 * @notice Simulates positive or negative yield on a TestnetMockYieldVault
 * @dev For testnet use only - allows testing of yield accrual mechanics
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * This script allows you to:
 * 1. Add positive yield (increases share value for all LPs)
 * 2. Simulate loss (decreases share value for all LPs)
 *
 * How it works:
 * - Positive yield: Script transfers underlying tokens to the vault
 * - Negative yield: Vault burns tokens to a dead address
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - YIELD_VAULT_{NETWORK}: Address of the TestnetMockYieldVault
 * - YIELD_AMOUNT_{NETWORK}: Amount to add/remove (in base units/wei)
 * - YIELD_IS_POSITIVE_{NETWORK}: "true" for yield, "false" for loss
 *
 * Prerequisites:
 * - For positive yield: Caller must have sufficient underlying tokens
 * - For negative yield: Vault must have sufficient balance
 *
 * Example Usage:
 * - Simulate 10% yield on a vault with 1000 USDC: Set YIELD_AMOUNT to 100000000 (100 USDC in 6 decimals)
 * - Simulate 5% loss: Set YIELD_AMOUNT to 50000000 and YIELD_IS_POSITIVE to "false"
 */
contract SimulateYieldScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        // Get vault address
        envVar = string.concat("YIELD_VAULT_", network);
        address vaultAddr = vm.envAddress(envVar);
        require(vaultAddr != address(0), string.concat(envVar, " not set"));

        // Get yield amount
        envVar = string.concat("YIELD_AMOUNT_", network);
        uint256 amount = vm.envUint(envVar);
        require(amount > 0, "YIELD_AMOUNT must be greater than 0");

        // Get yield direction (positive or negative)
        envVar = string.concat("YIELD_IS_POSITIVE_", network);
        bool isPositive = vm.envBool(envVar);

        TestnetMockYieldVault vault = TestnetMockYieldVault(vaultAddr);
        address asset = vault.asset();
        uint8 decimals = IERC20(asset).decimals();

        // Get vault state before
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSupplyBefore = vault.totalSupply();

        console.log("===========================================");
        console.log("SIMULATING YIELD ON MOCK VAULT");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Vault:", vaultAddr);
        console.log("Underlying Asset:", asset);
        console.log("Asset Decimals:", decimals);
        console.log("");
        console.log("Vault State Before:");
        console.log("  - Total Assets:", totalAssetsBefore);
        console.log("  - Total Supply (shares):", totalSupplyBefore);
        if (totalSupplyBefore > 0) {
            uint256 sharePriceBefore = (totalAssetsBefore * 1e18) / totalSupplyBefore;
            console.log("  - Share Price (1e18 base):", sharePriceBefore);
        }
        console.log("");
        console.log("Yield Simulation:");
        console.log("  - Amount:", amount, "wei");
        console.log("  - Direction:", isPositive ? "POSITIVE (adding yield)" : "NEGATIVE (simulating loss)");
        console.log("");

        vm.startBroadcast();

        if (isPositive) {
            // For positive yield, we need to approve and transfer tokens to vault
            console.log("Step 1: Approving underlying tokens to vault...");
            IERC20(asset).approve(vaultAddr, amount);
            console.log("  - Approved");

            console.log("Step 2: Simulating positive yield...");
            vault.simulateYield(amount);
            console.log("  - Yield added successfully");
        } else {
            // For negative yield, vault burns its own tokens
            console.log("Step 1: Simulating loss (negative yield)...");
            require(amount <= totalAssetsBefore, "Cannot lose more than vault balance");
            vault.simulateLoss(amount);
            console.log("  - Loss simulated successfully");
        }

        vm.stopBroadcast();

        // Get vault state after
        uint256 totalAssetsAfter = vault.totalAssets();
        uint256 totalSupplyAfter = vault.totalSupply();

        console.log("");
        console.log("===========================================");
        console.log("YIELD SIMULATION COMPLETE");
        console.log("===========================================");
        console.log("");
        console.log("Vault State After:");
        console.log("  - Total Assets:", totalAssetsAfter);
        console.log("  - Total Supply (shares):", totalSupplyAfter);
        if (totalSupplyAfter > 0) {
            uint256 sharePriceAfter = (totalAssetsAfter * 1e18) / totalSupplyAfter;
            console.log("  - Share Price (1e18 base):", sharePriceAfter);
        }
        console.log("");
        console.log("Change:");
        if (isPositive) {
            console.log("  - Assets Added:", amount);
        } else {
            console.log("  - Assets Removed:", amount);
        }

        // Calculate percentage change if there were assets before
        if (totalAssetsBefore > 0) {
            uint256 percentChange = (amount * 10000) / totalAssetsBefore; // basis points
            console.log("  - Percentage Change: %d bps", percentChange);
        }
        console.log("");
        console.log("EFFECT ON LPs:");
        console.log("- All LP shares now represent", isPositive ? "MORE" : "LESS", "underlying value");
        console.log("- No action required by LPs to benefit/suffer from this change");
        console.log("===========================================");
    }
}
