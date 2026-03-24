// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/* OZ UNISWAP HOOKS IMPORTS */
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";
import {BaseHookFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseHookFee.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";

/* LOCAL IMPORTS */
import {IAlphixLVRFee} from "./interfaces/IAlphixLVRFee.sol";

/**
 * @title AlphixLVRFee
 * @notice Uniswap V4 dynamic fee hook with protocol fee capture for L2 deployments.
 * @dev Multi-pool capable. Combines:
 *      - Dynamic LP fee via `poke()` (from BaseDynamicFee)
 *      - Hook fee taken from swap output as ERC-6909 claims (from BaseHookFee)
 *
 *      The hook fee is configurable per-pool. Set to 0 to disable (fast path, minimal gas).
 *      Accumulated fees are collected to a treasury via `handleHookFees()`.
 */
contract AlphixLVRFee is BaseDynamicFee, BaseHookFee, AccessManaged, Pausable, IUnlockCallback, IAlphixLVRFee {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;

    /// @dev Per-pool LP fee storage.
    mapping(PoolId => uint24) private _fees;

    /// @dev Per-pool hook fee storage (0 = disabled).
    mapping(PoolId => uint24) private _hookFees;

    /// @dev Treasury address where collected fees are sent.
    address public treasury;

    /// @dev Treasury address is zero.
    error TreasuryNotSet();

    /// @param _poolManager The Uniswap V4 PoolManager address.
    /// @param _accessManager The OpenZeppelin AccessManager address for role-based access control.
    /// @param _treasury The initial treasury address for collected hook fees.
    constructor(IPoolManager _poolManager, address _accessManager, address _treasury)
        BaseHook(_poolManager)
        AccessManaged(_accessManager)
    {
        if (_treasury == address(0)) revert TreasuryNotSet();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       DYNAMIC LP FEE (BaseDynamicFee)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc BaseDynamicFee
    function _getFee(PoolKey calldata key) internal view override returns (uint24) {
        return _fees[key.toId()];
    }

    /// @inheritdoc IAlphixLVRFee
    function poke(PoolKey calldata key, uint24 newFee) external restricted whenNotPaused {
        _fees[key.toId()] = newFee;
        _poke(key);
        emit FeePoked(key.toId(), newFee);
    }

    /// @inheritdoc IAlphixLVRFee
    function getFee(PoolId poolId) external view returns (uint24) {
        return _fees[poolId];
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       HOOK FEE (BaseHookFee)
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc BaseHookFee
    function _getHookFee(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        view
        override
        returns (uint24)
    {
        return _hookFees[key.toId()];
    }

    /// @inheritdoc IAlphixLVRFee
    function setHookFee(PoolKey calldata key, uint24 hookFee) external restricted whenNotPaused {
        if (hookFee > MAX_HOOK_FEE) revert HookFeeTooLarge();
        _hookFees[key.toId()] = hookFee;
        emit HookFeeSet(key.toId(), hookFee);
    }

    /// @inheritdoc IAlphixLVRFee
    function getHookFee(PoolId poolId) external view returns (uint24) {
        return _hookFees[poolId];
    }

    /// @inheritdoc BaseHookFee
    /// @dev Initiates an unlock on the PoolManager to burn ERC-6909 claims and transfer tokens to treasury.
    function handleHookFees(Currency[] memory currencies) public override(BaseHookFee, IAlphixLVRFee) {
        if (treasury == address(0)) revert TreasuryNotSet();
        poolManager.unlock(abi.encode(currencies));
    }

    /// @dev Callback from PoolManager.unlock(). Burns ERC-6909 claims and takes tokens to treasury.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only PoolManager");

        Currency[] memory currencies = abi.decode(data, (Currency[]));
        for (uint256 i = 0; i < currencies.length; i++) {
            uint256 balance = poolManager.balanceOf(address(this), currencies[i].toId());
            if (balance > 0) {
                // Burn ERC-6909 claims (settles debt with PoolManager)
                currencies[i].settle(poolManager, address(this), balance, true);
                // Take actual tokens to treasury
                currencies[i].take(poolManager, treasury, balance, false);
            }
        }
        return "";
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       TREASURY MANAGEMENT
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAlphixLVRFee
    function setTreasury(address _treasury) external restricted {
        if (_treasury == address(0)) revert TreasuryNotSet();
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       PAUSABLE
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IAlphixLVRFee
    function pause() external restricted {
        _pause();
    }

    /// @inheritdoc IAlphixLVRFee
    function unpause() external restricted {
        _unpause();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       HOOK PERMISSIONS (merged)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Merges permissions from BaseDynamicFee (afterInitialize) and BaseHookFee (afterSwap + returnDelta).
    function getHookPermissions() public pure override(BaseDynamicFee, BaseHookFee) returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // BaseDynamicFee: validate dynamic fee flag + set initial fee
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // BaseHookFee: capture hook fee from swap output
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: true, // BaseHookFee: adjust swapper output by fee amount
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @dev Required override since both BaseDynamicFee and BaseHookFee inherit BaseHook.
    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override(BaseHook, BaseDynamicFee)
        returns (bytes4)
    {
        return BaseDynamicFee._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /// @dev Required override since both BaseDynamicFee and BaseHookFee inherit BaseHook.
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata hookData)
        internal
        override(BaseHook, BaseHookFee)
        returns (bytes4, int128)
    {
        return BaseHookFee._afterSwap(sender, key, params, delta, hookData);
    }
}
