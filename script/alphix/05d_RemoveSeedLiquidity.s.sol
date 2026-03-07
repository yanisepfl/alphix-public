// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {Alphix} from "../../src/Alphix.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title Remove Seed Liquidity (PositionManager NFT)
 * @notice Removes the initial seed liquidity added during pool creation via PositionManager
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - POSITION_MANAGER_{NETWORK}: PositionManager address
 * - SEED_TOKEN_ID_{NETWORK}: NFT token ID to remove
 */
contract RemoveSeedLiquidityScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        address hookAddr = vm.envAddress(string.concat("ALPHIX_HOOK_", network));
        address posMgr = vm.envAddress(string.concat("POSITION_MANAGER_", network));
        uint256 tokenId = vm.envUint(string.concat("SEED_TOKEN_ID_", network));

        Alphix alphix = Alphix(hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();

        // Get current liquidity
        uint128 liquidity = IPositionManager(posMgr).getPositionLiquidity(tokenId);
        require(liquidity > 0, "Position has no liquidity");

        console.log("===========================================");
        console.log("REMOVING SEED LIQUIDITY");
        console.log("===========================================");
        console.log("Token ID:", tokenId);
        console.log("Liquidity:", liquidity);
        console.log("");

        // Build actions: DECREASE_LIQUIDITY, TAKE_PAIR, BURN_POSITION
        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR), uint8(Actions.BURN_POSITION));

        bytes[] memory params = new bytes[](3);

        // DECREASE_LIQUIDITY: (tokenId, liquidity, amount0Min, amount1Min, hookData)
        params[0] = abi.encode(tokenId, liquidity, uint256(0), uint256(0), bytes(""));

        // TAKE_PAIR: (currency0, currency1, recipient)
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, msg.sender);

        // BURN_POSITION: (tokenId, amount0Min, amount1Min, hookData)
        params[2] = abi.encode(tokenId, uint256(0), uint256(0), bytes(""));

        vm.startBroadcast();

        console.log("Removing liquidity and burning NFT...");
        IPositionManager(posMgr).modifyLiquidities(abi.encode(actions, params), block.timestamp + 5 minutes);
        console.log("  - Done");

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("SEED LIQUIDITY REMOVED");
        console.log("===========================================");
    }
}
