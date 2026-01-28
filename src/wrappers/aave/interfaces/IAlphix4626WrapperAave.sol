// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IAlphix4626WrapperAave
 * @author Alphix
 * @notice Interface for the Alphix 4626 Wrapper for Aave V3.
 * @dev This interface defines only the additional functions not in ERC4626.
 */
interface IAlphix4626WrapperAave {
    /* EVENTS */

    /**
     * @notice Emitted when the fee is updated.
     * @param newFee The new fee set.
     */
    event FeeUpdated(uint24 oldFee, uint24 newFee);

    /**
     * @notice Emitted when yield is accrued.
     * @param yieldAmount The amount of yield accrued.
     * @param feeAmount The amount of fee accrued.
     * @param newWrapperBalance The new balance of the wrapper in ATokens.
     */
    event YieldAccrued(uint256 yieldAmount, uint256 feeAmount, uint256 newWrapperBalance);

    /**
     * @notice Emitted when negative yield occurs (e.g., slashing).
     * @param lossAmount The amount of loss incurred.
     * @param feesReduced The amount of fees reduced to cover the loss.
     * @param newWrapperBalance The new balance of the wrapper in ATokens.
     */
    event NegativeYield(uint256 lossAmount, uint256 feesReduced, uint256 newWrapperBalance);

    /**
     * @notice Emitted when accumulated fees are collected.
     * @param amount The amount of fees collected.
     * @param newWrapperBalance The new balance of the wrapper in ATokens.
     */
    event FeesCollected(uint256 amount, uint256 newWrapperBalance);

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
     * @notice Emitted when rewards are claimed from Aave's incentives controller.
     * @param rewardsList The list of reward token addresses.
     * @param claimedAmounts The amounts claimed for each reward token.
     */
    event RewardsClaimed(address[] rewardsList, uint256[] claimedAmounts);

    /**
     * @notice Emitted when tokens are rescued from the wrapper.
     * @param token The address of the rescued token.
     * @param amount The amount of tokens rescued.
     */
    event TokensRescued(address indexed token, uint256 amount);

    /* ERRORS */

    /**
     * @dev Thrown when an address provided is invalid (e.g., zero address).
     */
    error InvalidAddress();

    /**
     * @dev Thrown at construction when the seed liquidity provided is zero.
     */
    error ZeroSeedLiquidity();

    /**
     * @dev Thrown when a caller is not the Alphix Hook.
     */
    error UnauthorizedCaller();

    /**
     * @dev Thrown when the underlying asset is not supported by Aave V3.
     */
    error UnsupportedAsset();

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
     * @dev Thrown when trying to claim rewards but no rewards controller is configured.
     */
    error NoRewardsController();

    /**
     * @dev Thrown when trying to rescue the aToken (which would break the wrapper).
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

    /* FEE RELATED FUNCTIONS */

    /**
     * @notice Sets the fee charged on yield.
     * @param newFee The new fee in hundredths of a bip (1e6 = 100%).
     * @dev Only callable by the owner. Accrues yield before updating.
     */
    function setFee(uint24 newFee) external;

    /**
     * @notice Collects all accumulated fees to the yield treasury (in aTokens).
     * @dev Only callable by the owner. Accrues yield before collecting.
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
     * @return The address where fees are sent when withdrawn.
     */
    function getYieldTreasury() external view returns (address);

    /**
     * @notice Returns the current claimable fees.
     * @return The amount of fees that can be claimed.
     * @dev Includes both accumulated fees and pending fees from unrealized yield.
     */
    function getClaimableFees() external view returns (uint256);

    /**
     * @notice Returns the last recorded wrapper balance in aTokens.
     * @return The last wrapper balance used for yield calculations.
     * @dev This value is updated on each yield accrual.
     */
    function getLastWrapperBalance() external view returns (uint256);

    /**
     * @notice Returns the current fee rate.
     * @return The fee in hundredths of a bip (1e6 = 100%).
     */
    function getFee() external view returns (uint256);

    /* ALPHIX HOOKS MANAGEMENT */

    /**
     * @notice Adds a new Alphix Hook to the authorized set.
     * @param hook The address to add as an authorized hook.
     * @dev Only callable by the owner.
     *      Reverts with `InvalidAddress` if hook is zero address.
     *      Reverts with `HookAlreadyExists` if hook is already authorized.
     *      Emits {AlphixHookAdded} on success.
     */
    function addAlphixHook(address hook) external;

    /**
     * @notice Removes an Alphix Hook from the authorized set.
     * @param hook The address to remove from authorized hooks.
     * @dev Only callable by the owner.
     *      Reverts with `HookDoesNotExist` if hook is not currently authorized.
     *      Emits {AlphixHookRemoved} on success.
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
     * @dev Only callable by the owner. Emits a {Paused} event.
     */
    function pause() external;

    /**
     * @notice Unpauses the contract, allowing deposits and withdrawals.
     * @dev Only callable by the owner. Emits an {Unpaused} event.
     */
    function unpause() external;

    /* REWARDS */

    /**
     * @notice Claims all pending rewards from Aave's incentives controller.
     * @dev Only callable by the owner. Rewards are sent to the yield treasury.
     *      Reverts with `InvalidAddress` if yield treasury is zero address.
     *      Emits {RewardsClaimed} on success.
     */
    function claimRewards() external;

    /* TOKEN RESCUE */

    /**
     * @notice Rescues tokens accidentally sent to the wrapper.
     * @param token The address of the token to rescue.
     * @param amount The amount of tokens to rescue.
     * @dev Only callable by the owner. Tokens are sent to the yield treasury.
     *      Reverts with `InvalidToken` if trying to rescue the aToken.
     *      Reverts with `InvalidAddress` if yield treasury is zero address.
     *      Reverts with `ZeroAmount` if amount is zero.
     *      Emits {TokensRescued} on success.
     */
    function rescueTokens(address token, uint256 amount) external;
}
