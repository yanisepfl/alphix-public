// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {DynamicFeeLib} from "../libraries/DynamicFee.sol";

/**
 * @title IAlphixLogic.
 * @notice Interface for the Alphix Hook logic.
 * @dev Defines the external API for the upgradeable Hook logic.
 */
interface IAlphixLogic {
    /* STRUCTS */

    struct PoolConfig {
        // slot 0
        uint24 initialFee;
        bool isConfigured;
        // slot 1
        uint256 initialTargetRatio;
    }

    /**
     * @notice Parameters for JIT liquidity modification.
     * @param tickLower Lower tick boundary for liquidity position.
     * @param tickUpper Upper tick boundary for liquidity position.
     * @param liquidityDelta Positive to add liquidity, negative to remove.
     * @param shouldExecute Whether to execute the modifyLiquidity call.
     */
    struct JitParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bool shouldExecute;
    }

    /* EVENTS */

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
     * @dev Thrown when an invalid fee is provided (outside pool params bounds).
     */
    error InvalidFee(uint24 fee);

    /**
     * @dev Thrown when an invalid ratio is provided (outside pool params bounds).
     */
    error InvalidRatio(uint256 ratio);

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
     * @return JitParams JIT liquidity parameters for Alphix to execute (add liquidity).
     */
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4, BeforeSwapDelta, uint24, JitParams memory);

    /**
     * @notice The hook called after a swap.
     * @param sender The initial msg.sender for the swap call.
     * @param key The key for the pool.
     * @param params The parameters for the swap.
     * @param delta The amount owed to the caller (positive) or owed to the pool (negative).
     * @param hookData Arbitrary data handed into the PoolManager by the swapper to be be passed on to the hook.
     * @return bytes4 The function selector for the hook.
     * @return int128 The hook's delta in unspecified currency. Positive: the hook is owed/took currency, negative: the hook owes/sent currency.
     * @return JitParams JIT liquidity parameters for Alphix to execute (remove liquidity).
     */
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128, JitParams memory);

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

    /* JIT LIQUIDITY (Flash Accounting Pattern) */

    /**
     * @notice Deposit tokens to yield source after receiving from PoolManager.
     * @dev Called by Alphix hook when hook has positive currencyDelta (is owed tokens).
     *      Tokens have already been transferred to Logic by PoolManager via take().
     *      For ETH pools: currency0 arrives as ETH, Logic wraps to WETH before depositing.
     * @param currency The currency to deposit.
     * @param amount The amount to deposit.
     */
    function depositToYieldSource(Currency currency, uint256 amount) external;

    /**
     * @notice Withdraw from yield source and approve/transfer for settlement.
     * @dev Called by Alphix hook when hook has negative currencyDelta (owes tokens).
     *      For ERC20: withdraw from yield source and approve PoolManager.
     *      For ETH: withdraw WETH, unwrap to ETH, send to hook (for settle).
     * @param currency The currency to withdraw and prepare for settlement.
     * @param amount The amount to withdraw.
     */
    function withdrawAndApprove(Currency currency, uint256 amount) external;

    /**
     * @notice Activate pool and configure it with initial parameters.
     * @param key The key of the pool to activate and configure.
     * @param _initialFee The initial fee of the pool to configure.
     * @param _initialTargetRatio The initial target ratio of the pool to configure.
     * @param _poolParams The pool parameters (bounds, algorithm knobs, side factors).
     */
    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        DynamicFeeLib.PoolParams calldata _poolParams
    ) external;

    /**
     * @notice Activate the pool (mark as initialized).
     */
    function activatePool() external;

    /**
     * @notice Deactivate the pool (mark as not initialized).
     */
    function deactivatePool() external;

    /**
     * @notice Compute what a poke would produce without any state changes.
     * @dev Useful for dry-run simulations, UI previews, or off-chain tooling.
     *      Does NOT check cooldown - that's only enforced in poke().
     *      NOTE: This function CAN still revert on:
     *        - InvalidRatio: if currentRatio is 0 or exceeds pool's maxCurrentRatio
     *        - InvalidRatio: if computed newTargetRatio is 0 (edge case)
     *      Unlike poke(), it does NOT check PoolPaused, PoolNotConfigured, or CooldownNotElapsed.
     * @param currentRatio The current ratio observed for this pool.
     * @return newFee The computed new fee that would be applied.
     * @return oldFee The current fee before the update.
     * @return oldTargetRatio The target ratio before the update.
     * @return newTargetRatio The target ratio after the update.
     * @return newOobState The new out-of-bounds state after the update.
     */
    function computeFeeUpdate(uint256 currentRatio)
        external
        view
        returns (
            uint24 newFee,
            uint24 oldFee,
            uint256 oldTargetRatio,
            uint256 newTargetRatio,
            DynamicFeeLib.OobState memory newOobState
        );

    /**
     * @notice Compute and apply a fee update for the pool.
     * @dev This is the main entry point for fee updates. It encapsulates all algorithm-specific
     *      logic (fee computation, EMA updates, OOB state tracking, cooldown checks) internally,
     *      treating AlphixLogic as a black box from Alphix's perspective.
     * @param currentRatio The current ratio observed for this pool.
     * @return newFee The computed new fee to be applied.
     * @return oldFee The previous fee before this update.
     * @return oldTargetRatio The target ratio before this update.
     * @return newTargetRatio The target ratio after this update.
     */
    function poke(uint256 currentRatio)
        external
        returns (uint24 newFee, uint24 oldFee, uint256 oldTargetRatio, uint256 newTargetRatio);

    /**
     * @notice Set pool params for the single pool.
     * @param params The parameters to set.
     */
    function setPoolParams(DynamicFeeLib.PoolParams calldata params) external;

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
     * @notice Get the pool key this contract serves.
     * @return poolKey The pool key.
     */
    function getPoolKey() external view returns (PoolKey memory poolKey);

    /**
     * @notice Check if the pool has been activated.
     * @return isActivated True if the pool has been activated.
     */
    function isPoolActivated() external view returns (bool isActivated);

    /**
     * @notice Get pool config.
     * @return poolConfig The configs for the pool.
     */
    function getPoolConfig() external view returns (PoolConfig memory poolConfig);

    /**
     * @notice Get the pool ID this contract serves.
     * @return poolId The pool ID.
     */
    function getPoolId() external view returns (PoolId poolId);

    /**
     * @notice Get pool parameters.
     * @return params The pool parameters.
     */
    function getPoolParams() external view returns (DynamicFeeLib.PoolParams memory params);

    /**
     * @notice Get the global max adjustment rate (common to all pools).
     * @return The global max adjustment rate.
     */
    function getGlobalMaxAdjRate() external view returns (uint256);
}
