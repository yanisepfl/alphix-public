// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "./BaseDynamicFee.sol";
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";
import {IAlphix} from "./interfaces/IAlphix.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {DynamicFeeLib} from "./libraries/DynamicFee.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

/**
 * @title Alphix.
 * @notice Uniswap v4 Dynamic Fee Hook delegating logic to AlphixLogic.
 * @dev Uses OpenZeppelin 5 security patterns.
 */
contract Alphix is
    BaseDynamicFee,
    Ownable2Step,
    AccessManaged,
    ReentrancyGuardTransient,
    Pausable,
    Initializable,
    IAlphix
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    /* STORAGE */

    /**
     * @dev Upgradeable logic of Alphix.
     * @notice Internal to allow AlphixETH inheritance.
     */
    address internal logic;

    /**
     * @dev Address of the registry.
     * @notice Internal to allow AlphixETH inheritance.
     */
    address internal registry;

    /**
     * @dev Cached pool key for the single pool this hook serves.
     * @notice Internal to allow AlphixETH inheritance.
     */
    PoolKey internal _poolKey;

    /**
     * @dev Cached pool ID.
     * @notice Internal to allow AlphixETH inheritance.
     */
    PoolId internal _poolId;

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
        IRegistry(_registry).registerContract(IRegistry.ContractKey.Alphix, address(this));
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
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
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
     * @notice Executes JIT liquidity addition using flash accounting (following OpenZeppelin pattern).
     *         Flow: get params -> execute modifyLiquidity -> delta carried forward via flash accounting.
     *         Settlement is deferred to afterSwap where net deltas are resolved.
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        validLogic
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get hook return values and JIT params
        (bytes4 selector, BeforeSwapDelta swapDelta, uint24 fee, IAlphixLogic.JitParams memory jitParams) =
            IAlphixLogic(logic).beforeSwap(sender, key, params, hookData);

        // Execute JIT liquidity addition if needed - NO settlement (flash accounting)
        // The negative delta from adding liquidity is carried forward and resolved in afterSwap
        if (jitParams.shouldExecute) {
            _executeJitLiquidity(key, jitParams);
        }

        return (selector, swapDelta, fee);
    }

    /**
     * @dev See {BaseHook-_afterSwap}.
     * @notice Executes JIT liquidity removal and resolves all hook deltas (following OpenZeppelin pattern).
     *         After removing liquidity, resolves net deltas from both add (beforeSwap) and remove operations.
     * @dev Virtual to allow AlphixETH to override for ETH-specific delta resolution.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override validLogic whenNotPaused returns (bytes4, int128) {
        // Get hook return values and JIT params in a single call
        (bytes4 selector, int128 hookDelta, IAlphixLogic.JitParams memory jitParams) =
            IAlphixLogic(logic).afterSwap(sender, key, params, delta, hookData);

        // Execute JIT liquidity removal and resolve all deltas
        if (jitParams.shouldExecute) {
            // Remove liquidity from pool
            _executeJitLiquidity(key, jitParams);

            // Resolve net hook deltas (from add + remove + any fees)
            // Following OpenZeppelin's _resolveHookDelta pattern
            _resolveHookDelta(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        return (selector, hookDelta);
    }

    /**
     * @dev See {BaseHook-_beforeDonate}.
     */
    function _beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4) {
        return IAlphixLogic(logic).beforeDonate(sender, key, amount0, amount1, hookData);
    }

    /**
     * @dev See {BaseHook-_afterDonate}.
     */
    function _afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4) {
        return IAlphixLogic(logic).afterDonate(sender, key, amount0, amount1, hookData);
    }

    /* ADMIN FUNCTIONS */

    /**
     * @dev See {BaseDynamicFee-poke}.
     * @notice Can be called by addresses with the POKER_ROLE granted via AccessManager.
     *         Delegates all fee computation and state management to AlphixLogic.
     */
    function poke(uint256 currentRatio) external override restricted nonReentrant whenNotPaused validLogic {
        // Delegate to AlphixLogic - it handles all algorithm-specific logic internally
        (uint24 newFee, uint24 oldFee, uint256 oldTargetRatio, uint256 newTargetRatio) =
            IAlphixLogic(logic).poke(currentRatio);

        // Update the fee in PoolManager using cached pool key
        _setDynamicFee(newFee);

        emit FeeUpdated(_poolId, oldFee, newFee, oldTargetRatio, currentRatio, newTargetRatio);
    }

    /**
     * @dev See {IAlphix-setLogic}.
     */
    function setLogic(address newLogic) external override onlyOwner nonReentrant {
        _setLogic(newLogic);
    }

    /**
     * @dev See {IAlphix-setRegistry}.
     * @notice IMPORTANT: Existing pools are NOT migrated. Admin must manually re-register pools
     *         in the new registry after this call completes.
     */
    function setRegistry(address newRegistry) external override onlyOwner nonReentrant {
        if (newRegistry == address(0)) revert InvalidAddress();
        registry = newRegistry;
        IRegistry(newRegistry).registerContract(IRegistry.ContractKey.Alphix, address(this));
        IRegistry(newRegistry).registerContract(IRegistry.ContractKey.AlphixLogic, logic);
    }

    /**
     * @dev See {IAlphix-initializePool}.
     */
    function initializePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        DynamicFeeLib.PoolParams calldata _poolParams
    ) external override onlyOwner nonReentrant whenNotPaused validLogic {
        // Cache pool key and ID (single-pool per hook architecture)
        _poolKey = key;
        _poolId = key.toId();

        IAlphixLogic(logic).activateAndConfigurePool(key, _initialFee, _initialTargetRatio, _poolParams);
        poolManager.updateDynamicLPFee(key, _initialFee);
        IRegistry(registry).registerPool(key, _initialFee, _initialTargetRatio);
        emit FeeUpdated(_poolId, 0, _initialFee, 0, _initialTargetRatio, _initialTargetRatio);
        emit PoolConfigured(_poolId, _initialFee, _initialTargetRatio);
    }

    /**
     * @dev See {IAlphix-activatePool}.
     */
    function activatePool() external override onlyOwner whenNotPaused {
        IAlphixLogic(logic).activatePool();
        emit PoolActivated(_poolId);
    }

    /**
     * @dev See {IAlphix-deactivatePool}.
     */
    function deactivatePool() external override onlyOwner whenNotPaused {
        IAlphixLogic(logic).deactivatePool();
        emit PoolDeactivated(_poolId);
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
    function getFee() external view override returns (uint24 fee) {
        (,,, fee) = poolManager.getSlot0(_poolId);
    }

    /**
     * @dev See {IAlphix-getPoolKey}.
     */
    function getPoolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /**
     * @dev See {IAlphix-getPoolId}.
     */
    function getPoolId() external view returns (PoolId) {
        return _poolId;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Setter for the logic.
     * @param newLogic The logic address.
     */
    function _setLogic(address newLogic) internal {
        if (newLogic == address(0)) revert InvalidAddress();
        logic = newLogic;
        IRegistry(registry).registerContract(IRegistry.ContractKey.AlphixLogic, newLogic);
    }

    /**
     * @notice Setter for the fee using stored pool key.
     * @param newFee The fee to set.
     */
    function _setDynamicFee(uint24 newFee) internal whenNotPaused {
        (,,, uint24 oldFee) = poolManager.getSlot0(_poolId);
        if (oldFee != newFee) {
            poolManager.updateDynamicLPFee(_poolKey, newFee);
        }
    }

    /* JIT LIQUIDITY */

    /**
     * @notice Execute JIT liquidity modification on the pool manager.
     * @dev Called internally during beforeSwap/afterSwap to add/remove liquidity.
     * @param key The pool key.
     * @param jitParams The JIT parameters computed by AlphixLogic.
     * @return delta The balance delta from the liquidity modification.
     */
    function _executeJitLiquidity(PoolKey calldata key, IAlphixLogic.JitParams memory jitParams)
        internal
        returns (BalanceDelta delta)
    {
        (delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: jitParams.tickLower,
                tickUpper: jitParams.tickUpper,
                liquidityDelta: jitParams.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
    }

    /**
     * @notice Resolve hook delta for a currency (following OpenZeppelin's _resolveHookDelta pattern).
     * @dev Takes or settles any pending currencyDelta with the PoolManager,
     *      neutralizing the flash accounting deltas. For positive delta (hook is owed),
     *      takes tokens to Logic for deposit. For negative delta (hook owes),
     *      Logic withdraws and approves, then we settle.
     * @param currency The currency to resolve.
     */
    function _resolveHookDelta(Currency currency) internal {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            // Hook is owed tokens (positive delta) - take to Logic, Logic deposits to yield source
            // Safe: currencyDelta > 0 check ensures value is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(currencyDelta);
            currency.take(poolManager, logic, amount, false);
            IAlphixLogic(logic).depositToYieldSource(currency, amount);
        } else if (currencyDelta < 0) {
            // Hook owes tokens (negative delta) - Logic withdraws and approves, then settle
            // Safe: currencyDelta < 0 check ensures -currencyDelta is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-currencyDelta);
            IAlphixLogic(logic).withdrawAndApprove(currency, amount);
            currency.settle(poolManager, logic, amount, false);
        }
        // If currencyDelta == 0, nothing to do
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
