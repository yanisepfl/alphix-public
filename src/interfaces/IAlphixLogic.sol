// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/* LOCAL IMPORTS */
import {DynamicFeeLib} from "../libraries/DynamicFee.sol";

/**
 * @title IAlphixLogic.
 * @notice Interface for the Alphix Hook logic.
 * @dev Defines the external API for the upgradeable Hook logic.
 */
interface IAlphixLogic {
    /* ENUMS */

    enum PoolType {
        STABLE,
        STANDARD,
        VOLATILE
    }

    /* STRUCTS */

    struct PoolConfig {
        uint24 initialFee;
        uint256 initialTargetRatio;
        PoolType poolType;
        bool isConfigured;
    }

    /* EVENTS */

    /**
     * @dev Emitted at every pool type params change.
     * @param poolType The pool type to change bounds of.
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
    event PoolTypeParamsUpdated(
        PoolType indexed poolType,
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
     * @dev Thrown when the implementation of the logic contract is invalid.
     */
    error InvalidLogicContract();

    /**
     * @dev Thrown when the caller is not as expected.
     */
    error InvalidCaller();

    /**
     * @dev Thrown when a pool is paused.
     */
    error PoolPaused();

    /**
     * @dev Thrown when a pool is already configured.
     */
    error PoolAlreadyConfigured();

    /**
     * @dev Thrown when a pool is not configured.
     */
    error PoolNotConfigured();

    /**
     * @dev Thrown when fee bounds are invalid.
     */
    error InvalidFeeBounds(uint24 minFee, uint24 maxFee);

    /**
     * @dev Thrown when another parameter than fee bounds is invalid.
     */
    error InvalidParameter();

    /**
     * @dev Thrown when an invalid address (e.g. 0) is provided.
     */
    error InvalidAddress();

    /**
     * @dev Thrown when the time elapsed since the pool's last fee update happened is less than minPeriod.
     */
    error CooldownNotElapsed(PoolId poolId, uint256 nextEligibleTimestamp, uint256 minPeriod);

    /**
     * @dev Thrown when an invalid fee is provided for a given pool type.
     */
    error InvalidFeeForPoolType(PoolType poolType, uint24 fee);

    /**
     * @dev Thrown when an invalid ratio is provided for a given pool type.
     */
    error InvalidRatioForPoolType(PoolType poolType, uint256 ratio);

    /* CORE HOOK LOGIC */

