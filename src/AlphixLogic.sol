// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";
import {IAlphix} from "./interfaces/IAlphix.sol";

/**
 * @title AlphixLogic.
 * @notice Upgradeable logic for Alphix Hook.
 * @dev Deployed behind an ERC1967Proxy.
 */
contract AlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    IAlphixLogic
{
    using LPFeeLibrary for uint24;

    /* STORAGE */

    /**
     * @dev The address of the Alphix Hook.
     */
    address private alphixHook;
    /**
     * @dev Base fee e.g. 3000 = 0.3%.
     */
    uint24 private baseFee;

    /* STORAGE GAP */

    uint256[50] private __gap;

    /* MODIFIERS */

    /**
     * @notice Enforce sender logic to be alphix hook.
     */
    modifier onlyAlphixHook() {
        if (msg.sender != alphixHook) {
            revert InvalidCaller();
        }
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @dev The deployed logic contract cannot later be initialized.
     */
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER */

    function initialize(address _owner, address _alphixHook, uint24 _baseFee) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _transferOwnership(_owner);

        alphixHook = _alphixHook;
        baseFee = _baseFee;
    }

    /* CORE HOOK LOGIC */

    /**
     * @dev See {IAlphixLogic-beforeInitialize}.
     */
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyAlphixHook
        returns (bytes4)
    {
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @dev See {BaseHook-afterInitialize}.
     */
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyAlphixHook
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert BaseDynamicFee.NotDynamicFee();
        BaseDynamicFee(alphixHook).poke(key);
        return BaseHook.afterInitialize.selector;
    }

    /**
     * @dev See {IAlphixLogic-getFee}.
     */
    function getFee(PoolKey calldata) external view returns (uint24) {
        // Example: return baseFee directly
        return baseFee;
    }

    /**
     * @dev Temporary function.
     */
    function getFee() external view returns (uint24) {
        // Example: return baseFee directly
        return baseFee;
    }

    /* ADMIN FUNCTIONS */

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

    function setParams(uint24 _baseFee) external onlyOwner {
        baseFee = _baseFee;
    }

    /* UUPS AUTHORIZATION */

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        try IAlphixLogic(newImplementation).getFee() returns (uint24) {}
        catch {
            revert InvalidLogicContract();
        }
    }
}
