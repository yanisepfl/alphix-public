// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/* LOCAL IMPORTS */
import {AlphixLogic} from "./AlphixLogic.sol";
import {BaseDynamicFee} from "./BaseDynamicFee.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";
import {ReHypothecationLib} from "./libraries/ReHypothecation.sol";

/**
 * @title AlphixLogicETH.
 * @notice Upgradeable logic for Alphix Hook - ETH pools (ETH as currency0).
 * @dev Extends AlphixLogic with WETH wrapping/unwrapping for ERC4626 compatibility.
 *      ETH must be currency0 (by Uniswap V4 convention, lower address is currency0).
 *
 *      USER OPERATIONS:
 *      - Deposit: User sends ETH → wrapped to WETH → deposited to ERC4626 vault
 *      - Withdraw: WETH withdrawn from vault → unwrapped → ETH sent to user
 *
 *      JIT OPERATIONS (via AlphixETH hook):
 *      - beforeSwap (negative delta): WETH withdrawn → unwrapped → ETH sent to AlphixETH hook
 *        Hook then settles with PoolManager using native ETH
 *      - afterSwap (positive delta): AlphixETH hook takes ETH from PoolManager → sends to this contract
 *        ETH received → wrapped to WETH → deposited to vault
 *
 *      SECURITY:
 *      - receive() only accepts ETH from WETH contract, PoolManager, and AlphixETH hook
 *      - User deposit validates msg.value matches required amount
 */
