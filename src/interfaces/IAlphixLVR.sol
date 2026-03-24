// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title IAlphixLVR
 * @notice Interface for the AlphixLVR dynamic fee hook.
 * @dev Multi-pool hook that allows an authorized role to set arbitrary dynamic fees.
 */
interface IAlphixLVR {
    /// @notice Emitted when the fee is updated for a pool.
    /// @param poolId The pool whose fee was updated.
    /// @param newFee The new fee in hundredths of a bip.
    event FeePoked(PoolId indexed poolId, uint24 newFee);

    /// @notice Set the dynamic fee for a pool.
    /// @dev Restricted to FEE_POKER_ROLE via AccessManager. Fee is validated by Uniswap's PoolManager
    ///      (must be <= MAX_LP_FEE = 1,000,000).
    /// @param key The pool key identifying the pool.
    /// @param newFee The new fee in hundredths of a bip.
    function poke(PoolKey calldata key, uint24 newFee) external;

    /// @notice Get the current stored fee for a pool.
    /// @param poolId The pool ID.
    /// @return The current fee in hundredths of a bip.
    function getFee(PoolId poolId) external view returns (uint24);

    /// @notice Pause the hook, preventing `poke()` calls.
    /// @dev Only affects `poke()`. Swaps continue to work with the last set fee.
    ///      Does not affect pool initialization via `afterInitialize`.
    function pause() external;

    /// @notice Unpause the hook, re-enabling `poke()` calls.
    function unpause() external;
}
