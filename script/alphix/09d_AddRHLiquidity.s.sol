// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";

/**
 * @title Add ReHypothecated Liquidity
 * @notice Adds rehypothecated liquidity to an Alphix pool by depositing tokens to yield sources
 * @dev User specifies desired shares; script previews required amounts and deposits
 *
 * DEPLOYMENT ORDER: 9d/11 (Run after pool creation and rehypothecation configuration)
 *
 * ARCHITECTURE: Single-Pool-Per-Hook Design
 * Each AlphixLogic manages ONE pool's rehypothecation. This script adds RH liquidity
 * to the specific AlphixLogic instance configured in environment variables.
 *
 * Prerequisites:
 * - Pool must be created and activated (script 09)
 * - Rehypothecation must be configured with yield sources (script 06d)
 * - User must have sufficient token balances
 *
 * How ReHypothecated Liquidity Works:
 * 1. User deposits tokens to AlphixLogic
 * 2. Tokens are deposited into ERC-4626 yield vaults
 * 3. User receives LP shares (AlphixLogic is an ERC20)
 * 4. JIT liquidity is provided during swaps using these funds
 * 5. Yield from vaults accrues to LP holders (minus tax)
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_LOGIC_PROXY_{NETWORK}: AlphixLogic proxy address
 * - RH_SHARES_{NETWORK}: Number of shares to mint (in wei, 18 decimals)
 *
 * Note: Token amounts are calculated automatically using previewAddReHypothecatedLiquidity()
 */
contract AddRHLiquidityScript is Script {
    // Struct to avoid stack too deep errors
    struct Config {
        string network;
        address logicAddr;
        uint256 shares;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint8 decimals0;
        uint8 decimals1;
    }

    function run() public {
        Config memory cfg;

        // Load environment variables
        cfg.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(cfg.network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar;

        // Get AlphixLogic proxy address
        envVar = string.concat("ALPHIX_LOGIC_PROXY_", cfg.network);
        cfg.logicAddr = vm.envAddress(envVar);
        require(cfg.logicAddr != address(0), string.concat(envVar, " not set"));

        // Get shares amount to add
        envVar = string.concat("RH_SHARES_", cfg.network);
        cfg.shares = vm.envUint(envVar);
        require(cfg.shares > 0, "RH_SHARES must be greater than 0");

        AlphixLogic logic = AlphixLogic(cfg.logicAddr);

        // Get pool currencies from PoolKey
        PoolKey memory poolKey = logic.getPoolKey();
        cfg.token0 = Currency.unwrap(poolKey.currency0);
        cfg.token1 = Currency.unwrap(poolKey.currency1);

        // Preview required amounts
        (cfg.amount0, cfg.amount1) = logic.previewAddReHypothecatedLiquidity(cfg.shares);

        // Get token decimals for display
        cfg.decimals0 = poolKey.currency0.isAddressZero() ? 18 : IERC20(cfg.token0).decimals();
        cfg.decimals1 = poolKey.currency1.isAddressZero() ? 18 : IERC20(cfg.token1).decimals();

        _logConfig(cfg);
        _checkPoolStatus(logic, poolKey);

        vm.startBroadcast();

        _approveAndDeposit(logic, cfg, poolKey);

        vm.stopBroadcast();

        _logSuccess(logic, cfg);
    }

    function _logConfig(Config memory cfg) internal pure {
        console.log("===========================================");
        console.log("ADDING REHYPOTHECATED LIQUIDITY");
        console.log("===========================================");
        console.log("Network:", cfg.network);
        console.log("AlphixLogic:", cfg.logicAddr);
        console.log("");
        console.log("Shares to mint:", cfg.shares);
        console.log("");
        console.log("Required token amounts:");
        console.log("  - Token0:", cfg.token0);
        console.log("    Amount: %d wei (%d decimals)", cfg.amount0, cfg.decimals0);
        console.log("  - Token1:", cfg.token1);
        console.log("    Amount: %d wei (%d decimals)", cfg.amount1, cfg.decimals1);
        console.log("");
    }

    function _checkPoolStatus(AlphixLogic logic, PoolKey memory poolKey) internal view {
        // Check if pool is activated
        bool isActive = logic.isPoolActivated();
        if (!isActive) {
            console.log("ERROR: Pool is not activated!");
            console.log("Please run script 09_CreatePoolAndAddLiquidity.s.sol first.");
            revert("Pool not activated");
        }
        console.log("Pool status: ACTIVE");

        // Check yield sources are configured
        address yieldSource0 = logic.getCurrencyYieldSource(poolKey.currency0);
        address yieldSource1 = logic.getCurrencyYieldSource(poolKey.currency1);

        console.log("");
        console.log("Yield Sources:");
        if (yieldSource0 == address(0)) {
            console.log("  - Currency0: NOT SET");
        } else {
            console.log("  - Currency0:", yieldSource0);
        }
        if (yieldSource1 == address(0)) {
            console.log("  - Currency1: NOT SET");
        } else {
            console.log("  - Currency1:", yieldSource1);
        }

        if (yieldSource0 == address(0) && yieldSource1 == address(0)) {
            console.log("");
            console.log("WARNING: No yield sources configured!");
            console.log("Consider running script 06d_ConfigureReHypothecation.s.sol first.");
        }
        console.log("");
    }

    function _approveAndDeposit(AlphixLogic logic, Config memory cfg, PoolKey memory poolKey) internal {
        console.log("Step 1: Approving tokens to AlphixLogic...");

        if (!poolKey.currency0.isAddressZero() && cfg.amount0 > 0) {
            IERC20(cfg.token0).approve(cfg.logicAddr, cfg.amount0 + 1);
            console.log("  - Approved token0");
        }
        if (!poolKey.currency1.isAddressZero() && cfg.amount1 > 0) {
            IERC20(cfg.token1).approve(cfg.logicAddr, cfg.amount1 + 1);
            console.log("  - Approved token1");
        }
        console.log("");

        console.log("Step 2: Adding rehypothecated liquidity...");
        logic.addReHypothecatedLiquidity(cfg.shares);
        console.log("  - Liquidity added successfully");
        console.log("");
    }

    function _logSuccess(AlphixLogic logic, Config memory cfg) internal view {
        // Get user's new share balance
        uint256 userShares = logic.balanceOf(msg.sender);

        console.log("===========================================");
        console.log("REHYPOTHECATED LIQUIDITY ADDED SUCCESSFULLY");
        console.log("===========================================");
        console.log("");
        console.log("Transaction Summary:");
        console.log("  - Shares minted:", cfg.shares);
        console.log("  - Token0 deposited:", cfg.amount0, "wei");
        console.log("  - Token1 deposited:", cfg.amount1, "wei");
        console.log("");
        console.log("User Status:");
        console.log("  - Total shares owned:", userShares);
        console.log("  - AlphixLogic address:", cfg.logicAddr);
        console.log("");
        console.log("WHAT HAPPENS NEXT:");
        console.log("1. Your tokens are now in ERC-4626 yield vaults");
        console.log("2. JIT liquidity will be provided during swaps");
        console.log("3. Yield accrues from the vaults (minus protocol tax)");
        console.log("4. Remove liquidity anytime with removeReHypothecatedLiquidity()");
        console.log("===========================================");
    }
}
