// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS
     *****************************************************************************************************************/
// OZ Uniswap Hooks
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
// OZ Contracts
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/* UNISWAP V4 IMPORTS
     *****************************************************************************************************************/
// Types
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
// Interfaces
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// Libraries
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/**
 * @title Alphix
 * @notice Uniswap v4 Dynamic Fee Hook.
 * @dev Inherits from OpenZeppelin’s BaseDynamicFee.
 */
contract Alphix is BaseDynamicFee, Ownable2Step {
    /* LIBRARIES
     *****************************************************************************************************************/

    using StateLibrary for IPoolManager;

    /* STRUCTURES
     *****************************************************************************************************************/

    /* VARIABLES
     *****************************************************************************************************************/

    /* EVENTS
     *****************************************************************************************************************/

    /**
     * @dev Emitted at every fee change.
     */
    event FeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee);

    /* MODIFIERS
     *****************************************************************************************************************/

    /* CONSTRUCTOR
     *****************************************************************************************************************/

    /**
     * @dev Initialize with PoolManager and alphixManager addresses.
     */
    constructor(IPoolManager _poolManager, address _alphixManager)
        BaseDynamicFee(_poolManager)
        Ownable(_alphixManager)
    {}

    /**
     * @dev See {BaseDynamicFee-poke}.
     */
    function poke(PoolKey calldata key) external override onlyValidPools(key.hooks) onlyOwner {
        PoolId poolId = key.toId();
        (,,, uint24 oldFee) = poolManager.getSlot0(poolId);
        uint24 newFee = _getFee(key);
        poolManager.updateDynamicLPFee(key, newFee);
        emit FeeUpdated(poolId, oldFee, newFee);
    }

    /**
     * @dev Core logic for dynamic fee calculation.
     * @param key The pool key for which the fee is being updated.
     * @return fee The new LP fee, in hundredths of a bip (1e-6).
     */
    function _getFee(PoolKey calldata key) internal pure override returns (uint24 fee) {
        // Example: return a constant for now
        return 3000; // 0.3%
    }
}
