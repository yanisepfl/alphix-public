// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title Swap Tokens
 * @notice Executes swaps on a Uniswap V4 pool with Alphix Hook
 * @dev Uses PoolSwapTest router for testing swaps
 *
 * USAGE: Run this script to test swaps and observe dynamic fee adjustments
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_SWAP_TEST_ROUTER_{NETWORK}: PoolSwapTest router address
 * - DEPLOYMENT_TOKEN0_{NETWORK}: Token0 address
 * - DEPLOYMENT_TOKEN1_{NETWORK}: Token1 address
 * - POOL_TICK_SPACING_{NETWORK}: Pool tick spacing
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook address
 * - SWAP_AMOUNT_{NETWORK}: Amount in base units/wei
 * - SWAP_EXACT_INPUT_{NETWORK}: 1 for exact input swap, 0 for exact output swap
 * - SWAP_ZERO_FOR_ONE_{NETWORK}: 1 for token0→token1, 0 for token1→token0
 * - SWAP_MAX_INPUT_{NETWORK}: (Required ONLY for exact output) Max input amount in INPUT token base units
 *
 * IMPORTANT: SWAP_AMOUNT must be in base units (wei), NOT human-readable units.
 * - For exact input swaps (SWAP_EXACT_INPUT=1): Amount in INPUT token decimals
 *   Example: Selling 0.1 ETH (18 decimals) → SWAP_AMOUNT=100000000000000000
 * - For exact output swaps (SWAP_EXACT_INPUT=0): Amount in OUTPUT token decimals
 *   Example: Buying 50 USDC (6 decimals) → SWAP_AMOUNT=50000000
 *   ALSO SET: SWAP_MAX_INPUT (in INPUT token decimals, e.g., 100000000000000000 for 0.1 ETH max)
 *
 * Examples:
 *   - Sell 0.1 ETH for USDC (exact input):
 *     SWAP_AMOUNT=100000000000000000 (ETH decimals: 18)
 *     SWAP_MAX_INPUT not needed
 *   - Buy 50 USDC with ETH (exact output):
 *     SWAP_AMOUNT=50000000 (USDC decimals: 6)
 *     SWAP_MAX_INPUT=100000000000000000 (max 0.1 ETH to spend, ETH decimals: 18)
 *   - Use `cast --to-wei 0.1 ether` for 18-decimal tokens
 *
 * Note:
 * - Exact input: You specify how much you want to sell
 * - Exact output: You specify how much you want to buy
 */
