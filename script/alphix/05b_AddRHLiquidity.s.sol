// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";

/**
 * @title Add ReHypothecated Liquidity
 * @notice Deposits tokens to yield sources in exchange for LP shares
 * @dev Supports both ERC20/ERC20 (Alphix) and ETH/ERC20 (AlphixETH) pools
 *
 * DEPLOYMENT ORDER: 5 (After rehypothecation configuration)
 *
 * How ReHypothecation Works:
 * 1. User specifies desired LP shares to mint
 * 2. Script calculates required token amounts via previewAddReHypothecatedLiquidity
 * 3. Tokens are deposited into ERC-4626 yield vaults
 * 4. User receives LP shares (Alphix is an ERC20)
 * 5. JIT liquidity uses these funds during swaps
 * 6. Yield from vaults accrues to LP holders
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - RH_SHARES_{NETWORK}: Number of shares to mint (in wei, 18 decimals)
 * - RH_AMOUNT0_MAX_{NETWORK}: Maximum amount of token0 willing to spend (safety limit)
 * - RH_AMOUNT1_MAX_{NETWORK}: Maximum amount of token1 willing to spend (safety limit)
 *
 * Note: Token amounts are calculated automatically using previewAddReHypothecatedLiquidity()
 */
contract AddRHLiquidityScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("RH_SHARES_", network);
        uint256 shares = vm.envUint(envVar);
        require(shares > 0, "RH_SHARES must be > 0");

        envVar = string.concat("RH_AMOUNT0_MAX_", network);
        uint256 amount0Max = vm.envUint(envVar);
        require(amount0Max > 0, string.concat(envVar, " not set"));

        envVar = string.concat("RH_AMOUNT1_MAX_", network);
        uint256 amount1Max = vm.envUint(envVar);
        require(amount1Max > 0, string.concat(envVar, " not set"));

        Alphix alphix = Alphix(hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();
        bool isEthPool = poolKey.currency0.isAddressZero();

        console.log("===========================================");
        console.log("ADDING REHYPOTHECATED LIQUIDITY");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix:", hookAddr);
        console.log("Pool Type:", isEthPool ? "ETH/ERC20" : "ERC20/ERC20");
        console.log("");

        // Verify yield sources are configured FIRST (before preview)
        address yieldSource0 = alphix.getCurrencyYieldSource(poolKey.currency0);
        address yieldSource1 = alphix.getCurrencyYieldSource(poolKey.currency1);
        console.log("Yield Sources:");
        console.log("  - Currency0:", yieldSource0 == address(0) ? "NOT SET" : _addressToString(yieldSource0));
        console.log("  - Currency1:", yieldSource1 == address(0) ? "NOT SET" : _addressToString(yieldSource1));
        console.log("");

        // Warn if either yield source is missing (not just both)
        if (yieldSource0 == address(0) || yieldSource1 == address(0)) {
            if (yieldSource0 == address(0)) {
                console.log("WARNING: Yield source for currency0 is not configured!");
            }
            if (yieldSource1 == address(0)) {
                console.log("WARNING: Yield source for currency1 is not configured!");
            }
            console.log("Run 04_ConfigureReHypothecation.s.sol first.");
            return;
        }

        // Preview required amounts (after yield source validation)
        (uint256 amount0, uint256 amount1) = alphix.previewAddReHypothecatedLiquidity(shares);

        console.log("Shares to mint:", shares);
        console.log("Required amounts:");
        console.log("  - Amount0:", amount0, "wei", isEthPool ? "(ETH)" : "");
        console.log("  - Amount1:", amount1, "wei");
        console.log("Max limits:");
        console.log("  - Amount0 max:", amount0Max, "wei");
        console.log("  - Amount1 max:", amount1Max, "wei");
        console.log("");

        // Safety check: ensure required amounts don't exceed max limits
        require(amount0 <= amount0Max, "Amount0 exceeds RH_AMOUNT0_MAX limit");
        require(amount1 <= amount1Max, "Amount1 exceeds RH_AMOUNT1_MAX limit");

        vm.startBroadcast();

        // Approve tokens (for ERC20 pools, approve both; for ETH pools, only approve token1)
        // Note: Reset to 0 first for USDT-style tokens that require zero allowance before setting new value
        console.log("Step 1: Approving tokens...");
        if (!isEthPool && amount0 > 0) {
            IERC20 token0 = IERC20(Currency.unwrap(poolKey.currency0));
            token0.approve(hookAddr, 0);
            token0.approve(hookAddr, amount0 + 1);
            console.log("  - Approved token0");
        }
        if (amount1 > 0) {
            IERC20 token1 = IERC20(Currency.unwrap(poolKey.currency1));
            token1.approve(hookAddr, 0);
            token1.approve(hookAddr, amount1 + 1);
            console.log("  - Approved token1");
        }

        // Add liquidity
        console.log("Step 2: Adding rehypothecated liquidity...");
        if (isEthPool) {
            // For ETH pools, send ETH with the call
            AlphixETH(payable(hookAddr)).addReHypothecatedLiquidity{value: amount0}(shares);
        } else {
            alphix.addReHypothecatedLiquidity(shares);
        }
        console.log("  - Done");

        vm.stopBroadcast();

        // Verify (use tx.origin since msg.sender is the script contract, not the broadcaster)
        uint256 userShares = alphix.balanceOf(tx.origin);

        console.log("");
        console.log("===========================================");
        console.log("LIQUIDITY ADDED SUCCESSFULLY");
        console.log("===========================================");
        console.log("Shares minted:", shares);
        console.log("Total shares owned by broadcaster:", userShares);
        console.log("");
        console.log("Your tokens are now earning yield in ERC-4626 vaults!");
        console.log("JIT liquidity will be provided during swaps.");
        console.log("");
        console.log("To withdraw: call removeReHypothecatedLiquidity(shares)");
        console.log("===========================================");
    }

    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory result = new bytes(42);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            result[2 + i * 2] = alphabet[uint8(uint160(addr) >> (8 * (19 - i)) >> 4) & 0xf];
            result[2 + i * 2 + 1] = alphabet[uint8(uint160(addr) >> (8 * (19 - i))) & 0xf];
        }
        return string(result);
    }
}
