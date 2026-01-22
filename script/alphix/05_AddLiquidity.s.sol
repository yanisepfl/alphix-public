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
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Add Liquidity to Existing Pool
 * @notice Adds liquidity to an existing Uniswap V4 pool with Alphix Hook
 * @dev Use this after creating a pool with 03_CreatePool.s.sol
 *
 * DEPLOYMENT ORDER: 5 (After pool creation)
 *
 * SENDER REQUIREMENTS: Any address can run this script.
 * The sender must have sufficient token balances to provide liquidity.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - POSITION_MANAGER_{NETWORK}: Uniswap V4 PositionManager address
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - LP_AMOUNT0_{NETWORK}: Token0 amount in wei
 * - LP_AMOUNT1_{NETWORK}: Token1 amount in wei
 * - LP_LIQUIDITY_RANGE_{NETWORK}: Range in tick spacings around current price
 *
 * Prerequisites:
 * - Pool must already exist (created via 03_CreatePool.s.sol)
 * - Sender must have sufficient token balances
 *
 * After Execution:
 * - Liquidity position is minted to the sender
 * - Position NFT ID is logged for future reference
 */
contract AddLiquidityScript is Script {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    struct Config {
        string network;
        address poolManager;
        address positionManager;
        address hook;
        uint256 liquidityRange;
        uint256 token0Amount;
        uint256 token1Amount;
        // From hook
        PoolKey poolKey;
        // Computed values
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        int24 currentTick;
    }

    function run() public {
        Config memory c = _loadConfig();
        _computePoolState(c);
        _logConfig(c);
        _executeLiquidity(c);
    }

    function _loadConfig() internal view returns (Config memory c) {
        c.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(c.network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("POOL_MANAGER_", c.network);
        c.poolManager = vm.envAddress(envVar);
        require(c.poolManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("POSITION_MANAGER_", c.network);
        c.positionManager = vm.envAddress(envVar);
        require(c.positionManager != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_HOOK_", c.network);
        c.hook = vm.envAddress(envVar);
        require(c.hook != address(0), string.concat(envVar, " not set"));

        // Get pool key from hook
        c.poolKey = Alphix(c.hook).getPoolKey();

        // Liquidity range validation
        envVar = string.concat("LP_LIQUIDITY_RANGE_", c.network);
        uint256 rawRange = vm.envUint(envVar);
        require(rawRange > 0, string.concat(envVar, " must be > 0"));
        require(rawRange <= uint256(uint24(type(int24).max)), string.concat(envVar, " exceeds int24 max"));
        c.liquidityRange = rawRange;

        // Token amounts
        envVar = string.concat("LP_AMOUNT0_", c.network);
        c.token0Amount = vm.envUint(envVar);

        envVar = string.concat("LP_AMOUNT1_", c.network);
        c.token1Amount = vm.envUint(envVar);

        require(c.token0Amount > 0 || c.token1Amount > 0, "At least one LP_AMOUNT must be > 0");
    }

    function _computePoolState(Config memory c) internal view {
        PoolId poolId = c.poolKey.toId();

        IPoolManager pm = IPoolManager(c.poolManager);
        (c.sqrtPriceX96, c.currentTick,,) = pm.getSlot0(poolId);
        require(c.sqrtPriceX96 != 0, "Pool not initialized - run 03_CreatePool.s.sol first");

        int24 compressed = TickBitmap.compress(c.currentTick, c.poolKey.tickSpacing);
        // forge-lint: disable-next-line(unsafe-typecast)
        c.tickLower = (compressed - int24(uint24(c.liquidityRange))) * c.poolKey.tickSpacing;
        // forge-lint: disable-next-line(unsafe-typecast)
        c.tickUpper = (compressed + int24(uint24(c.liquidityRange))) * c.poolKey.tickSpacing;

        // Validate tick bounds
        require(c.tickLower >= TickMath.MIN_TICK, "tickLower below MIN_TICK - reduce LP_LIQUIDITY_RANGE");
        require(c.tickUpper <= TickMath.MAX_TICK, "tickUpper above MAX_TICK - reduce LP_LIQUIDITY_RANGE");

        c.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            c.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(c.tickLower),
            TickMath.getSqrtPriceAtTick(c.tickUpper),
            c.token0Amount,
            c.token1Amount
        );

        require(c.liquidity > 0, "Computed liquidity is 0 - increase token amounts or adjust range");
    }

    function _logConfig(Config memory c) internal view {
        PoolId poolId = c.poolKey.toId();
        bool isEthPool = c.poolKey.currency0.isAddressZero();

        console.log("===========================================");
        console.log("ADDING LIQUIDITY TO POOL");
        console.log("===========================================");
        console.log("Network:", c.network);
        console.log("Hook:", c.hook);
        console.log("Pool ID:", _toHex(PoolId.unwrap(poolId)));
        console.log("");
        console.log("Current Pool State:");
        console.log("  - sqrtPriceX96:", c.sqrtPriceX96);
        console.log("  - Current Tick:", c.currentTick);
        console.log("");
        console.log("Token Amounts:");
        console.log("  - Token0:", c.token0Amount, isEthPool ? "wei (ETH)" : "wei");
        console.log("  - Token1:", c.token1Amount, "wei");
        console.log("");
        console.log("Tick Range:");
        console.log("  - Lower:", c.tickLower);
        console.log("  - Upper:", c.tickUpper);
        console.log("  - Range: +/-", c.liquidityRange, "tick spacings");
        console.log("");
        console.log("Calculated Liquidity:", c.liquidity);
        console.log("");
    }

    function _executeLiquidity(Config memory c) internal {
        IPositionManager posm = IPositionManager(c.positionManager);
        bool isEthPool = c.poolKey.currency0.isAddressZero();

        vm.startBroadcast();

        // Approve tokens
        _approveTokens(c, isEthPool);

        // Add liquidity
        console.log("Adding liquidity...");
        _addLiquidity(posm, c, isEthPool);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("LIQUIDITY ADDITION SUCCESSFUL");
        console.log("===========================================");
        console.log("Liquidity Added:", c.liquidity);
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Perform swaps: 06_Swap.s.sol");
        console.log("2. Configure rehypothecation: 04_ConfigureReHypothecation.s.sol");
        console.log("3. Add RH liquidity: 05b_AddRHLiquidity.s.sol");
        console.log("===========================================");
    }

    function _approveTokens(Config memory c, bool isEthPool) internal {
        uint256 amount0Max = c.token0Amount + 1;
        uint256 amount1Max = c.token1Amount + 1;
        uint48 expiration = uint48(block.timestamp + 1 hours);

        require(amount0Max <= type(uint160).max, "Amount0 exceeds uint160 max for Permit2");
        require(amount1Max <= type(uint160).max, "Amount1 exceeds uint160 max for Permit2");

        if (!isEthPool) {
            address token0 = Currency.unwrap(c.poolKey.currency0);
            IERC20(token0).approve(address(PERMIT2), amount0Max);
            // forge-lint: disable-next-line(unsafe-typecast)
            PERMIT2.approve(token0, c.positionManager, uint160(amount0Max), expiration);
        }

        address token1 = Currency.unwrap(c.poolKey.currency1);
        IERC20(token1).approve(address(PERMIT2), amount1Max);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.approve(token1, c.positionManager, uint160(amount1Max), expiration);
    }

    function _addLiquidity(IPositionManager posm, Config memory c, bool isEthPool) internal {
        uint256 amount0Max = c.token0Amount + 1;
        uint256 amount1Max = c.token1Amount + 1;

        bytes memory actions;
        bytes[] memory params;

        if (isEthPool) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            params[0] = abi.encode(
                c.poolKey, c.tickLower, c.tickUpper, c.liquidity, amount0Max, amount1Max, msg.sender, ""
            );
            params[1] = abi.encode(c.poolKey.currency0, c.poolKey.currency1);
            params[2] = abi.encode(Currency.wrap(address(0)), msg.sender);
            posm.modifyLiquidities{value: amount0Max}(abi.encode(actions, params), block.timestamp + 60);
        } else {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
            params[0] = abi.encode(
                c.poolKey, c.tickLower, c.tickUpper, c.liquidity, amount0Max, amount1Max, msg.sender, ""
            );
            params[1] = abi.encode(c.poolKey.currency0, c.poolKey.currency1);
            posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
        }
    }

    function _toHex(bytes32 data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(66);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            result[2 + i * 2 + 1] = hexChars[uint8(data[i] & 0x0f)];
        }
        return string(result);
    }
}
