// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/* LOCAL IMPORTS */
import {DynamicFeeLib} from "../libraries/DynamicFee.sol";

/**
 * @title IAlphix.
 * @notice Interface for the Alphix Uniswap v4 Dynamic Fee Hook with JIT liquidity rehypothecation.
 * @dev Single contract combining hook, dynamic fee logic, and rehypothecation.
 *      Each instance serves exactly one pool. Shares are ERC20 tokens.
 */
interface IAlphix {
    /* STRUCTS */

    /**
     * @dev Pool configuration data.
     * @param initialFee The initial fee set during pool initialization.
     * @param initialTargetRatio The initial target ratio set during pool initialization.
     * @param isConfigured Whether the pool has been configured.
     */
    struct PoolConfig {
        uint24 initialFee;
        uint256 initialTargetRatio;
        bool isConfigured;
    }

    /* EVENTS */

    /**
     * @dev Emitted at every fee change.
     * @param poolId The pool identifier.
     * @param oldFee The previous fee value.
     * @param newFee The new fee value.
     * @param oldTargetRatio The previous target ratio used for the fee computation.
     * @param currentRatio The observed ratio input used for this update.
     * @param newTargetRatio The updated target ratio after applying the algorithm.
     */
    event FeeUpdated(
        PoolId indexed poolId,
        uint24 oldFee,
        uint24 newFee,
        uint256 oldTargetRatio,
        uint256 currentRatio,
        uint256 newTargetRatio
    );

    /**
     * @dev Emitted upon pool configuration.
     * @param poolId The pool ID of the pool that has been configured.
     * @param initialFee The initial fee of the pool that has been configured.
     * @param initialTargetRatio The initial target ratio of the pool that has been configured.
     */
    event PoolConfigured(PoolId indexed poolId, uint24 initialFee, uint256 initialTargetRatio);

    /**
     * @dev Emitted when pool params are updated.
     * @param minFee The min fee value.
     * @param maxFee The max fee value.
     * @param baseMaxFeeDelta The maximum fee delta per streak hit (expressed as uint24).
     * @param lookbackPeriod The lookbackPeriod to consider for the EMA smoothing factor (expressed in days).
     * @param minPeriod The minimum period between 2 fee updates (expressed in s).
     * @param ratioTolerance The tolerated difference in ratio between current and target ratio to not be considered out of bounds.
     * @param linearSlope The linear slope to consider for the dynamic fee algorithm.
     * @param maxCurrentRatio The maximum allowed current ratio (to avoid extreme outliers).
     * @param lowerSideFactor The downward multiplier to throttle our dynamic fee algorithm by side.
     * @param upperSideFactor The upward multiplier to throttle our dynamic fee algorithm by side.
     */
    event PoolParamsUpdated(
        uint24 minFee,
        uint24 maxFee,
        uint24 baseMaxFeeDelta,
        uint24 lookbackPeriod,
        uint256 minPeriod,
        uint256 ratioTolerance,
        uint256 linearSlope,
        uint256 maxCurrentRatio,
        uint256 lowerSideFactor,
        uint256 upperSideFactor
    );

    /**
     * @dev Emitted at every global max adjustment rate change.
     * @param oldGlobalMaxAdjRate The old global max adjustment rate.
     * @param newGlobalMaxAdjRate The new global max adjustment rate.
     */
    event GlobalMaxAdjRateUpdated(uint256 oldGlobalMaxAdjRate, uint256 newGlobalMaxAdjRate);

    /* ERRORS */

    /**
     * @dev Thrown when an invalid address (e.g. 0) is provided.
     */
    error InvalidAddress();

    /**
     * @dev Thrown when the pool is paused or not activated.
     */
    error PoolPaused();

    /**
     * @dev Thrown when a pool is already configured.
     */
    error PoolAlreadyConfigured();

    /**
     * @dev Thrown when pool initialization is attempted on an already initialized pool.
     */
    error PoolAlreadyInitialized();

    /**
     * @dev Thrown when a pool is not configured.
     */
    error PoolNotConfigured();

