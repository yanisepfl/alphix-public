// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Alphix} from "../../src/Alphix.sol";

/**
 * @title Execute Swap
 * @notice Performs a swap through the Alphix-managed pool
 * @dev Uses PoolSwapTest router for testing (testnet only)
 *
 * DEPLOYMENT ORDER: 6 (Operational script - run anytime after pool creation)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_SWAP_TEST_ROUTER_{NETWORK}: PoolSwapTest router address
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - SWAP_AMOUNT_IN_{NETWORK}: Amount to swap (in wei)
 * - SWAP_ZERO_FOR_ONE_{NETWORK}: true = sell token0, false = sell token1
 *
 * Note: This uses PoolSwapTest which is suitable for testing.
 * For production, use Universal Router or V4Router.
 */
contract SwapScript is Script {
    using CurrencyLibrary for Currency;

    // Slippage tolerance - unlimited price impact for testing
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("POOL_SWAP_TEST_ROUTER_", network);
        address routerAddr = vm.envAddress(envVar);
        require(routerAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("SWAP_AMOUNT_IN_", network);
        uint256 amountIn = vm.envUint(envVar);
        require(amountIn > 0, "SWAP_AMOUNT_IN must be > 0");

        envVar = string.concat("SWAP_ZERO_FOR_ONE_", network);
        bool zeroForOne = vm.envBool(envVar);

        Alphix alphix = Alphix(hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();
        bool isEthPool = poolKey.currency0.isAddressZero();

        address tokenIn = zeroForOne ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);
        address tokenOut = zeroForOne ? Currency.unwrap(poolKey.currency1) : Currency.unwrap(poolKey.currency0);

        console.log("===========================================");
        console.log("EXECUTING SWAP");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Hook:", hookAddr);
        console.log("Router:", routerAddr);
        console.log("");
        console.log("Swap Parameters:");
        console.log("  - Amount In:", amountIn, "wei");
        console.log("  - Direction:", zeroForOne ? "token0 -> token1" : "token1 -> token0");
        console.log("  - Token In:", tokenIn);
        console.log("  - Token Out:", tokenOut);
        console.log("");

        PoolSwapTest router = PoolSwapTest(routerAddr);

        vm.startBroadcast();

        // Approve input token (skip if selling native ETH)
        bool sellingEth = isEthPool && zeroForOne;
        if (!sellingEth) {
            console.log("Approving input token...");
            IERC20(tokenIn).approve(routerAddr, amountIn + 1);
        }

        // Build swap params
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // Safe: amountIn fits in int256
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(amountIn), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("Executing swap...");
        uint256 valueToSend = sellingEth ? amountIn : 0;
        router.swap{value: valueToSend}(poolKey, params, testSettings, "");
        console.log("  - Done");

        vm.stopBroadcast();

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
