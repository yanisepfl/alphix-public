// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {AlphixLVR} from "../../src/AlphixLVR.sol";

/**
 * @title Poke Fee for AlphixLVR
 * @notice Updates the dynamic fee for a specific pool
 * @dev Must be run by an address with FEE_POKER_ROLE
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LVR_HOOK_{NETWORK}: AlphixLVR Hook contract address
 * - TOKEN0_{NETWORK}: First token address
 * - TOKEN1_{NETWORK}: Second token address
 * - TICK_SPACING_{NETWORK}: Tick spacing for the pool
 * - NEW_FEE_{NETWORK}: New fee in hundredths of a bip (e.g., 3000 = 0.3%)
 */
contract PokeLVRScript is Script {
    using PoolIdLibrary for PoolKey;

    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_LVR_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TOKEN0_", network);
        address token0 = vm.envAddress(envVar);

        envVar = string.concat("TOKEN1_", network);
        address token1 = vm.envAddress(envVar);
        require(token1 != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TICK_SPACING_", network);
        int24 tickSpacing = int24(vm.envInt(envVar));

        envVar = string.concat("NEW_FEE_", network);
        uint24 newFee = uint24(vm.envUint(envVar));

        AlphixLVR hook = AlphixLVR(hookAddr);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        PoolId poolId = poolKey.toId();
        uint24 currentFee = hook.getFee(poolId);

        console.log("===========================================");
        console.log("POKING ALPHIX LVR FEE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Hook:", hookAddr);
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("Current Fee:", uint256(currentFee));
        console.log("New Fee:", uint256(newFee));
        console.log("");

        vm.startBroadcast();

        hook.poke(poolKey, newFee);

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("FEE UPDATED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Fee changed:", uint256(currentFee), "->", uint256(newFee));
        console.log("===========================================");
    }
}
