// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./IAlphixLogic.sol";

/**
 * @title IRegistry.
 * @notice Interface for the Alphix ecosystem registry.
 * @dev Tracks contract addresses and pools.
 */
interface IRegistry {
    /**
     * @dev Keys for stored contracts.
     */
    enum ContractKey {
        Alphix,
        AlphixLogic
    }

    /* EVENTS */

    /**
     * @dev Emitted when a contract address is registered or updated.
     * @param key The key of the registered contract.
     * @param contractAddress The address of the registered contract.
     */
    event ContractRegistered(ContractKey indexed key, address indexed contractAddress);

    /**
     * @dev Emitted when a pool is registered or updated.
     * @param poolId The pool ID of the registered pool.
     * @param timestamp The timestamp at which the pool got registered.
     * @param poolType The type of the registered pool.
     */
    event PoolRegistered(
        PoolId indexed poolId,
        address indexed token0,
        address indexed token1,
        uint256 timestamp,
        IAlphixLogic.PoolType poolType
    );

    /**
     * @dev Emitted when an address is added to authorized registrars.
     * @param addedRegistrar The address of the added registrar.
     */
    event AuthorizedRegistrarAdded(address indexed addedRegistrar);

    /**
     * @dev Emitted when an address is removed to authorized registrars.
     * @param removedRegistrar The address of the removed registrar.
     */
    event AuthorizedRegistrarRemoved(address indexed removedRegistrar);

    /* ERRORS */

    /**
     * @dev Thrown when registering the zero address.
     */
    error InvalidAddress();

    /**
     * @dev Thrown when access manager address is zero in constructor.
     */
    error InvalidAccessManager();

    /**
     * @dev Thrown when registering an already registered pool.
     */
    error PoolAlreadyRegistered(PoolId poolId);

    /**
     * @dev Thrown when caller is unauthorized to perform an action (e.g. registering a pool).
     */
    error UnauthorizedCaller();

    /* STRUCTS */

    /**
     * @notice Stores registration info for a pool.
     */
    struct PoolInfo {
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint24 initialFee;
        uint256 initialTargetRatio;
        uint256 timestamp;
        IAlphixLogic.PoolType poolType;
    }

    /* REGISTRATION FUNCTIONS */

    /**
     * @notice Register an important contract by key.
     * @param key The key of the registered contract.
     * @param contractAddress The address to register.
     * @dev Restricted function - requires appropriate role via AccessManager.
     */
    function registerContract(ContractKey key, address contractAddress) external;

    /**
     * @notice Register a pool.
     * @param key The pool key containing some pool parameters.
     * @param poolType The type of the pool to register.
     * @param _initialFee The initial fee of the pool to register.
     * @param _initialTargetRatio The initial target ratio of the pool to register.
     * @dev Restricted function - requires appropriate role via AccessManager.
     */
    function registerPool(
        PoolKey calldata key,
        IAlphixLogic.PoolType poolType,
        uint24 _initialFee,
        uint256 _initialTargetRatio
    ) external;

    /* VIEW FUNCTIONS */

    /**
     * @notice Get a registered contract address.
     * @param key The key of the contract.
     * @return contractAddress The registered address.
     */
    function getContract(ContractKey key) external view returns (address);

    /**
     * @notice Get info about a registered pool.
     * @param poolId The pool identifier.
     * @return info The PoolInfo struct.
     */
    function getPoolInfo(PoolId poolId) external view returns (PoolInfo memory);

    /**
     * @notice List all registered pool IDs.
     * @return poolIds The array of PoolIds.
     */
    function listPools() external view returns (PoolId[] memory);
}
