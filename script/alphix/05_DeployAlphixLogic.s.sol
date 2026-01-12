// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";

/**
 * @title Deploy AlphixLogic (Implementation + Proxy)
 * @notice Deploys AlphixLogic implementation and ERC1967 proxy with initialization
 * @dev The proxy will be the actual contract used by the Alphix hook
 *
 * DEPLOYMENT ORDER: 5/11
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each AlphixLogic proxy is paired with exactly ONE Alphix Hook and manages ONE pool.
 * AlphixLogic is an ERC20 token - LP shares are transferable tokens.
 *
 * To deploy multiple pools, you need to:
 * 1. Deploy a new Alphix Hook (script 04) - requires CREATE2 mining
 * 2. Deploy a new AlphixLogic proxy (this script)
 * 3. Configure the new hook+logic pair (script 06)
 *
 * SENDER REQUIREMENTS: Any address can run this script.
 * The ALPHIX_MANAGER address will become the AlphixLogic owner (not necessarily the sender).
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_MANAGER_{NETWORK}: Initial owner address (will own AlphixLogic)
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook address (deployed in script 04)
 * - ACCESS_MANAGER_{NETWORK}: Access manager address
 *
 * Prerequisites:
 * - Script 04 (DeployAlphix) must be completed first
 * - ALPHIX_HOOK address must be set in .env
 *
 * Note: Pool parameters (PoolParams) are now passed at pool activation via initializePool(),
 * not at AlphixLogic deployment. This allows fine-tuning per pool.
 *
 * After Deployment:
 * - Copy implementation address to ALPHIX_LOGIC_IMPL_{NETWORK} in .env
 * - Copy proxy address to ALPHIX_LOGIC_PROXY_{NETWORK} in .env
 *
 * Note: The Alphix hook will interact with the PROXY address, not the implementation
 */
contract DeployAlphixLogicScript is Script {
    function run() public {
        // Load environment variables
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get owner address
        string memory ownerEnvVar = string.concat("ALPHIX_MANAGER_", network);
        address owner = vm.envAddress(ownerEnvVar);
        require(owner != address(0), string.concat(ownerEnvVar, " not set or invalid"));

        // Get Alphix Hook address (deployed in script 04)
        string memory alphixHookEnvVar = string.concat("ALPHIX_HOOK_", network);
        address alphixHook = vm.envAddress(alphixHookEnvVar);
        require(alphixHook != address(0), string.concat(alphixHookEnvVar, " not set or invalid"));

        // Get Access Manager address
        string memory accessManagerEnvVar = string.concat("ACCESS_MANAGER_", network);
        address accessManager = vm.envAddress(accessManagerEnvVar);
        require(accessManager != address(0), string.concat(accessManagerEnvVar, " not set or invalid"));

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX LOGIC");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Owner:", owner);
        console.log("Alphix Hook:", alphixHook);
        console.log("Access Manager:", accessManager);
        console.log("");

        // Deploy implementation
        vm.startBroadcast();
        AlphixLogic implementation = new AlphixLogic();
        console.log("Implementation deployed at:", address(implementation));

        // Prepare initialization data
        // Note: Pool parameters (PoolParams) are passed at pool activation via initializePool()
        bytes memory initData = abi.encodeWithSelector(
            AlphixLogic.initialize.selector,
            owner,
            alphixHook,
            accessManager,
            "Alphix LP Shares", // Share token name
            "aLP" // Share token symbol
        );

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("AlphixLogic Implementation:", address(implementation));
        console.log("AlphixLogic Proxy:", address(proxy));
        console.log("");
        console.log("IMPORTANT: The Alphix Hook will use the PROXY address");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Add these to your .env file:");
        console.log("   ALPHIX_LOGIC_IMPL_%s=%s", network, address(implementation));
        console.log("   ALPHIX_LOGIC_PROXY_%s=%s", network, address(proxy));
        console.log("2. Run script 06_ConfigureSystem.s.sol");
        console.log("===========================================");
    }
}
