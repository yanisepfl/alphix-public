// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/**
 * @title IAlphix.
 * @notice Interface for the Alphix Uniswap v4 Hook.
 * @dev Defines the external API for the hook.
 */
interface IAlphix {
    /* EVENTS */

    /**
     * @dev Emitted at every fee change.
     * @param poolId The pool identifier.
     * @param oldFee The previous fee value.
     * @param newFee The new fee value.
     */
    event FeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee);

    /**
     * @dev Emitted upon logic change.
     * @param oldLogic The previous logic contract address.
     * @param newLogic The new logic contract address.
     */
    event LogicUpdated(address oldLogic, address newLogic);

    /* ERRORS */

    /**
     * @dev Thrown when logic contract is not set.
     */
    error LogicNotSet();

    /**
     * @dev Thrown when an invalid address (e.g. 0) is provided.
     */
    error InvalidAddress();

    /* INITIALIZER */

    /**
     * @notice Initialize the contract with a logic contract address.
     * @param _logic The initial logic contract address.
     * @dev Can only be called by the owner, sets logic and unpauses contract.
     */
    function initialize(address _logic) external;

    /* ADMIN FUNCTIONS */

    /**
     * @notice Set a new logic contract address.
     * @param newLogic The new logic contract address.
     * @param key A sample pool key for validation.
     * @dev Validates the new logic contract implements required interface.
     */
    function setLogic(address newLogic, PoolKey calldata key) external;

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

    /* GETTERS */

    /**
     * @notice Get the current logic contract address.
     * @return currentLogic The address of the current logic contract.
     */
    function getLogic() external view returns (address currentLogic);
}
