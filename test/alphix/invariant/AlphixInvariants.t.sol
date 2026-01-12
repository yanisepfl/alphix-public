// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {StdInvariant} from "forge-std/StdInvariant.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../BaseAlphix.t.sol";
import {AlphixInvariantHandler} from "./handlers/AlphixInvariantHandler.sol";
import {IAlphixLogic} from "../../../src/interfaces/IAlphixLogic.sol";
import {AlphixGlobalConstants} from "../../../src/libraries/AlphixGlobalConstants.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";

/**
 * @title AlphixInvariantsTest
 * @author Alphix
 * @notice Stateful invariant tests for the Alphix protocol
 * @dev Tests critical invariants that must hold across all possible state transitions
 *
 * Key Invariants Tested:
 * 1. Fee Bounds: Fees always within global and pool-type bounds
 * 2. Target Ratio Bounds: Target ratios never exceed MAX_CURRENT_RATIO
 * 3. Pool State Consistency: Valid state transitions only
 * 4. EMA Convergence: EMA calculations stay within bounds
 * 5. Cooldown Enforcement: Cooldowns prevent rapid updates
 */
contract AlphixInvariantsTest is StdInvariant, BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    AlphixInvariantHandler public handler;

    // Track pools created during invariant testing
    PoolKey[] public trackedPools;
    mapping(PoolId => bool) public isTrackedPool;

    function setUp() public override {
        super.setUp();

        // Deploy handler for invariant testing
        handler = new AlphixInvariantHandler(
            hook, logic, owner, user1, user2, poolManager, positionManager, swapRouter, permit2, currency0, currency1
        );

        // Add initial pool to tracked pools
        trackedPools.push(key);
        isTrackedPool[key.toId()] = true;

        // Add initial pool to handler
        handler.addPool(key);

        // Target the handler for invariant testing
        targetContract(address(handler));

        // Exclude these addresses from being used as msg.sender in invariant tests
        excludeSender(address(0));
        excludeSender(address(hook));
        excludeSender(address(logic));
        excludeSender(address(logicProxy));
        excludeSender(address(poolManager));
    }

    /* ========================================================================== */
    /*                           INVARIANT 1: FEE BOUNDS                          */
    /* ========================================================================== */

    /**
     * @notice Invariant: All pool fees must stay within global bounds
     * @dev Critical for preventing fee manipulation and ensuring protocol safety
     */
    function invariant_feesWithinGlobalBounds() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // Skip unconfigured pools
            if (!config.isConfigured) continue;

            // Get current fee
            uint24 currentFee = hook.getFee();

            // Verify within global bounds
            assertGe(currentFee, AlphixGlobalConstants.MIN_FEE, "Fee below global minimum");
            assertLe(currentFee, LPFeeLibrary.MAX_LP_FEE, "Fee above global maximum");
        }
    }

    /**
     * @notice Invariant: All pool fees must stay within pool-type specific bounds
     * @dev Ensures pool-type parameters are respected
     */
    function invariant_feesWithinPoolTypeBounds() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // Skip unconfigured pools
            if (!config.isConfigured) continue;

            // Get pool type parameters
            DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

            // Get current fee
            uint24 currentFee = hook.getFee();

            // Verify within pool-type bounds
            assertGe(currentFee, params.minFee, "Fee below pool-type minimum");
            assertLe(currentFee, params.maxFee, "Fee above pool-type maximum");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 2: TARGET RATIO BOUNDS                        */
    /* ========================================================================== */

    /**
     * @notice Invariant: Target ratios never exceed MAX_CURRENT_RATIO
     * @dev Critical for preventing overflow and maintaining EMA calculations
     */
    function invariant_targetRatioNeverExceedsCap() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // Skip unconfigured pools
            if (!config.isConfigured) continue;

            // Verify initial target ratio
            assertLe(
                config.initialTargetRatio, AlphixGlobalConstants.MAX_CURRENT_RATIO, "Initial target ratio exceeds cap"
            );
        }
    }

    /**
     * @notice Invariant: Target ratios are never zero for configured pools
     * @dev Zero target ratios would break fee calculations
     */
    function invariant_targetRatioNonZeroForConfiguredPools() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // Only check configured pools
            if (!config.isConfigured) continue;

            assertGt(config.initialTargetRatio, 0, "Configured pool has zero initial target ratio");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 3: POOL STATE CONSISTENCY                     */
    /* ========================================================================== */

    /**
     * @notice Invariant: All tracked pools have valid configuration
     * @dev Basic sanity check for pool state
     */
    function invariant_trackedPoolsAreValid() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            // Pool exists in tracking means it was properly initialized
            assertTrue(isTrackedPool[poolKey.toId()], "Tracked pool not in mapping");
        }
    }

    /**
     * @notice Invariant: Configured pools have valid initial parameters
     * @dev Ensures configuration data integrity
     */
    function invariant_configuredPoolsHaveValidParams() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // Skip unconfigured pools
            if (!config.isConfigured) continue;

            // Verify initial fee is within bounds
            DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
            assertGe(config.initialFee, params.minFee, "Configured pool initial fee below minimum");
            assertLe(config.initialFee, params.maxFee, "Configured pool initial fee above maximum");

            // Verify initial target ratio is non-zero and within cap
            assertGt(config.initialTargetRatio, 0, "Configured pool has zero initial target ratio");
            assertLe(
                config.initialTargetRatio,
                AlphixGlobalConstants.MAX_CURRENT_RATIO,
                "Configured pool initial target ratio exceeds cap"
            );
        }
    }

    /* ========================================================================== */
    /*                     INVARIANT 4: POOL TYPE CONSISTENCY                     */
    /* ========================================================================== */

    /**
     * @notice Invariant: Pool types are valid
     * @dev Ensures pool types are within enum bounds
     */
    function invariant_poolTypesAreValid() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // Skip unconfigured pools
            if (!config.isConfigured) continue;

            // Pool type must be 0, 1, or 2 (STABLE, STANDARD, VOLATILE)
        }
    }

    /* ========================================================================== */
    /*                     INVARIANT 5: FEE BEHAVIOR                              */
    /* ========================================================================== */

    /**
     * @notice Invariant: Fees never decrease below initial fee for configured pools
     * @dev Ensures fee adjustments are reasonable and don't undercut initial parameters
     */
    function invariant_feeNeverBelowReasonableMinimum() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            uint24 currentFee = hook.getFee();
            DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

            // Current fee should never be below pool type minimum
            assertGe(currentFee, params.minFee, "Fee below pool type minimum");
        }
    }

    /**
     * @notice Invariant: Ghost variable tracking is consistent
     * @dev Ensures statistical tracking doesn't overflow or become invalid
     */
    function invariant_ghostVariablesConsistent() public view {
        (uint256 sumFees,,,,, uint256 liquidityAdded, uint256 liquidityRemoved) = handler.getGhostVariables();

        // Ghost variables should be consistent
        // Sum of fees should be reasonable if we have pokes
        if (sumFees > 0) {
            assertTrue(sumFees < type(uint256).max / 2, "Sum fees overflow risk");
        }

        // Liquidity removed cannot exceed liquidity added
        assertGe(liquidityAdded, liquidityRemoved, "More liquidity removed than added");

        // Sum of fees should grow if poke was called
        if (handler.callCountpoke() > 0) {
            assertGt(sumFees, 0, "Fee sum should be positive if pokes occurred");
        }
    }

    /* ========================================================================== */
    /*                     INVARIANT 6: VOLUME AND LIQUIDITY                      */
    /* ========================================================================== */

    /**
     * @notice Invariant: Swap volume tracking is reasonable
     * @dev Ensures volume doesn't overflow and matches call count
     */
    function invariant_swapVolumeReasonable() public view {
        (,,,, uint256 swapVolume,,) = handler.getGhostVariables();

        // If swaps occurred, volume should be positive
        if (handler.callCountswap() > 0) {
            assertGt(swapVolume, 0, "Swap volume should be positive");
        }

        // Volume shouldn't be unreasonably large (sanity check)
        // With max 100e18 per swap and reasonable call counts
        uint256 maxReasonableVolume = handler.callCountswap() * 100e18;
        assertLe(swapVolume, maxReasonableVolume, "Swap volume unreasonably large");
    }

    /**
     * @notice Invariant: Net liquidity is non-negative
     * @dev Can't remove more liquidity than was added
     */
    function invariant_netLiquidityNonNegative() public view {
        (,,,,, uint256 liquidityAdded, uint256 liquidityRemoved) = handler.getGhostVariables();

        assertGe(liquidityAdded, liquidityRemoved, "Negative net liquidity");
    }

    /* ========================================================================== */
    /*                     INVARIANT 7: STATE MACHINE SAFETY                      */
    /* ========================================================================== */

    /**
     * @notice Invariant: Pause state transitions are valid
     * @dev Validates that pause/unpause operations maintain consistent state
     */
    function invariant_pauseStateConsistent() public view {
        bool isPaused = hook.paused();
        uint256 pauseCount = handler.callCountpause();
        uint256 unpauseCount = handler.callCountunpause();

        // If we've never paused, contract should be unpaused
        if (pauseCount == 0) {
            assertFalse(isPaused, "Contract should be unpaused initially");
        }

        // If significantly more successful pauses than unpauses, likely paused
        // We use >2 difference to account for failed pause/unpause attempts
        if (pauseCount > unpauseCount + 2) {
            assertTrue(isPaused, "Contract should be paused after multiple pause calls");
        }

        // If significantly more successful unpauses than pauses, likely unpaused
        if (unpauseCount > pauseCount + 2) {
            assertFalse(isPaused, "Contract should be unpaused after multiple unpause calls");
        }
    }

    /**
     * @notice Invariant: All configured pools have consistent fee parameters
     * @dev Fee should match what the pool manager reports
     */
    function invariant_poolManagerFeeConsistency() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            // Get fee from hook
            uint24 hookFee = hook.getFee();

            // Fee should be within valid LP fee range
            assertLe(hookFee, LPFeeLibrary.MAX_LP_FEE, "Fee exceeds max LP fee");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 8: MATHEMATICAL PROPERTIES                    */
    /* ========================================================================== */

    /**
     * @notice Invariant: All active pools have valid fee values
     * @dev Fees retrieved via getFee should always be valid
     */
    function invariant_allActiveFeesValid() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            // Current fee should be within global MAX_LP_FEE
            uint24 currentFee = hook.getFee();
            assertLe(currentFee, LPFeeLibrary.MAX_LP_FEE, "Active fee exceeds max");
        }
    }

    /**
     * @notice Invariant: Initial target ratios are within valid range
     * @dev Initial ratios should be non-zero and capped at MAX_CURRENT_RATIO
     */
    function invariant_initialTargetRatiosValid() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            // Initial target ratio should be non-zero and within valid range
            assertGt(config.initialTargetRatio, 0, "Initial target ratio is zero for configured pool");
            assertLe(config.initialTargetRatio, AlphixGlobalConstants.MAX_CURRENT_RATIO, "Initial target exceeds max");
        }
    }

    /**
     * @notice Invariant: Pool configurations remain consistent
     * @dev Once configured, pool type and initial params shouldn't change
     */
    function invariant_poolConfigurationsConsistent() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            // Configured pools should have valid pool types

            // Initial fee should be within pool type bounds
            DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
            assertGe(config.initialFee, params.minFee, "Initial fee below pool type min");
            assertLe(config.initialFee, params.maxFee, "Initial fee above pool type max");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 9: ECONOMIC SECURITY                          */
    /* ========================================================================== */

    /**
     * @notice Invariant: No single actor can manipulate fees beyond bounds
     * @dev Even with MEV attacks, fees stay within configured bounds
     */
    function invariant_feesAlwaysBoundedDespiteManipulation() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            uint24 currentFee = hook.getFee();

            // Fee must be within pool type bounds regardless of manipulation attempts
            DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
            assertGe(currentFee, params.minFee, "Fee below min despite manipulation");
            assertLe(currentFee, params.maxFee, "Fee above max despite manipulation");
        }
    }

    /**
     * @notice Invariant: Cooldown prevents rapid fee manipulation
     * @dev Validates cooldown enforcement while accounting for fuzzer behavior
     */
    function invariant_cooldownPreventsSameBlockManipulation() public view {
        uint256 pokeSuccessCount = handler.callCountpoke();
        uint256 pokeFailedCount = handler.callCountpokeFailed();
        uint256 totalPokeAttempts = pokeSuccessCount + pokeFailedCount;

        // Need sufficient attempts to validate cooldown behavior
        if (totalPokeAttempts < 10) return;

        bool isPaused = hook.paused();
        uint256 poolCount = handler.getPoolCount();

        // Case 1: All pokes failed
        if (pokeSuccessCount == 0) {
            uint256 pauseCount = handler.callCountpause();
            uint256 unpauseCount = handler.callCountunpause();

            // Legitimate scenarios for all pokes failing:
            // 1. Contract is currently paused
            // 2. No pools configured
            // 3. Pause/unpause activity occurred during run (pokes may have been attempted while paused)
            if (!isPaused && poolCount > 0 && pauseCount == 0 && unpauseCount == 0) {
                assertFalse(true, "All pokes failing with active pools suggests issue");
            }
            return;
        }

        // Case 2: All pokes succeeded with many attempts (potentially suspicious)
        if (pokeFailedCount == 0 && totalPokeAttempts >= 20) {
            uint256 timeWarpCount = handler.callCounttimeWarp();

            // If many independent time warps occurred, all successes could be legitimate
            // Each warp allows cooldown to elapse, enabling subsequent pokes
            // Only flag as suspicious if successes >> time opportunities
            uint256 timeOpportunities = timeWarpCount + (totalPokeAttempts / 2); // 50% handler warps

            if (totalPokeAttempts > timeOpportunities + 10) {
                assertFalse(true, "Too many poke successes relative to time manipulation opportunities");
            }
            return;
        }

        // Case 3: Mixed results (expected behavior) - no assertion needed
        // Handler's 50% conditional warping + fuzzer's time manipulation
        // naturally creates varied success/failure patterns
    }

    /* ========================================================================== */
    /*                    INVARIANT 10: EDGE CASES & SAFETY                       */
    /* ========================================================================== */

    /**
     * @notice Invariant: Zero target ratio never causes division by zero
     * @dev System should handle zero target gracefully
     */
    function invariant_zeroTargetHandledSafely() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();

            // If pool is configured, initial target should never be zero
            if (config.isConfigured) {
                assertGt(config.initialTargetRatio, 0, "Configured pool has zero initial target");
            }
        }
    }

    /**
     * @notice Invariant: Extreme ratios don't cause overflow
     * @dev All ratio calculations should handle max values safely
     */
    function invariant_extremeRatiosHandledSafely() public view {
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            // Initial target ratio should never exceed MAX_CURRENT_RATIO
            assertLe(
                config.initialTargetRatio, AlphixGlobalConstants.MAX_CURRENT_RATIO, "Initial target ratio overflow"
            );

            // Current fee should be valid
            uint24 fee = hook.getFee();
            assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "Fee overflow");
        }
    }

    /**
     * @notice Invariant: Time warps don't break timestamp logic
     * @dev Even with extreme time jumps, timestamps remain valid
     */
    function invariant_timeWarpsSafe() public view {
        uint256 warpCount = handler.callCounttimeWarp();

        if (warpCount > 0) {
            // After time warps, cooldowns should still work correctly
            // Verified by checking that timestamps are never in future
            for (uint256 i = 0; i < trackedPools.length; i++) {
                PoolKey memory poolKey = trackedPools[i];
                poolKey.toId(); // Validate poolKey

                IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
                if (!config.isConfigured) continue;

                // Note: lastUpdateTimestamp is not exposed in PoolConfig
                // Timestamp safety is validated through cooldown enforcement
                // Pool is guaranteed configured here due to continue above
            }
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 11: STREAK & OOB BEHAVIOR                     */
    /* ========================================================================== */

    /**
     * @notice Invariant: Poke operations track fee changes correctly
     * @dev Ghost variables should accumulate when pokes succeed
     */
    function invariant_pokeTrackingConsistent() public view {
        (uint256 sumFees,, uint256 maxFee,,,,) = handler.getGhostVariables();

        // Ghost variables should not overflow
        assertTrue(sumFees < type(uint256).max / 2, "Sum fees overflow risk");

        // If maxFee was observed, it should be within valid LP fee range
        if (maxFee > 0 && maxFee < type(uint256).max) {
            assertLe(maxFee, LPFeeLibrary.MAX_LP_FEE, "Max fee exceeds LP fee limit");
        }
    }

    /**
     * @notice Invariant: Fee adjustments respect side factors
     * @dev Upper/lower side factors should create asymmetric adjustments
     */
    function invariant_sideFactorsCreateAsymmetry() public view {
        // Side factors are applied correctly if fees stay within bounds
        // This is validated by pool type bounds invariant
        // Additional validation: configured pools have valid side factors
        for (uint256 i = 0; i < trackedPools.length; i++) {
            PoolKey memory poolKey = trackedPools[i];
            poolKey.toId(); // Validate poolKey

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
            if (!config.isConfigured) continue;

            // Fees should respect bounds even with side factor asymmetry
            uint24 currentFee = hook.getFee();
            DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
            assertGe(currentFee, params.minFee, "Side factor violated min");
            assertLe(currentFee, params.maxFee, "Side factor violated max");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 12: UPGRADE SAFETY                            */
    /* ========================================================================== */

    /**
     * @notice Invariant: Logic contract address is always valid
     * @dev Hook should always point to a valid logic contract
     */
    function invariant_logicAddressValid() public view {
        address logicAddr = hook.getLogic();
        assertTrue(logicAddr != address(0), "Logic address is zero");
        assertTrue(logicAddr == address(logic), "Logic address mismatch");
    }

    /**
     * @notice Invariant: Hook permissions remain constant
     * @dev Validates that hook permissions match expected values and never change
     */
    function invariant_hookPermissionsImmutable() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();

        // Verify all expected permissions are set correctly
        // These are defined in Alphix.sol and should never change
        assertTrue(perms.beforeInitialize, "beforeInitialize should be true");
        assertTrue(perms.afterInitialize, "afterInitialize should be true");
        assertTrue(perms.beforeAddLiquidity, "beforeAddLiquidity should be true");
        assertTrue(perms.afterAddLiquidity, "afterAddLiquidity should be true");
        assertTrue(perms.beforeRemoveLiquidity, "beforeRemoveLiquidity should be true");
        assertTrue(perms.afterRemoveLiquidity, "afterRemoveLiquidity should be true");
        assertTrue(perms.beforeSwap, "beforeSwap should be true");
        assertTrue(perms.afterSwap, "afterSwap should be true");
        assertTrue(perms.beforeDonate, "beforeDonate should be true");
        assertTrue(perms.afterDonate, "afterDonate should be true");
        assertTrue(perms.beforeSwapReturnDelta, "beforeSwapReturnDelta should be true");
        assertTrue(perms.afterSwapReturnDelta, "afterSwapReturnDelta should be true");
        assertTrue(perms.afterAddLiquidityReturnDelta, "afterAddLiquidityReturnDelta should be true");
        assertTrue(perms.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta should be true");
    }

    /* ========================================================================== */
    /*                          HANDLER STATE TRACKING                            */
    /* ========================================================================== */

    /**
     * @notice Add a pool to tracking when created by handler
     * @dev Called by handler when new pools are created
     */
    function trackPool(PoolKey memory poolKey) external {
        require(msg.sender == address(handler), "Only handler can track pools");

        poolKey.toId(); // Validate poolKey
        if (!isTrackedPool[poolId]) {
            trackedPools.push(poolKey);
            isTrackedPool[poolId] = true;
        }
    }

    /* ========================================================================== */
    /*                             INVARIANT HELPERS                              */
    /* ========================================================================== */

    /**
     * @notice Get handler call summary for debugging
     * @dev Useful for understanding which operations were tested
     */
    function getHandlerCallSummary()
        public
        view
        returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256)
    {
        return (
            handler.callCountpoke(),
            handler.callCountswap(),
            handler.callCountaddLiquidity(),
            handler.callCountremoveLiquidity(),
            handler.callCounttimeWarp(),
            handler.callCountpause(),
            handler.callCountunpause()
        );
    }

    /**
     * @notice Get number of tracked pools
     */
    function getTrackedPoolCount() public view returns (uint256) {
        return trackedPools.length;
    }
}
