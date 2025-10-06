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

/**
 * @title Swap Tokens
 * @notice Executes swaps on a Uniswap V4 pool with Alphix Hook
 * @dev Uses PoolSwapTest router for testing swaps, handles human-readable amounts
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
 * - SWAP_AMOUNT_{NETWORK}: Human-readable amount to swap (e.g., "1" for 1 token)
 * - SWAP_EXACT_INPUT_{NETWORK}: 1 for exact input swap, 0 for exact output swap
 * - SWAP_ZERO_FOR_ONE_{NETWORK}: 1 for token0→token1, 0 for token1→token0
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
        uint256 swapAmountRaw;
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

        // Get swap parameters
        config.swapAmountRaw = _getEnvUint("SWAP_AMOUNT_", config.network);
        config.isExactInput = _getEnvUint("SWAP_EXACT_INPUT_", config.network) == 1;
        config.zeroForOne = _getEnvUint("SWAP_ZERO_FOR_ONE_", config.network) == 1;

        console.log("===========================================");
        console.log("EXECUTING SWAP");
        console.log("===========================================");
        console.log("Network:", config.network);
        console.log("Swap Router:", config.swapRouterAddr);
        console.log("");
        console.log("Swap Parameters:");
        console.log("  - Amount (human-readable): %s", config.swapAmountRaw);
        console.log("  - Type: %s", config.isExactInput ? "Exact Input" : "Exact Output");
        console.log("  - Direction: %s", config.zeroForOne ? "Token0 -> Token1" : "Token1 -> Token0");
        console.log("");

        // Get pool details from environment variables
        config.token0Addr = vm.envAddress(string.concat("DEPLOYMENT_TOKEN0_", config.network));
        config.token1Addr = vm.envAddress(string.concat("DEPLOYMENT_TOKEN1_", config.network));
        config.tickSpacing = int24(uint24(vm.envUint(string.concat("POOL_TICK_SPACING_", config.network))));
        config.hookAddr = vm.envAddress(string.concat("ALPHIX_HOOK_", config.network));

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
                console.log("  - Sold %s Token0", config.swapAmountRaw);
                console.log("  - Received Token1 (check balance)");
            } else {
                console.log("  - Sold %s Token1", config.swapAmountRaw);
                console.log("  - Received Token0 (check balance)");
            }
        } else {
            if (config.zeroForOne) {
                console.log("  - Bought %s Token1", config.swapAmountRaw);
                console.log("  - Spent Token0 (check balance)");
            } else {
                console.log("  - Bought %s Token0", config.swapAmountRaw);
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

        // Determine which token decimals to use for amount
        // Exact input: use input token decimals
        // Exact output: use output token decimals
        Currency amountToken;
        {
            bool useToken0 = config.isExactInput ? config.zeroForOne : !config.zeroForOne;
            amountToken = useToken0 ? currency0 : currency1;
        }

        // Convert amount to wei
        uint8 decimals = amountToken.isAddressZero() ? 18 : IERC20(Currency.unwrap(amountToken)).decimals();
        uint256 swapAmountWei = config.swapAmountRaw * (10 ** decimals);

        console.log("Amount Conversion:");
        console.log("  - Currency: %s", Currency.unwrap(amountToken));
        console.log("  - Decimals: %s", decimals);
        console.log("  - Amount (wei): %s", swapAmountWei);
        console.log("");

        // Prepare amount with sign
        int256 amountSpecified = config.isExactInput ? -int256(swapAmountWei) : int256(swapAmountWei);
        console.log("Amount Specified: %d", amountSpecified);
        console.log("");

        // Determine approval/value for INPUT token
        address tokenToApprove;
        uint256 valueToPass;
        {
            Currency inputToken = config.zeroForOne ? currency0 : currency1;
            if (inputToken.isAddressZero()) {
                valueToPass = config.isExactInput ? swapAmountWei : (swapAmountWei * 2);
            } else {
                tokenToApprove = Currency.unwrap(inputToken);
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
        // For exact input: approve exact amount
        // For exact output: approve generous amount to cover slippage
        if (tokenToApprove != address(0)) {
            uint256 approveAmount;
            if (config.isExactInput) {
                approveAmount = swapAmountWei;
            } else {
                // For exact output, approve 2x the output amount as buffer
                approveAmount = swapAmountWei * 2;
            }
            console.log("Approving token %s for amount %s", tokenToApprove, approveAmount);
            IERC20(tokenToApprove).approve(address(swapRouter), approveAmount);
        }

        if (valueToPass > 0) {
            console.log("Sending %s wei of native ETH with swap", valueToPass);
        }

        // Execute swap
        console.log("");
        console.log("Executing swap...");
        swapRouter.swap{value: valueToPass}(poolKey, swapParams, testSettings, hookData);

        vm.stopBroadcast();
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
