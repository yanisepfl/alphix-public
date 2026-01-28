// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Alphix} from "../../src/Alphix.sol";
import {AlphixETH} from "../../src/AlphixETH.sol";

/**
 * @title Add ReHypothecated Liquidity
 * @notice Deposits tokens to yield sources in exchange for LP shares
 * @dev Supports both ERC20/ERC20 (Alphix) and ETH/ERC20 (AlphixETH) pools
 *
 * DEPLOYMENT ORDER: 5b (After rehypothecation configuration)
 *
 * How ReHypothecation Works:
 * 1. User specifies desired LP shares to mint
 * 2. Script calculates required token amounts via previewAddReHypothecatedLiquidity
 * 3. Tokens are deposited into ERC-4626 yield vaults
 * 4. User receives LP shares (Alphix is an ERC20)
 * 5. JIT liquidity uses these funds during swaps
 * 6. Yield from vaults accrues to LP holders
 *
 * Slippage Protection:
 * The script supports on-chain slippage protection to guard against sandwich attacks.
 * If the pool price moves beyond your tolerance between submitting and executing,
 * the transaction will revert.
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix hook address
 * - RH_SHARES_{NETWORK}: Number of shares to mint (in wei, 18 decimals)
 * - RH_AMOUNT0_MAX_{NETWORK}: Maximum amount of token0 willing to spend (safety limit)
 * - RH_AMOUNT1_MAX_{NETWORK}: Maximum amount of token1 willing to spend (safety limit)
 *
 * Optional Slippage Protection Variables:
 * - RH_EXPECTED_PRICE_{NETWORK}: Expected sqrtPriceX96 (set to 0 or omit to use current price)
 * - RH_MAX_SLIPPAGE_{NETWORK}: Max price slippage tolerance (same scale as LP fee: 1000000 = 100%, 10000 = 1%)
 *                              Default: 10000 (1%) if not set. Set to 0 to disable slippage check.
 *
 * Note: Token amounts are calculated automatically using previewAddReHypothecatedLiquidity()
 */
