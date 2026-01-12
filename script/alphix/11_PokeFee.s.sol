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
import {IAlphixLogic} from "../../src/interfaces/IAlphixLogic.sol";
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
 * @dev Calls Alphix.poke() to trigger fee recalculation. Uses computeFeeUpdate for dry-run preview.
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

    // Struct to hold pool info to reduce stack depth
    struct PoolInfo {
        PoolKey poolKey;
        PoolId poolId;
        Alphix alphix;
        IAlphixLogic logic;
    }

    // Struct to hold fee computation results
    struct FeeResult {
        uint24 predictedNewFee;
        uint24 currentFee;
        uint256 oldTargetRatio;
        uint256 newTargetRatio;
    }

    /**
     * @dev Execute poke with the provided configuration
     */
    function _executePoke(PokeConfig memory config) internal {
        // Build pool info
        PoolInfo memory info = _buildPoolInfo(config);

        // Log pool details
        _logPoolDetails(info.poolKey);

        // Get pool params directly from logic (single pool)
        DynamicFeeLib.PoolParams memory params = info.logic.getPoolParams();

        console.log("Pool Parameters:");
        console.log("  - Min Period (cooldown): %s seconds", params.minPeriod);
        console.log("  - Min Fee: %s bps", params.minFee);
        console.log("  - Max Fee: %s bps", params.maxFee);
        console.log("");

        // Use computeFeeUpdate for a dry-run preview (no cooldown check)
        FeeResult memory result = _computeDryRun(info.logic, info.poolKey, config.currentRatio);

        _logDryRunResult(result, params.minPeriod);

        // Execute the poke
        _executePokeCall(info, config.currentRatio, result);
    }

    /**
     * @dev Build PoolInfo struct from config
     */
    function _buildPoolInfo(PokeConfig memory config) internal view returns (PoolInfo memory info) {
        IPositionManagerPoolKeys posm = IPositionManagerPoolKeys(config.positionManagerAddr);

        // Fetch pool info from PoolId
        bytes25 poolIdBytes25 = bytes25(config.poolIdFull);
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, IHooks hooks) =
            posm.poolKeys(poolIdBytes25);

        info.poolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
        info.poolId = info.poolKey.toId();
        info.alphix = Alphix(address(hooks));
        info.logic = IAlphixLogic(info.alphix.getLogic());
    }

    /**
     * @dev Log pool details
     */
    function _logPoolDetails(PoolKey memory poolKey) internal pure {
        console.log("Pool Details (fetched from PoolId):");
        console.log("  - Token0:", Currency.unwrap(poolKey.currency0));
        console.log("  - Token1:", Currency.unwrap(poolKey.currency1));
        console.log("  - Fee: DYNAMIC (0x%x)", poolKey.fee);
        // Casting tickSpacing to uint256 via uint24 is safe for display purposes
        // forge-lint: disable-next-line(unsafe-typecast)
        console.log("  - Tick Spacing:", uint256(uint24(poolKey.tickSpacing)));
        console.log("  - Hook:", address(poolKey.hooks));
        console.log("");
    }

    /**
     * @dev Compute dry-run fee update
     */
    function _computeDryRun(IAlphixLogic logic, PoolKey memory, uint256 currentRatio)
        internal
        view
        returns (FeeResult memory result)
    {
        (result.predictedNewFee, result.currentFee, result.oldTargetRatio, result.newTargetRatio,) =
            logic.computeFeeUpdate(currentRatio);
    }

    /**
     * @dev Log dry-run results
     */
    function _logDryRunResult(FeeResult memory result, uint256 minPeriod) internal pure {
        console.log("DRY RUN (computeFeeUpdate):");
        console.log("  - Current Fee: %s bps (0.%s%%)", result.currentFee, _bpsToPercent(result.currentFee));
        console.log(
            "  - Predicted New Fee: %s bps (0.%s%%)", result.predictedNewFee, _bpsToPercent(result.predictedNewFee)
        );
        console.log("  - Old Target Ratio: %s", result.oldTargetRatio);
        console.log("  - New Target Ratio: %s", result.newTargetRatio);

        if (result.predictedNewFee > result.currentFee) {
            console.log("  - Expected Change: +%s bps (fee increase)", result.predictedNewFee - result.currentFee);
        } else if (result.predictedNewFee < result.currentFee) {
            console.log("  - Expected Change: -%s bps (fee decrease)", result.currentFee - result.predictedNewFee);
        } else {
            console.log("  - Expected Change: 0 bps (no change)");
        }
        console.log("");

        console.log("COOLDOWN WARNING:");
        console.log("  - You must wait at least %s seconds between pokes", minPeriod);
        console.log("  - If cooldown not met, this transaction will REVERT");
        console.log("");

        console.log("Attempting to poke fee...");
        console.log("NOTE: This will revert if:");
        console.log("  1. Caller does not have FEE_POKER role");
        console.log("  2. Pool cooldown period has not elapsed");
        console.log("");
    }

    /**
     * @dev Execute the actual poke call
     */
    function _executePokeCall(PoolInfo memory info, uint256 currentRatio, FeeResult memory result) internal {
        vm.startBroadcast();

        // Poke the fee - may revert due to role or cooldown
        try info.alphix.poke(currentRatio) {
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
        IPoolManager poolManager = info.alphix.poolManager();
        (,,, uint24 actualNewFee) = poolManager.getSlot0(info.poolId);

        console.log("");
        console.log("===========================================");
        console.log("FEE UPDATE SUCCESSFUL");
        console.log("===========================================");
        console.log("Old Fee: %s bps (0.%s%%)", result.currentFee, _bpsToPercent(result.currentFee));
        console.log("New Fee: %s bps (0.%s%%)", actualNewFee, _bpsToPercent(actualNewFee));

        if (actualNewFee > result.currentFee) {
            console.log("Change: +%s bps (fee increased)", actualNewFee - result.currentFee);
        } else if (actualNewFee < result.currentFee) {
            console.log("Change: -%s bps (fee decreased)", result.currentFee - actualNewFee);
        } else {
            console.log("Change: 0 bps (no change)");
        }

        // Verify prediction matched reality
        if (actualNewFee == result.predictedNewFee) {
            console.log("");
            console.log("(computeFeeUpdate prediction was correct)");
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
