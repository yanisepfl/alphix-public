// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Emergency Pause Script
 * @notice Pauses the Alphix hook to halt all operations in case of emergency
 * @dev EMERGENCY USE ONLY - Pausing blocks ALL protocol operations
 *
 * WHAT GETS BLOCKED WHEN PAUSED:
 * ===============================
 * Uniswap V4 Hook Operations:
 *   - beforeSwap (JIT liquidity addition)
 *   - afterSwap (JIT liquidity removal)
 *   => All swaps through the pool will revert
 *
 * Rehypothecation Operations:
 *   - addReHypothecatedLiquidity
 *   - removeReHypothecatedLiquidity
 *   - setYieldSource (migration)
 *
 * Fee Operations:
 *   - poke() (fee updates)
 *   - computeFeeUpdate()
 *
 * Configuration:
 *   - setPoolParams()
 *   - setGlobalMaxAdjRate()
 *
 * WHAT REMAINS AVAILABLE:
 * =======================
 *   - pause() / unpause() (owner only)
 *   - View functions (getters)
 *   - ERC20 share transfers
 *   - Ownership transfer
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - PRIVATE_KEY: Owner's private key
 *
 * SENDER REQUIREMENTS: Must be current owner of Alphix Hook
 *
 * Usage:
 *   forge script script/alphix/09a_Pause.s.sol --rpc-url $RPC_URL --broadcast
 */
contract PauseScript is Script {
    function run() public {
        string memory network = vm.envString("DEPLOYMENT_NETWORK");
        require(bytes(network).length > 0, "DEPLOYMENT_NETWORK not set");

        string memory envVar = string.concat("ALPHIX_HOOK_", network);
        address hookAddr = vm.envAddress(envVar);
        require(hookAddr != address(0), string.concat(envVar, " not set"));

        Alphix alphix = Alphix(hookAddr);
        address currentOwner = alphix.owner();

        // Get the broadcaster address from the private key
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(privateKey);

        console.log("===========================================");
        console.log("EMERGENCY PAUSE");
        console.log("===========================================");
        console.log("Network:", network);
        console.log("Alphix Hook:", hookAddr);
        console.log("");
        console.log("Current Owner:", currentOwner);
        console.log("Broadcaster:", broadcaster);
        console.log("");

        require(currentOwner == broadcaster, "Broadcaster is not current owner");

        // Check current pause state
        bool isPaused = alphix.paused();
        console.log("Current Pause State:", isPaused ? "PAUSED" : "NOT PAUSED");

        if (isPaused) {
            console.log("");
            console.log("WARNING: Contract is already paused!");
            console.log("No action taken.");
            return;
        }

        console.log("");
        console.log("PAUSING CONTRACT...");
        console.log("");

        vm.startBroadcast(privateKey);

        alphix.pause();

        vm.stopBroadcast();

        // Verify pause state
        bool isPausedAfter = alphix.paused();
        require(isPausedAfter, "CRITICAL: Pause failed - contract not paused!");

        console.log("===========================================");
        console.log("PAUSE COMPLETE - VERIFYING OPERATIONS BLOCKED");
        console.log("===========================================");
        console.log("");
        console.log("New Pause State:", isPausedAfter ? "PAUSED" : "NOT PAUSED");
        console.log("");

        // Verify key operations now revert
        console.log("Verifying operations are blocked...");
        console.log("");

        // Test 1: computeFeeUpdate should revert
        bool computeFeeReverted = _testComputeFeeUpdateReverts(alphix);
        console.log("  [", computeFeeReverted ? "PASS" : "FAIL", "] computeFeeUpdate() reverts");

        // Test 2: addReHypothecatedLiquidity should revert
        bool addLiqReverted = _testAddRHLiquidityReverts(alphix);
        console.log("  [", addLiqReverted ? "PASS" : "FAIL", "] addReHypothecatedLiquidity() reverts");

        // Test 3: removeReHypothecatedLiquidity should revert
        bool removeLiqReverted = _testRemoveRHLiquidityReverts(alphix);
        console.log("  [", removeLiqReverted ? "PASS" : "FAIL", "] removeReHypothecatedLiquidity() reverts");

        console.log("");

        // Fail if any verification failed
        require(
            computeFeeReverted && addLiqReverted && removeLiqReverted,
            "CRITICAL: Some operations did not revert as expected!"
        );

        console.log("All verifications passed!");
        console.log("");
        console.log("===========================================");
        console.log("PAUSE VERIFIED SUCCESSFULLY");
        console.log("===========================================");
        console.log("");
        console.log("BLOCKED OPERATIONS:");
        console.log("  - All swaps through the pool");
        console.log("  - addReHypothecatedLiquidity");
        console.log("  - removeReHypothecatedLiquidity");
        console.log("  - setYieldSource");
        console.log("  - poke (fee updates)");
        console.log("  - setPoolParams");
        console.log("  - setGlobalMaxAdjRate");
        console.log("");
        console.log("STILL AVAILABLE:");
        console.log("  - unpause()");
        console.log("  - View functions (getters)");
        console.log("  - ERC20 share transfers");
        console.log("  - Ownership transfer");
        console.log("");
        console.log("To unpause, run: 09b_Unpause.s.sol");
        console.log("===========================================");
    }

    /**
     * @dev Tests that computeFeeUpdate reverts with EnforcedPause when paused.
     *      Uses a low-level call and checks the revert selector to avoid false positives.
     */
    function _testComputeFeeUpdateReverts(Alphix alphix) internal returns (bool) {
        (bool success, bytes memory data) =
            address(alphix).call(abi.encodeWithSelector(Alphix.computeFeeUpdate.selector, 1e18));
        if (success) return false;
        // Verify revert reason is EnforcedPause()
        return data.length >= 4 && bytes4(data) == Pausable.EnforcedPause.selector;
    }

    /**
     * @dev Tests that addReHypothecatedLiquidity reverts with EnforcedPause when paused.
     *      Uses a low-level call and checks the revert selector to avoid false positives
     *      (staticcall always reverts on state-mutating functions regardless of pause state).
     */
    function _testAddRHLiquidityReverts(Alphix alphix) internal returns (bool) {
        (bool success, bytes memory data) = address(alphix)
            .call(abi.encodeWithSelector(Alphix.addReHypothecatedLiquidity.selector, 1e18, uint160(0), uint24(0)));
        if (success) return false;
        // Verify revert reason is EnforcedPause()
        return data.length >= 4 && bytes4(data) == Pausable.EnforcedPause.selector;
    }

    /**
     * @dev Tests that removeReHypothecatedLiquidity reverts with EnforcedPause when paused.
     *      Uses a low-level call and checks the revert selector to avoid false positives
     *      (staticcall always reverts on state-mutating functions regardless of pause state).
     */
    function _testRemoveRHLiquidityReverts(Alphix alphix) internal returns (bool) {
        (bool success, bytes memory data) = address(alphix)
            .call(abi.encodeWithSelector(Alphix.removeReHypothecatedLiquidity.selector, 1e18, uint160(0), uint24(0)));
        if (success) return false;
        // Verify revert reason is EnforcedPause()
        return data.length >= 4 && bytes4(data) == Pausable.EnforcedPause.selector;
    }
}
