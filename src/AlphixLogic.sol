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
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

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
     * @dev See {IAlphixLogic-afterInitialize}.
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
     * @dev See {IAlphixLogic-beforeAddLiquidity}.
     */
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        returns (bytes4)
    {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @dev See {IAlphixLogic-beforeRemoveLiquidity}.
     */
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        returns (bytes4)
    {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @dev See {IAlphixLogic-afterAddLiquidity}.
     */
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev See {IAlphixLogic-afterRemoveLiquidity}.
     */
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev See {IAlphixLogic-beforeSwap}.
     */
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev See {IAlphixLogic-afterSwap}.
     */
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
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
