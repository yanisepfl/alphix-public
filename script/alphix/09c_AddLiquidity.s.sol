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

/**
 * @title Add Liquidity to Existing Pool
 * @notice Adds liquidity to an existing Uniswap V4 pool with Alphix Hook
 * @dev Use this after creating a pool with 09b_CreatePool.s.sol or for adding more liquidity
 *
 * USAGE: Run this script to add liquidity to an existing pool
 *
 * SENDER REQUIREMENTS: Any address can run this script.
 * The sender must have sufficient token balances to provide liquidity.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - POSITION_MANAGER_{NETWORK}: Uniswap V4 PositionManager address
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - DEPLOYMENT_TOKEN0_{NETWORK}: First token address (must be < TOKEN1)
 * - DEPLOYMENT_TOKEN1_{NETWORK}: Second token address (must be > TOKEN0)
 * - POOL_TICK_SPACING_{NETWORK}: Tick spacing for the pool
 * - POOL_TOKEN0_AMOUNT_{NETWORK}: Amount in base units/wei
 * - POOL_TOKEN1_AMOUNT_{NETWORK}: Amount in base units/wei
 * - POOL_LIQUIDITY_RANGE_{NETWORK}: Range in tick spacings around current price
 *
 * IMPORTANT: Token amounts must be specified in base units (wei), NOT human-readable units.
 *
 * Prerequisites:
 * - Pool must already exist (created via 09b_CreatePool.s.sol or 09_CreatePoolAndAddLiquidity.s.sol)
 * - Sender must have sufficient token balances
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
        address token0;
        address token1;
        int24 tickSpacing;
        uint256 liquidityRange;
        uint256 token0Amount;
        uint256 token1Amount;
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

        c.poolManager = vm.envAddress(string.concat("POOL_MANAGER_", c.network));
        c.positionManager = vm.envAddress(string.concat("POSITION_MANAGER_", c.network));
        c.hook = vm.envAddress(string.concat("ALPHIX_HOOK_", c.network));
        c.token0 = vm.envAddress(string.concat("DEPLOYMENT_TOKEN0_", c.network));
        c.token1 = vm.envAddress(string.concat("DEPLOYMENT_TOKEN1_", c.network));
        require(c.token0 < c.token1, "TOKEN0 must be < TOKEN1");

        c.tickSpacing = int24(uint24(vm.envUint(string.concat("POOL_TICK_SPACING_", c.network))));
        c.liquidityRange = vm.envUint(string.concat("POOL_LIQUIDITY_RANGE_", c.network));
        c.token0Amount = vm.envUint(string.concat("POOL_TOKEN0_AMOUNT_", c.network));
        c.token1Amount = vm.envUint(string.concat("POOL_TOKEN1_AMOUNT_", c.network));
    }

    function _computePoolState(Config memory c) internal view {
        PoolKey memory poolKey = _createPoolKey(c);
        PoolId poolId = poolKey.toId();

        IPoolManager pm = IPoolManager(c.poolManager);
        (c.sqrtPriceX96, c.currentTick,,) = pm.getSlot0(poolId);
        require(c.sqrtPriceX96 != 0, "Pool not initialized - run 09b_CreatePool.s.sol first");

        int24 compressed = TickBitmap.compress(c.currentTick, c.tickSpacing);
        c.tickLower = (compressed - int24(uint24(c.liquidityRange))) * c.tickSpacing;
        c.tickUpper = (compressed + int24(uint24(c.liquidityRange))) * c.tickSpacing;

        c.liquidity = LiquidityAmounts.getLiquidityForAmounts(
            c.sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(c.tickLower),
            TickMath.getSqrtPriceAtTick(c.tickUpper),
            c.token0Amount,
            c.token1Amount
        );
    }

    function _createPoolKey(Config memory c) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(c.token0),
            currency1: Currency.wrap(c.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: c.tickSpacing,
            hooks: IHooks(c.hook)
        });
    }

    function _logConfig(Config memory c) internal pure {
        PoolId poolId = _createPoolKey(c).toId();

        console.log("===========================================");
        console.log("ADDING LIQUIDITY TO EXISTING POOL");
        console.log("===========================================");
        console.log("Network:", c.network);
        console.log("Pool ID: 0x%s", _toHex(PoolId.unwrap(poolId)));
        console.log("");
        console.log("Current Pool State:");
        console.log("  - sqrtPriceX96:", c.sqrtPriceX96);
        console.log("  - Current Tick: %d", c.currentTick);
        console.log("");
        console.log("Token Amounts:");
        console.log("  - Token0: %s wei", c.token0Amount);
        console.log("  - Token1: %s wei", c.token1Amount);
        console.log("");
        console.log("Tick Range:");
        console.log("  - Lower: %d", c.tickLower);
        console.log("  - Upper: %d", c.tickUpper);
        console.log("  - Range: +/- %s tick spacings", c.liquidityRange);
        console.log("");
        console.log("Calculated Liquidity:", c.liquidity);
        console.log("");
    }

    function _executeLiquidity(Config memory c) internal {
        Currency currency0 = Currency.wrap(c.token0);
        Currency currency1 = Currency.wrap(c.token1);
        IPositionManager posm = IPositionManager(c.positionManager);
        PoolKey memory poolKey = _createPoolKey(c);

        vm.startBroadcast();

        _approveTokens(currency0, currency1, address(posm), c.token0Amount + 1, c.token1Amount + 1);

        console.log("Adding liquidity...");
        _addLiquidity(posm, poolKey, c, currency0.isAddressZero());
        console.log("  - Liquidity added successfully");

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("LIQUIDITY ADDITION SUCCESSFUL");
        console.log("===========================================");
        console.log("Liquidity Added: %s", c.liquidity);
        console.log("NEXT STEPS:");
        console.log("1. Perform swaps using script 10_Swap.s.sol");
        console.log("2. Update fees using script 11_PokeFee.s.sol");
        console.log("===========================================");
    }

    function _approveTokens(Currency currency0, Currency currency1, address posm, uint256 amount0, uint256 amount1)
        internal
    {
        require(amount0 <= type(uint160).max, "Amount0 exceeds uint160 max");
        require(amount1 <= type(uint160).max, "Amount1 exceeds uint160 max");

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

    function _addLiquidity(IPositionManager posm, PoolKey memory poolKey, Config memory c, bool isNativeEth) internal {
        uint256 amount0Max = c.token0Amount + 1;
        uint256 amount1Max = c.token1Amount + 1;
        uint256 valueToPass = isNativeEth ? amount0Max : 0;

        bytes memory actions;
        bytes[] memory params;

        if (isNativeEth) {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
            params = new bytes[](3);
            params[0] =
                abi.encode(poolKey, c.tickLower, c.tickUpper, c.liquidity, amount0Max, amount1Max, msg.sender, "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
            params[2] = abi.encode(Currency.wrap(address(0)), msg.sender);
        } else {
            actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
            params = new bytes[](2);
            params[0] =
                abi.encode(poolKey, c.tickLower, c.tickUpper, c.liquidity, amount0Max, amount1Max, msg.sender, "");
            params[1] = abi.encode(poolKey.currency0, poolKey.currency1);
        }

        posm.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), block.timestamp + 60);
    }

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
