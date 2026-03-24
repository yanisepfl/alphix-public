// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {AlphixLVRFee} from "../../src/AlphixLVRFee.sol";

/**
 * @title Deploy AlphixLVRFee Hook
 * @notice Mines address and deploys the AlphixLVRFee dynamic fee + hook fee hook
 * @dev Uses CREATE2 to deploy at an address with afterInitialize + afterSwap + afterSwapReturnDelta flags.
 *      AlphixLVRFee is multi-pool capable — one deployment serves all pools.
 *
 * DEPLOYMENT ORDER: 1 (After AccessManager)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier (e.g., BASE, ARB)
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - CREATE2_DEPLOYER_{NETWORK}: CREATE2 factory address
 * - ACCESS_MANAGER_LVR_{NETWORK}: LVR-specific AccessManager contract address
 * - TREASURY_LVR_{NETWORK}: Treasury address for hook fee collection
 *
 * Hook Permissions (3 enabled):
 * - afterInitialize (BaseDynamicFee: LP fee management)
 * - afterSwap (BaseHookFee: hook fee capture)
 * - afterSwapReturnDelta (BaseHookFee: adjust swapper output)
 *
 * After Deployment:
 * - Copy the deployed address to ALPHIX_LVR_FEE_HOOK_{NETWORK} in .env
 */
contract DeployAlphixLVRFeeScript is Script {
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

        envVar = string.concat("ACCESS_MANAGER_LVR_", network);
        address accessManagerAddr = vm.envAddress(envVar);
        require(accessManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TREASURY_LVR_", network);
        address treasuryAddr = vm.envAddress(envVar);
        require(treasuryAddr != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX LVR FEE HOOK");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("PoolManager:", poolManagerAddr);
        console.log("CREATE2 Deployer:", create2DeployerAddr);
        console.log("AccessManager:", accessManagerAddr);
        console.log("Treasury:", treasuryAddr);
        console.log("");

        // Hook permissions: afterInitialize + afterSwap + afterSwapReturnDelta
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG) | uint160(Hooks.AFTER_SWAP_FLAG) | uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        console.log("Mining hook address with afterInitialize + afterSwap + afterSwapReturnDelta flags...");

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        bytes memory constructorArgs = abi.encode(poolManager, accessManagerAddr, treasuryAddr);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(create2DeployerAddr, flags, type(AlphixLVRFee).creationCode, constructorArgs);

        console.log("Mined hook address:", hookAddress);
        console.log("");

        vm.startBroadcast();

        AlphixLVRFee hook = new AlphixLVRFee{salt: salt}(poolManager, accessManagerAddr, treasuryAddr);

        vm.stopBroadcast();

        require(address(hook) == hookAddress, "Hook address mismatch");

        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("AlphixLVRFee Hook deployed at:", address(hook));
        console.log("");
        console.log("Add to .env:");
        console.log("  ALPHIX_LVR_FEE_HOOK_%s=%s", network, address(hook));
        console.log("");
        console.log("Next: Run 02_ConfigureRoles.s.sol");
        console.log("===========================================");
    }
}
