// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TestnetMockERC20} from "./mocks/TestnetMockERC20.sol";

/**
 * @title Deploy Mock ERC20 Token
 * @notice Deploys a permissionless mock ERC20 token for testnet use
 * @dev Anyone can mint/burn tokens after deployment - for testing only
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., "SEPOLIA", "HOLESKY")
 * - MOCK_TOKEN_NAME_{NETWORK}: Token name (e.g., "Alphix Testnet USDC")
 * - MOCK_TOKEN_SYMBOL_{NETWORK}: Token symbol (e.g., "atUSDC")
 * - MOCK_TOKEN_DECIMALS_{NETWORK}: Token decimals (e.g., 6, 18)
 *
 * Optional Environment Variables:
 * - MOCK_TOKEN_INITIAL_MINT_{NETWORK}: Initial amount to mint to deployer (in base units)
 *
 * Example .env configuration:
 *   MOCK_TOKEN_NAME_SEPOLIA=Alphix Testnet USDC
 *   MOCK_TOKEN_SYMBOL_SEPOLIA=atUSDC
 *   MOCK_TOKEN_DECIMALS_SEPOLIA=6
 *   MOCK_TOKEN_INITIAL_MINT_SEPOLIA=1000000000000  # 1M USDC
 *
 * Usage:
 *   forge script script/alphix/testnet/00_DeployMockERC20.s.sol --broadcast
 *
 * After deployment, anyone can:
 * - Call mint(address to, uint256 amount) to mint tokens
 * - Call burn(uint256 amount) to burn their own tokens
 */
contract DeployMockERC20Script is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        // Get token configuration
        envVar = string.concat("MOCK_TOKEN_NAME_", network);
        string memory tokenName = vm.envString(envVar);
        require(bytes(tokenName).length > 0, string.concat(envVar, " not set"));

        envVar = string.concat("MOCK_TOKEN_SYMBOL_", network);
        string memory tokenSymbol = vm.envString(envVar);
        require(bytes(tokenSymbol).length > 0, string.concat(envVar, " not set"));

        envVar = string.concat("MOCK_TOKEN_DECIMALS_", network);
        uint8 tokenDecimals = uint8(vm.envUint(envVar));
        require(tokenDecimals >= 1 && tokenDecimals <= 18, "Decimals must be 1-18");

        // Optional: initial mint amount
        envVar = string.concat("MOCK_TOKEN_INITIAL_MINT_", network);
        uint256 initialMint;
        try vm.envUint(envVar) returns (uint256 amt) {
            initialMint = amt;
        } catch {
            initialMint = 0;
        }

        console.log("===========================================");
        console.log("DEPLOYING TESTNET MOCK ERC20");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Token Name:", tokenName);
        console.log("Token Symbol:", tokenSymbol);
        console.log("Decimals:", tokenDecimals);
        if (initialMint > 0) {
            console.log("Initial Mint:", initialMint);
        }
        console.log("");

        vm.startBroadcast();

        // Deploy the mock token
        TestnetMockERC20 token = new TestnetMockERC20(tokenName, tokenSymbol, tokenDecimals);
        console.log("Mock ERC20 deployed at:", address(token));

        // Mint initial supply if specified
        if (initialMint > 0) {
            token.mint(msg.sender, initialMint);
            console.log("Minted %s tokens to deployer", initialMint);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("Token Address:", address(token));
        console.log("");
        console.log("TOKEN FEATURES:");
        console.log("  - Anyone can mint: token.mint(to, amount)");
        console.log("  - Anyone can burn their tokens: token.burn(amount)");
        console.log("");
        console.log("Add to your .env:");
        console.log("   MOCK_TOKEN_%s=%s", network, address(token));
        console.log("===========================================");
    }
}
