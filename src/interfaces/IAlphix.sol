// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/* LOCAL IMPORTS */
import {DynamicFeeLib} from "../libraries/DynamicFee.sol";

/**
 * @title IAlphix.
 * @notice Interface for the Alphix Uniswap v4 Hook.
 * @dev All user-facing operations go through this contract.
 */
interface IAlphix {
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
     * @dev Emitted upon pool activation.
     * @param poolId The pool ID of the pool that has been activated.
     */
    event PoolActivated(PoolId indexed poolId);

    /**
     * @dev Emitted upon pool deactivation.
     * @param poolId The pool ID of the pool that has been deactivated.
     */
    event PoolDeactivated(PoolId indexed poolId);

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
     * @dev Validates the new logic contract implements required constant signature.
     */
    function setLogic(address newLogic) external;

    /**
     * @notice Set a new registry contract address.
     * @param newRegistry The new registry contract address.
     * @dev Registers Alphix Hook and AlphixLogic contracts in the new registry.
     *      IMPORTANT: Existing pools are NOT automatically migrated to the new registry.
     *      Admin must manually re-register pools after updating the registry.
     */
    function setRegistry(address newRegistry) external;

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
     * @notice Activate the pool this hook serves.
     * @dev Uses the stored pool key from initializePool.
     */
    function activatePool() external;

    /**
     * @notice Deactivate the pool this hook serves.
     * @dev Uses the stored pool key from initializePool.
     */
    function deactivatePool() external;

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

    /**
     * @notice Get the registry address.
     * @return registry The address of the registry.
     */
    function getRegistry() external view returns (address registry);

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
}
