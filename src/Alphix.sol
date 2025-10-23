// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

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
import {BaseDynamicFee} from "./BaseDynamicFee.sol";
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";
import {IAlphix} from "./interfaces/IAlphix.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {DynamicFeeLib} from "./libraries/DynamicFee.sol";

/**
 * @title Alphix.
 * @notice Uniswap v4 Dynamic Fee Hook delegating logic to AlphixLogic.
 * @dev Uses OpenZeppelin 5 security patterns.
 */
contract Alphix is BaseDynamicFee, Ownable2Step, AccessManaged, ReentrancyGuard, Pausable, Initializable, IAlphix {
    using StateLibrary for IPoolManager;

    /* STORAGE */

    /**
     * @dev Upgradeable logic of Alphix.
     */
    address private logic;

    /**
     * @dev Address of the registry.
     */
    address private registry;

    /* MODIFIERS */

    /**
     * @notice Enforce logic to be not null.
     */
    modifier validLogic() {
        _validLogic();
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @notice Initialize with PoolManager, alphixManager, and accessManager addresses.
     * @dev Check for _alphixManager != address(0) is done in Ownable.
     */
    constructor(IPoolManager _poolManager, address _alphixManager, address _accessManager, address _registry)
        BaseDynamicFee(_poolManager)
        Ownable(_alphixManager)
        AccessManaged(_accessManager)
    {
        if (address(_poolManager) == address(0) || _registry == address(0) || _accessManager == address(0)) {
            revert InvalidAddress();
        }
        registry = _registry;
        IRegistry(registry).registerContract(IRegistry.ContractKey.Alphix, address(this));
        _pause(); // Use internal function to bypass onlyOwner check in constructor
    }

    /* INITIALIZER */

    /**
     * @dev See {IAlphix-initialize}.
     */
    function initialize(address _logic) public override onlyOwner initializer {
        if (_logic == address(0)) {
            revert InvalidAddress();
        }
        _setLogic(_logic);
        IRegistry(registry).registerContract(IRegistry.ContractKey.AlphixLogic, _logic);
        _unpause();
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
     * @dev See {BaseDynamicFee-poke}.
     * @notice Can be called by addresses with the POKER_ROLE granted via AccessManager
     */
    function poke(PoolKey calldata key, uint256 currentRatio)
        external
        override
        onlyValidPools(key.hooks)
        restricted
        nonReentrant
        whenNotPaused
    {
        PoolId poolId = key.toId();
        (,,, uint24 oldFee) = poolManager.getSlot0(poolId);

        // Compute new fee and target ratio
        (uint24 newFee, uint256 oldTargetRatio, uint256 newTargetRatio, DynamicFeeLib.OobState memory sOut) =
            _getFee(key, currentRatio);

        // Update the fee
        _setDynamicFee(key, newFee);

        // Update the storage
        newTargetRatio = IAlphixLogic(logic).finalizeAfterFeeUpdate(key, newTargetRatio, sOut);

        emit FeeUpdated(poolId, oldFee, newFee, oldTargetRatio, currentRatio, newTargetRatio);
    }

    /**
     * @dev See {IAlphix-setLogic}.
     */
    function setLogic(address newLogic) external override onlyOwner nonReentrant {
        _setLogic(newLogic);
    }

    /**
     * @dev See {IAlphix-setRegistry}.
     */
    function setRegistry(address newRegistry) external override onlyOwner nonReentrant {
        if (newRegistry == address(0)) {
            revert InvalidAddress();
        }
        address oldRegistry = registry;
        registry = newRegistry;
        emit RegistryUpdated(oldRegistry, newRegistry);
        IRegistry(newRegistry).registerContract(IRegistry.ContractKey.Alphix, address(this));
        IRegistry(newRegistry).registerContract(IRegistry.ContractKey.AlphixLogic, logic);
    }

    /**
     * @dev See {IAlphix-setPoolTypeParams}.
     */
    function setPoolTypeParams(IAlphixLogic.PoolType poolType, DynamicFeeLib.PoolTypeParams calldata params)
        external
        override
        onlyOwner
    {
        IAlphixLogic(logic).setPoolTypeParams(poolType, params);
    }

    /**
     * @dev See {IAlphix-setGlobalMaxAdjRate}.
     */
    function setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) external override onlyOwner {
        IAlphixLogic(logic).setGlobalMaxAdjRate(_globalMaxAdjRate);
    }

    /**
     * @dev See {IAlphix-initializePool}.
     */
    function initializePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        IAlphixLogic.PoolType _poolType
    ) external override onlyOwner nonReentrant whenNotPaused validLogic {
        IAlphixLogic(logic).activateAndConfigurePool(key, _initialFee, _initialTargetRatio, _poolType);
        _setDynamicFee(key, _initialFee);
        PoolId poolId = key.toId();
        IRegistry(registry).registerPool(key, _poolType, _initialFee, _initialTargetRatio);
        emit FeeUpdated(poolId, 0, _initialFee, 0, _initialTargetRatio, _initialTargetRatio);
        emit PoolConfigured(poolId, _initialFee, _initialTargetRatio, _poolType);
    }

    /**
     * @dev See {IAlphix-activatePool}.
     */
    function activatePool(PoolKey calldata key) external override onlyOwner whenNotPaused {
        IAlphixLogic(logic).activatePool(key);
        PoolId poolId = key.toId();
        emit PoolActivated(poolId);
    }

    /**
     * @dev See {IAlphix-deactivatePool}.
     */
    function deactivatePool(PoolKey calldata key) external override onlyOwner whenNotPaused {
        IAlphixLogic(logic).deactivatePool(key);
        PoolId poolId = key.toId();
        emit PoolDeactivated(poolId);
    }

    /**
     * @dev See {IAlphix-pause}.
     */
    function pause() external override onlyOwner {
        _pause();
    }

    /**
     * @dev See {IAlphix-unpause}.
     */
    function unpause() external override onlyOwner {
        _unpause();
    }

    /* GETTERS */

    /**
     * @dev See {IAlphix-getLogic}.
     */
    function getLogic() external view override returns (address) {
        return logic;
    }

    /**
     * @dev See {IAlphix-getRegistry}.
     */
    function getRegistry() external view override returns (address) {
        return registry;
    }

    /**
     * @dev See {IAlphix-getFee}.
     */
    function getFee(PoolKey calldata key) external view override returns (uint24 fee) {
        PoolId poolId = key.toId();
        (,,, fee) = poolManager.getSlot0(poolId);
    }

    /**
     * @dev See {IAlphix-getPoolParams}.
     */
    function getPoolParams(PoolId poolId) external view override returns (DynamicFeeLib.PoolTypeParams memory) {
        IAlphixLogic.PoolType poolType = IAlphixLogic(logic).getPoolConfig(poolId).poolType;
        return getPoolTypeParams(poolType);
    }

    /**
     * @dev See {IAlphix-getPoolTypeParams}.
     */
    function getPoolTypeParams(IAlphixLogic.PoolType poolType)
        public
        view
        override
        returns (DynamicFeeLib.PoolTypeParams memory)
    {
        return IAlphixLogic(logic).getPoolTypeParams(poolType);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Setter for the logic.
     * @param newLogic The logic address.
     */
    function _setLogic(address newLogic) internal {
        if (newLogic == address(0)) {
            revert InvalidAddress();
        }
        if (!IERC165(newLogic).supportsInterface(type(IAlphixLogic).interfaceId)) {
            revert IAlphixLogic.InvalidLogicContract();
        }
        address oldLogic = logic;
        logic = newLogic;
        emit LogicUpdated(oldLogic, newLogic);
    }

    /**
     * @notice Setter for the fee of a key.
     * @param key The key to set the fee for.
     * @param newFee The fee to set.
     */
    function _setDynamicFee(PoolKey calldata key, uint24 newFee) internal whenNotPaused {
        PoolId poolId = key.toId();
        (,,, uint24 oldFee) = poolManager.getSlot0(poolId);
        if (oldFee != newFee) {
            poolManager.updateDynamicLPFee(key, newFee);
        }
    }

    /**
     * @dev See {BaseDynamicFee-_getFee}.
     */
    function _getFee(PoolKey calldata key, uint256 currentRatio)
        internal
        view
        override
        validLogic
        returns (uint24 fee, uint256 oldTargetRatio, uint256 newTargetRatio, DynamicFeeLib.OobState memory sOut)
    {
        return IAlphixLogic(logic).computeFeeAndTargetRatio(key, currentRatio);
    }

    /* MODIFIER HELPERS */

    /**
     * @dev Internal function to validate logic is set (reduces contract size)
     */
    function _validLogic() internal view {
        if (logic == address(0)) {
            revert LogicNotSet();
        }
    }
}
