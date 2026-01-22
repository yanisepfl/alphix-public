// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TestnetMockYieldVaultETH} from "./mocks/TestnetMockYieldVaultETH.sol";

/**
 * @title Deploy Mock ETH Yield Vault (ERC-4626 + IAlphix4626WrapperWeth)
 * @notice Deploys a mock ERC-4626 vault for ETH that supports native ETH deposits
 * @dev For use with AlphixETH hooks that need an ETH yield source
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., "BASE_SEPOLIA")
 * - MOCK_ETH_VAULT_WETH_{NETWORK}: Address of the WETH contract
 * - MOCK_ETH_VAULT_NAME_{NETWORK}: Vault share token name (e.g., "Alphix Testnet ETH Vault")
 * - MOCK_ETH_VAULT_SYMBOL_{NETWORK}: Vault share token symbol (e.g., "atETH-V")
 *
 * Example .env configuration:
 *   MOCK_ETH_VAULT_WETH_BASE_SEPOLIA=0x...  # Your mock WETH address
 *   MOCK_ETH_VAULT_NAME_BASE_SEPOLIA=Alphix Testnet ETH Vault
 *   MOCK_ETH_VAULT_SYMBOL_BASE_SEPOLIA=atETH-V
 *
 * Usage:
 *   forge script script/alphix/testnet/02b_DeployMockYieldVaultETH.s.sol --broadcast
 *
 * After deployment, anyone can:
 * - depositETH(receiver): Deposit native ETH, receive vault shares
 * - withdrawETH(assets, receiver, owner): Withdraw as native ETH
 * - redeemETH(shares, receiver, owner): Redeem shares for native ETH
 * - deposit/withdraw/redeem: Standard ERC-4626 (uses WETH)
 * - simulateYieldETH(): Send ETH to add yield
 * - simulateLoss(amount): Remove WETH to simulate loss
 */
contract DeployMockYieldVaultETHScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("MOCK_ETH_VAULT_WETH_", network);
        address wethAddr = vm.envAddress(envVar);
        require(wethAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("MOCK_ETH_VAULT_NAME_", network);
        string memory vaultName = vm.envString(envVar);
        require(bytes(vaultName).length > 0, string.concat(envVar, " not set"));

        envVar = string.concat("MOCK_ETH_VAULT_SYMBOL_", network);
        string memory vaultSymbol = vm.envString(envVar);
        require(bytes(vaultSymbol).length > 0, string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("DEPLOYING TESTNET MOCK ETH YIELD VAULT");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("WETH Address:", wethAddr);
        console.log("Vault Name:", vaultName);
        console.log("Vault Symbol:", vaultSymbol);
        console.log("");

        vm.startBroadcast();

        TestnetMockYieldVaultETH vault = new TestnetMockYieldVaultETH(wethAddr, vaultName, vaultSymbol);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("ETH Vault Address:", address(vault));
        console.log("Underlying Asset: WETH at", wethAddr);
        console.log("");
        console.log("ETH VAULT FEATURES (IAlphix4626WrapperWeth):");
        console.log("  - depositETH(receiver): Deposit native ETH, receive shares");
        console.log("  - withdrawETH(assets, receiver, owner): Withdraw as native ETH");
        console.log("  - redeemETH(shares, receiver, owner): Redeem shares for native ETH");
        console.log("");
        console.log("STANDARD ERC-4626 (WETH):");
        console.log("  - deposit(assets, receiver): Deposit WETH, receive shares");
        console.log("  - withdraw(assets, receiver, owner): Withdraw WETH");
        console.log("  - redeem(shares, receiver, owner): Redeem shares for WETH");
        console.log("");
        console.log("YIELD SIMULATION:");
        console.log("  - simulateYieldETH(): Send ETH to add yield (increases share value)");
        console.log("  - simulateYield(amount): Transfer WETH to add yield");
        console.log("  - simulateLoss(amount): Remove WETH (decreases share value)");
        console.log("");
        console.log("Add to your .env:");
        console.log("  YIELD_SOURCE_ETH_%s=%s", network, address(vault));
        console.log("===========================================");
    }
}
