// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";

/**
 * @title Alphix
 * @notice Uniswap v4 Dynamic Fee Hook delegating logic to AlphixLogic.
 * @dev Uses OpenZeppelin 5 security patterns.
 */
contract Alphix is BaseDynamicFee, Ownable2Step, ReentrancyGuard, Pausable {
    using StateLibrary for IPoolManager;

    /* STORAGE */
    /**
     * @dev Upgradeable logic of Alphix.
     */
    address private logic;

    /* EVENTS */
    /**
     * @dev Emitted at every fee change.
     */
    event FeeUpdated(PoolId indexed poolId, uint24 oldFee, uint24 newFee);

    /**
     * @dev Emitted upon logic change.
     */
    event LogicUpdated(address oldLogic, address newLogic);

    /* ERRORS */
    error LogicNotSet();
    error InvalidAddress();

    /* MODIFIERS */
    /**
     * @notice Enforce logic to be not null.
     */
    modifier ValidLogic() {
        if (logic == address(0)) {
            revert LogicNotSet();
        }
        _;
    }

    /* CONSTRUCTOR */
    /**
     * @dev Initialize with PoolManager and alphixManager addresses.
     */
    constructor(IPoolManager _poolManager, address _alphixManager)
        BaseDynamicFee(_poolManager)
        Ownable(_alphixManager)
    {}

    /* ADMIN FUNCTIONS */
    /**
     * @dev See {BaseDynamicFee-poke}.
     */
    function poke(PoolKey calldata key)
        external
        override
        onlyValidPools(key.hooks)
        onlyOwner
        nonReentrant
        whenNotPaused
    {
        PoolId poolId = key.toId();
        (,,, uint24 oldFee) = poolManager.getSlot0(poolId);
        uint24 newFee = _getFee(key);
        poolManager.updateDynamicLPFee(key, newFee);
        emit FeeUpdated(poolId, oldFee, newFee);
    }

    /**
     * @notice Setter for the logic.
     * @param newLogic The new logic address.
     */
    function setLogic(address newLogic) external onlyOwner nonReentrant {
        if (newLogic == address(0)) {
            revert InvalidAddress();
        }
        address oldLogic = logic;
        logic = newLogic;
        emit LogicUpdated(oldLogic, newLogic);
    }

    /**
     * @notice Pause the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /* GETTERS */
    /**
     * @notice Getter for the logic.
     * @return currentLogic The current logic address.
     */
    function getLogic() external view returns (address) {
        return logic;
    }

    /* INTERNAL FUNCTIONS */
    /**
     * @dev See {BaseDynamicFee-_getFee}.
     */
    function _getFee(PoolKey calldata key) internal view override ValidLogic returns (uint24 fee) {
        return IAlphixLogic(logic).getFee(key);
    }
}
