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
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TickBitmap} from "v4-core/src/libraries/TickBitmap.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {Alphix} from "../../src/Alphix.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

/**
 * @title Create Pool and Add Liquidity
 * @notice Creates a Uniswap V4 pool with Alphix Hook and seeds it with liquidity
 * @dev Properly initializes pool BEFORE adding liquidity, uses human-readable amounts
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each Alphix Hook + AlphixLogic pair manages exactly ONE pool.
 * This script creates THE pool for a specific hook deployment.
 * Once a pool is created for a hook, you cannot create another pool with the same hook.
 *
 * To deploy multiple pools:
 * 1. Deploy a new Alphix Hook (script 04)
 * 2. Deploy a new AlphixLogic proxy (script 05)
 * 3. Configure the system (script 06)
 * 4. Create the pool (this script)
 *
 * USAGE: Run this script after system configuration to create your first pool
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
 * - POOL_TOKEN0_AMOUNT_{NETWORK}: Amount in base units/wei (e.g., "100000000" for 0.1 USDC with 6 decimals)
 * - POOL_TOKEN1_AMOUNT_{NETWORK}: Amount in base units/wei (e.g., "100000000000000000" for 0.1 ETH with 18 decimals)
 * - POOL_LIQUIDITY_RANGE_{NETWORK}: Range in tick spacings around current price (e.g., "100")
 *
 * IMPORTANT: Token amounts must be specified in base units (wei), NOT human-readable units.
 * Examples:
 *   - For 0.1 USDC (6 decimals): POOL_TOKEN0_AMOUNT_SEPOLIA=100000
 *   - For 0.5 ETH (18 decimals):  POOL_TOKEN0_AMOUNT_SEPOLIA=500000000000000000
 *   - For 100 USDC (6 decimals):  POOL_TOKEN0_AMOUNT_SEPOLIA=100000000
 *   - You can use scientific notation: cast --to-wei 0.1 ether
 * - POOL_INITIAL_FEE_{NETWORK}: Initial dynamic fee
 * - POOL_INITIAL_TARGET_RATIO_{NETWORK}: Initial target ratio
 * Note: Pool parameters (PoolParams) are now set with sensible defaults in this script.
 *
 * After Execution:
 * - Pool is created and initialized
 * - Liquidity is added
 * - Dynamic fee system is activated
 * - Pool is registered in Registry
 */
