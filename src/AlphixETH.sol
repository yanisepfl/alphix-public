// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {Alphix} from "./Alphix.sol";
import {IAlphix4626WrapperWeth} from "./interfaces/IAlphix4626WrapperWeth.sol";
import {IReHypothecation} from "./interfaces/IReHypothecation.sol";
import {ReHypothecationLib} from "./libraries/ReHypothecation.sol";

/**
 * @title AlphixETH
 * @notice Uniswap v4 Dynamic Fee Hook for ETH pools with JIT liquidity rehypothecation.
 * @dev Extends Alphix with native ETH handling for currency0.
 *      This hook is designed to work with pools where currency0 is native ETH (address(0)).
 *      Uses yield sources that support native ETH deposits/withdrawals.
 *
 *      ETH HANDLING:
 *      - For user deposits: ETH → yieldSource.depositETH{value}()
 *      - For user withdrawals: yieldSource.withdrawETH() → ETH sent to user
 *      - For JIT settlement: Uses depositETH/withdrawETH for yield source interactions
 *
 *      NOTE: The yield source for currency0 (ETH) must implement IAlphix4626WrapperWeth.
 */
contract AlphixETH is Alphix {
    using TransientStateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    /* ERRORS */

    /**
     * @dev Thrown when ETH sender is not authorized.
     */
    error UnauthorizedETHSender();

    /**
     * @dev Thrown when pool is not an ETH pool (currency0 must be native).
     */
    error NotAnETHPool();

    /* CONSTRUCTOR */

    /**
     * @notice Initialize with PoolManager, owner, accessManager, name and symbol.
     * @dev Delegates to Alphix constructor for all initialization.
     */
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _accessManager,
        string memory name_,
        string memory symbol_
    ) Alphix(_poolManager, _owner, _accessManager, name_, symbol_) {}

    /**
     * @notice Accept ETH from PoolManager and ETH yield source.
     * @dev Accepts ETH from:
     *      - PoolManager: for settle operations during swaps
     *      - ETH yield source: for withdrawETH operations during delta resolution
     */
    receive() external payable {
        address ethYieldSource = _yieldSourceState[Currency.wrap(address(0))].yieldSource;
        if (msg.sender != address(poolManager)) {
            if (msg.sender != ethYieldSource) {
                revert UnauthorizedETHSender();
            }
        }
    }

    /* HOOK ENTRY POINTS - ETH OVERRIDES */

    /**
     * @dev Validates pool initialization conditions for ETH pools.
     *      Only owner can initialize, prevents re-initialization, and requires native ETH as currency0.
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        // Only owner can initialize the pool at PoolManager level
        if (sender != owner()) revert OwnableUnauthorizedAccount(sender);

        // Prevent re-initialization if pool already configured
        if (address(_poolKey.hooks) != address(0)) revert PoolAlreadyInitialized();

        // Require ETH pools - currency0 must be native (address(0))
        if (!key.currency0.isAddressZero()) revert NotAnETHPool();
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @dev Override afterSwap to use ETH-specific delta resolution for currency0.
     *      Settlement happens here following OpenZeppelin flash accounting pattern.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        whenNotPaused
        returns (bytes4, int128)
    {
        // Compute JIT removal params
        JitParams memory jitParams = _computeAfterSwapJit();

        // Execute JIT liquidity removal and resolve all deltas
        if (jitParams.shouldExecute) {
            _executeJitLiquidity(key, jitParams);

            // Resolve net hook deltas (from add + remove)
            // For ETH pools, currency0 uses native ETH handling
            _resolveHookDeltaEth(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /* YIELD MANAGER OVERRIDES */

    /**
     * @inheritdoc IReHypothecation
     * @dev Override to validate ETH yield source implements IAlphix4626WrapperWeth.
     *
     *      SECURITY: This function can send ETH/tokens to arbitrary addresses during migration.
     *      The newYieldSource parameter is trusted as the AccessManager restricts this function
     *      to authorized yield managers only. The owner/AccessManager admin is assumed to be
     *      a secure multisig that validates yield sources before configuration.
     */
    function setYieldSource(Currency currency, address newYieldSource)
        external
        override
        restricted
        poolConfigured
        nonReentrant
    {
        if (currency.isAddressZero()) {
            // For ETH currency, just validate basic 4626 compliance
            // The yield source must implement depositETH/withdrawETH but we can't
            // easily check interface support without ERC165
            if (newYieldSource != address(0)) {
                if (newYieldSource.code.length == 0) {
                    revert InvalidYieldSource();
                }
            }
        } else {
            // For non-ETH currencies, use standard validation
            if (!ReHypothecationLib.isValidYieldSource(newYieldSource, currency)) {
                revert InvalidYieldSource();
            }
        }

        YieldSourceState storage state = _yieldSourceState[currency];
        address oldYieldSource = state.yieldSource;

        // Migrate if old yield source exists with shares
        if (oldYieldSource != address(0)) {
            if (state.sharesOwned > 0) {
                if (currency.isAddressZero()) {
                    // For ETH, redeem to ETH then deposit ETH to new yield source
                    uint256 assetsRedeemed = IAlphix4626WrapperWeth(oldYieldSource)
                        .redeemETH(state.sharesOwned, address(this), address(this));
                    uint256 newShares =
                        IAlphix4626WrapperWeth(newYieldSource).depositETH{value: assetsRedeemed}(address(this));
                    if (newShares == 0) revert ReHypothecationLib.ZeroSharesReceived();
                    state.sharesOwned = newShares;
                } else {
                    state.sharesOwned = ReHypothecationLib.migrateYieldSource(
                        oldYieldSource, newYieldSource, currency, state.sharesOwned
                    );
                }
            }
        }

        state.yieldSource = newYieldSource;

        emit YieldSourceUpdated(currency, oldYieldSource, newYieldSource);
    }

    /* LIQUIDITY OPERATIONS OVERRIDES */

    /**
     * @inheritdoc IReHypothecation
     * @dev Override to handle native ETH deposits for currency0.
     */
    function addReHypothecatedLiquidity(uint256 shares, uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage)
        external
        payable
        override
        whenNotPaused
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        // Check slippage before any state changes
        _checkPriceSlippage(expectedSqrtPriceX96, maxPriceSlippage);

        // Calculate amounts with rounding up (protocol-favorable for deposits)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForDeposit(shares);

        if (amount0 == 0) {
            if (amount1 == 0) revert ZeroAmounts();
        }

        // Validate ETH amount
        if (msg.value < amount0) revert InvalidMsgValue();

        // Deposit ETH to yield source using depositETH
        _depositToYieldSourceEth(_poolKey.currency0, amount0);

        // Refund excess ETH
        if (msg.value > amount0) {
            (bool success,) = msg.sender.call{value: msg.value - amount0}("");
            if (!success) revert RefundFailed();
        }

        // Handle currency1 (ERC20) - transfer and deposit to yield source
        _transferFromSender(_poolKey.currency1, amount1);
        _depositToYieldSource(_poolKey.currency1, amount1);

        // Mint shares
        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, shares, amount0, amount1);

        // Safe: amounts bounded by yield source deposits, never exceed int256.max
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128());
    }

    /**
     * @inheritdoc IReHypothecation
     * @dev Override to handle native ETH withdrawals for currency0.
     */
    function removeReHypothecatedLiquidity(uint256 shares, uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage)
        external
        override
        whenNotPaused
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < shares) revert InsufficientShares();

        // Check slippage before any state changes
        _checkPriceSlippage(expectedSqrtPriceX96, maxPriceSlippage);

        // Calculate amounts with rounding down (protocol-favorable for withdrawals)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForWithdrawal(shares);

        // Prevent burning shares when both amounts round to zero
        if (amount0 == 0 && amount1 == 0) revert ZeroAmounts();

        // Burn shares first
        _burn(msg.sender, shares);

        // Withdraw ETH from yield source using withdrawETH
        _withdrawFromYieldSourceToEth(_poolKey.currency0, amount0, msg.sender);

        // Withdraw currency1 (ERC20) directly to sender
        _withdrawFromYieldSourceTo(_poolKey.currency1, amount1, msg.sender);

        emit ReHypothecatedLiquidityRemoved(msg.sender, shares, amount0, amount1);

        // Safe: amounts bounded by yield source deposits, never exceed int256.max
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /* ETH-SPECIFIC INTERNAL FUNCTIONS */

    /**
     * @dev Deposits native ETH to yield source using depositETH.
     * @param currency The native currency (must be address(0)).
     * @param amount The amount of ETH to deposit.
     */
    function _depositToYieldSourceEth(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured();

        // Deposit ETH directly to yield source
        uint256 sharesReceived = IAlphix4626WrapperWeth(state.yieldSource).depositETH{value: amount}(address(this));
        if (sharesReceived == 0) revert ReHypothecationLib.ZeroSharesReceived();
        state.sharesOwned += sharesReceived;
    }

    /**
     * @dev Withdraws from yield source to recipient as native ETH.
     * @param currency The native currency (must be address(0)).
     * @param amount The amount to withdraw.
     * @param recipient The address to receive ETH.
     */
    function _withdrawFromYieldSourceToEth(Currency currency, uint256 amount, address recipient) internal {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured();

        // Withdraw ETH directly from yield source to recipient
        uint256 sharesRedeemed = IAlphix4626WrapperWeth(state.yieldSource).withdrawETH(amount, recipient, address(this));
        // Safe: subtraction only executes when sharesOwned > sharesRedeemed (explicit guard)
        unchecked {
            state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;
        }
    }

    /**
     * @dev Resolves hook delta for native ETH (currency0).
     *      Takes or settles any pending currencyDelta with the PoolManager for native ETH.
     *      For positive delta (hook is owed ETH): take from PoolManager → deposit to yield source
     *      For negative delta (hook owes ETH): withdraw from yield source → settle with PoolManager
     *
     * SECURITY (Reentrancy): External calls to yield source occur before state updates, but
     * reentrancy is prevented by: (1) public entry points use nonReentrant modifier,
     * (2) hook callbacks are protected by Uniswap V4's unlock pattern,
     * (3) yield sources are trusted (configured by AccessManager).
     *
     * @param currency The currency to resolve (must be native ETH).
     */
    function _resolveHookDeltaEth(Currency currency) internal {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            // Hook is owed ETH - take and deposit to yield source
            // Safe: currencyDelta > 0 guarantees positive value
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(currencyDelta);
            poolManager.take(currency, address(this), amount);
            _depositToYieldSourceEth(currency, amount);
        } else if (currencyDelta < 0) {
            // Hook owes ETH - withdraw from yield source and settle
            // Safe: currencyDelta < 0
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-currencyDelta);

            YieldSourceState storage state = _yieldSourceState[currency];
            if (state.yieldSource == address(0)) revert YieldSourceNotConfigured();
            uint256 sharesRedeemed =
                IAlphix4626WrapperWeth(state.yieldSource).withdrawETH(amount, address(this), address(this));
            // Safe: subtraction only executes when sharesOwned > sharesRedeemed (explicit guard)
            unchecked {
                state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;
            }

            poolManager.settle{value: amount}();
        }
    }

    /**
     * @dev Override _depositToYieldSource to handle ETH currency.
     *      For non-ETH currencies, uses parent implementation.
     */
    function _depositToYieldSource(Currency currency, uint256 amount) internal override {
        if (currency.isAddressZero()) {
            _depositToYieldSourceEth(currency, amount);
        } else {
            super._depositToYieldSource(currency, amount);
        }
    }

    /**
     * @dev Override _withdrawFromYieldSourceTo to handle ETH currency.
     *      For non-ETH currencies, uses parent implementation.
     */
    function _withdrawFromYieldSourceTo(Currency currency, uint256 amount, address recipient) internal override {
        if (currency.isAddressZero()) {
            _withdrawFromYieldSourceToEth(currency, amount, recipient);
        } else {
            super._withdrawFromYieldSourceTo(currency, amount, recipient);
        }
    }
}