contract AlphixLogicETH is AlphixLogic {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;

    /* STORAGE */

    /**
     * @dev The WETH9 contract for wrapping/unwrapping native ETH.
     *      Stored after parent's _gap to maintain layout compatibility.
     */
    IWETH9 internal _weth9;

    /**
     * @dev Storage gap for future AlphixLogicETH upgrades.
     */
    uint256[49] internal _gapEth;

    /* ERRORS */

    /**
     * @dev Thrown when ETH sender is not authorized (not WETH or PoolManager).
     */
    error UnauthorizedETHSender();

    /**
     * @dev Thrown when ETH transfer fails.
     */
    error ETHTransferFailed();

    /**
     * @dev Thrown when pool is not an ETH pool (currency0 must be native).
     */
    error NotAnETHPool();

    /**
     * @dev Thrown when WETH address is invalid.
     */
    error InvalidWETHAddress();

    /**
     * @dev Thrown when yield source asset doesn't match WETH for native currency.
     */
    error YieldSourceAssetMismatch();

    /* CONSTRUCTOR */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() AlphixLogic() {}

    /* INITIALIZER */

    /**
     * @notice Disabled - use initializeETH instead.
     * @dev Overrides parent to prevent accidental initialization without WETH.
     */
    function initialize(address, address, address, string memory, string memory) public pure override {
        revert InvalidWETHAddress(); // Must use initializeETH for ETH variant
    }

    /**
     * @notice Initialize the ETH variant with WETH address.
     * @dev Extends base initialization with WETH9 address.
     */
    function initializeEth(
        address owner_,
        address alphixHook_,
        address accessManager_,
        address weth9_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        if (weth9_ == address(0)) revert InvalidWETHAddress();

        // Initialize common state from parent
        _initializeCommon(owner_, alphixHook_, accessManager_, name_, symbol_);

        // Set ETH-specific state
        _weth9 = IWETH9(weth9_);
    }

    /* RECEIVE */

    /**
     * @notice Accept ETH from WETH contract (unwrap) and PoolManager (JIT settlement).
     * @dev Only accepts ETH from trusted sources to prevent griefing.
     */
    receive() external payable {
        // Only accept ETH from WETH (unwrap) or PoolManager (JIT take)
        address pm = address(BaseDynamicFee(_alphixHook).poolManager());
        if (msg.sender != address(_weth9) && msg.sender != pm) {
            revert UnauthorizedETHSender();
        }
    }

    /* HOOK OVERRIDES */

    /**
     * @dev Override beforeInitialize to REQUIRE ETH pools.
     */
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        // Require ETH pools - currency0 must be native (address(0))
        if (!key.currency0.isAddressZero()) revert NotAnETHPool();
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @dev Override depositToYieldSource to handle ETH.
     * @notice Called by hook when it has positive currencyDelta (is owed tokens).
     *         For ETH: wrap received ETH to WETH, then deposit to yield source.
     *         For ERC20: delegate to parent (standard deposit).
     *         Gracefully returns if no yield source configured (for JIT flow).
     */
    function depositToYieldSource(Currency currency, uint256 amount) external override onlyAlphixHook nonReentrant {
        if (amount == 0) return;
        if (_yieldSourceState[currency].yieldSource == address(0)) return;

        if (currency.isAddressZero()) {
            _depositToYieldSourceWeth(currency, amount);
        } else {
            _depositToYieldSource(currency, amount);
        }
    }

    /**
     * @dev Override withdrawAndApprove to handle ETH.
     * @notice Called by hook when it has negative currencyDelta (owes tokens).
     *         For ETH: withdraw WETH, unwrap to ETH, send to hook.
     *         For ERC20: withdraw and approve Hook (Hook calls transferFrom as msg.sender).
     *         Gracefully returns if no yield source configured (for JIT flow).
     */
    function withdrawAndApprove(Currency currency, uint256 amount) external override onlyAlphixHook nonReentrant {
        if (amount == 0) return;
        if (_yieldSourceState[currency].yieldSource == address(0)) return;

        if (currency.isAddressZero()) {
            _withdrawFromYieldSourceEth(currency, amount);

            // Send ETH to AlphixETH hook for settlement
            (bool success,) = _alphixHook.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            _withdrawFromYieldSourceTo(currency, amount, address(this));

            // Approve Hook to pull tokens during settle (Hook calls transferFrom as msg.sender)
            IERC20(Currency.unwrap(currency)).forceApprove(_alphixHook, amount);
        }
    }

    /* YIELD MANAGER OVERRIDES */

    /**
     * @dev Override setYieldSource to validate WETH asset for native currency.
     */
    function setYieldSource(Currency currency, address newYieldSource)
        external
        override
        restricted
        poolConfigured
        whenNotPaused
        nonReentrant
    {
        // For native currency (ETH), validate that yield source asset is WETH
        if (currency.isAddressZero()) {
            if (newYieldSource != address(0)) {
                address vaultAsset = IERC4626(newYieldSource).asset();
                if (vaultAsset != address(_weth9)) {
                    revert YieldSourceAssetMismatch();
                }
            }
        } else {
            // For non-native currencies, use standard validation
            if (!ReHypothecationLib.isValidYieldSource(newYieldSource, currency)) {
                revert InvalidYieldSource(newYieldSource);
            }
        }

        YieldSourceState storage state = _yieldSourceState[currency];
        address oldYieldSource = state.yieldSource;

        // Harvest accrued yield before migration (accumulates tax)
        if (oldYieldSource != address(0) && state.sharesOwned > 0) {
            _accumulateYieldTax(currency);

            // Migrate - for ETH currency, use WETH as the actual asset
            Currency migrationCurrency = currency.isAddressZero() ? Currency.wrap(address(_weth9)) : currency;
            state.sharesOwned = ReHypothecationLib.migrateYieldSource(
                oldYieldSource, newYieldSource, migrationCurrency, state.sharesOwned
            );
        }

        state.yieldSource = newYieldSource;
        // Record the rate for the new yield source
        (state.lastRecordedRate,) = ReHypothecationLib.getCurrentRate(newYieldSource);

        emit YieldSourceUpdated(currency, oldYieldSource, newYieldSource);
    }

    /* LIQUIDITY OPERATIONS OVERRIDES */

    /**
     * @dev Override addReHypothecatedLiquidity to handle ETH.
     */
    function addReHypothecatedLiquidity(uint256 shares)
        external
        payable
        override
        poolActivated
        whenNotPaused
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        // Accumulate yield tax before modifying position
        _accumulateYieldTax(_poolKey.currency0);
        _accumulateYieldTax(_poolKey.currency1);

        // Calculate amounts with rounding up (protocol-favorable for deposits)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForDeposit(shares);

        // Prevent minting shares for zero deposits
        if (amount0 == 0 && amount1 == 0) revert ZeroAmounts();

        // Validate ETH amount
        if (msg.value < amount0) revert InvalidMsgValue();

        // Handle currency0 (ETH) - wrap to WETH and deposit to yield source
        _depositToYieldSourceWeth(_poolKey.currency0, amount0);

        // Refund excess ETH (after wrapping to avoid using refunded ETH)
        if (msg.value > amount0) {
            (bool success,) = msg.sender.call{value: msg.value - amount0}("");
            if (!success) revert ETHTransferFailed();
        }

        // Handle currency1 (ERC20) - transfer and deposit to yield source
        if (amount1 > 0) {
            IERC20(Currency.unwrap(_poolKey.currency1)).safeTransferFrom(msg.sender, address(this), amount1);
        }
        _depositToYieldSource(_poolKey.currency1, amount1);

        // Mint shares (ERC20)
        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, shares, amount0, amount1);

        // Safe: toInt128() uses SafeCast which reverts if value exceeds int128 max (~1.7e38), far above realistic token amounts
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128());
    }

    /**
     * @dev Override removeReHypothecatedLiquidity to handle ETH.
     */
    function removeReHypothecatedLiquidity(uint256 shares)
        external
        override
        poolActivated
        whenNotPaused
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < shares) revert InsufficientShares(shares, userBalance);

        // Accumulate yield tax before modifying position
        _accumulateYieldTax(_poolKey.currency0);
        _accumulateYieldTax(_poolKey.currency1);

        // Calculate amounts with rounding down (protocol-favorable for withdrawals)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForWithdrawal(shares);

        // Burn shares first (ERC20)
        _burn(msg.sender, shares);

        // Withdraw currency0 (ETH) - withdraw WETH then unwrap and send ETH
        _withdrawFromYieldSourceToEth(_poolKey.currency0, amount0, msg.sender);

        // Withdraw currency1 (ERC20) directly to sender
        _withdrawFromYieldSourceTo(_poolKey.currency1, amount1, msg.sender);

        emit ReHypothecatedLiquidityRemoved(msg.sender, shares, amount0, amount1);

        // Safe: toInt128() uses SafeCast which reverts if value exceeds int128 max (~1.7e38), far above realistic token amounts
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /**
     * @dev Override collectAccumulatedTax to handle ETH.
     */
    function collectAccumulatedTax()
        external
        override
        poolActivated
        whenNotPaused
        nonReentrant
        returns (uint256 collected0, uint256 collected1)
    {
        collected0 = _collectCurrencyTaxEth(_poolKey.currency0);
        collected1 = _collectCurrencyTax(_poolKey.currency1);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Wrap ETH to WETH and deposit to yield source for native currency.
     * @dev ETH must have been received by this contract before calling.
     * @param currency The native currency (must be address(0)).
     * @param amount The amount of ETH to wrap and deposit.
     */
    function _depositToYieldSourceWeth(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured(currency);

        // Wrap ETH to WETH
        _weth9.deposit{value: amount}();

        // Approve and deposit WETH to yield source
        IERC20(address(_weth9)).forceApprove(state.yieldSource, amount);
        uint256 sharesReceived = IERC4626(state.yieldSource).deposit(amount, address(this));
        state.sharesOwned += sharesReceived;
    }

    /**
     * @notice Withdraw WETH from yield source and unwrap to ETH (held by this contract).
     * @dev Used by withdrawAndApprove for JIT flow - ETH is then sent to hook for settlement.
     * @param currency The native currency (must be address(0)).
     * @param amount The amount to withdraw.
     */
    function _withdrawFromYieldSourceEth(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured(currency);

        // Withdraw WETH from yield source to this contract
        uint256 sharesRedeemed = IERC4626(state.yieldSource).withdraw(amount, address(this), address(this));
        state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;

        // Unwrap WETH to ETH (held at this contract)
        _weth9.withdraw(amount);
    }

    /**
     * @notice Withdraw from yield source to recipient as ETH.
     * @dev Withdraws WETH from vault, unwraps to ETH, sends to recipient.
     * @param currency The native currency (must be address(0)).
     * @param amount The amount to withdraw.
     * @param recipient The address to receive ETH.
     */
    function _withdrawFromYieldSourceToEth(Currency currency, uint256 amount, address recipient) internal {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured(currency);

        // Withdraw WETH from yield source to this contract
        uint256 sharesRedeemed = IERC4626(state.yieldSource).withdraw(amount, address(this), address(this));
        state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;

        // Unwrap WETH to ETH
        _weth9.withdraw(amount);

        // Send ETH to recipient
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /**
     * @notice Collect tax for ETH currency.
     * @dev Withdraws WETH from vault, unwraps to ETH, sends to treasury.
     * @param currency The native currency.
     * @return collected The amount collected.
     */
    function _collectCurrencyTaxEth(Currency currency) internal returns (uint256 collected) {
        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) return 0;

        // First accumulate any pending yield tax
        _accumulateYieldTax(currency);

        collected = state.accumulatedTax;
        if (collected == 0 || _yieldTreasury == address(0)) return 0;

        // Reset accumulated tax
        state.accumulatedTax = 0;

        // Withdraw WETH from yield source to this contract
        uint256 sharesRedeemed = IERC4626(state.yieldSource).withdraw(collected, address(this), address(this));
        state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;

        // Unwrap WETH to ETH
        _weth9.withdraw(collected);

        // Send ETH to treasury
        (bool success,) = _yieldTreasury.call{value: collected}("");
        if (!success) revert ETHTransferFailed();

        // Update rate after withdrawal
        (state.lastRecordedRate,) = ReHypothecationLib.getCurrentRate(state.yieldSource);

        emit AccumulatedTaxCollected(currency, collected);
    }

    /* GETTERS */

    /**
     * @notice Get the WETH9 contract address.
     * @return The WETH9 address.
     */
    function getWeth9() external view returns (address) {
        return address(_weth9);
    }
}