    /**
     * @notice The hook called before the state of a pool is initialized.
     * @param sender The initial msg.sender for the initialize call.
     * @param key The key for the pool being initialized.
     * @param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96.
     * @return bytes4 The function selector for the hook
     */
    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);

    /**
     * @notice The hook called after the state of a pool is initialized.
     * @param sender The initial msg.sender for the initialize call.
     * @param key The key for the pool being initialized.
     * @param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96.
     * @param tick The current tick after the state of a pool is initialized.
     * @return bytes4 The function selector for the hook.
     */
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4);

    /**
     * @notice The hook called before liquidity is added.
     * @param sender The initial msg.sender for the add liquidity call.
     * @param key The key for the pool.
     * @param params The parameters for adding liquidity.
     * @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     */
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);

    /**
     * @notice The hook called before liquidity is removed.
     * @param sender The initial msg.sender for the remove liquidity call.
     * @param key The key for the pool.
     * @param params The parameters for removing liquidity.
     * @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     */
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4);

    /**
     * @notice The hook called after liquidity is added.
     * @param sender The initial msg.sender for the add liquidity call.
     * @param key The key for the pool.
     * @param params The parameters for adding liquidity.
     * @param delta The caller's balance delta after adding liquidity; the sum of principal delta, fees accrued, and hook delta.
     * @param feesAccrued The fees accrued since the last time fees were collected from this position.
     * @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     * @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency.
     */
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    /**
     * @notice The hook called after liquidity is removed.
     * @param sender The initial msg.sender for the remove liquidity call.
     * @param key The key for the pool.
     * @param params The parameters for removing liquidity.
     * @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta.
     * @param feesAccrued The fees accrued since the last time fees were collected from this position.
     * @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     * @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency.
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4, BalanceDelta);

    /**
     * @notice The hook called before a swap.
     * @param sender The initial msg.sender for the swap call.
     * @param key The key for the pool.
     * @param params The parameters for the swap.
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     * @return BeforeSwapDelta The hook's delta in specified and unspecified currencies. Positive: the hook is owed/took currency, negative: the hook owes/sent currency.
     * @return uint24 Optionally override the lp fee, only used if three conditions are met: 1. the Pool has a dynamic fee, 2. the value's 2nd highest bit is set (23rd bit, 0x400000), and 3. the value is less than or equal to the maximum fee (1 million).
     */
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24);

    /**
     * @notice The hook called after a swap.
     * @param sender The initial msg.sender for the swap call.
     * @param key The key for the pool.
     * @param params The parameters for the swap.
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative).
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     * @return int128 The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency.
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128);

    /**
     * @notice The hook called before a donation.
     * @param sender The initial msg.sender for the donate call.
     * @param key The key for the pool.
     * @param amount0 The amount of token0 being donated.
     * @param amount1 The amount of token1 being donated.
     * @param hookData Arbitrary data handed into the PoolManager by the donator to be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     */
    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);

    /**
     * @notice The hook called after a donation.
     * @param sender The initial msg.sender for the donate call.
     * @param key The key for the pool.
     * @param amount0 The amount of token0 being donated.
     * @param amount1 The amount of token1 being donated.
     * @param hookData Arbitrary data handed into the PoolManager by the donator to be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     */
    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external returns (bytes4);

    /**
     * @notice Activate pool and configure it with initial parameters.
     * @param key The key of the pool to activate and configure.
     * @param _initialFee The initial fee of the pool to configure.
     * @param _initialTargetRatio The initial target ratio of the pool to configure.
     * @param _poolType The pool type of the pool to configure.
     */
    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        PoolType _poolType
    ) external;

    /**
     * @notice Deactivate pool.
     * @param key The key of the pool to activate.
     */
    function activatePool(PoolKey calldata key) external;

    /**
     * @notice Deactivate pool.
     * @param key The key of the pool to deactivate.
     */
    function deactivatePool(PoolKey calldata key) external;

    /**
     * @notice Set per-pool type params.
     * @param poolType The pool type to set params to.
     * @param params The parameters to set.
     */
    function setPoolTypeParams(PoolType poolType, DynamicFeeLib.PoolTypeParams calldata params) external;

    /**
     * @notice Set the global max adjustment rate (common to all pools).
     * @param _globalMaxAdjRate The global max adjustment rate to set.
     */
    function setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) external;

    /* GETTERS */

    /**
     * @notice Get the Alphix Hook address.
     * @return hookAddress The address of the main Alphix hook contract.
     */
    function getAlphixHook() external view returns (address hookAddress);

    /**
     * @notice Compute the new fee and target ratio of a given pool given its current ratio.
     * @param key The key of the pool.
     * @param currentRatio The current ratio of the pool.
     * @return newFee The new fee of the pool.
     * @return oldTargetRatio The old target ratio of the pool.
     * @return newTargetRatio The new target ratio of the pool.
     * @return sOut The OobState of the pool.
     */
    function computeFeeAndTargetRatio(PoolKey calldata key, uint256 currentRatio)
        external
        view
        returns (uint24 newFee, uint256 oldTargetRatio, uint256 newTargetRatio, DynamicFeeLib.OobState memory sOut);

    /**
     * @notice Store new values right after a fee update.
     * @param key The key of the pool.
     * @param newTargetRatio The new target ratio of the pool.
     * @param sOut The OobState of the pool.
     * @return targetRatioAfterUpdate The target ratio after the update.
     */
    function finalizeAfterFeeUpdate(PoolKey calldata key, uint256 newTargetRatio, DynamicFeeLib.OobState calldata sOut)
        external
        returns (uint256 targetRatioAfterUpdate);

    /**
     * @notice Get pool config for a specific pool.
     * @param poolId The pool ID of the pool to get configs for.
     * @return poolConfig The configs for the given pool.
     */
    function getPoolConfig(PoolId poolId) external view returns (PoolConfig memory poolConfig);

    /**
     * @notice Get parameters of a specific pool type.
     * @param poolType The pool type to get parameters of.
     * @return params The parameters of the pool type.
     */
    function getPoolTypeParams(PoolType poolType) external view returns (DynamicFeeLib.PoolTypeParams memory params);

    /**
     * @notice Get the global max adjustment rate (common to all pools).
     * @return The global max adjustment rate.
     */
    function getGlobalMaxAdjRate() external view returns (uint256);
}