    /**
     * @dev Thrown when fee bounds are invalid.
     */
    error InvalidFeeBounds(uint24 minFee, uint24 maxFee);

    /**
     * @dev Thrown when initial fee is outside the configured pool params bounds.
     */
    error InvalidInitialFee(uint24 fee, uint24 minFee, uint24 maxFee);

    /**
     * @dev Thrown when another parameter than fee bounds is invalid.
     */
    error InvalidParameter();

    /**
     * @dev Thrown when the time elapsed since the pool's last fee update is less than minPeriod.
     */
    error CooldownNotElapsed(uint256 currentTimestamp, uint256 nextEligibleTimestamp);

    /**
     * @dev Thrown when an invalid ratio is provided (outside pool params bounds).
     */
    error InvalidCurrentRatio(uint256 ratio);

    /**
     * @dev Thrown when ETH is sent to a non-ETH pool.
     */
    error UnexpectedETH();

    /* ADMIN FUNCTIONS */

    /**
     * @notice Initialize pool by activating and configuring it, and sets its initial fee.
     * @param key The key of the pool to initialize.
     * @param _initialFee The initial fee of the pool to initialize.
     * @param _initialTargetRatio The initial target ratio of the pool to initialize.
     * @param _poolParams The pool parameters for the dynamic fee algorithm.
     */
    function initializePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        DynamicFeeLib.PoolParams calldata _poolParams
    ) external;

    /**
     * @notice Set pool params for the single pool.
     * @param params The parameters to set.
     */
    function setPoolParams(DynamicFeeLib.PoolParams calldata params) external;

    /**
     * @notice Set the global max adjustment rate.
     * @param globalMaxAdjRate_ The global max adjustment rate to set.
     */
    function setGlobalMaxAdjRate(uint256 globalMaxAdjRate_) external;

    /**
     * @notice Pause the contract.
     * @dev Only callable by owner, prevents most contract operations.
     */
    function pause() external;

    /**
     * @notice Unpause the contract.
     * @dev Only callable by owner, restores normal contract operations.
     */
    function unpause() external;

    /* FEE FUNCTIONS */

    /**
     * @notice Compute and apply a fee update for the pool.
     * @dev This is the main entry point for fee updates. Gated by POKER_ROLE via AccessManager.
     * @param currentRatio The current ratio observed for this pool.
     */
    function poke(uint256 currentRatio) external;

    /**
     * @notice Compute what a poke would produce without any state changes.
     * @dev Useful for dry-run simulations, UI previews, or off-chain tooling.
     *      Does NOT check cooldown - that's only enforced in poke().
     * @param currentRatio The current ratio observed for this pool.
     * @return newFee The computed new fee that would be applied.
     * @return newOobState The new out-of-bounds state after the update.
     * @return wouldUpdate Whether the fee would actually update (passes cooldown check).
     */
    function computeFeeUpdate(uint256 currentRatio)
        external
        view
        returns (uint24 newFee, DynamicFeeLib.OobState memory newOobState, bool wouldUpdate);

    /* GETTERS */

    /**
     * @notice Get the pool's current fee.
     * @return fee The current fee of the pool.
     */
    function getFee() external view returns (uint24 fee);

    /**
     * @notice Get the cached pool key.
     * @return The pool key for the single pool this hook serves.
     */
    function getPoolKey() external view returns (PoolKey memory);

    /**
     * @notice Get the cached pool ID.
     * @return The pool ID for the single pool this hook serves.
     */
    function getPoolId() external view returns (PoolId);

    /**
     * @notice Get pool config.
     * @return poolConfig The configs for the pool.
     */
    function getPoolConfig() external view returns (PoolConfig memory poolConfig);

    /**
     * @notice Get pool parameters.
     * @return params The pool parameters.
     */
    function getPoolParams() external view returns (DynamicFeeLib.PoolParams memory params);

    /**
     * @notice Get the global max adjustment rate.
     * @return The global max adjustment rate.
     */
    function getGlobalMaxAdjRate() external view returns (uint256);
}