contract CreatePoolAndAddLiquidityScript is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // PERMIT2 constant address across networks
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // Struct to avoid stack too deep errors
    struct PoolConfig {
        string network;
        address poolManagerAddr;
        address positionManagerAddr;
        address alphixHookAddr;
        address token0Addr;
        address token1Addr;
        int24 tickSpacing;
        uint160 startPrice;
        uint256 liquidityRange;
        uint24 initialFee;
        uint256 initialTargetRatio;
        DynamicFeeLib.PoolParams poolParams;
    }

    struct LiquidityConfig {
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint256 token0Amount;
        uint256 token1Amount;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 valueToPass;
    }

    function run() public {
        PoolConfig memory config;
        LiquidityConfig memory liq;

        // Load environment variables
        config.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(config.network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Reuse envVar string for all lookups
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

        // Get token amounts (already in base units/wei)
        envVar = string.concat("POOL_TOKEN0_AMOUNT_", config.network);
        liq.token0Amount = vm.envUint(envVar);

        envVar = string.concat("POOL_TOKEN1_AMOUNT_", config.network);
        liq.token1Amount = vm.envUint(envVar);

        envVar = string.concat("POOL_LIQUIDITY_RANGE_", config.network);
        config.liquidityRange = vm.envUint(envVar);

        envVar = string.concat("POOL_INITIAL_FEE_", config.network);
        config.initialFee = uint24(vm.envUint(envVar));

        envVar = string.concat("POOL_INITIAL_TARGET_RATIO_", config.network);
        config.initialTargetRatio = vm.envUint(envVar);

        // Load pool params from environment or use defaults
        // These can be customized per-deployment for fine-tuning
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

        // Get token decimals for display purposes
        liq.token0Decimals = currency0.isAddressZero() ? 18 : IERC20(config.token0Addr).decimals();
        liq.token1Decimals = currency1.isAddressZero() ? 18 : IERC20(config.token1Addr).decimals();

        // Calculate tick bounds around current price
        // Uses TickBitmap.compress to ensure ticks are multiples of tickSpacing
        int24 currentTick = TickMath.getTickAtSqrtPrice(config.startPrice);
        int24 compressed = TickBitmap.compress(currentTick, config.tickSpacing);
        liq.tickLower = (compressed - int24(uint24(config.liquidityRange))) * config.tickSpacing;
        liq.tickUpper = (compressed + int24(uint24(config.liquidityRange))) * config.tickSpacing;

        console.log("===========================================");
        console.log("CREATING POOL AND ADDING LIQUIDITY");
        console.log("===========================================");
        console.log("Network:", config.network);
        console.log("Token0:", config.token0Addr);
        console.log("Token1:", config.token1Addr);
        console.log("Hook:", config.alphixHookAddr);
        console.log("Tick Spacing:", uint256(uint24(config.tickSpacing)));
        console.log("Start Price:", config.startPrice);
        console.log("");
        console.log("Token Amounts:");
        console.log("  - Token0: %s wei (%s decimals)", liq.token0Amount, liq.token0Decimals);
        console.log("  - Token1: %s wei (%s decimals)", liq.token1Amount, liq.token1Decimals);
        console.log("");
        console.log("Tick Range:");
        console.log("  - Current Tick: %d", currentTick);
        console.log("  - Compressed Tick: %d", compressed);
        console.log("  - Lower: %d", liq.tickLower);
        console.log("  - Upper: %d", liq.tickUpper);
        console.log("  - Range: +/- %s tick spacings", config.liquidityRange);
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
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, // Required for dynamic fees
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.alphixHookAddr)
        });

        PoolId poolId = poolKey.toId();
        console.log("Pool ID: 0x%s", _toHex(PoolId.unwrap(poolId)));
        console.log("");

        // Calculate liquidity from amounts
        liq.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            config.startPrice,
            TickMath.getSqrtPriceAtTick(liq.tickLower),
            TickMath.getSqrtPriceAtTick(liq.tickUpper),
            liq.token0Amount,
            liq.token1Amount
        );

        console.log("Calculated Liquidity:", liq.liquidity);
        console.log("");

        vm.startBroadcast();

        // Approve tokens to PERMIT2 and PositionManager (token amounts + 1 wei for slippage)
        _approveTokens(currency0, currency1, address(posm), liq.token0Amount + 1, liq.token1Amount + 1);

        // STEP 1: Initialize pool FIRST
        console.log("Step 1: Initializing pool...");
        posm.initializePool(poolKey, config.startPrice);
        console.log("  - Pool initialized successfully (Uniswap V4)");
        console.log("");

        // STEP 2: Initialize Alphix dynamic fee system for this pool
        console.log("Step 2: Initializing Alphix dynamic fee system...");
        alphix.initializePool(poolKey, config.initialFee, config.initialTargetRatio, config.poolParams);
        console.log("  - Pool initialized successfully (Alphix)");
        console.log("");

        // STEP 3: Add liquidity AFTER initialization
        console.log("Step 3: Adding liquidity...");
        _addLiquidity(posm, poolKey, liq, currency0.isAddressZero());
        console.log("  - Liquidity added successfully");
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
        console.log("  - Liquidity: %s", liq.liquidity);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Add this Pool ID to your .env:");
        console.log("   POOL_ID_%s=0x%s", config.network, _toHex(PoolId.unwrap(poolId)));
        console.log("2. Perform swaps using script 10_Swap.s.sol");
        console.log("3. Update fees using script 11_PokeFee.s.sol");
        console.log("===========================================");
    }

    /**
     * @dev Helper to get environment variable address
     */
    function _getEnvAddress(string memory prefix, string memory network) internal view returns (address) {
        string memory envVar = string.concat(prefix, network);
        address addr = vm.envAddress(envVar);
        require(addr != address(0), string.concat(envVar, " not set or invalid"));
        return addr;
    }

    /**
     * @dev Helper to get environment variable uint
     */
    function _getEnvUint(string memory prefix, string memory network) internal view returns (uint256) {
        string memory envVar = string.concat(prefix, network);
        return vm.envUint(envVar);
    }

    /**
     * @dev Approve tokens to PERMIT2 and PositionManager
     * @param amount0 Amount of token0 to approve (must fit in uint160 for PERMIT2)
     * @param amount1 Amount of token1 to approve (must fit in uint160 for PERMIT2)
     */
    function _approveTokens(Currency currency0, Currency currency1, address posm, uint256 amount0, uint256 amount1)
        internal
    {
        // PERMIT2 uses uint160 for amounts, ensure no overflow
        require(amount0 <= type(uint160).max, "Amount0 exceeds uint160 max");
        require(amount1 <= type(uint160).max, "Amount1 exceeds uint160 max");

        // Set realistic expiry: 1 hour from now
        uint48 expiration = uint48(block.timestamp + 1 hours);

        if (!currency0.isAddressZero()) {
            address token0 = Currency.unwrap(currency0);
            IERC20(token0).approve(address(PERMIT2), amount0);
            // forge-lint: disable-next-line(unsafe-typecast)
            PERMIT2.approve(token0, posm, uint160(amount0), expiration);
        }
        if (!currency1.isAddressZero()) {
            address token1 = Currency.unwrap(currency1);
            IERC20(token1).approve(address(PERMIT2), amount1);
            // forge-lint: disable-next-line(unsafe-typecast)
            PERMIT2.approve(token1, posm, uint160(amount1), expiration);
        }
    }

    /**
     * @dev Add liquidity to the pool
     */
    function _addLiquidity(IPositionManager posm, PoolKey memory poolKey, LiquidityConfig memory liq, bool isNativeEth)
        internal
    {
        bytes memory hookData = "";
        bytes memory actions;
        bytes[] memory params;

        uint256 amount0Max = liq.token0Amount + 1 wei;
        uint256 amount1Max = liq.token1Amount + 1 wei;
        uint256 valueToPass = isNativeEth ? amount0Max : 0;

        if (isNativeEth) {
            (actions, params) = _mintLiquidityParamsWithSweep(
                poolKey, liq.tickLower, liq.tickUpper, liq.liquidity, amount0Max, amount1Max, hookData
            );
        } else {
            (actions, params) = _mintLiquidityParams(
                poolKey, liq.tickLower, liq.tickUpper, liq.liquidity, amount0Max, amount1Max, hookData
            );
        }

        posm.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 60);
    }

    /**
     * @dev Helper to encode mint liquidity operation for ERC20 pairs
     */
    function _mintLiquidityParams(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        bytes memory hookData
    ) internal view returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, msg.sender, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        return (actions, params);
    }

    /**
     * @dev Helper to encode mint liquidity operation with SWEEP for native ETH pairs
     */
    function _mintLiquidityParamsWithSweep(
        PoolKey memory poolKey,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 liquidity,
        uint256 amount0Max,
        uint256 amount1Max,
        bytes memory hookData
    ) internal view returns (bytes memory, bytes[] memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(poolKey, _tickLower, _tickUpper, liquidity, amount0Max, amount1Max, msg.sender, hookData);
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), msg.sender); // Sweep ETH to sender

        return (actions, params);
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