contract SwapScript is Script {
    // Slippage tolerance - unlimited price impact
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    struct SwapConfig {
        string network;
        address swapRouterAddr;
        address token0Addr;
        address token1Addr;
        int24 tickSpacing;
        address hookAddr;
        uint256 swapAmount;
        uint256 maxInputAmount;
        bool isExactInput;
        bool zeroForOne;
    }

    function run() public {
        SwapConfig memory config;

        // Load environment variables
        config.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(config.network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get contract addresses
        config.swapRouterAddr = _getEnvAddress("POOL_SWAP_TEST_ROUTER_", config.network);

        // Get swap parameters (amount is already in base units/wei)
        config.swapAmount = _getEnvUint("SWAP_AMOUNT_", config.network);
        config.isExactInput = _getEnvUint("SWAP_EXACT_INPUT_", config.network) == 1;
        config.zeroForOne = _getEnvUint("SWAP_ZERO_FOR_ONE_", config.network) == 1;

        // For exact output, get max input amount (in input token decimals)
        if (!config.isExactInput) {
            config.maxInputAmount = _getEnvUint("SWAP_MAX_INPUT_", config.network);
            require(config.maxInputAmount > 0, "SWAP_MAX_INPUT required for exact output swaps");
        }

        console.log("===========================================");
        console.log("EXECUTING SWAP");
        console.log("===========================================");
        console.log("Network:", config.network);
        console.log("Swap Router:", config.swapRouterAddr);
        console.log("");
        console.log("Swap Parameters:");
        console.log("  - Amount (wei): %s", config.swapAmount);
        console.log("  - Type: %s", config.isExactInput ? "Exact Input" : "Exact Output");
        if (!config.isExactInput) {
            console.log("  - Max Input (wei): %s", config.maxInputAmount);
        }
        console.log("  - Direction: %s", config.zeroForOne ? "Token0 -> Token1" : "Token1 -> Token0");
        console.log("");

        // Get pool details from environment variables
        config.token0Addr = vm.envAddress(string.concat("DEPLOYMENT_TOKEN0_", config.network));
        config.token1Addr = vm.envAddress(string.concat("DEPLOYMENT_TOKEN1_", config.network));
        config.tickSpacing = int24(uint24(vm.envUint(string.concat("POOL_TICK_SPACING_", config.network))));
        config.hookAddr = vm.envAddress(string.concat("ALPHIX_HOOK_", config.network));

        // Validate token ordering (token0 must be numerically less than token1)
        require(config.token0Addr < config.token1Addr, "Invalid token order: TOKEN0 must be < TOKEN1");

        console.log("Pool Details:");
        console.log("  - Token0:", config.token0Addr);
        console.log("  - Token1:", config.token1Addr);
        console.log("  - Fee: DYNAMIC (0x800000)");
        console.log("  - Tick Spacing:", uint256(uint24(config.tickSpacing)));
        console.log("  - Hook:", config.hookAddr);
        console.log("");

        // Execute the swap
        _executeSwap(config);

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
        console.log("4. Observe how fees adjust based on pool imbalance");
        console.log("===========================================");
    }

    /**
     * @dev Execute swap with the provided configuration
     */
    function _executeSwap(SwapConfig memory config) internal {
        // Create contract instances
        PoolSwapTest swapRouter = PoolSwapTest(config.swapRouterAddr);

        Currency currency0 = Currency.wrap(config.token0Addr);
        Currency currency1 = Currency.wrap(config.token1Addr);

        // Create PoolKey
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0x800000, // Dynamic fee flag
            tickSpacing: config.tickSpacing,
            hooks: IHooks(config.hookAddr)
        });

        // Amount is already in base units (wei)
        uint256 swapAmountWei = config.swapAmount;

        // Prepare amount with sign
        // Exact input: negative (selling), Exact output: positive (buying)
        int256 amountSpecified = config.isExactInput ? -int256(swapAmountWei) : int256(swapAmountWei);
        console.log("Amount Specified: %d", amountSpecified);
        console.log("");

        // Determine approval/value for INPUT token
        address tokenToApprove;
        uint256 valueToPass;
        uint256 approvalAmount;
        {
            Currency inputToken = config.zeroForOne ? currency0 : currency1;
            if (inputToken.isAddressZero()) {
                // Native ETH - send value (in input token decimals)
                if (config.isExactInput) {
                    valueToPass = swapAmountWei; // Exact amount to sell
                } else {
                    valueToPass = config.maxInputAmount; // Max to spend
                }
            } else {
                // ERC20 - approve (in input token decimals)
                tokenToApprove = Currency.unwrap(inputToken);
                if (config.isExactInput) {
                    approvalAmount = swapAmountWei; // Exact amount to sell
                } else {
                    approvalAmount = config.maxInputAmount; // Max to spend
                }
            }
        }

        // Prepare swap parameters
        SwapParams memory swapParams = SwapParams({
            zeroForOne: config.zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: config.zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        // Test settings - take ERC20s, not claims
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        bytes memory hookData = "";

        vm.startBroadcast();

        // Approve token if not native ETH
        if (tokenToApprove != address(0)) {
            console.log("Approving token %s for amount %s", tokenToApprove, approvalAmount);
            IERC20(tokenToApprove).approve(address(swapRouter), approvalAmount);
        }

        if (valueToPass > 0) {
            console.log("Sending %s wei of native ETH with swap", valueToPass);
        }

        // Execute swap
        console.log("");
        console.log("Executing swap...");
        BalanceDelta delta = swapRouter.swap{value: valueToPass}(poolKey, swapParams, testSettings, hookData);

        vm.stopBroadcast();

        // Log actual amounts transacted
        console.log("");
        console.log("Swap executed successfully!");
        console.log("Actual amounts transacted (BalanceDelta):");
        console.log("  - Amount0: %d wei", delta.amount0());
        console.log("  - Amount1: %d wei", delta.amount1());
        console.log("");
        console.log("Note: Negative values = tokens debited (sent), Positive values = tokens credited (received)");
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
}
