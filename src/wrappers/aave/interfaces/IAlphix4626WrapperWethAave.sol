// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IAlphix4626WrapperAave} from "./IAlphix4626WrapperAave.sol";

/**
 * @title IAlphix4626WrapperWethAave
 * @author Alphix
 * @notice Interface for the WETH-specific Alphix 4626 Wrapper for Aave V3.
 * @dev Extends IAlphix4626WrapperAave with native ETH deposit/withdraw capabilities.
 */
interface IAlphix4626WrapperWethAave is IAlphix4626WrapperAave {
    /* EVENTS */

    /**
     * @notice Emitted when native ETH is deposited (wrapped to WETH and supplied to Aave).
     * @param caller The address that initiated the deposit.
     * @param receiver The address that received the shares.
     * @param ethAmount The amount of ETH deposited.
     * @param shares The amount of shares minted.
     */
    event DepositETH(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);

    /**
     * @notice Emitted when shares are withdrawn as native ETH.
     * @param caller The address that initiated the withdrawal.
     * @param receiver The address that received the ETH.
     * @param owner The address that owned the shares.
     * @param ethAmount The amount of ETH withdrawn.
     * @param shares The amount of shares burned.
     */
    event WithdrawETH(
        address indexed caller, address indexed receiver, address indexed owner, uint256 ethAmount, uint256 shares
    );

    /* ERRORS */

    /**
     * @dev Thrown when an ETH transfer fails.
     */
    error ETHTransferFailed();

    /**
     * @dev Thrown when receive() is called by a non-WETH address.
     */
    error ReceiveNotAllowed();

    /**
     * @dev Thrown when fallback() is called.
     */
    error FallbackNotAllowed();

    /* ETH DEPOSIT/WITHDRAW FUNCTIONS */

    /**
     * @notice Deposits native ETH, wraps it to WETH, and deposits into the vault.
     * @param receiver The address that will receive the shares (must equal msg.sender).
     * @return shares The amount of shares minted.
     * @dev Only callable by authorized Alphix Hooks or the owner.
     *      Wraps msg.value ETH to WETH before depositing.
     *      Reverts with `InvalidReceiver` if receiver != msg.sender.
     *      Reverts with `ZeroAmount` if msg.value == 0.
     *      Reverts with `DepositExceedsMax` if msg.value exceeds max deposit.
     *      Emits {DepositETH} on success.
     */
    function depositETH(address receiver) external payable returns (uint256 shares);

    /**
     * @notice Withdraws assets from the vault and sends them as native ETH.
     * @param assets The amount of assets to withdraw.
     * @param receiver The address that will receive the ETH.
     * @param owner The address that owns the shares (must equal msg.sender).
     * @return shares The amount of shares burned.
     * @dev Only callable by authorized Alphix Hooks or the owner.
     *      Withdraws WETH from Aave and unwraps to ETH before sending.
     *      Reverts with `CallerNotOwner` if owner != msg.sender.
     *      Reverts with `WithdrawExceedsMax` if assets exceed max withdrawal.
     *      Reverts with `ETHTransferFailed` if ETH transfer fails.
     *      Emits {WithdrawETH} on success.
     */
    function withdrawETH(uint256 assets, address receiver, address owner) external returns (uint256 shares);

    /**
     * @notice Redeems shares from the vault and sends the assets as native ETH.
     * @param shares The amount of shares to redeem.
     * @param receiver The address that will receive the ETH.
     * @param owner The address that owns the shares (must equal msg.sender).
     * @return assets The amount of assets withdrawn.
     * @dev Only callable by authorized Alphix Hooks or the owner.
     *      Withdraws WETH from Aave and unwraps to ETH before sending.
     *      Reverts with `CallerNotOwner` if owner != msg.sender.
     *      Reverts with `RedeemExceedsMax` if shares exceed max redeem.
     *      Reverts with `ETHTransferFailed` if ETH transfer fails.
     *      Emits {WithdrawETH} on success.
     */
    function redeemETH(uint256 shares, address receiver, address owner) external returns (uint256 assets);
}