contract AddRHLiquidityScript is Script {
    using StateLibrary for IPoolManager;

    struct Config {
        address hookAddr;
        uint256 shares;
        uint256 amount0Max;
        uint256 amount1Max;
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
        console.log("ADDING REHYPOTHECATED LIQUIDITY");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix:", cfg.hookAddr);
        console.log("Pool Type:", isEthPool ? "ETH/ERC20" : "ERC20/ERC20");
        console.log("");

        // Verify yield sources are configured
        if (!_checkYieldSources(alphix, poolKey)) return;

        // Get current price if expected price not provided
        (uint160 currentPrice,,,) = alphix.poolManager().getSlot0(poolKey.toId());
        if (cfg.expectedPrice == 0) {
            cfg.expectedPrice = currentPrice;
            console.log("Using current pool price for slippage check");
        }

        // Preview required amounts
        (uint256 amount0, uint256 amount1) = alphix.previewAddReHypothecatedLiquidity(cfg.shares);

        _logAmounts(cfg, amount0, amount1, currentPrice, isEthPool);

        // Safety check
        require(amount0 <= cfg.amount0Max, "Amount0 exceeds RH_AMOUNT0_MAX limit");
        require(amount1 <= cfg.amount1Max, "Amount1 exceeds RH_AMOUNT1_MAX limit");

        vm.startBroadcast();

        // Approve and add liquidity
        _approveAndAddLiquidity(alphix, poolKey, cfg, amount0, amount1, isEthPool);

        vm.stopBroadcast();

        // Verify
        uint256 userShares = alphix.balanceOf(tx.origin);
        _logSuccess(cfg.shares, userShares);
    }

    function _loadConfig(string memory network) internal view returns (Config memory cfg) {
        string memory envVar;

        envVar = string.concat("ALPHIX_HOOK_", network);
        cfg.hookAddr = vm.envAddress(envVar);
        require(cfg.hookAddr != address(0), string.concat(envVar, " not set"));

        envVar = string.concat("RH_SHARES_", network);
        cfg.shares = vm.envUint(envVar);
        require(cfg.shares > 0, "RH_SHARES must be > 0");

        envVar = string.concat("RH_AMOUNT0_MAX_", network);
        cfg.amount0Max = vm.envUint(envVar);
        require(cfg.amount0Max > 0, string.concat(envVar, " not set"));

        envVar = string.concat("RH_AMOUNT1_MAX_", network);
        cfg.amount1Max = vm.envUint(envVar);
        require(cfg.amount1Max > 0, string.concat(envVar, " not set"));

        envVar = string.concat("RH_EXPECTED_PRICE_", network);
        cfg.expectedPrice = uint160(vm.envOr(envVar, uint256(0)));

        envVar = string.concat("RH_MAX_SLIPPAGE_", network);
        cfg.maxSlippage = uint24(vm.envOr(envVar, uint256(10000))); // Default 1%
    }

    function _checkYieldSources(Alphix alphix, PoolKey memory poolKey) internal view returns (bool) {
        address yieldSource0 = alphix.getCurrencyYieldSource(poolKey.currency0);
        address yieldSource1 = alphix.getCurrencyYieldSource(poolKey.currency1);
        console.log("Yield Sources:");
        console.log("  - Currency0:", yieldSource0 == address(0) ? "NOT SET" : _addressToString(yieldSource0));
        console.log("  - Currency1:", yieldSource1 == address(0) ? "NOT SET" : _addressToString(yieldSource1));
        console.log("");

        if (yieldSource0 == address(0) || yieldSource1 == address(0)) {
            if (yieldSource0 == address(0)) console.log("WARNING: Yield source for currency0 is not configured!");
            if (yieldSource1 == address(0)) console.log("WARNING: Yield source for currency1 is not configured!");
            console.log("Run 04_ConfigureReHypothecation.s.sol first.");
            return false;
        }
        return true;
    }

    function _logAmounts(Config memory cfg, uint256 amount0, uint256 amount1, uint160 currentPrice, bool isEthPool)
        internal
        pure
    {
        console.log("Shares to mint:", cfg.shares);
        console.log("Required amounts:");
        console.log("  - Amount0:", amount0, "wei", isEthPool ? "(ETH)" : "");
        console.log("  - Amount1:", amount1, "wei");
        console.log("Max limits:");
        console.log("  - Amount0 max:", cfg.amount0Max, "wei");
        console.log("  - Amount1 max:", cfg.amount1Max, "wei");
        console.log("");
        console.log("Slippage Protection:");
        console.log("  - Current price (sqrtPriceX96):", currentPrice);
        console.log("  - Expected price (sqrtPriceX96):", cfg.expectedPrice);
        console.log("  - Max slippage (raw):", cfg.maxSlippage);
        console.log("  - Max slippage (%):", _formatSlippage(cfg.maxSlippage));
        if (cfg.maxSlippage == 0) console.log("  - WARNING: Slippage check DISABLED (maxSlippage=0)");
        console.log("");
    }

    function _approveAndAddLiquidity(
        Alphix alphix,
        PoolKey memory poolKey,
        Config memory cfg,
        uint256 amount0,
        uint256 amount1,
        bool isEthPool
    ) internal {
        console.log("Step 1: Approving tokens...");
        if (!isEthPool && amount0 > 0) {
            IERC20 token0 = IERC20(Currency.unwrap(poolKey.currency0));
            token0.approve(cfg.hookAddr, 0);
            token0.approve(cfg.hookAddr, amount0 + 1);
            console.log("  - Approved token0");
        }
        if (amount1 > 0) {
            IERC20 token1 = IERC20(Currency.unwrap(poolKey.currency1));
            token1.approve(cfg.hookAddr, 0);
            token1.approve(cfg.hookAddr, amount1 + 1);
            console.log("  - Approved token1");
        }

        console.log("Step 2: Adding rehypothecated liquidity...");
        if (isEthPool) {
            AlphixETH(payable(cfg.hookAddr)).addReHypothecatedLiquidity{value: amount0}(
                cfg.shares, cfg.expectedPrice, cfg.maxSlippage
            );
        } else {
            alphix.addReHypothecatedLiquidity(cfg.shares, cfg.expectedPrice, cfg.maxSlippage);
        }
        console.log("  - Done");
    }

    function _logSuccess(uint256 shares, uint256 userShares) internal pure {
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
