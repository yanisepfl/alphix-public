// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {AlphixLVRFee} from "../../src/AlphixLVRFee.sol";

/**
 * @title Set Hook Fee for AlphixLVRFee
 * @notice Updates the protocol hook fee for a specific pool
 * @dev Must be run by an address with HOOK_FEE_ROLE
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LVR_FEE_HOOK_{NETWORK}: AlphixLVRFee Hook contract address
 * - TOKEN0_{NETWORK}: First token address
 * - TOKEN1_{NETWORK}: Second token address
 * - TICK_SPACING_{NETWORK}: Tick spacing for the pool
 * - HOOK_FEE_{NETWORK}: New hook fee in hundredths of a bip (max 1,000,000)
 */
contract SetHookFeeScript is Script {
    using PoolIdLibrary for PoolKey;

    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_LVR_FEE_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TOKEN0_", network);
        address token0 = vm.envAddress(envVar);

        envVar = string.concat("TOKEN1_", network);
        address token1 = vm.envAddress(envVar);
        require(token1 != address(0), string.concat(envVar, " not set"));
        require(token0 < token1, "Tokens must be in canonical order (token0 < token1)");

        envVar = string.concat("TICK_SPACING_", network);
        int24 tickSpacing = int24(vm.envInt(envVar));
        require(tickSpacing > 0, "TICK_SPACING must be positive");

        envVar = string.concat("HOOK_FEE_", network);
        uint24 hookFee = uint24(vm.envUint(envVar));

        AlphixLVRFee hook = AlphixLVRFee(hookAddr);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        PoolId poolId = poolKey.toId();
        uint24 currentHookFee = hook.getHookFee(poolId);

        console.log("===========================================");
        console.log("SETTING HOOK FEE (PROTOCOL FEE)");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Hook:", hookAddr);
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("Current Hook Fee:", uint256(currentHookFee));
        console.log("New Hook Fee:", uint256(hookFee));
        console.log("");

        vm.startBroadcast();
        hook.setHookFee(poolKey, hookFee);
        vm.stopBroadcast();

        console.log("===========================================");
        console.log("HOOK FEE UPDATED SUCCESSFULLY");
        console.log("===========================================");
    }
}
