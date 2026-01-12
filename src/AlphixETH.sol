// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {Alphix} from "./Alphix.sol";
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";

/**
 * @title AlphixETH
 * @notice Uniswap v4 Dynamic Fee Hook for ETH pools, delegating logic to AlphixLogicETH.
 * @dev Extends Alphix with native ETH settlement for currency0.
 *      This hook is designed to work with pools where currency0 is native ETH (address(0)).
 *      JIT liquidity operations use native ETH transfers for currency0.
 */
contract AlphixETH is Alphix {
    using TransientStateLibrary for IPoolManager;

    /* CONSTRUCTOR */

    /**
     * @notice Initialize with PoolManager, alphixManager, accessManager, and registry addresses.
     * @dev Delegates to Alphix constructor for all initialization.
     */
    constructor(IPoolManager _poolManager, address _alphixManager, address _accessManager, address _registry)
        Alphix(_poolManager, _alphixManager, _accessManager, _registry)
    {}

    /**
     * @notice Accept ETH from the logic contract and PoolManager.
     * @dev Required for receiving ETH during JIT operations.
     */
    receive() external payable {}

    /* HOOK ENTRY POINTS - ETH OVERRIDES */

    /**
     * @dev See {BaseHook-_afterSwap}.
     * @notice Executes JIT liquidity removal and resolves all hook deltas (following OpenZeppelin pattern).
     *         For ETH pools, handles native ETH for currency0.
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override validLogic whenNotPaused returns (bytes4, int128) {
        // Get hook return values and JIT params in a single call
        (bytes4 selector, int128 hookDelta, IAlphixLogic.JitParams memory jitParams) =
            IAlphixLogic(logic).afterSwap(sender, key, params, delta, hookData);

        // Execute JIT liquidity removal and resolve all deltas
        if (jitParams.shouldExecute) {
            // Remove liquidity from pool
            _executeJitLiquidity(key, jitParams);

            // Resolve net hook deltas (from add + remove + any fees)
            // For ETH pools, currency0 uses native ETH handling
            _resolveHookDeltaEth(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        return (selector, hookDelta);
    }

    /* ETH-SPECIFIC INTERNAL FUNCTIONS */

    /**
     * @notice Resolve hook delta for native ETH (currency0) following OpenZeppelin's _resolveHookDelta pattern.
     * @dev Takes or settles any pending currencyDelta with the PoolManager for native ETH.
     *      For positive delta (hook is owed), takes ETH to Logic which wraps to WETH and deposits.
     *      For negative delta (hook owes), Logic withdraws WETH, unwraps to ETH, sends here, then we settle.
     * @param currency The currency to resolve (must be native ETH).
     */
    function _resolveHookDeltaEth(Currency currency) internal {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            // Hook is owed ETH (positive delta) - take to Logic
            // Logic's receive() accepts from PoolManager, then wraps to WETH and deposits
            // Safe: currencyDelta > 0 check ensures value is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(currencyDelta);
            poolManager.take(currency, logic, amount);
            IAlphixLogic(logic).depositToYieldSource(currency, amount);
        } else if (currencyDelta < 0) {
            // Hook owes ETH (negative delta) - Logic unwraps WETH and sends ETH here
            // Safe: currencyDelta < 0 check ensures -currencyDelta is positive
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-currencyDelta);
            IAlphixLogic(logic).withdrawAndApprove(currency, amount);
            poolManager.settle{value: amount}();
        }
    }
}
