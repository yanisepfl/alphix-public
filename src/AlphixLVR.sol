// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/* OZ UNISWAP HOOKS IMPORTS */
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* LOCAL IMPORTS */
import {IAlphixLVR} from "./interfaces/IAlphixLVR.sol";

/**
 * @title AlphixLVR
 * @notice Minimalist Uniswap V4 dynamic fee hook for LVR protection.
 * @dev Multi-pool capable. An authorized role sets the fee directly via `poke()`.
 *      Fee is applied via `poolManager.updateDynamicLPFee()` (stored in PoolManager state).
 *      Zero gas overhead on swaps.
 *
 *      Inherits from OpenZeppelin's BaseDynamicFee which provides:
 *      - `afterInitialize` hook to validate dynamic fee flag and set initial fee
 *      - `_poke()` internal to call `poolManager.updateDynamicLPFee(key, _getFee(key))`
 *      - `getHookPermissions()` with only `afterInitialize: true`
 */
contract AlphixLVR is BaseDynamicFee, AccessManaged, Pausable, IAlphixLVR {
    using PoolIdLibrary for PoolKey;

    /// @dev Per-pool fee storage.
    mapping(PoolId => uint24) private _fees;

    /// @param _poolManager The Uniswap V4 PoolManager address.
    /// @param _accessManager The OpenZeppelin AccessManager address for role-based access control.
    constructor(IPoolManager _poolManager, address _accessManager)
        BaseHook(_poolManager)
        AccessManaged(_accessManager)
    {}

    /// @inheritdoc BaseDynamicFee
    /// @dev Returns the stored fee for a pool. Called by `_poke()` and `_afterInitialize()`.
    function _getFee(PoolKey calldata key) internal view override returns (uint24) {
        return _fees[key.toId()];
    }

    /// @inheritdoc IAlphixLVR
    function poke(PoolKey calldata key, uint24 newFee) external restricted whenNotPaused {
        PoolId poolId = key.toId();
        _fees[poolId] = newFee;
        _poke(key);
        emit FeePoked(poolId, newFee);
    }

    /// @inheritdoc IAlphixLVR
    function getFee(PoolId poolId) external view returns (uint24) {
        return _fees[poolId];
    }

    /// @inheritdoc IAlphixLVR
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc IAlphixLVR
    function unpause() external restricted {
        _unpause();
    }
}
