// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";
import {IAlphix} from "./interfaces/IAlphix.sol";

/**
 * @title Alphix.
 * @notice Uniswap v4 Dynamic Fee Hook delegating logic to AlphixLogic.
 * @dev Uses OpenZeppelin 5 security patterns.
 */
contract Alphix is BaseDynamicFee, Ownable2Step, ReentrancyGuard, Pausable, Initializable, IAlphix {
    using StateLibrary for IPoolManager;

    /* STORAGE */

    /**
     * @dev Upgradeable logic of Alphix.
     */
    address private logic;

    /* MODIFIERS */

    /**
     * @notice Enforce logic to be not null.
     */
    modifier validLogic() {
        if (logic == address(0)) {
            revert LogicNotSet();
        }
        _;
    }

    /**
     * @notice Enforce sender logic to be logic.
     */
    modifier onlyLogic() {
        if (msg.sender != logic) {
            revert IAlphixLogic.InvalidCaller();
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
    {
        pause();
    }

    /* INITIALIZER */

    /**
     * @dev See {IAlphix-initialize}.
     */
    function initialize(address _logic) public override onlyOwner initializer {
        _setInitialLogic(_logic);
        unpause();
    }

    /* HOOK PERMISSIONS */

    /**
     * @dev See {BaseDynamicFee-getHookPermissions}.
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* HOOK ENTRY POINTS */

    /**
     * @dev See {BaseHook-_beforeInitialize}.
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        validLogic
        whenNotPaused
        returns (bytes4)
    {
        return IAlphixLogic(logic).beforeInitialize(sender, key, sqrtPriceX96);
    }

    /**
     * @dev See {BaseHook-_afterInitialize}.
     */
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        validLogic
        whenNotPaused
        returns (bytes4)
    {
        return IAlphixLogic(logic).afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /**
     * @dev See {BaseHook-_beforeAddLiquidity}.
     */
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4) {
        return IAlphixLogic(logic).beforeAddLiquidity(sender, key, params, hookData);
    }

    /**
     * @dev See {BaseHook-_beforeRemoveLiquidity}.
     */
    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4) {
        return IAlphixLogic(logic).beforeRemoveLiquidity(sender, key, params, hookData);
    }

    /**
     * @dev See {BaseHook-_afterAddLiquidity}.
     */
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta delta1,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4, BalanceDelta) {
        return IAlphixLogic(logic).afterAddLiquidity(sender, key, params, delta0, delta1, hookData);
    }

    /**
     * @dev See {BaseHook-_afterRemoveLiquidity}.
     */
    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta0,
        BalanceDelta delta1,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4, BalanceDelta) {
        return IAlphixLogic(logic).afterRemoveLiquidity(sender, key, params, delta0, delta1, hookData);
    }

    /**
     * @dev See {BaseHook-_beforeSwap}.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        validLogic
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return IAlphixLogic(logic).beforeSwap(sender, key, params, hookData);
    }

    /**
     * @dev See {BaseHook-_afterSwap}.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4, int128) {
        return IAlphixLogic(logic).afterSwap(sender, key, params, delta, hookData);
    }

    /* ADMIN FUNCTIONS */

    /**
     * @dev See {IAlphix-setLogic}.
     */
    function setLogic(address newLogic, PoolKey calldata key) external override onlyOwner nonReentrant {
        if (newLogic == address(0)) {
            revert InvalidAddress();
        }
        try IAlphixLogic(newLogic).getFee(key) returns (uint24) {}
        catch {
            revert IAlphixLogic.InvalidLogicContract();
        }
        address oldLogic = logic;
        logic = newLogic;
        emit LogicUpdated(oldLogic, newLogic);
    }

    /**
     * @dev See {IAlphix-initializePool}.
     */
    function initializePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        IAlphixLogic.PoolType _poolType
    ) external override onlyOwner nonReentrant whenNotPaused {
        IAlphixLogic(logic).activateAndConfigurePool(key, _initialFee, _initialTargetRatio, _poolType);
        _setDynamicFee(key, _initialFee);
    }

    /**
     * @dev See {IAlphix-activatePool}.
     */
    function activatePool(PoolKey calldata key) external override onlyOwner whenNotPaused {
        IAlphixLogic(logic).activatePool(key);
    }

    /**
     * @dev See {IAlphix-deactivatePool}.
     */
    function deactivatePool(PoolKey calldata key) external override onlyOwner whenNotPaused {
        IAlphixLogic(logic).deactivatePool(key);
    }

    /**
     * @dev See {IAlphix-pause}.
     */
    function pause() public override onlyOwner {
        _pause();
    }

    /**
     * @dev See {IAlphix-unpause}.
     */
    function unpause() public override onlyOwner {
        _unpause();
    }

    /* LOGIC FUNCTIONS */

    /**
     * @dev See {BaseDynamicFee-poke}.
     */
    function poke(PoolKey calldata key) external override onlyValidPools(key.hooks) onlyLogic nonReentrant {
        uint24 newFee = _getFee(key);
        _setDynamicFee(key, newFee);
    }

    /* GETTERS */

    /**
     * @dev See {IAlphix-getLogic}.
     */
    function getLogic() external view override returns (address) {
        return logic;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Setter for the initial logic.
     * @param newLogic The initial logic address.
     */
    function _setInitialLogic(address newLogic) internal {
        if (newLogic == address(0)) {
            revert InvalidAddress();
        }
        logic = newLogic;
        emit LogicUpdated(address(0), newLogic);
    }

    /**
     * @notice Setter for the fee of a key.
     * @param key The key to set the fee for.
     * @param newFee The fee to set.
     */
    function _setDynamicFee(PoolKey calldata key, uint24 newFee) internal whenNotPaused {
        PoolId poolId = key.toId();
        (,,, uint24 oldFee) = poolManager.getSlot0(poolId);
        poolManager.updateDynamicLPFee(key, newFee);
        emit FeeUpdated(poolId, oldFee, newFee);
    }

    /**
     * @dev See {BaseDynamicFee-_getFee}.
     */
    function _getFee(PoolKey calldata key) internal view override validLogic returns (uint24 fee) {
        return IAlphixLogic(logic).getFee(key);
    }
}
