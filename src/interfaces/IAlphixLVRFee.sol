// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/**
 * @title IAlphixLVRFee
 * @notice Interface for the AlphixLVRFee dynamic fee hook with protocol fee capture.
 * @dev Multi-pool hook with admin-controlled LP fees AND per-pool hook fees.
 *      Hook fees are taken from swap output as ERC-6909 claims and collected to a treasury.
 */
interface IAlphixLVRFee {
    /// @notice Emitted when the LP fee is updated for a pool.
    event FeePoked(PoolId indexed poolId, uint24 newFee);

    /// @notice Emitted when the hook fee is updated for a pool.
    event HookFeeSet(PoolId indexed poolId, uint24 hookFee);

    /// @notice Emitted when the treasury address is updated.
    event TreasurySet(address treasury);

    /// @notice Set the dynamic LP fee for a pool.
    /// @dev Restricted to FEE_POKER_ROLE via AccessManager.
    /// @param key The pool key identifying the pool.
    /// @param newFee The new LP fee in hundredths of a bip.
    function poke(PoolKey calldata key, uint24 newFee) external;

    /// @notice Set the hook fee (protocol fee) for a pool.
    /// @dev Restricted via AccessManager. Fee is taken from swap output as ERC-6909 claims.
    ///      Set to 0 to disable hook fee for a pool.
    /// @param key The pool key identifying the pool.
    /// @param hookFee The hook fee in hundredths of a bip (1,000,000 = 100%).
    function setHookFee(PoolKey calldata key, uint24 hookFee) external;

    /// @notice Set the treasury address where collected fees are sent.
    /// @dev Restricted via AccessManager.
    /// @param treasury The new treasury address.
    function setTreasury(address treasury) external;

    /// @notice Collect accumulated hook fees (ERC-6909 claims) and transfer to treasury.
    /// @param currencies The currencies to collect fees for.
    function handleHookFees(Currency[] memory currencies) external;

    /// @notice Get the current stored LP fee for a pool.
    function getFee(PoolId poolId) external view returns (uint24);

    /// @notice Get the current stored hook fee for a pool.
    function getHookFee(PoolId poolId) external view returns (uint24);

    /// @notice Pause the hook, preventing `poke()` and `setHookFee()` calls.
    /// @dev Only affects admin functions. Swaps continue with the last set fees.
    function pause() external;

    /// @notice Unpause the hook, re-enabling admin functions.
    function unpause() external;
}
