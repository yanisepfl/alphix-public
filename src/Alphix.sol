// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// OZ Imports
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

// Uniswap v4 Imports
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title Alphix
 * @notice Uniswap v4 Dynamic Fee Hook.
 * @dev Inherits from OpenZeppelin’s BaseDynamicFee.
 */
contract Alphix is BaseDynamicFee, Ownable2Step {
    /* LIBRARIES
     *****************************************************************************************************************/
    
    /* STRUCTURES
     *****************************************************************************************************************/

    /* VARIABLES
     *****************************************************************************************************************/

    /* EVENTS
     *****************************************************************************************************************/

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
     * @dev Core logic for dynamic fee calculation.
     * @param key The pool key for which the fee is being updated.
     * @return fee The new LP fee, in hundredths of a bip (1e-6).
     */
    function _getFee(PoolKey calldata key) internal pure override returns (uint24 fee) {
        // Example: return a constant for now
        return 3000; // 0.3%
    }
}
