// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
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
 * Slippage Protection:
 * The script supports on-chain slippage protection to guard against sandwich attacks.
 * If the pool price moves beyond your tolerance between submitting and executing,
 * the transaction will revert.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - RH_REMOVE_SHARES_{NETWORK}: Number of shares to burn (in wei, 18 decimals)
 * - RH_REMOVE_AMOUNT0_MIN_{NETWORK}: Minimum amount of token0 expected (off-chain preflight check)
 * - RH_REMOVE_AMOUNT1_MIN_{NETWORK}: Minimum amount of token1 expected (off-chain preflight check)
 *
 * Optional Slippage Protection Variables:
 * - RH_REMOVE_EXPECTED_PRICE_{NETWORK}: Expected sqrtPriceX96 (set to 0 or omit to use current price)
 * - RH_REMOVE_MAX_SLIPPAGE_{NETWORK}: Max price slippage tolerance (same scale as LP fee: 1000000 = 100%, 10000 = 1%)
 *                                     Default: 10000 (1%) if not set. Set to 0 to disable slippage check.
 *
 * Note: Token amounts are calculated automatically using previewRemoveReHypothecatedLiquidity()
 */
contract RemoveRHLiquidityScript is Script {
    using StateLibrary for IPoolManager;

    struct Config {
        address hookAddr;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint160 expectedPrice;
        uint24 maxSlippage;
    }

    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        Config memory cfg = _loadConfig(network);

        Alphix alphix = Alphix(cfg.hookAddr);
        PoolKey memory poolKey = alphix.getPoolKey();
        bool isEthPool = poolKey.currency0.isAddressZero();

        console.log("===========================================");
        console.log("REMOVING REHYPOTHECATED LIQUIDITY");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix:", cfg.hookAddr);
        console.log("Pool Type:", isEthPool ? "ETH/ERC20" : "ERC20/ERC20");
        console.log("");

        // Check user's current balance
        uint256 userSharesBefore = alphix.balanceOf(tx.origin);
        console.log("Your current shares:", userSharesBefore);
        require(userSharesBefore >= cfg.shares, "Insufficient shares to remove");
        console.log("Shares to burn:", cfg.shares);
        console.log("");

        // Get current price if expected price not provided
        (uint160 currentPrice,,,) = alphix.poolManager().getSlot0(poolKey.toId());
        if (cfg.expectedPrice == 0) {
            cfg.expectedPrice = currentPrice;
            console.log("Using current pool price for slippage check");
        }

        // Preview withdrawal amounts
        (uint256 amount0, uint256 amount1) = alphix.previewRemoveReHypothecatedLiquidity(cfg.shares);

        _logAmounts(cfg, amount0, amount1, currentPrice, isEthPool);

        // Off-chain preflight check
        require(amount0 >= cfg.amount0Min, "Amount0 below RH_REMOVE_AMOUNT0_MIN limit");
        require(amount1 >= cfg.amount1Min, "Amount1 below RH_REMOVE_AMOUNT1_MIN limit");

        vm.startBroadcast();

        // Remove liquidity with slippage protection
        console.log("Removing rehypothecated liquidity...");
        if (isEthPool) {
            AlphixETH(payable(cfg.hookAddr))
                .removeReHypothecatedLiquidity(cfg.shares, cfg.expectedPrice, cfg.maxSlippage);
        } else {
            alphix.removeReHypothecatedLiquidity(cfg.shares, cfg.expectedPrice, cfg.maxSlippage);
        }
        console.log("  - Done");

        vm.stopBroadcast();

        // Verify
        uint256 userSharesAfter = alphix.balanceOf(tx.origin);
        _logSuccess(cfg.shares, userSharesAfter, amount0, amount1, isEthPool);
    }

    function _loadConfig(string memory network) internal view returns (Config memory cfg) {
        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        cfg.hookAddr = vm.envAddress(envVar);
        require(cfg.hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("RH_REMOVE_SHARES_", network);
        cfg.shares = vm.envUint(envVar);
        require(cfg.shares > 0, "RH_REMOVE_SHARES must be > 0");

        envVar = string.concat("RH_REMOVE_AMOUNT0_MIN_", network);
        cfg.amount0Min = vm.envUint(envVar);

        envVar = string.concat("RH_REMOVE_AMOUNT1_MIN_", network);
        cfg.amount1Min = vm.envUint(envVar);

        envVar = string.concat("RH_REMOVE_EXPECTED_PRICE_", network);
        cfg.expectedPrice = uint160(vm.envOr(envVar, uint256(0)));

        envVar = string.concat("RH_REMOVE_MAX_SLIPPAGE_", network);
        cfg.maxSlippage = uint24(vm.envOr(envVar, uint256(10000))); // Default 1%
    }

    function _logAmounts(Config memory cfg, uint256 amount0, uint256 amount1, uint160 currentPrice, bool isEthPool)
        internal
        pure
    {
        console.log("Expected withdrawal amounts:");
        console.log("  - Amount0:", amount0, "wei", isEthPool ? "(ETH)" : "");
        console.log("  - Amount1:", amount1, "wei");
        console.log("Minimum limits (off-chain preflight check):");
        console.log("  - Amount0 min:", cfg.amount0Min, "wei");
        console.log("  - Amount1 min:", cfg.amount1Min, "wei");
        console.log("");
        console.log("Slippage Protection:");
        console.log("  - Current price (sqrtPriceX96):", currentPrice);
        console.log("  - Expected price (sqrtPriceX96):", cfg.expectedPrice);
        console.log("  - Max slippage (raw):", cfg.maxSlippage);
        console.log("  - Max slippage (%):", _formatSlippage(cfg.maxSlippage));
        if (cfg.maxSlippage == 0) console.log("  - WARNING: Slippage check DISABLED (maxSlippage=0)");
        console.log("");
    }

    function _logSuccess(uint256 shares, uint256 userSharesAfter, uint256 amount0, uint256 amount1, bool isEthPool)
        internal
        pure
    {
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

    function _formatSlippage(uint24 slippage) internal pure returns (string memory) {
        uint256 whole = (uint256(slippage) * 100) / 1000000;
        uint256 decimal = ((uint256(slippage) * 10000) / 1000000) % 100;
        return string(abi.encodePacked(_uintToString(whole), ".", decimal < 10 ? "0" : "", _uintToString(decimal), "%"));
    }

    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
