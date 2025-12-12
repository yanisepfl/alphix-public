// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

/**
 * @title Swap Tokens via Universal Router
 * @notice Executes swaps on a Uniswap V4 pool using the Universal Router (works on mainnet)
 * @dev Uses the Universal Router instead of PoolSwapTest for production-ready swaps
 *
 * USAGE: Run this script to swap tokens on mainnet via the Universal Router.
 * Unlike 10_Swap.s.sol which uses PoolSwapTest (testnet only), this works on production networks.
 *
 * SENDER REQUIREMENTS: Any address can run this script.
 * The sender must have sufficient token balance to perform the swap.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - UNIVERSAL_ROUTER_{NETWORK}: Universal Router address
 * - POOL_MANAGER_{NETWORK}: PoolManager address
 * - DEPLOYMENT_TOKEN0_{NETWORK}: Token0 address
 * - DEPLOYMENT_TOKEN1_{NETWORK}: Token1 address
 * - POOL_TICK_SPACING_{NETWORK}: Pool tick spacing
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook address
 * - SWAP_AMOUNT_{NETWORK}: Amount in base units/wei
 * - SWAP_EXACT_INPUT_{NETWORK}: 1 for exact input swap, 0 for exact output swap
 * - SWAP_ZERO_FOR_ONE_{NETWORK}: 1 for token0→token1, 0 for token1→token0
 * - SWAP_MIN_OUTPUT_{NETWORK}: (For exact input) Minimum output amount (slippage protection)
 * - SWAP_MAX_INPUT_{NETWORK}: (For exact output) Maximum input amount (slippage protection)
 *
 * IMPORTANT: SWAP_AMOUNT must be in base units (wei), NOT human-readable units.
 */
