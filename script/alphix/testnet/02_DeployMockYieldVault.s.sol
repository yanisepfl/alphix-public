// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestnetMockYieldVault} from "./mocks/TestnetMockYieldVault.sol";

/**
 * @title Deploy Mock Yield Vault (ERC-4626)
 * @notice Deploys a mock ERC-4626 vault for testnet use
 * @dev Anyone can simulate yield (positive or negative) - for testing only
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., "SEPOLIA", "HOLESKY")
 * - MOCK_VAULT_ASSET_{NETWORK}: Address of the underlying ERC20 asset
 * - MOCK_VAULT_NAME_{NETWORK}: Vault share token name (e.g., "Alphix USDC Vault")
 * - MOCK_VAULT_SYMBOL_{NETWORK}: Vault share token symbol (e.g., "aUSDC-V")
 *
 * Example .env configuration:
 *   MOCK_VAULT_ASSET_SEPOLIA=0x...  # Your mock USDC address
 *   MOCK_VAULT_NAME_SEPOLIA=Alphix Testnet USDC Vault
 *   MOCK_VAULT_SYMBOL_SEPOLIA=atUSDC-V
 *
 * Usage:
 *   forge script script/alphix/testnet/02_DeployMockYieldVault.s.sol --broadcast
 *
 * After deployment, anyone can:
 * - deposit(assets, receiver): Deposit assets and receive vault shares
 * - withdraw(assets, receiver, owner): Withdraw assets by burning shares
 * - simulateYield(amount): Add assets to vault (increases share value)
 * - simulateLoss(amount): Remove assets from vault (decreases share value)
 *
 * Yield Simulation Example:
 *   // Simulate 10% yield on a vault with 1000 USDC
 *   vault.simulateYield(100e6);  // Add 100 USDC as yield
 *
 *   // Simulate 5% loss
 *   vault.simulateLoss(50e6);    // Remove 50 USDC as loss
 */
contract DeployMockYieldVaultScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        // Get vault configuration
        envVar = string.concat("MOCK_VAULT_ASSET_", network);
        address assetAddr = vm.envAddress(envVar);
        require(assetAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("MOCK_VAULT_NAME_", network);
        string memory vaultName = vm.envString(envVar);
        require(bytes(vaultName).length > 0, string.concat(envVar, " not set"));

        envVar = string.concat("MOCK_VAULT_SYMBOL_", network);
        string memory vaultSymbol = vm.envString(envVar);
        require(bytes(vaultSymbol).length > 0, string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("DEPLOYING TESTNET MOCK YIELD VAULT");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Underlying Asset:", assetAddr);
        console.log("Vault Name:", vaultName);
        console.log("Vault Symbol:", vaultSymbol);
        console.log("");

        vm.startBroadcast();

        // Deploy the mock vault
        TestnetMockYieldVault vault = new TestnetMockYieldVault(IERC20(assetAddr), vaultName, vaultSymbol);
        console.log("Mock Yield Vault deployed at:", address(vault));

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("Vault Address:", address(vault));
        console.log("Underlying Asset:", assetAddr);
        console.log("");
        console.log("VAULT FEATURES (ERC-4626):");
        console.log("  - deposit(assets, receiver): Deposit and receive shares");
        console.log("  - withdraw(assets, receiver, owner): Withdraw assets");
        console.log("  - redeem(shares, receiver, owner): Redeem shares for assets");
        console.log("");
        console.log("YIELD SIMULATION:");
        console.log("  - simulateYield(amount): Add assets (positive yield)");
        console.log("  - simulateLoss(amount): Remove assets (negative yield)");
        console.log("");
        console.log("Add to your .env:");
        console.log("   MOCK_VAULT_%s=%s", network, address(vault));
        console.log("===========================================");
    }
}
