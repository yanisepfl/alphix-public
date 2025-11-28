// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";

/**
 * @title Registry.
 * @notice Registry for Alphix ecosystem contracts and pools.
 * @dev Uses AccessManaged for centralized access control.
 */
contract Registry is AccessManaged, ERC165, IRegistry {
    /* STORAGE */

    /**
     * @dev Per-key contract addresses.
     */
    mapping(ContractKey => address) private contracts;

    /**
     * @dev Per-poolId pool info.
     */
    mapping(PoolId => PoolInfo) private pools;

    /**
     * @dev All registered pools.
     */
    PoolId[] private allPools;

    /* CONSTRUCTOR */

    /**
     * @dev Initialize with access manager address.
     * @param accessManager The AccessManager contract address.
     */
    constructor(address accessManager) AccessManaged(accessManager) {
        if (accessManager == address(0)) {
            revert InvalidAccessManager();
        }
    }

    /* REGISTRATION FUNCTIONS */

    /**
     * @dev See {IRegistry-registerContract}.
     */
    function registerContract(ContractKey key, address contractAddress) external override restricted {
        if (contractAddress == address(0)) revert InvalidAddress();
        contracts[key] = contractAddress;
        emit ContractRegistered(key, contractAddress);
    }

    /**
     * @dev See {IRegistry-registerPool}.
     */
    function registerPool(
        PoolKey calldata key,
        IAlphixLogic.PoolType poolType,
        uint24 _initialFee,
        uint256 _initialTargetRatio
    ) external override restricted {
        PoolId poolId = key.toId();
        if (pools[poolId].timestamp != 0) {
            revert PoolAlreadyRegistered(poolId);
        }

        // Register pool and its info
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 currentTimestamp = block.timestamp;

        pools[poolId] = PoolInfo({
            token0: token0,
            token1: token1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: address(key.hooks),
            initialFee: _initialFee,
            initialTargetRatio: _initialTargetRatio,
            timestamp: currentTimestamp,
            poolType: poolType
        });
        allPools.push(poolId);
        emit PoolRegistered(poolId, token0, token1, currentTimestamp, poolType);
    }

    /* VIEW FUNCTIONS */

    /**
     * @dev See {IRegistry-getContract}.
     */
    function getContract(ContractKey key) external view override returns (address) {
        return contracts[key];
    }

    /**
     * @dev See {IRegistry-getPoolInfo}.
     */
    function getPoolInfo(PoolId poolId) external view override returns (PoolInfo memory) {
        return pools[poolId];
    }

    /**
     * @dev See {IRegistry-listPools}.
     */
    function listPools() external view override returns (PoolId[] memory) {
        return allPools;
    }

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165) returns (bool) {
        return interfaceId == type(IRegistry).interfaceId || super.supportsInterface(interfaceId);
    }
}
