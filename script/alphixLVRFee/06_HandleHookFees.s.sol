// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {AlphixLVRFee} from "../../src/AlphixLVRFee.sol";

/**
 * @title Handle Hook Fees for AlphixLVRFee
 * @notice Collects accumulated ERC-6909 claims and transfers to treasury
 * @dev Callable by anyone (permissionless). Burns ERC-6909 claims and sends tokens to treasury.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LVR_FEE_HOOK_{NETWORK}: AlphixLVRFee Hook contract address
 * - COLLECT_CURRENCY0_{NETWORK}: First currency to collect (address, 0x0 for ETH)
 * - COLLECT_CURRENCY1_{NETWORK}: Second currency to collect (address)
 */
contract HandleHookFeesScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_LVR_FEE_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("COLLECT_CURRENCY0_", network);
        address curr0 = vm.envAddress(envVar);

        envVar = string.concat("COLLECT_CURRENCY1_", network);
        address curr1 = vm.envAddress(envVar);
        require(curr1 != address(0), string.concat(envVar, " not set"));

        AlphixLVRFee hook = AlphixLVRFee(hookAddr);
        IPoolManager poolManager = hook.poolManager();

        // Check balances before
        uint256 bal0 = poolManager.balanceOf(hookAddr, Currency.wrap(curr0).toId());
        uint256 bal1 = poolManager.balanceOf(hookAddr, Currency.wrap(curr1).toId());

        console.log("===========================================");
        console.log("COLLECTING HOOK FEES TO TREASURY");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Hook:", hookAddr);
        console.log("Treasury:", hook.treasury());
        console.log("Currency0 claims:", bal0);
        console.log("Currency1 claims:", bal1);
        console.log("");

        Currency[] memory currencies = new Currency[](2);
        currencies[0] = Currency.wrap(curr0);
        currencies[1] = Currency.wrap(curr1);

        vm.startBroadcast();
        hook.handleHookFees(currencies);
        vm.stopBroadcast();

        console.log("===========================================");
        console.log("FEES COLLECTED SUCCESSFULLY");
        console.log("===========================================");
    }
}
