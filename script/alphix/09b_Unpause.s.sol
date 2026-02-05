// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Alphix} from "../../src/Alphix.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title Unpause Script
 * @notice Resumes the Alphix hook after an emergency pause
 * @dev Only use after confirming the emergency situation is resolved
 *
 * WHAT GETS UNBLOCKED:
 * ====================
 * Uniswap V4 Hook Operations:
 *   - beforeSwap (JIT liquidity addition)
 *   - afterSwap (JIT liquidity removal)
 *   => Swaps through the pool will work again
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
 * SAFETY CHECKLIST BEFORE UNPAUSING:
 * ==================================
 *   [ ] Root cause of emergency identified
 *   [ ] Vulnerability patched or mitigated
 *   [ ] No malicious transactions pending
 *   [ ] Team consensus on resuming operations
 *   [ ] Monitoring systems active
 *
 * Environment Variables Required:
 * - DEPLOYMENT_NETWORK: Network identifier
 * - ALPHIX_HOOK_{NETWORK}: Alphix Hook contract address
 * - PRIVATE_KEY: Owner's private key
 *
 * SENDER REQUIREMENTS: Must be current owner of Alphix Hook
 *
 * Usage:
 *   forge script script/alphix/09b_Unpause.s.sol --rpc-url $RPC_URL --broadcast
 */
contract UnpauseScript is Script {
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
        console.log("UNPAUSE - RESUME OPERATIONS");
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

        if (!isPaused) {
            console.log("");
            console.log("WARNING: Contract is already unpaused!");
            console.log("No action taken.");
            return;
        }

        console.log("");
        console.log("SAFETY REMINDER:");
        console.log("  - Ensure root cause is resolved");
        console.log("  - Ensure monitoring is active");
        console.log("  - Ensure team consensus reached");
        console.log("");
        console.log("UNPAUSING CONTRACT...");
        console.log("");

        vm.startBroadcast(privateKey);

        alphix.unpause();

        vm.stopBroadcast();

        // Verify unpause state
        bool isPausedAfter = alphix.paused();
        require(!isPausedAfter, "CRITICAL: Unpause failed - contract still paused!");

        console.log("===========================================");
        console.log("UNPAUSE COMPLETE - VERIFYING OPERATIONS RESTORED");
        console.log("===========================================");
        console.log("");
        console.log("New Pause State:", isPausedAfter ? "PAUSED" : "NOT PAUSED");
        console.log("");

        // Verify key operations no longer revert due to pause
        // Note: They may revert for other reasons (e.g., no yield source, invalid params)
        // but should NOT revert with EnforcedPause
        console.log("Verifying operations are no longer pause-blocked...");
        console.log("");

        // Test 1: computeFeeUpdate should NOT revert with EnforcedPause
        bool computeFeeWorks = _testComputeFeeUpdateDoesNotRevertWithPause(alphix);
        console.log("  [", computeFeeWorks ? "PASS" : "FAIL", "] computeFeeUpdate() not pause-blocked");

        console.log("");

        require(computeFeeWorks, "CRITICAL: Operations still blocked after unpause!");

        console.log("Verification passed - operations restored!");
        console.log("");
        console.log("===========================================");
        console.log("UNPAUSE VERIFIED SUCCESSFULLY");
        console.log("===========================================");
        console.log("");
        console.log("RESTORED OPERATIONS:");
        console.log("  - All swaps through the pool");
        console.log("  - addReHypothecatedLiquidity");
        console.log("  - removeReHypothecatedLiquidity");
        console.log("  - setYieldSource");
        console.log("  - poke (fee updates)");
        console.log("  - setPoolParams");
        console.log("  - setGlobalMaxAdjRate");
        console.log("");
        console.log("RECOMMENDED NEXT STEPS:");
        console.log("  1. Monitor protocol activity closely");
        console.log("  2. Check fee update is working (07_PokeFee.s.sol)");
        console.log("  3. Test a small swap via frontend/script");
        console.log("  4. Announce resumption to users");
        console.log("===========================================");
    }

    /**
     * @dev Tests that computeFeeUpdate does NOT revert with EnforcedPause
     *      It may still revert for other reasons (invalid ratio, etc.) but
     *      the pause check should pass.
     */
    function _testComputeFeeUpdateDoesNotRevertWithPause(Alphix alphix) internal view returns (bool) {
        // Try with a valid ratio - if pool is configured, this should work
        // or revert with a non-pause error
        try alphix.computeFeeUpdate(1e18) {
            return true; // Works - not paused
        } catch (bytes memory reason) {
            // Check if it's the EnforcedPause error
            // EnforcedPause() selector = 0xd93c0665
            if (reason.length >= 4) {
                bytes4 selector;
                assembly {
                    selector := mload(add(reason, 32))
                }
                // If it reverted with EnforcedPause, that's a failure
                if (selector == Pausable.EnforcedPause.selector) {
                    return false;
                }
            }
            // Reverted with something else (e.g., pool not configured, invalid ratio)
            // That's fine - the pause check passed
            return true;
        }
    }
}
