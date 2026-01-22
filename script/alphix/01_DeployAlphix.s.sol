// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Deploy Alphix Hook (ERC20/ERC20 Pools)
 * @notice Mines address and deploys the Alphix Hook for ERC20 token pairs
 * @dev Uses CREATE2 to deploy at an address with required hook flags
 *
 * DEPLOYMENT ORDER: 1 (After AccessManager)
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each Alphix Hook manages exactly ONE pool. To deploy multiple pools,
 * deploy multiple hooks (repeat this script with different token configs).
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - CREATE2_DEPLOYER_{NETWORK}: CREATE2 factory address
 * - ALPHIX_OWNER_{NETWORK}: Initial owner address of the Alphix hook
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - TOKEN_NAME_{NETWORK}: ERC20 share token name (default: "Alphix LP Shares")
 * - TOKEN_SYMBOL_{NETWORK}: ERC20 share token symbol (default: "ALPHIX-LP")
 *
 * Hook Permissions (3 enabled - matching Alphix.sol):
 * - beforeInitialize
 * - beforeSwap
 * - afterSwap
 *
 * After Deployment:
 * - Copy the deployed address to ALPHIX_HOOK in .env
 */
contract DeployAlphixScript is Script {
    struct DeploymentData {
        string network;
        address poolManagerAddr;
        address create2DeployerAddr;
        address alphixOwner;
        address accessManager;
        string tokenName;
        string tokenSymbol;
        uint160 flags;
        address hookAddress;
        bytes32 salt;
    }

    function run() public {
        DeploymentData memory data;

        data.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(data.network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("POOL_MANAGER_", data.network);
        data.poolManagerAddr = vm.envAddress(envVar);
        require(data.poolManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("CREATE2_DEPLOYER_", data.network);
        data.create2DeployerAddr = vm.envAddress(envVar);
        require(data.create2DeployerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_OWNER_", data.network);
        data.alphixOwner = vm.envAddress(envVar);
        require(data.alphixOwner != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_", data.network);
        data.accessManager = vm.envAddress(envVar);
        require(data.accessManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TOKEN_NAME_", data.network);
        try vm.envString(envVar) returns (string memory name) {
            data.tokenName = bytes(name).length > 0 ? name : "Alphix LP Shares";
        } catch {
            data.tokenName = "Alphix LP Shares";
        }

        envVar = string.concat("TOKEN_SYMBOL_", data.network);
        try vm.envString(envVar) returns (string memory symbol) {
            data.tokenSymbol = bytes(symbol).length > 0 ? symbol : "ALPHIX-LP";
        } catch {
            data.tokenSymbol = "ALPHIX-LP";
        }

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX HOOK (ERC20/ERC20)");
        console.log("===========================================");
        console.log("Network:", data.network);
        console.log("PoolManager:", data.poolManagerAddr);
        console.log("CREATE2 Deployer:", data.create2DeployerAddr);
        console.log("Alphix Owner:", data.alphixOwner);
        console.log("AccessManager:", data.accessManager);
        console.log("Token Name:", data.tokenName);
        console.log("Token Symbol:", data.tokenSymbol);
        console.log("");

        // Hook permissions matching Alphix.getHookPermissions()
        data.flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        console.log("Mining hook address with required flags...");

        IPoolManager poolManager = IPoolManager(data.poolManagerAddr);
        bytes memory constructorArgs =
            abi.encode(poolManager, data.alphixOwner, data.accessManager, data.tokenName, data.tokenSymbol);

        (data.hookAddress, data.salt) =
            HookMiner.find(data.create2DeployerAddr, data.flags, type(Alphix).creationCode, constructorArgs);

        console.log("Mined hook address:", data.hookAddress);
        console.log("");

        vm.startBroadcast();

        Alphix alphix = new Alphix{salt: data.salt}(
            poolManager, data.alphixOwner, data.accessManager, data.tokenName, data.tokenSymbol
        );

        vm.stopBroadcast();

        require(address(alphix) == data.hookAddress, "Hook address mismatch");

        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("Alphix Hook deployed at:", address(alphix));
        console.log("");
        console.log("Add to .env:");
        console.log("  ALPHIX_HOOK_%s=%s", data.network, address(alphix));
        console.log("");
        console.log("NOTES:");
        console.log("- Hook is PAUSED by default (unpause in step 02)");
        console.log("- This hook is for ERC20/ERC20 pools");
        console.log("");
        console.log("Next: Run 02_ConfigureAndUnpause.s.sol");
        console.log("===========================================");
    }
}
