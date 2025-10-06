// SPDX-License-Identifier: MIT
// inspiration from: OpenZeppelin Uniswap Hooks (last updated v0.1.0) (src/fee/BaseDynamicFee.sol)
// Alphix version of the BaseDynamicFee

pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {DynamicFeeLib} from "./libraries/DynamicFee.sol";

/**
 * @dev This contract takes inspiration from OpenZeppelin's Uniswap BaseDynamicFee Hook and slightly
 * modifies it according to Alphix's Dynamic Fee Algorithm needs.
 *
 * WARNING: This is experimental software and is provided on an "as is" and "as available" basis. We do
 * not give any warranties and will not be liable for any losses incurred through any use of this code
 * base.
 *
 * _Available since v0.1.0_
 */
abstract contract BaseDynamicFee is BaseHook {
    using LPFeeLibrary for uint24;

    /**
     * @dev The hook was attempted to be initialized with a non-dynamic fee.
     */
    error NotDynamicFee();

    /**
     * @dev Set the `PoolManager` address.
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @dev Returns a fee, denominated in hundredths of a bip, to be applied to the pool after it is initialized.
     * @dev The currentRatio parameter and 3 return values have been added to OpenZeppelin's implementation.
     */
    function _getFee(PoolKey calldata key, uint256 currentRatio)
        internal
        virtual
        returns (uint24, uint256, uint256, DynamicFeeLib.OobState memory);

    /**
     * @dev Set the fee after the pool is initialized.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24)
        internal
        virtual
        override
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return this.afterInitialize.selector;
    }

    /**
     * @dev Updates the dynamic LP fee for the given pool, which must have a key
     * that contains this hook's address.
     * @dev The currentRatio parameter has been added to OpenZeppelin's implementation.
     * @param key The pool key to update the dynamic LP fee for.
     * @param currentRatio The current ratio of the pool, used to update the dynamic LP fee.
     */
    function poke(PoolKey calldata key, uint256 currentRatio) external virtual onlyValidPools(key.hooks) {
        // Base implementation ignores currentRatio but keeps signature for overrides
        (uint24 newFee,,,) = _getFee(key, currentRatio);
        poolManager.updateDynamicLPFee(key, newFee);
    }

    /**
     * @dev Set the hook permissions, specifically `afterInitialize`.
     *
     * @return permissions The hook permissions.
     */
    function getHookPermissions() public pure virtual override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
