// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";

/**
 * @title Remove ReHypothecated Liquidity
 * @notice Withdraws tokens from yield sources by burning LP shares
 * @dev Supports both ERC20/ERC20 (Alphix) and ETH/ERC20 (AlphixETH) pools
 *
 * DEPLOYMENT ORDER: 5c (After adding liquidity, when ready to withdraw)
 *
 * How Removal Works:
 * 1. User specifies number of LP shares to burn
 * 2. Script calculates token amounts via previewRemoveReHypothecatedLiquidity
 * 3. Tokens are withdrawn from ERC-4626 yield vaults
 * 4. LP shares are burned
 * 5. User receives tokens (or ETH for ETH pools)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - RH_REMOVE_SHARES_{NETWORK}: Number of shares to burn (in wei, 18 decimals)
 * - RH_REMOVE_AMOUNT0_MIN_{NETWORK}: Minimum amount of token0 expected (slippage protection)
 * - RH_REMOVE_AMOUNT1_MIN_{NETWORK}: Minimum amount of token1 expected (slippage protection)
 *
 * Note: Token amounts are calculated automatically using previewRemoveReHypothecatedLiquidity()
 */
contract RemoveRHLiquidityScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("RH_REMOVE_SHARES_", network);
        uint256 shares = vm.envUint(envVar);
        require(shares > 0, "RH_REMOVE_SHARES must be > 0");

        envVar = string.concat("RH_REMOVE_AMOUNT0_MIN_", network);
        uint256 amount0Min = vm.envUint(envVar);
        // amount0Min can be 0 (no slippage protection), but we require the var to be set
        // to make users consciously choose 0 if they want no protection

        envVar = string.concat("RH_REMOVE_AMOUNT1_MIN_", network);
        uint256 amount1Min = vm.envUint(envVar);
        // amount1Min can be 0 (no slippage protection), but we require the var to be set

        Alphix alphix = Alphix(hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();
        bool isEthPool = poolKey.currency0.isAddressZero();

        console.log("===========================================");
        console.log("REMOVING REHYPOTHECATED LIQUIDITY");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix:", hookAddr);
        console.log("Pool Type:", isEthPool ? "ETH/ERC20" : "ERC20/ERC20");
        console.log("");

        // Check user's current balance
        uint256 userSharesBefore = alphix.balanceOf(tx.origin);
        console.log("Your current shares:", userSharesBefore);
        require(userSharesBefore >= shares, "Insufficient shares to remove");
        console.log("Shares to burn:", shares);
        console.log("");

        // Preview withdrawal amounts
        (uint256 amount0, uint256 amount1) = alphix.previewRemoveReHypothecatedLiquidity(shares);

        console.log("Expected withdrawal amounts:");
        console.log("  - Amount0:", amount0, "wei", isEthPool ? "(ETH)" : "");
        console.log("  - Amount1:", amount1, "wei");
        console.log("Minimum limits (slippage protection):");
        console.log("  - Amount0 min:", amount0Min, "wei");
        console.log("  - Amount1 min:", amount1Min, "wei");
        console.log("");

        // Safety check: ensure expected amounts meet minimum requirements
        require(amount0 >= amount0Min, "Amount0 below RH_REMOVE_AMOUNT0_MIN limit");
        require(amount1 >= amount1Min, "Amount1 below RH_REMOVE_AMOUNT1_MIN limit");

        vm.startBroadcast();

        // Remove liquidity
        console.log("Removing rehypothecated liquidity...");
        if (isEthPool) {
            AlphixETH(payable(hookAddr)).removeReHypothecatedLiquidity(shares);
        } else {
            alphix.removeReHypothecatedLiquidity(shares);
        }
        console.log("  - Done");

        vm.stopBroadcast();

        // Verify
        uint256 userSharesAfter = alphix.balanceOf(tx.origin);

        console.log("");
        console.log("===========================================");
        console.log("LIQUIDITY REMOVED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Shares burned:", shares);
        console.log("Shares remaining:", userSharesAfter);
        console.log("");
        console.log("Tokens withdrawn:");
        console.log("  - Amount0:", amount0, "wei", isEthPool ? "(ETH sent to your wallet)" : "");
        console.log("  - Amount1:", amount1, "wei");
        console.log("");
        console.log("Your tokens have been withdrawn from ERC-4626 yield vaults.");
        console.log("===========================================");
    }
}
