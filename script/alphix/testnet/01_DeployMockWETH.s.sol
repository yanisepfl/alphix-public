// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {TestnetMockWETH} from "./mocks/TestnetMockWETH.sol";

/**
 * @title Deploy Mock WETH
 * @notice Deploys a mock WETH9 contract for testnet use
 * @dev Provides wrap/unwrap functionality for native ETH - for testing only
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., "SEPOLIA", "HOLESKY")
 *
 * Note: WETH is hardcoded with:
 * - Name: "Wrapped Ether"
 * - Symbol: "WETH"
 * - Decimals: 18
 *
 * Usage:
 *   forge script script/alphix/testnet/01_DeployMockWETH.s.sol --broadcast
 *
 * After deployment:
 * - Send ETH to the contract to wrap (receive WETH)
 * - Call deposit() with ETH value to wrap
 * - Call withdraw(amount) to unwrap (receive ETH)
 */
contract DeployMockWETHScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        console.log("===========================================");
        console.log("DEPLOYING TESTNET MOCK WETH");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Token Name: Wrapped Ether");
        console.log("Token Symbol: WETH");
        console.log("Decimals: 18");
        console.log("");

        vm.startBroadcast();

        // Deploy the mock WETH
        TestnetMockWETH weth = new TestnetMockWETH();
        console.log("Mock WETH deployed at:", address(weth));

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("WETH Address:", address(weth));
        console.log("");
        console.log("WETH FEATURES:");
        console.log("  - Wrap ETH: Send ETH to contract or call deposit() with value");
        console.log("  - Unwrap WETH: Call withdraw(amount) to receive ETH");
        console.log("  - Standard ERC20: transfer, approve, transferFrom");
        console.log("");
        console.log("Add to your .env:");
        console.log("   MOCK_WETH_%s=%s", network, address(weth));
        console.log("===========================================");
    }
}
