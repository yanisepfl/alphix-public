// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";

/**
 * @title Deploy AlphixETH Hook (ETH/ERC20 Pools)
 * @notice Mines address and deploys the AlphixETH Hook for native ETH pairs
 * @dev Uses CREATE2 to deploy at an address with required hook flags
 *
 * DEPLOYMENT ORDER: 1 (After AccessManager - alternative to 01_DeployAlphix.s.sol)
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each AlphixETH Hook manages exactly ONE ETH/ERC20 pool.
 * currency0 MUST be native ETH (address(0)).
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - CREATE2_DEPLOYER_{NETWORK}: CREATE2 factory address
 * - ALPHIX_MANAGER_{NETWORK}: Initial owner address (must be tx sender)
 * - ACCESS_MANAGER_{NETWORK}: AccessManager contract address
 * - TOKEN_NAME_{NETWORK}: ERC20 share token name (default: "Alphix ETH LP Shares")
 * - TOKEN_SYMBOL_{NETWORK}: ERC20 share token symbol (default: "ALPHIX-ETH-LP")
 *
 * ETH-Specific Requirements:
 * - Pool currency0 must be native ETH (address(0))
 * - Yield source for currency0 must implement IAlphix4626WrapperWeth
 *
 * After Deployment:
 * - Copy the deployed address to ALPHIX_HOOK in .env
 */
contract DeployAlphixETHScript is Script {
    struct DeploymentData {
        string network;
        address poolManagerAddr;
        address create2DeployerAddr;
        address alphixManager;
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

        envVar = string.concat("ALPHIX_MANAGER_", data.network);
        data.alphixManager = vm.envAddress(envVar);
        require(data.alphixManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ACCESS_MANAGER_", data.network);
        data.accessManager = vm.envAddress(envVar);
        require(data.accessManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TOKEN_NAME_", data.network);
        try vm.envString(envVar) returns (string memory name) {
            data.tokenName = bytes(name).length > 0 ? name : "Alphix ETH LP Shares";
        } catch {
            data.tokenName = "Alphix ETH LP Shares";
        }

        envVar = string.concat("TOKEN_SYMBOL_", data.network);
        try vm.envString(envVar) returns (string memory symbol) {
            data.tokenSymbol = bytes(symbol).length > 0 ? symbol : "ALPHIX-ETH-LP";
        } catch {
            data.tokenSymbol = "ALPHIX-ETH-LP";
        }

        console.log("===========================================");
        console.log("DEPLOYING ALPHIX ETH HOOK (ETH/ERC20)");
        console.log("===========================================");
        console.log("Network:", data.network);
        console.log("PoolManager:", data.poolManagerAddr);
        console.log("CREATE2 Deployer:", data.create2DeployerAddr);
        console.log("Alphix Manager:", data.alphixManager);
        console.log("AccessManager:", data.accessManager);
        console.log("Token Name:", data.tokenName);
        console.log("Token Symbol:", data.tokenSymbol);
        console.log("");

        // All 14 hook permissions enabled
        data.flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_DONATE_FLAG | Hooks.AFTER_DONATE_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        console.log("Mining hook address with required flags...");

        IPoolManager poolManager = IPoolManager(data.poolManagerAddr);
        bytes memory constructorArgs =
            abi.encode(poolManager, data.alphixManager, data.accessManager, data.tokenName, data.tokenSymbol);

        (data.hookAddress, data.salt) =
            HookMiner.find(data.create2DeployerAddr, data.flags, type(AlphixETH).creationCode, constructorArgs);

        console.log("Mined hook address:", data.hookAddress);
        console.log("");

        vm.startBroadcast();

        AlphixETH alphix = new AlphixETH{salt: data.salt}(
            poolManager, data.alphixManager, data.accessManager, data.tokenName, data.tokenSymbol
        );

        vm.stopBroadcast();

        require(address(alphix) == data.hookAddress, "Hook address mismatch");

        console.log("===========================================");
        console.log("DEPLOYMENT SUCCESSFUL");
        console.log("===========================================");
        console.log("AlphixETH Hook deployed at:", address(alphix));
        console.log("");
        console.log("Add to .env:");
        console.log("  ALPHIX_HOOK_%s=%s", data.network, address(alphix));
        console.log("");
        console.log("NOTES:");
        console.log("- Hook is PAUSED by default (unpause in step 02)");
        console.log("- This hook REQUIRES ETH as currency0 (address(0))");
        console.log("- Yield source for ETH must implement IAlphix4626WrapperWeth");
        console.log("");
        console.log("Next: Run 02_ConfigureAndUnpause.s.sol");
        console.log("===========================================");
    }
}
