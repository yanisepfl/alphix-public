// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";

/**
 * @title Upgrade AlphixLogic
 * @notice Upgrades the AlphixLogic implementation behind the proxy
 * @dev Uses UUPS upgrade pattern - only owner can upgrade
 *
 * USAGE: Run this script when you need to upgrade the logic contract
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LOGIC_PROXY_{NETWORK}: AlphixLogic proxy address (the one being upgraded)
 *
 * Security Notes:
 * - Only the owner of AlphixLogic can execute upgrades
 * - The proxy address remains the same, only implementation changes
 * - All state is preserved during upgrade
 * - The Alphix Hook continues to use the same proxy address
 *
 * After Upgrade:
 * - Copy new implementation address to ALPHIX_LOGIC_IMPL_{NETWORK} in .env
 * - Update any documentation with new implementation address
 */
contract UpgradeAlphixLogicScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get AlphixLogic proxy address
        string memory proxyEnvVar = string.concat("ALPHIX_LOGIC_PROXY_", network);
        address proxyAddr = vm.envAddress(proxyEnvVar);
        require(proxyAddr != address(0), string.concat(proxyEnvVar, " not set"));

        console.log("===========================================");
        console.log("UPGRADING ALPHIX LOGIC");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Proxy Address (unchanged):", proxyAddr);
        console.log("");

        AlphixLogic proxy = AlphixLogic(proxyAddr);

        // Get current implementation address for comparison
        address currentImpl = _getImplementation(proxyAddr);
        console.log("Current Implementation:", currentImpl);
        console.log("");

        vm.startBroadcast();

        // Deploy new implementation
        console.log("Deploying new AlphixLogic implementation...");
        AlphixLogic newImplementation = new AlphixLogic();
        console.log("New Implementation deployed at:", address(newImplementation));
        console.log("");

        // Upgrade proxy to new implementation
        console.log("Upgrading proxy to new implementation...");
        proxy.upgradeToAndCall(address(newImplementation), "");
        console.log("Upgrade successful!");

        vm.stopBroadcast();

        // Verify upgrade
        address upgradedImpl = _getImplementation(proxyAddr);
        require(upgradedImpl == address(newImplementation), "Upgrade verification failed");
        require(upgradedImpl != currentImpl, "Implementation should have changed");

        console.log("");
        console.log("===========================================");
        console.log("UPGRADE SUCCESSFUL");
        console.log("===========================================");
        console.log("Proxy Address (unchanged):", proxyAddr);
        console.log("Old Implementation:", currentImpl);
        console.log("New Implementation:", address(newImplementation));
        console.log("");
        console.log("IMPORTANT NOTES:");
        console.log("- The proxy address remains the same");
        console.log("- All state has been preserved");
        console.log("- Alphix Hook continues to use the same proxy address");
        console.log("- No additional configuration needed");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Update .env with new implementation:");
        console.log("   ALPHIX_LOGIC_IMPL_%s=%s", network, address(newImplementation));
        console.log("2. Update documentation/records with new implementation address");
        console.log("3. Test the upgraded system thoroughly");
        console.log("===========================================");
    }

    /**
     * @dev Get implementation address from ERC1967 proxy
     * @param proxy The proxy contract address
     * @return impl The implementation address
     */
    function _getImplementation(address proxy) internal view returns (address impl) {
        // ERC1967 implementation slot: keccak256("eip1967.proxy.implementation") - 1
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 data = vm.load(proxy, slot);
        impl = address(uint160(uint256(data)));
    }
}