contract SwapUniversalRouterScript is Script {
    using PoolIdLibrary for PoolKey;

    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @dev Universal Router command for V4 swaps
    uint8 constant COMMAND_V4_SWAP = 0x10;

    struct SwapConfig {
        string network;
        address universalRouter;
        address poolManager;
        address token0Addr;
        address token1Addr;
        int24 tickSpacing;
        address hookAddr;
        uint256 swapAmount;
        uint256 amountLimit; // min output for exact input, max input for exact output
        bool isExactInput;
        bool zeroForOne;
    }

    function run() public {
        SwapConfig memory config = _loadConfig();
        _logConfig(config);
        _executeSwap(config);
    }

    function _loadConfig() internal view returns (SwapConfig memory config) {
        config.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(config.network).length > 0, "DEPLOYMENT_NETWORK not set");

        config.universalRouter = _getEnvAddress("UNIVERSAL_ROUTER_", config.network);
        config.poolManager = _getEnvAddress("POOL_MANAGER_", config.network);
        config.token0Addr = _getEnvAddress("DEPLOYMENT_TOKEN0_", config.network);
        config.token1Addr = _getEnvAddress("DEPLOYMENT_TOKEN1_", config.network);
        config.tickSpacing = int24(uint24(_getEnvUint("POOL_TICK_SPACING_", config.network)));
        config.hookAddr = _getEnvAddress("ALPHIX_HOOK_", config.network);

        config.swapAmount = _getEnvUint("SWAP_AMOUNT_", config.network);
        config.isExactInput = _getEnvUint("SWAP_EXACT_INPUT_", config.network) == 1;
        config.zeroForOne = _getEnvUint("SWAP_ZERO_FOR_ONE_", config.network) == 1;

        // Get slippage protection amount
        if (config.isExactInput) {
            config.amountLimit = _getEnvUintOptional("SWAP_MIN_OUTPUT_", config.network);
        } else {
            config.amountLimit = _getEnvUint("SWAP_MAX_INPUT_", config.network);
            require(config.amountLimit > 0, "SWAP_MAX_INPUT required for exact output swaps");
        }

        require(config.token0Addr < config.token1Addr, "TOKEN0 must be < TOKEN1");
    }

    function _logConfig(SwapConfig memory config) internal pure {
        console.log("===========================================");
        console.log("EXECUTING SWAP VIA UNIVERSAL ROUTER");
        console.log("===========================================");
        console.log("Network:", config.network);
        console.log("Universal Router:", config.universalRouter);
        console.log("Pool Manager:", config.poolManager);
        console.log("");
        console.log("Swap Parameters:");
        console.log("  - Amount (wei): %s", config.swapAmount);
        console.log("  - Type: %s", config.isExactInput ? "Exact Input" : "Exact Output");
        if (config.isExactInput) {
            console.log("  - Min Output (wei): %s", config.amountLimit);
        } else {
            console.log("  - Max Input (wei): %s", config.amountLimit);
        }
        console.log("  - Direction: %s", config.zeroForOne ? "Token0 -> Token1" : "Token1 -> Token0");
        console.log("");
        console.log("Pool Details:");
        console.log("  - Token0:", config.token0Addr);
        console.log("  - Token1:", config.token1Addr);
        console.log("  - Fee: DYNAMIC (0x800000)");
        console.log("  - Tick Spacing:", uint256(uint24(config.tickSpacing)));
        console.log("  - Hook:", config.hookAddr);
        console.log("");
    }

    function _executeSwap(SwapConfig memory config) internal {
        Currency currency0 = Currency.wrap(config.token0Addr);
        Currency currency1 = Currency.wrap(config.token1Addr);

        // Build PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // Dynamic fee flag
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hookAddr)
        });

        PoolId poolId = poolKey.toId();
        console.log("Pool ID: 0x%s", _toHex(PoolId.unwrap(poolId)));
        console.log("");

        // Determine input currency for approval
        Currency inputCurrency = config.zeroForOne ? currency0 : currency1;

        // Calculate approval amount
        uint256 approvalAmount;
        if (config.isExactInput) {
            approvalAmount = config.swapAmount;
        } else {
            approvalAmount = config.amountLimit;
        }

        vm.startBroadcast();

        // Approve tokens via Permit2
        if (!inputCurrency.isAddressZero()) {
            _approveWithPermit2(inputCurrency, config.universalRouter, approvalAmount);
        }

        // Build and execute swap
        console.log("Executing swap via Universal Router...");
        uint256 valueToSend = inputCurrency.isAddressZero() ? approvalAmount : 0;

        bytes memory commands;
        bytes[] memory inputs;

        if (config.isExactInput) {
            (commands, inputs) = _buildExactInputSwap(poolKey, config);
        } else {
            (commands, inputs) = _buildExactOutputSwap(poolKey, config);
        }

        // Execute via Universal Router
        IUniversalRouter(config.universalRouter).execute{value: valueToSend}(commands, inputs, block.timestamp + 120);

        vm.stopBroadcast();

        console.log("");
        console.log("===========================================");
        console.log("SWAP SUCCESSFUL");
        console.log("===========================================");
        console.log("");
        console.log("What happened:");
        if (config.isExactInput) {
            if (config.zeroForOne) {
                console.log("  - Sold %s wei of Token0", config.swapAmount);
                console.log("  - Received Token1 (check balance)");
            } else {
                console.log("  - Sold %s wei of Token1", config.swapAmount);
                console.log("  - Received Token0 (check balance)");
            }
        } else {
            if (config.zeroForOne) {
                console.log("  - Bought %s wei of Token1", config.swapAmount);
                console.log("  - Spent Token0 (check balance)");
            } else {
                console.log("  - Bought %s wei of Token0", config.swapAmount);
                console.log("  - Spent Token1 (check balance)");
            }
        }
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Check pool state with getSlot0()");
        console.log("2. Perform more swaps to shift the pool ratio");
        console.log("3. Update dynamic fee with script 11_PokeFee.s.sol");
        console.log("===========================================");
    }

    function _approveWithPermit2(Currency currency, address spender, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        require(amount <= type(uint160).max, "Amount exceeds uint160 max");

        uint48 expiration = uint48(block.timestamp + 1 hours);

        console.log("Approving token %s via Permit2...", token);
        IERC20(token).approve(address(PERMIT2), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.approve(token, spender, uint160(amount), expiration);
    }

    function _buildExactInputSwap(PoolKey memory poolKey, SwapConfig memory config)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = abi.encodePacked(uint8(COMMAND_V4_SWAP));
        inputs = new bytes[](1);

        // Build V4Router actions: SWAP_EXACT_IN_SINGLE -> SETTLE_ALL -> TAKE_ALL
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        // Swap params
        require(config.swapAmount <= type(uint128).max, "Swap amount exceeds uint128");
        require(config.amountLimit <= type(uint128).max, "Amount limit exceeds uint128");

        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: config.zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountIn: uint128(config.swapAmount),
                // forge-lint: disable-next-line(unsafe-typecast)
                amountOutMinimum: uint128(config.amountLimit),
                hookData: bytes("")
            })
        );

        // Settle the input currency (max amount)
        Currency inputCurrency = config.zeroForOne ? poolKey.currency0 : poolKey.currency1;
        params[1] = abi.encode(inputCurrency, config.swapAmount);

        // Take the output currency (min amount)
        Currency outputCurrency = config.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        params[2] = abi.encode(outputCurrency, config.amountLimit);

        inputs[0] = abi.encode(actions, params);
    }

    function _buildExactOutputSwap(PoolKey memory poolKey, SwapConfig memory config)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        commands = abi.encodePacked(uint8(COMMAND_V4_SWAP));
        inputs = new bytes[](1);

        // Build V4Router actions: SWAP_EXACT_OUT_SINGLE -> SETTLE_ALL -> TAKE_ALL
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory params = new bytes[](3);

        // Swap params
        require(config.swapAmount <= type(uint128).max, "Swap amount exceeds uint128");
        require(config.amountLimit <= type(uint128).max, "Amount limit exceeds uint128");

        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: poolKey,
                zeroForOne: config.zeroForOne,
                // forge-lint: disable-next-line(unsafe-typecast)
                amountOut: uint128(config.swapAmount),
                // forge-lint: disable-next-line(unsafe-typecast)
                amountInMaximum: uint128(config.amountLimit),
                hookData: bytes("")
            })
        );

        // Settle the input currency (max amount)
        Currency inputCurrency = config.zeroForOne ? poolKey.currency0 : poolKey.currency1;
        params[1] = abi.encode(inputCurrency, config.amountLimit);

        // Take the output currency (exact amount)
        Currency outputCurrency = config.zeroForOne ? poolKey.currency1 : poolKey.currency0;
        params[2] = abi.encode(outputCurrency, config.swapAmount);

        inputs[0] = abi.encode(actions, params);
    }

    function _getEnvAddress(string memory prefix, string memory network) internal view returns (address) {
        string memory envVar = string.concat(prefix, network);
        address addr = vm.envAddress(envVar);
        require(addr != address(0), string.concat(envVar, " not set or invalid"));
        return addr;
    }

    function _getEnvUint(string memory prefix, string memory network) internal view returns (uint256) {
        string memory envVar = string.concat(prefix, network);
        return vm.envUint(envVar);
    }

    function _getEnvUintOptional(string memory prefix, string memory network) internal view returns (uint256) {
        string memory envVar = string.concat(prefix, network);
        try vm.envUint(envVar) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
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

/// @notice Minimal Universal Router interface for V4 swaps
interface IUniversalRouter {
    /// @notice Executes encoded commands along with provided inputs
    /// @param commands A set of concatenated commands, each 1 byte in length
    /// @param inputs An array of byte strings containing abi encoded inputs for each command
    /// @param deadline The deadline by which the transaction must be executed
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}
