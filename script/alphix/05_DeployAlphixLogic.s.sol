// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

/**
 * @title Deploy AlphixLogic (Implementation + Proxy)
 * @notice Deploys AlphixLogic implementation and ERC1967 proxy with initialization
 * @dev The proxy will be the actual contract used by the Alphix hook
 *
 * DEPLOYMENT ORDER: 5/11
 *
 * SENDER REQUIREMENTS: Any address can run this script.
 * The ALPHIX_MANAGER address will become the AlphixLogic owner (not necessarily the sender).
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_MANAGER_{NETWORK}: Initial owner address (will own AlphixLogic)
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook address (deployed in script 04)
 *
 * Prerequisites:
 * - Script 04 (DeployAlphix) must be completed first
 * - ALPHIX_HOOK address must be set in .env
 *
 * /!\ Don't forget to configure default parameters (and the global max adjustment rate if needed)
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

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX LOGIC");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Owner:", owner);
        console.log("Alphix Hook:", alphixHook);
        console.log("");

        // Define pool type parameters (STABLE, STANDARD, VOLATILE)
        DynamicFeeLib.PoolTypeParams memory stableParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1, // 0.0001%
            maxFee: 1001, // 0.1001%
            baseMaxFeeDelta: 10, // 0.001%
            lookbackPeriod: 30, // 30 days
            minPeriod: 172_800, // 2 days
            ratioTolerance: 5e15, // 0.5%
            linearSlope: 5e17, // 0.5x
            maxCurrentRatio: 1e21, // 1000x
            upperSideFactor: 1e18, // 1.0x
            lowerSideFactor: 2e18 // 2.0x
        });

        DynamicFeeLib.PoolTypeParams memory standardParams = DynamicFeeLib.PoolTypeParams({
            minFee: 99, // 0.0099%
            maxFee: 10001, // 1.0001%
            baseMaxFeeDelta: 25, // 0.0025%
            lookbackPeriod: 15, // 15 days
            minPeriod: 86_400, // 1 day
            ratioTolerance: 1e16, // 1%
            linearSlope: 1e18, // 1.0x
            maxCurrentRatio: 1e21, // 1000x
            upperSideFactor: 1e18, // 1.0x
            lowerSideFactor: 15e17 // 1.5x
        });

        DynamicFeeLib.PoolTypeParams memory volatileParams = DynamicFeeLib.PoolTypeParams({
            minFee: 249, // 0.0249%
            maxFee: 200001, // 20.0001%
            baseMaxFeeDelta: 100, // 0.01%
            lookbackPeriod: 7, // 7 days
            minPeriod: 43_200, // 0.5 day
            ratioTolerance: 5e16, // 5%
            linearSlope: 2e18, // 2.0x
            maxCurrentRatio: 1e21, // 1000x
            upperSideFactor: 1e18, // 1.0x
            lowerSideFactor: 1e18 // 1.0x
        });

        // Deploy implementation
        vm.startBroadcast();
        AlphixLogic implementation = new AlphixLogic();
        console.log("Implementation deployed at:", address(implementation));

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            AlphixLogic.initialize.selector, owner, alphixHook, stableParams, standardParams, volatileParams
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
