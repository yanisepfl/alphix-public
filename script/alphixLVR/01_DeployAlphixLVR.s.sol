// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {AlphixLVR} from "../../src/AlphixLVR.sol";

/**
 * @title Deploy AlphixLVR Hook
 * @notice Mines address and deploys the AlphixLVR dynamic fee hook
 * @dev Uses CREATE2 to deploy at an address with the afterInitialize flag.
 *      AlphixLVR is multi-pool capable — one deployment serves all LVR pools.
 *
 * DEPLOYMENT ORDER: 1 (After AccessManager, or reuse existing one)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., BASE, ARB)
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - CREATE2_DEPLOYER_{NETWORK}: CREATE2 factory address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 *
 * Hook Permissions (1 enabled — matching BaseDynamicFee):
 * - afterInitialize
 *
 * After Deployment:
 * - Copy the deployed address to ALPHIX_LVR_HOOK_{NETWORK} in .env
 */
contract DeployAlphixLVRScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("POOL_MANAGER_", network);
        address poolManagerAddr = vm.envAddress(envVar);
        require(poolManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("CREATE2_DEPLOYER_", network);
        address create2DeployerAddr = vm.envAddress(envVar);
        require(create2DeployerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_", network);
        address accessManagerAddr = vm.envAddress(envVar);
        require(accessManagerAddr != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX LVR HOOK");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("PoolManager:", poolManagerAddr);
        console.log("CREATE2 Deployer:", create2DeployerAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("");

        // Hook permissions: only afterInitialize
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);

        console.log("Mining hook address with afterInitialize flag...");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        bytes memory constructorArgs = abi.encode(poolManager, accessManagerAddr);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2DeployerAddr, flags, type(AlphixLVR).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("");

        vm.startBroadcast();

        AlphixLVR hook = new AlphixLVR{salt: salt}(poolManager, accessManagerAddr);

        vm.stopBroadcast();

        require(address(hook) == hookAddress, "Hook address mismatch");

        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("AlphixLVR Hook deployed at:", address(hook));
        console.log("");
        console.log("Add to .env:");
        console.log("  ALPHIX_LVR_HOOK_%s=%s", network, address(hook));
        console.log("");
        console.log("NOTES:");
        console.log("- Multi-pool capable: use this hook for all LVR pools");
        console.log("- No beforeSwap/afterSwap: zero gas overhead on swaps");
        console.log("- Initial fee for new pools is 0 until first poke()");
        console.log("");
        console.log("Next: Run 02_ConfigureRoles.s.sol");
        console.log("===========================================");
    }
}
