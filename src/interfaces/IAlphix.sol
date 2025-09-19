// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./IAlphixLogic.sol";
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
     * @dev Emitted upon logic change.
     * @param oldLogic The previous logic contract address.
     * @param newLogic The new logic contract address.
     */
    event LogicUpdated(address oldLogic, address newLogic);

    /**
     * @dev Emitted upon registry change.
     * @param oldRegistry The previous registry contract address.
     * @param newRegistry The new registry contract address.
     */
    event RegistryUpdated(address oldRegistry, address newRegistry);

    /**
     * @dev Emitted upon pool configuration.
     * @param poolId The pool ID of the pool that has been configured.
     * @param initialFee The initial fee of the pool that has been configured.
     * @param initialTargetRatio The initial target ratio of the pool that has been configured.
     * @param poolType The pool type of the pool that has been configured.
     */
    event PoolConfigured(
        PoolId indexed poolId, uint24 initialFee, uint256 initialTargetRatio, IAlphixLogic.PoolType poolType
    );

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

    /**
     * @dev Thrown when a function argument is invalid.
     */
    error NullArgument();

    /**
     * @dev Thrown when fee is invalid for the pool type.
     */
    error InvalidFeeForPoolType(IAlphixLogic.PoolType poolType, uint24 fee);

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
     * @param newRegistry The new logic contract address.
     * @dev Also register Alphix Hook and logic contracts.
     */
    function setRegistry(address newRegistry) external;

    /**
     * @notice Set per-pool type params.
     * @param poolType The pool type to set params to.
     * @param params The params to set.
     */
    function setPoolTypeParams(IAlphixLogic.PoolType poolType, DynamicFeeLib.PoolTypeParams calldata params) external;

    /**
     * @notice Set global max adjustment rate.
     * @param _globalMaxAdjRate The global max adjustment rate to set.
     */
    function setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) external;

    /**
     * @notice Initialize pool by activating and configuring it, and sets its initial fee.
     * @param key The key of the pool to initialize.
     * @param _initialFee The initial fee of the pool to initialize.
     * @param _initialTargetRatio The initial target ratio of the pool to initialize.
     * @param _poolType The pool type of the pool to initialize.
     */
    function initializePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        IAlphixLogic.PoolType _poolType
    ) external;

    /**
     * @notice Activate pool.
     * @param key The key of the pool to activate.
     */
    function activatePool(PoolKey calldata key) external;

    /**
     * @notice Deactivate pool.
     * @param key The key of the pool to deactivate.
     */
    function deactivatePool(PoolKey calldata key) external;

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
     * @notice Get the given key's current fee.
     * @param key The key of the pool to get the current fee from.
     * @return fee The current fee of the given pool.
     */
    function getFee(PoolKey calldata key) external view returns (uint24 fee);

    /**
     * @notice Get the given pool params.
     * @return poolId The pool ID to get the params of.
     */
    function getPoolParams(PoolId poolId) external view returns (DynamicFeeLib.PoolTypeParams memory);

    /**
     * @notice Get the given pool type params.
     * @return poolType The pool type to get the params of.
     */
    function getPoolTypeParams(IAlphixLogic.PoolType poolType)
        external
        view
        returns (DynamicFeeLib.PoolTypeParams memory);
}
