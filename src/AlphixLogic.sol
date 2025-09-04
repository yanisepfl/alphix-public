// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title AlphixLogic
 * @notice Upgradeable logic for Alphix Hook.
 * @dev Deployed behind an ERC1967Proxy.
 */
contract AlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    /* STORAGE */
    /**
     * @dev Base fee e.g. 3000 = 0.3%.
     */
    uint24 public baseFee;

    /* STORAGE GAP */
    uint256[50] private __gap;

    /* CONSTRUCTOR */
    /**
     * @dev The deployed logic contract cannot later be initialized.
     */
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER */
    function initialize(address _owner, uint24 _baseFee) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _transferOwnership(_owner);

        baseFee = _baseFee;
    }

    /* CORE HOOK LOGIC */
    function getFee(PoolKey calldata key) external view whenNotPaused returns (uint24) {
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
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
