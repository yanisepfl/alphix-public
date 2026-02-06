// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IAlphix4626WrapperSky
 * @author Alphix
 * @notice Interface for the Alphix 4626 Wrapper for Spark sUSDS on Base.
 * @dev This interface defines the additional functions not in ERC4626.
 *
 * Architecture:
 * - ERC4626 Asset: USDS (18 decimals)
 * - Internally holds: sUSDS (18 decimals) for yield
 * - Swaps via PSM: USDS ↔ sUSDS
 * - Rate tracked via rate provider (27 decimals)
 */
interface IAlphix4626WrapperSky {
    /* EVENTS */

    /**
     * @notice Emitted when the fee is updated.
     * @param oldFee The previous fee.
     * @param newFee The new fee set.
     */
    event FeeUpdated(uint24 oldFee, uint24 newFee);

    /**
     * @notice Emitted when yield is accrued based on rate increase.
     * @param yieldAmount The amount of yield accrued (in USDS terms, 18 decimals).
     * @param feeAmount The amount of fee accrued (in sUSDS terms, 18 decimals).
     * @param newRate The new sUSDS/USDS rate (27 decimals).
     */
    event YieldAccrued(uint256 yieldAmount, uint256 feeAmount, uint256 newRate);

    /**
     * @notice Emitted when accumulated fees are collected.
     * @param amount The amount of fees collected (in sUSDS, 18 decimals).
     */
    event FeesCollected(uint256 amount);

    /**
     * @notice Emitted when the yield treasury is updated.
     * @param oldTreasury The previous yield treasury address.
     * @param newTreasury The new yield treasury address.
     */
    event YieldTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitted when an Alphix Hook is added.
     * @param hook The address of the added hook.
     */
    event AlphixHookAdded(address indexed hook);

    /**
     * @notice Emitted when an Alphix Hook is removed.
     * @param hook The address of the removed hook.
     */
    event AlphixHookRemoved(address indexed hook);

    /**
     * @notice Emitted when tokens are rescued from the wrapper.
     * @param token The address of the rescued token.
     * @param amount The amount of tokens rescued.
     */
    event TokensRescued(address indexed token, uint256 amount);

    /**
     * @notice Emitted when the referral code is updated.
     * @param oldReferralCode The previous referral code.
     * @param newReferralCode The new referral code.
     */
    event ReferralCodeUpdated(uint256 oldReferralCode, uint256 newReferralCode);

    /**
     * @notice Emitted when the circuit breaker triggers due to excessive rate change.
     * @param lastRate The previous rate.
     * @param currentRate The current rate.
     * @param changeBps The rate change in basis points.
     */
    event CircuitBreakerTriggered(uint256 lastRate, uint256 currentRate, uint256 changeBps);

    /**
     * @notice Emitted when _lastRate is synced towards the current rate.
     * @param oldRate The previous _lastRate value.
     * @param newRate The new _lastRate value after sync.
     * @param targetRate The actual current rate from the rate provider.
     */
    event RateSynced(uint256 indexed oldRate, uint256 indexed newRate, uint256 targetRate);

    /* ERRORS */

    /**
     * @dev Thrown when an address provided is invalid (e.g., zero address).
     */
    error InvalidAddress();

    /**
     * @dev Thrown when a caller is not the Alphix Hook or owner.
     */
    error UnauthorizedCaller();

    /**
     * @dev Thrown when a deposit exceeds the maximum allowed deposit.
     */
    error DepositExceedsMax();

    /**
     * @dev Thrown when a deposit attempts to mint zero shares.
     */
    error ZeroShares();

    /**
     * @dev Thrown when a new fee exceeds the maximum allowed fee.
     */
    error FeeTooHigh();

    /**
     * @dev Thrown when attempting to add a hook that already exists.
     */
    error HookAlreadyExists();

    /**
     * @dev Thrown when attempting to remove a hook that does not exist.
     */
    error HookDoesNotExist();

    /**
     * @dev Thrown when a function is not implemented.
     */
    error NotImplemented();

    /**
     * @dev Thrown when the receiver is invalid (must be msg.sender for deposit).
     */
    error InvalidReceiver();

    /**
     * @dev Thrown when the caller is not the owner of the shares being withdrawn.
     */
    error CallerNotOwner();

    /**
     * @dev Thrown when a withdrawal exceeds the maximum allowed withdrawal.
     */
    error WithdrawExceedsMax();

    /**
     * @dev Thrown when a redeem exceeds the maximum allowed redeem.
     */
    error RedeemExceedsMax();

    /**
     * @dev Thrown when a redeem would result in zero assets.
     */
    error ZeroAssets();

    /**
     * @dev Thrown when trying to rescue a protected token.
     */
    error InvalidToken();

