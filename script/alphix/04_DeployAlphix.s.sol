// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {Registry} from "../../src/Registry.sol";

/**
 * @title Deploy Alphix Hook
 * @notice Mines the address and deploys the Alphix Hook contract
 * @dev Uses CREATE2 to deploy at an address with required hook flags
 *
 * DEPLOYMENT ORDER: 4/11
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - CREATE2_DEPLOYER_{NETWORK}: CREATE2 factory address
 * - ALPHIX_MANAGER_{NETWORK}: Initial owner address
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - REGISTRY_{NETWORK}: Registry contract address
 *
 * After Deployment:
 * - Copy the deployed address to ALPHIX_HOOK_{NETWORK} in .env
 *
 * Hook Permissions:
 * - afterInitialize: Register pool in registry
 * - afterAddLiquidity: Track liquidity events
 * - afterRemoveLiquidity: Track liquidity events
 * - beforeSwap: Update dynamic fees
 * - afterSwap: Track swap events
 */
contract DeployAlphixScript is Script {
    uint64 constant REGISTRAR_ROLE = 2;
    // Struct to avoid stack too deep errors

    struct DeploymentData {
        string network;
        address poolManagerAddr;
        address create2DeployerAddr;
        address alphixManager;
        address accessManager;
        address registry;
        uint160 flags;
        address hookAddress;
        bytes32 salt;
    }

    function run() public {
        DeploymentData memory data;

        // Load environment variables
        data.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(data.network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get required addresses using single envVar pattern
        string memory envVar;

        envVar = string.concat("POOL_MANAGER_", data.network);
        data.poolManagerAddr = vm.envAddress(envVar);
        require(data.poolManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("CREATE2_DEPLOYER_", data.network);
        data.create2DeployerAddr = vm.envAddress(envVar);
        require(data.create2DeployerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_MANAGER_", data.network);
        data.alphixManager = vm.envAddress(envVar);
        require(data.alphixManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_", data.network);
        data.accessManager = vm.envAddress(envVar);
        require(data.accessManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("REGISTRY_", data.network);
        data.registry = vm.envAddress(envVar);
        require(data.registry != address(0), string.concat(envVar, " not set"));

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX HOOK");
        console.log("===========================================");
        console.log("Network:", data.network);
        console.log("PoolManager:", data.poolManagerAddr);
        console.log("CREATE2 Deployer:", data.create2DeployerAddr);
        console.log("Alphix Manager:", data.alphixManager);
        console.log("AccessManager:", data.accessManager);
        console.log("Registry:", data.registry);
        console.log("");

        // Hook contracts must have specific flags encoded in the address
        // Required permissions (from Alphix.getHookPermissions()):
        // - BEFORE_INITIALIZE_FLAG: Validate pool initialization
        // - AFTER_INITIALIZE_FLAG: Register pool in Registry
        // - BEFORE_ADD_LIQUIDITY_FLAG: Pre-liquidity checks
        // - AFTER_ADD_LIQUIDITY_FLAG: Track liquidity additions
        // - BEFORE_REMOVE_LIQUIDITY_FLAG: Pre-removal checks
        // - AFTER_REMOVE_LIQUIDITY_FLAG: Track liquidity removals
        // - BEFORE_SWAP_FLAG: Update dynamic fees before swap
        // - AFTER_SWAP_FLAG: Track swaps and update state
        data.flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        console.log("Mining hook address with required flags...");
        console.log("Required flags:", data.flags);
        console.log("");

        // Mine a salt that will produce a hook address with the correct flags
        IPoolManager poolManager = IPoolManager(data.poolManagerAddr);
        bytes memory constructorArgs = abi.encode(poolManager, data.alphixManager, data.accessManager, data.registry);

        (data.hookAddress, data.salt) =
            HookMiner.find(data.create2DeployerAddr, data.flags, type(Alphix).creationCode, constructorArgs);

        console.log("Mined hook address:", data.hookAddress);
        console.log("Salt:", uint256(data.salt));
        console.log("");

        // Grant REGISTRAR role BEFORE deploying the hook
        // The hook needs this role during construction/initialization
        console.log("Granting REGISTRAR role to future hook address...");

        AccessManager accessMgr = AccessManager(data.accessManager);
        Registry reg = Registry(data.registry);

        vm.startBroadcast();

        // Set target function role for Registry
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = reg.registerContract.selector;
        selectors[1] = reg.registerPool.selector;

        accessMgr.setTargetFunctionRole(data.registry, selectors, REGISTRAR_ROLE);
        console.log("  - Set Registry functions to require REGISTRAR_ROLE");

        // Grant REGISTRAR role to the mined address BEFORE deployment
        accessMgr.grantRole(REGISTRAR_ROLE, data.hookAddress, 0);
        console.log("  - Granted REGISTRAR_ROLE to address:", data.hookAddress);
        console.log("");

        // Now deploy the hook using CREATE2 at the pre-authorized address
        console.log("Deploying Alphix Hook at pre-authorized address...");
        Alphix alphix = new Alphix{salt: data.salt}(poolManager, data.alphixManager, data.accessManager, data.registry);

        vm.stopBroadcast();

        // Verify deployment
        require(address(alphix) == data.hookAddress, "DeployAlphixScript: hook address mismatch");

        console.log("");
        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("Alphix Hook deployed at:", address(alphix));
        console.log("");
        console.log("IMPORTANT NOTES:");
        console.log("- This is the HOOK contract that users interact with");
        console.log("- The hook is currently PAUSED (unpaused in script 06)");
        console.log("- Logic is NOT set yet (set in script 06)");
        console.log("- REGISTRAR role granted (hook can register pools)");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Add this to your .env file:");
        console.log("   ALPHIX_HOOK_%s=%s", data.network, address(alphix));
        console.log("2. Run script 05_DeployAlphixLogic.s.sol next");
        console.log("===========================================");
    }
}
