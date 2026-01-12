// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Alphix} from "../../src/Alphix.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

/**
 * @title Create Pool (without liquidity)
 * @notice Creates and initializes a Uniswap V4 pool with Alphix Hook, but does NOT add liquidity
 * @dev Use this when you want to separate pool creation from liquidity addition
 *
 * USAGE: Run this script to create a pool, then use 09c_AddLiquidity.s.sol to add liquidity
 *
 * SENDER REQUIREMENTS: Any address can run this script.
 * Pool creation does not require any special permissions.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - POSITION_MANAGER_{NETWORK}: Uniswap V4 PositionManager address
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - DEPLOYMENT_TOKEN0_{NETWORK}: First token address (must be < TOKEN1)
 * - DEPLOYMENT_TOKEN1_{NETWORK}: Second token address (must be > TOKEN0)
 * - POOL_TICK_SPACING_{NETWORK}: Tick spacing for the pool
 * - POOL_START_PRICE_{NETWORK}: Starting sqrtPriceX96
 * - POOL_INITIAL_FEE_{NETWORK}: Initial dynamic fee
 * - POOL_INITIAL_TARGET_RATIO_{NETWORK}: Initial target ratio
 * Note: Pool parameters (PoolParams) are now set with sensible defaults in this script.
 *
 * After Execution:
 * - Pool is created and initialized in Uniswap V4
 * - Alphix dynamic fee system is configured for the pool
 * - Pool is registered in Registry
 * - NO liquidity is added (use 09c_AddLiquidity.s.sol for that)
 */
contract CreatePoolScript is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    struct PoolConfig {
        string network;
        address poolManagerAddr;
        address positionManagerAddr;
        address alphixHookAddr;
        address token0Addr;
        address token1Addr;
        int24 tickSpacing;
        uint160 startPrice;
        uint24 initialFee;
        uint256 initialTargetRatio;
        DynamicFeeLib.PoolParams poolParams;
    }

    function run() public {
        PoolConfig memory config;

        // Load environment variables
        config.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(config.network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        // Get contract addresses
        envVar = string.concat("POOL_MANAGER_", config.network);
        config.poolManagerAddr = vm.envAddress(envVar);

        envVar = string.concat("POSITION_MANAGER_", config.network);
        config.positionManagerAddr = vm.envAddress(envVar);

        envVar = string.concat("ALPHIX_HOOK_", config.network);
        config.alphixHookAddr = vm.envAddress(envVar);

        envVar = string.concat("DEPLOYMENT_TOKEN0_", config.network);
        config.token0Addr = vm.envAddress(envVar);

        envVar = string.concat("DEPLOYMENT_TOKEN1_", config.network);
        config.token1Addr = vm.envAddress(envVar);

        // Validate token ordering
        require(config.token0Addr < config.token1Addr, "TOKEN0 must be < TOKEN1");

        // Get pool configuration
        envVar = string.concat("POOL_TICK_SPACING_", config.network);
        config.tickSpacing = int24(uint24(vm.envUint(envVar)));

        envVar = string.concat("POOL_START_PRICE_", config.network);
        config.startPrice = uint160(vm.envUint(envVar));

        envVar = string.concat("POOL_INITIAL_FEE_", config.network);
        config.initialFee = uint24(vm.envUint(envVar));

        envVar = string.concat("POOL_INITIAL_TARGET_RATIO_", config.network);
        config.initialTargetRatio = vm.envUint(envVar);

        // Load pool params with sensible defaults
        config.poolParams = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001, // Wide range
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });

        // Create currencies
        Currency currency0 = Currency.wrap(config.token0Addr);
        Currency currency1 = Currency.wrap(config.token1Addr);

        // Get token decimals for display
        uint8 token0Decimals = currency0.isAddressZero() ? 18 : IERC20(config.token0Addr).decimals();
        uint8 token1Decimals = currency1.isAddressZero() ? 18 : IERC20(config.token1Addr).decimals();

        // Calculate current tick for display
        int24 currentTick = TickMath.getTickAtSqrtPrice(config.startPrice);

        console.log("===========================================");
        console.log("CREATING POOL (WITHOUT LIQUIDITY)");
        console.log("===========================================");
        console.log("Network:", config.network);
        console.log("Token0:", config.token0Addr);
        console.log("  - Decimals:", token0Decimals);
        console.log("Token1:", config.token1Addr);
        console.log("  - Decimals:", token1Decimals);
        console.log("Hook:", config.alphixHookAddr);
        console.log("Tick Spacing:", uint256(uint24(config.tickSpacing)));
        console.log("Start Price (sqrtPriceX96):", config.startPrice);
        console.log("Current Tick:", currentTick);
        console.log("");
        console.log("Alphix Configuration:");
        console.log("  - Initial Fee: %s bps", config.initialFee);
        console.log("  - Initial Target Ratio: %s", config.initialTargetRatio);
        console.log("  - Min Fee: %s bps", config.poolParams.minFee);
        console.log("  - Max Fee: %s bps", config.poolParams.maxFee);
        console.log("");

        // Create contract instances
        IPositionManager posm = IPositionManager(config.positionManagerAddr);
        Alphix alphix = Alphix(config.alphixHookAddr);

        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.alphixHookAddr)
        });

        PoolId poolId = poolKey.toId();
        console.log("Pool ID: 0x%s", _toHex(PoolId.unwrap(poolId)));
        console.log("");

        vm.startBroadcast();

        // STEP 1: Initialize pool in Uniswap V4
        console.log("Step 1: Initializing pool in Uniswap V4...");
        posm.initializePool(poolKey, config.startPrice);
        console.log("  - Pool initialized successfully (Uniswap V4)");
        console.log("");

        // STEP 2: Initialize Alphix dynamic fee system for this pool
        console.log("Step 2: Initializing Alphix dynamic fee system...");
        alphix.initializePool(poolKey, config.initialFee, config.initialTargetRatio, config.poolParams);
        console.log("  - Pool initialized successfully (Alphix)");
        console.log("");

        vm.stopBroadcast();

        console.log("===========================================");
        console.log("POOL CREATION SUCCESSFUL");
        console.log("===========================================");
        console.log("Pool ID: 0x%s", _toHex(PoolId.unwrap(poolId)));
        console.log("");
        console.log("Pool Details:");
        console.log("  - Token0: %s", config.token0Addr);
        console.log("  - Token1: %s", config.token1Addr);
        console.log("  - Fee: DYNAMIC (managed by Alphix)");
        console.log("  - Initial Fee: %s bps", config.initialFee);
        console.log("  - Tick Spacing: %d", config.tickSpacing);
        console.log("  - Liquidity: NONE (use 09c_AddLiquidity.s.sol)");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Add this Pool ID to your .env:");
        console.log("   POOL_ID_%s=0x%s", config.network, _toHex(PoolId.unwrap(poolId)));
        console.log("2. Add liquidity using script 09c_AddLiquidity.s.sol");
        console.log("===========================================");
    }

    /**
     * @dev Convert bytes32 to hex string
     */
    function _toHex(bytes32 data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(64);

        for (uint256 i = 0; i < 32; i++) {
            result[i * 2] = hexChars[uint8(data[i] >> 4)];
            result[i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }

        return string(result);
    }
}
