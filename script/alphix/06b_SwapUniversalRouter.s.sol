// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Execute Swap via Universal Router (Mainnet)
 * @notice Performs a swap through the Alphix-managed pool using Universal Router
 * @dev For production use - uses Universal Router with Permit2
 *
 * DEPLOYMENT ORDER: 6b (Operational script - mainnet alternative to 06_Swap.s.sol)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - UNIVERSAL_ROUTER_{NETWORK}: Universal Router address
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - SWAP_AMOUNT_IN_{NETWORK}: Amount to swap (in wei)
 * - SWAP_ZERO_FOR_ONE_{NETWORK}: true = sell token0, false = sell token1
 * - SWAP_MIN_OUTPUT_{NETWORK}: Minimum output amount (slippage protection)
 *
 * Note: This script uses Universal Router which is suitable for production.
 * For testnet, use 06_Swap.s.sol with PoolSwapTest instead.
 */

/// @notice Minimal interface for Universal Router
interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice Universal Router command constants
library Commands {
    uint256 constant V4_SWAP = 0x10;
}

contract SwapUniversalRouterScript is Script {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    IPermit2 constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    struct SwapConfig {
        string network;
        address routerAddr;
        address hookAddr;
        uint256 amountIn;
        bool zeroForOne;
        uint256 minOutput;
    }

    function run() public {
        SwapConfig memory cfg = _loadConfig();
        _executeSwap(cfg);
    }

    function _loadConfig() internal view returns (SwapConfig memory cfg) {
        cfg.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(cfg.network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("UNIVERSAL_ROUTER_", cfg.network);
        cfg.routerAddr = vm.envAddress(envVar);
        require(cfg.routerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_HOOK_", cfg.network);
        cfg.hookAddr = vm.envAddress(envVar);
        require(cfg.hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("SWAP_AMOUNT_IN_", cfg.network);
        cfg.amountIn = vm.envUint(envVar);
        require(cfg.amountIn > 0, "SWAP_AMOUNT_IN must be > 0");
        require(
            cfg.amountIn <= type(uint128).max, string.concat("SWAP_AMOUNT_IN_", cfg.network, " exceeds uint128 max")
        );

        envVar = string.concat("SWAP_ZERO_FOR_ONE_", cfg.network);
        cfg.zeroForOne = vm.envBool(envVar);

        envVar = string.concat("SWAP_MIN_OUTPUT_", cfg.network);
        cfg.minOutput = vm.envUint(envVar);
        require(
            cfg.minOutput <= type(uint128).max, string.concat("SWAP_MIN_OUTPUT_", cfg.network, " exceeds uint128 max")
        );
        if (cfg.minOutput == 0) {
            console.log("WARNING: SWAP_MIN_OUTPUT_%s is 0 - no slippage protection", cfg.network);
        }
    }

    function _executeSwap(SwapConfig memory cfg) internal {
        Alphix alphix = Alphix(cfg.hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();

        address tokenIn = cfg.zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        address tokenOut = cfg.zeroForOne ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);

        _logSwapInfo(cfg, tokenIn, tokenOut);

        vm.startBroadcast();

        // Approve input token via Permit2 (skip if selling native ETH)
        // Derive from tokenIn directly to handle any pool ordering
        bool sellingEth = tokenIn == address(0);
        if (!sellingEth) {
            _approveToken(tokenIn, cfg.routerAddr, cfg.amountIn);
        }

        // Build and execute swap
        _buildAndExecuteSwap(cfg, poolKey, sellingEth);

        vm.stopBroadcast();

        _logSwapComplete();
    }

    function _logSwapInfo(SwapConfig memory cfg, address tokenIn, address tokenOut) internal pure {
        console.log("===========================================");
        console.log("EXECUTING SWAP (Universal Router)");
        console.log("===========================================");
        console.log("Network:", cfg.network);
        console.log("Hook:", cfg.hookAddr);
        console.log("Router:", cfg.routerAddr);
        console.log("");
        console.log("Swap Parameters:");
        console.log("  - Amount In:", cfg.amountIn, "wei");
        console.log("  - Min Output:", cfg.minOutput, "wei");
        console.log("  - Direction:", cfg.zeroForOne ? "token0 -> token1" : "token1 -> token0");
        console.log("  - Token In:", tokenIn);
        console.log("  - Token Out:", tokenOut);
        console.log("");
    }

    function _approveToken(address token, address router, uint256 amount) internal {
        console.log("Approving input token via Permit2...");
        IERC20(token).forceApprove(address(PERMIT2), amount);
        // forge-lint: disable-next-line(unsafe-typecast)
        PERMIT2.approve(token, router, uint160(amount), uint48(block.timestamp + 1 hours));
    }

    function _buildAndExecuteSwap(SwapConfig memory cfg, PoolKey memory poolKey, bool sellingEth) internal {
        Currency currencyIn = cfg.zeroForOne ? poolKey.currency0 : poolKey.currency1;
        Currency currencyOut = cfg.zeroForOne ? poolKey.currency1 : poolKey.currency0;

        // Build V4 swap actions: swap, settle input, take output
        bytes memory v4Actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory v4Params = new bytes[](3);

        // SWAP_EXACT_IN_SINGLE params: ExactInputSingleParams struct
        // Must encode as struct for correct ABI encoding with offset pointer
        // forge-lint: disable-next-line(unsafe-typecast)
        v4Params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: cfg.zeroForOne,
                amountIn: uint128(cfg.amountIn),
                amountOutMinimum: uint128(cfg.minOutput),
                hookData: bytes("")
            })
        );

        // SETTLE_ALL params: (Currency, maxAmount)
        v4Params[1] = abi.encode(currencyIn, cfg.amountIn);

        // TAKE_ALL params: (Currency, minAmount)
        // For native ETH output, TAKE_ALL transfers ETH directly to msgSender (the original caller)
        v4Params[2] = abi.encode(currencyOut, cfg.minOutput);

        // Encode for Universal Router
        bytes memory v4SwapData = abi.encode(v4Actions, v4Params);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = v4SwapData;

        console.log("Executing swap via Universal Router...");
        uint256 valueToSend = sellingEth ? cfg.amountIn : 0;
        // Use 5 minute deadline to handle mainnet congestion
        IUniversalRouter(cfg.routerAddr).execute{value: valueToSend}(commands, inputs, block.timestamp + 5 minutes);
        console.log("  - Done");
    }

    function _logSwapComplete() internal pure {
        console.log("");
        console.log("===========================================");
        console.log("SWAP EXECUTED");
        console.log("===========================================");
        console.log("Check your token balances to verify the swap.");
        console.log("");
        console.log("The dynamic fee was applied during this swap.");
        console.log("Run 07_PokeFee.s.sol to update the fee based on current ratio.");
        console.log("===========================================");
    }
}
