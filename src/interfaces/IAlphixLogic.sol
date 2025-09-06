// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title IAlphixLogic.
 * @notice Interface for the Alphix Hook logic.
 * @dev Defines the external API for the upgradeable Hook logic.
 */
interface IAlphixLogic {
    /* ERRORS */

    error InvalidLogicContract();
    error InvalidCaller();

    /* CORE FUNCTIONS */

    /**
     * @notice Getter for the fee of a given pool.
     * @param key The key of the pool to retrieve the fee of.
     * @return The fee of the given pool.
     */
    function getFee(PoolKey calldata key) external view returns (uint24);

    function getFee() external view returns (uint24);

    /* HOOK ENTRY POINTS */

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
}