    /**
     * @dev Thrown when the amount provided is zero.
     */
    error ZeroAmount();

    /**
     * @dev Thrown when attempting to renounce ownership.
     */
    error RenounceDisabled();

    /**
     * @dev Thrown when the rate provider returns an invalid rate (out of bounds).
     */
    error InvalidRate();

    /**
     * @dev Thrown when seed liquidity is below the minimum required amount.
     */
    error InsufficientSeedLiquidity();

    /**
     * @dev Thrown when rate change exceeds circuit breaker threshold (5%).
     * @param lastRate The previous rate.
     * @param currentRate The current rate that triggered the circuit breaker.
     * @param changeBps The actual rate change in basis points.
     */
    error ExcessiveRateChange(uint256 lastRate, uint256 currentRate, uint256 changeBps);

    /**
     * @dev Thrown when syncRate() is called but no sync is needed.
     */
    error NoSyncNeeded();

    /* FEE RELATED FUNCTIONS */

    /**
     * @notice Sets the fee charged on yield.
     * @param newFee The new fee in hundredths of a bip (1e6 = 100%).
     * @dev Only callable by the owner. Accrues yield before updating.
     */
    function setFee(uint24 newFee) external;

    /**
     * @notice Collects all accumulated fees to the yield treasury.
     * @dev Only callable by the owner. Fees are collected in sUSDS.
     */
    function collectFees() external;

    /**
     * @notice Sets the yield treasury address.
     * @param newYieldTreasury The new yield treasury address.
     * @dev Only callable by the owner.
     */
    function setYieldTreasury(address newYieldTreasury) external;

    /**
     * @notice Returns the current yield treasury address.
     * @return The address where fees are sent when collected.
     */
    function getYieldTreasury() external view returns (address);

    /**
     * @notice Returns the current claimable fees (in sUSDS, 18 decimals).
     * @return The amount of fees that can be claimed.
     * @dev Includes both accumulated fees and pending fees from unrealized yield.
     */
    function getClaimableFees() external view returns (uint256);

    /**
     * @notice Returns the last recorded sUSDS/USDS rate.
     * @return The last rate used for yield calculations (27 decimal precision).
     * @dev This value is updated on each yield accrual.
     */
    function getLastRate() external view returns (uint256);

    /**
     * @notice Returns the current fee rate.
     * @return The fee in hundredths of a bip (1e6 = 100%).
     */
    function getFee() external view returns (uint256);

    /**
     * @notice Sets the referral code for PSM swaps.
     * @param newReferralCode The new referral code (can be 0).
     * @dev Only callable by the owner.
     */
    function setReferralCode(uint256 newReferralCode) external;

    /**
     * @notice Returns the current referral code.
     * @return The referral code used for PSM swaps.
     */
    function getReferralCode() external view returns (uint256);

    /* ALPHIX HOOKS MANAGEMENT */

    /**
     * @notice Adds a new Alphix Hook to the authorized set.
     * @param hook The address to add as an authorized hook.
     * @dev Only callable by the owner.
     */
    function addAlphixHook(address hook) external;

    /**
     * @notice Removes an Alphix Hook from the authorized set.
     * @param hook The address to remove from authorized hooks.
     * @dev Only callable by the owner.
     */
    function removeAlphixHook(address hook) external;

    /**
     * @notice Checks if an address is an authorized Alphix Hook.
     * @param hook The address to check.
     * @return True if the address is an authorized hook, false otherwise.
     */
    function isAlphixHook(address hook) external view returns (bool);

    /**
     * @notice Returns all authorized Alphix Hook addresses.
     * @return An array of all authorized hook addresses.
     */
    function getAllAlphixHooks() external view returns (address[] memory);

    /* PAUSABLE */

    /**
     * @notice Pauses the contract, preventing deposits and withdrawals.
     * @dev Only callable by the owner.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract, allowing deposits and withdrawals.
     * @dev Only callable by the owner.
     */
    function unpause() external;

    /* TOKEN RESCUE */

    /**
     * @notice Rescues tokens accidentally sent to the wrapper.
     * @param token The address of the token to rescue.
     * @param amount The amount of tokens to rescue.
     * @dev Only callable by the owner. Cannot rescue sUSDS.
     */
    function rescueTokens(address token, uint256 amount) external;

    /* RATE SYNC */

    /**
     * @notice Syncs _lastRate to the current rate, accruing yield and bypassing circuit breaker.
     * @dev Use when circuit breaker blocks operations due to large rate jump.
     *      Sets _lastRate directly to current rate in a single call.
     *      Accrues yield (and fees) for the rate change.
     *      Reverts if no sync is needed (rate unchanged or lastRate is 0).
     */
    function syncRate() external;
}
