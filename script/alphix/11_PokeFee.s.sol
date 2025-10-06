// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Alphix} from "../../src/Alphix.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";

// Minimal interface to access PositionManager's public poolKeys mapping
interface IPositionManagerPoolKeys {
    function poolKeys(bytes25 poolId)
        external
        view
        returns (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks);
}

/**
 * @title Poke Dynamic Fee
 * @notice Manually updates the dynamic fee for a pool based on current ratio
 * @dev Calls Alphix.poke() to trigger fee recalculation
 *
 * USAGE: Run this script to manually update pool fees (e.g., after swaps or ratio changes)
 *
 * IMPORTANT REQUIREMENTS:
 *
 * 1. ROLE REQUIREMENT:
 *    - Caller MUST have FEE_POKER role granted via AccessManager (script 06b)
 *    - Without proper role, the call will revert with "UnauthorizedCaller"
 *
 * 2. COOLDOWN ENFORCEMENT:
 *    - Each pool type has a minimum period between fee updates (minPeriod)
 *    - STABLE: typically 2 days
 *    - STANDARD: typically 1 day
 *    - VOLATILE: typically 0.5 day
 *    - If you try to poke before cooldown expires, tx will revert with "CooldownNotMet"
 *    - Best practice: Wait at least the pool's minPeriod after the last poke
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - POOL_MANAGER_{NETWORK}: Uniswap V4 PoolManager address
 * - POSITION_MANAGER_{NETWORK}: Uniswap V4 PositionManager address
 * - POOL_ID_{NETWORK}: Pool ID (bytes32) - pool info will be fetched automatically
 * - CURRENT_RATIO_{NETWORK}: Current observed ratio for fee calculation
 *
 */
contract PokeFeeScript is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Struct to avoid stack too deep errors
    struct PokeConfig {
        string network;
        address poolManagerAddr;
        address positionManagerAddr;
        uint256 currentRatio;
        bytes32 poolIdFull;
    }

    function run() public {
        PokeConfig memory config;

        // Load environment variables
        config.network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(config.network).length > 0, "DEPLOYMENT_NETWORK not set");

        // Get contract addresses
        config.poolManagerAddr = _getEnvAddress("POOL_MANAGER_", config.network);
        config.positionManagerAddr = _getEnvAddress("POSITION_MANAGER_", config.network);

        // Get pool parameters
        try vm.envBytes32(string.concat("POOL_ID_", config.network)) returns (bytes32 id) {
            config.poolIdFull = id;
        } catch {
            revert("POOL_ID_{NETWORK} not set");
        }

        config.currentRatio = _getEnvUint("CURRENT_RATIO_", config.network);

        console.log("===========================================");
        console.log("POKING DYNAMIC FEE");
        console.log("===========================================");
        console.log("Network:", config.network);
        console.log("Pool Manager:", config.poolManagerAddr);
        console.log("Pool ID: 0x%s", _toHex(config.poolIdFull));
        console.log("Current Ratio:", config.currentRatio);
        console.log("");

        // Execute the poke
        _executePoke(config);

        console.log("");
        console.log("NOTES:");
        console.log("- Fee changes are based on ratio deviation from target");
        console.log("- Higher fees discourage trading in the imbalanced direction");
        console.log("- Lower fees encourage trading to rebalance the pool");
        console.log("- Dynamic fees help maintain pool balance over time");
        console.log("");
        console.log("NEXT STEPS:");
        console.log("1. Wait at least minPeriod seconds before poking again");
        console.log("2. Perform swaps to observe how fees affect trading");
        console.log("3. Monitor pool reserves to calculate new ratio");
        console.log("4. Poke again after cooldown with updated current ratio");
        console.log("===========================================");
    }

    /**
     * @dev Execute poke with the provided configuration
     */
    function _executePoke(PokeConfig memory config) internal {
        // Create contract instances
        IPoolManager poolManager = IPoolManager(config.poolManagerAddr);
        IPositionManagerPoolKeys posm = IPositionManagerPoolKeys(config.positionManagerAddr);

        // Fetch pool info from PoolId
        bytes25 poolIdBytes25 = bytes25(config.poolIdFull);
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            posm.poolKeys(poolIdBytes25);

        // Get Alphix hook address from the pool info
        Alphix alphix = Alphix(address(hooks));

        // Log fetched pool info
        console.log("Pool Details (fetched from PoolId):");
        console.log("  - Token0:", Currency.unwrap(currency0));
        console.log("  - Token1:", Currency.unwrap(currency1));
        console.log("  - Fee: DYNAMIC (0x%x)", fee);
        console.log("  - Tick Spacing:", uint256(uint24(tickSpacing)));
        console.log("  - Hook:", address(hooks));
        console.log("");

        // Create PoolKey
        PoolKey memory poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});

        PoolId poolId = poolKey.toId();

        // Get pool configuration to show cooldown info
        try alphix.getPoolParams(poolId) returns (DynamicFeeLib.PoolTypeParams memory params) {
            console.log("Pool Type Parameters:");
            console.log("  - Min Period (cooldown): %s seconds", params.minPeriod);
            console.log("  - Min Fee: %s bps", params.minFee);
            console.log("  - Max Fee: %s bps", params.maxFee);
            console.log("");
            console.log("COOLDOWN WARNING:");
            console.log("  - You must wait at least %s seconds between pokes", params.minPeriod);
            console.log("  - If cooldown not met, this transaction will REVERT");
            console.log("  - There is no way to check last update time on-chain currently");
            console.log("");
        } catch {
            console.log("Could not fetch pool parameters");
            console.log("");
        }

        // Get current fee before poke
        (,,, uint24 oldFee) = poolManager.getSlot0(poolId);
        console.log("Current Fee: %s bps (0.%s%%)", oldFee, _bpsToPercent(oldFee));
        console.log("");

        console.log("Attempting to poke fee...");
        console.log("NOTE: This will revert if:");
        console.log("  1. Caller does not have FEE_POKER role");
        console.log("  2. Pool cooldown period has not elapsed");
        console.log("");

        vm.startBroadcast();

        // Poke the fee - may revert due to role or cooldown
        try alphix.poke(poolKey, config.currentRatio) {
            console.log("Poke successful!");
        } catch Error(string memory reason) {
            console.log("Poke FAILED with reason:", reason);
            revert(reason);
        } catch (bytes memory lowLevelData) {
            console.log("Poke FAILED with low-level error");
            console.logBytes(lowLevelData);
            revert("Poke failed - check role permissions and cooldown");
        }

        vm.stopBroadcast();

        // Get new fee after poke
        (,,, uint24 newFee) = poolManager.getSlot0(poolId);

        console.log("");
        console.log("===========================================");
        console.log("FEE UPDATE SUCCESSFUL");
        console.log("===========================================");
        console.log("Old Fee: %s bps (0.%s%%)", oldFee, _bpsToPercent(oldFee));
        console.log("New Fee: %s bps (0.%s%%)", newFee, _bpsToPercent(newFee));

        if (newFee > oldFee) {
            console.log("Change: +%s bps (fee increased)", newFee - oldFee);
        } else if (newFee < oldFee) {
            console.log("Change: -%s bps (fee decreased)", oldFee - newFee);
        } else {
            console.log("Change: 0 bps (no change)");
        }
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

    /**
     * @dev Convert bps to percentage string (e.g., 3000 -> "30")
     */
    function _bpsToPercent(uint24 bps) internal pure returns (uint256) {
        return bps / 100;
    }

    /**
     * @dev Convert bytes32 to hex string
     */
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
