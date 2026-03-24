// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {AlphixLVR} from "../../src/AlphixLVR.sol";

/**
 * @title Create Pool for AlphixLVR
 * @notice Initializes a Uniswap V4 pool with the AlphixLVR dynamic fee hook and pokes the initial fee
 * @dev Since AlphixLVR is multi-pool, this can be run multiple times for different pools.
 *      IMPORTANT: Atomically pokes the initial fee after pool creation to avoid the zero-fee window.
 *
 * DEPLOYMENT ORDER: 3 (After role configuration)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - ALPHIX_LVR_HOOK_{NETWORK}: AlphixLVR Hook contract address
 * - TOKEN0_{NETWORK}: First token address (must be < TOKEN1)
 * - TOKEN1_{NETWORK}: Second token address (must be > TOKEN0)
 * - TICK_SPACING_{NETWORK}: Tick spacing for the pool
 * - SQRT_PRICE_{NETWORK}: Starting sqrtPriceX96
 * - INITIAL_FEE_{NETWORK}: Initial dynamic fee in hundredths of a bip (e.g., 3000 = 0.3%)
 */
contract CreatePoolLVRScript is Script {
    using PoolIdLibrary for PoolKey;

    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("POOL_MANAGER_", network);
        address poolManagerAddr = vm.envAddress(envVar);
        require(poolManagerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_LVR_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("TOKEN0_", network);
        address token0 = vm.envAddress(envVar);

        envVar = string.concat("TOKEN1_", network);
        address token1 = vm.envAddress(envVar);
        require(token1 != address(0), string.concat(envVar, " not set"));
        require(token0 < token1, "TOKEN0 must be < TOKEN1");

        envVar = string.concat("TICK_SPACING_", network);
        int24 tickSpacing = int24(vm.envInt(envVar));
        require(tickSpacing > 0, string.concat(envVar, " must be > 0"));

        envVar = string.concat("SQRT_PRICE_", network);
        uint160 sqrtPrice = uint160(vm.envUint(envVar));
        require(sqrtPrice > 0, string.concat(envVar, " must be > 0"));

        envVar = string.concat("INITIAL_FEE_", network);
        uint24 initialFee = uint24(vm.envUint(envVar));

        IPoolManager poolManager = IPoolManager(poolManagerAddr);
        AlphixLVR hook = AlphixLVR(hookAddr);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(hook)
        });

        PoolId poolId = poolKey.toId();

        console.log("===========================================");
        console.log("CREATING POOL WITH ALPHIX LVR HOOK");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("PoolManager:", poolManagerAddr);
        console.log("AlphixLVR Hook:", hookAddr);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        console.log("Tick Spacing:", uint256(uint24(tickSpacing)));
        console.log("Initial Fee:", uint256(initialFee));
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("");

        vm.startBroadcast();

        // Step 1: Initialize pool (triggers afterInitialize which sets fee to 0)
        console.log("Step 1: Initializing pool...");
        poolManager.initialize(poolKey, sqrtPrice);
        console.log("  - Pool initialized");

        // Step 2: Atomically poke the initial fee (avoids zero-fee window)
        if (initialFee > 0) {
            console.log("Step 2: Setting initial fee...");
            hook.poke(poolKey, initialFee);
            console.log("  - Fee set to:", uint256(initialFee));
        }

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("POOL CREATED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console.log("Fee:", uint256(initialFee));
        console.log("");
        console.log("NOTES:");
        console.log("- Pool is ready for liquidity (add via PositionManager)");
        console.log("- Fee can be updated via poke() by the FEE_POKER_ROLE");
        console.log("- This hook has zero gas overhead on swaps");
        console.log("===========================================");
    }
}
