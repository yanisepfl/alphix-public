// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAlphix4626WrapperWeth} from "../../../src/interfaces/IAlphix4626WrapperWeth.sol";

/**
 * @title MockAlphix4626WrapperWeth
 * @notice A mock ERC-4626 vault for WETH that supports native ETH deposits/withdrawals.
 * @dev Implements IAlphix4626WrapperWeth for testing AlphixETH functionality.
 *      This mock wraps ETH to WETH internally and tracks shares.
 */
contract MockAlphix4626WrapperWeth is ERC20, IAlphix4626WrapperWeth {
    using SafeERC20 for IERC20;
    using Math for uint256;

    IERC20 private immutable _weth;
    address private _admin;

    constructor(address weth_) ERC20("Mock WETH Yield Vault", "mWETHv") {
        _weth = IERC20(weth_);
        _admin = msg.sender;
    }

    /* ERC4626 IMPLEMENTATION */

    function asset() public view override returns (address) {
        return address(_weth);
    }

    function totalAssets() public view override returns (uint256) {
        return _weth.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxMint(address) public pure override returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Ceil);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        return _convertToShares(assets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return _convertToAssets(shares, Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        shares = previewDeposit(assets);
        _weth.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256 assets) {
        assets = previewMint(shares);
        _weth.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        _weth.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        assets = previewRedeem(shares);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        _weth.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    /* ETH-SPECIFIC FUNCTIONS */

    /// @inheritdoc IAlphix4626WrapperWeth
    function depositETH(address receiver) external payable override returns (uint256 shares) {
        uint256 assets = msg.value;
        shares = previewDeposit(assets);

        // Wrap ETH to WETH by calling deposit on WETH contract
        (bool success,) = address(_weth).call{value: assets}("");
        require(success, "WETH deposit failed");

        _mint(receiver, shares);
        emit DepositETH(msg.sender, receiver, assets, shares);
    }

    /// @inheritdoc IAlphix4626WrapperWeth
    function withdrawETH(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        shares = previewWithdraw(assets);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);

        // Unwrap WETH to ETH
        _unwrapAndSendETH(assets, receiver);

        emit WithdrawETH(msg.sender, receiver, owner, assets, shares);
    }

    /// @inheritdoc IAlphix4626WrapperWeth
    function redeemETH(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        assets = previewRedeem(shares);
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);

        // Unwrap WETH to ETH
        _unwrapAndSendETH(assets, receiver);

        emit WithdrawETH(msg.sender, receiver, owner, assets, shares);
    }

    /* TEST HELPER FUNCTIONS */

    /**
     * @notice Simulate yield generation by minting WETH to the vault.
     * @dev This increases the value of all shares proportionally.
     * @param amount Amount of WETH to add as yield.
     */
    function simulateYield(uint256 amount) external {
        _weth.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Simulate a loss by burning WETH from the vault.
     * @dev This decreases the value of all shares proportionally.
     * @param amount Amount of WETH to remove.
     */
    function simulateLoss(uint256 amount) external {
        uint256 balance = _weth.balanceOf(address(this));
        require(amount <= balance, "Cannot lose more than balance");
        _weth.safeTransfer(_admin, amount);
    }

    /* RECEIVE ETH */

    /**
     * @notice Accept ETH from WETH contract during unwrap.
     */
    receive() external payable {
        // Only accept ETH from WETH contract (during unwrap)
        if (msg.sender != address(_weth)) revert ReceiveNotAllowed();
    }

    /**
     * @notice Reject any fallback calls.
     */
    fallback() external payable {
        revert FallbackNotAllowed();
    }

    /* INTERNAL FUNCTIONS */

    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply();
        return (supply == 0) ? assets : assets.mulDiv(supply, totalAssets(), rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view returns (uint256) {
        uint256 supply = totalSupply();
        return (supply == 0) ? shares : shares.mulDiv(totalAssets(), supply, rounding);
    }

    function _unwrapAndSendETH(uint256 amount, address receiver) internal {
        // Call withdraw on WETH to unwrap
        (bool success,) = address(_weth).call(abi.encodeWithSignature("withdraw(uint256)", amount));
        require(success, "WETH withdraw failed");

        // Send ETH to receiver
        (success,) = receiver.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    // Exclude from coverage report
    function test() public {}
}
