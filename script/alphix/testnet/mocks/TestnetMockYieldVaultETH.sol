// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAlphix4626WrapperWeth} from "../../../../src/interfaces/IAlphix4626WrapperWeth.sol";

/**
 * @title IWETH9
 * @notice Minimal WETH9 interface for ETH wrapping/unwrapping
 */
interface IWETH9 is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

/**
 * @title TestnetMockYieldVaultETH
 * @notice A mock ERC-4626 yield vault for ETH that implements IAlphix4626WrapperWeth
 * @dev Allows native ETH deposits/withdrawals via WETH wrapping
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Features:
 * - Standard ERC-4626 vault interface (using WETH as asset)
 * - Native ETH deposit/withdraw via IAlphix4626WrapperWeth interface
 * - Anyone can simulate positive yield (increases share value)
 * - Anyone can simulate negative yield/loss (decreases share value)
 *
 * How it works:
 * - depositETH(): Wraps ETH -> WETH -> deposits to vault
 * - withdrawETH(): Withdraws from vault -> unwraps WETH -> sends ETH
 * - Positive yield: Caller transfers additional WETH to the vault
 * - Negative yield: Vault burns some of its WETH (transfers to dead address)
 */
contract TestnetMockYieldVaultETH is ERC4626, IAlphix4626WrapperWeth {
    using SafeERC20 for IERC20;

    /// @notice WETH contract for ETH wrapping/unwrapping
    IWETH9 public immutable weth;

    /// @notice Dead address for simulating losses
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event YieldSimulated(address indexed caller, int256 amount);

    /**
     * @notice Deploy a new mock ETH yield vault
     * @param weth_ The WETH contract address
     * @param name_ Vault share token name (e.g., "Alphix Testnet ETH Vault")
     * @param symbol_ Vault share token symbol (e.g., "atETH-V")
     */
    constructor(address weth_, string memory name_, string memory symbol_)
        ERC4626(IERC20(weth_))
        ERC20(name_, symbol_)
    {
        weth = IWETH9(weth_);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              ETH DEPOSIT/WITHDRAW FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Deposits native ETH, wraps it to WETH, and deposits into the vault
     * @param receiver The address that will receive the shares
     * @return shares The amount of shares minted
     * @dev Wraps msg.value ETH to WETH before depositing
     */
    function depositETH(address receiver) external payable override returns (uint256 shares) {
        require(msg.value > 0, "Must send ETH");

        // Calculate shares BEFORE wrapping ETH (otherwise totalAssets increases first,
        // causing previewDeposit to return 0 when totalSupply is 0)
        shares = previewDeposit(msg.value);

        // Wrap ETH -> WETH
        weth.deposit{value: msg.value}();

        // Mint shares to receiver
        _mint(receiver, shares);

        emit DepositETH(msg.sender, receiver, msg.value, shares);
    }

    /**
     * @notice Withdraws assets from the vault and sends them as native ETH
     * @param assets The amount of assets (WETH) to withdraw
     * @param receiver The address that will receive the ETH
     * @param owner The address that owns the shares
     * @return shares The amount of shares burned
     */
    function withdrawETH(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        require(assets > 0, "Must withdraw something");

        shares = previewWithdraw(assets);

        // Handle allowance if caller is not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn shares from owner
        _burn(owner, shares);

        // Unwrap WETH -> ETH and send to receiver
        weth.withdraw(assets);
        _sendETH(receiver, assets);

        emit WithdrawETH(msg.sender, receiver, owner, assets, shares);
    }

    /**
     * @notice Redeems shares from the vault and sends the assets as native ETH
     * @param shares The amount of shares to redeem
     * @param receiver The address that will receive the ETH
     * @param owner The address that owns the shares
     * @return assets The amount of ETH withdrawn
     */
    function redeemETH(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        require(shares > 0, "Must redeem something");

        assets = previewRedeem(shares);

        // Handle allowance if caller is not owner
        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        // Burn shares from owner
        _burn(owner, shares);

        // Unwrap WETH -> ETH and send to receiver
        weth.withdraw(assets);
        _sendETH(receiver, assets);

        emit WithdrawETH(msg.sender, receiver, owner, assets, shares);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              YIELD SIMULATION (TESTNET ONLY)
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Simulate positive yield by adding WETH to the vault
     * @dev Caller must have approved the vault to transfer WETH
     *      This increases the value of all shares proportionally
     * @param amount Amount of WETH to add as yield
     */
    function simulateYield(uint256 amount) external {
        require(amount > 0, "Amount must be positive");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        // Casting is safe: amount is uint256 and int256 max is 2^255-1
        // forge-lint: disable-next-line(unsafe-typecast)
        emit YieldSimulated(msg.sender, int256(amount));
    }

    /**
     * @notice Simulate positive yield by sending ETH directly
     * @dev Wraps ETH to WETH and adds to vault as yield
     */
    function simulateYieldETH() external payable {
        require(msg.value > 0, "Must send ETH");
        weth.deposit{value: msg.value}();
        // Casting is safe: msg.value is uint256 and int256 max is 2^255-1
        // forge-lint: disable-next-line(unsafe-typecast)
        emit YieldSimulated(msg.sender, int256(msg.value));
    }

    /**
     * @notice Simulate negative yield (loss) by removing WETH from the vault
     * @dev This decreases the value of all shares proportionally
     *      Assets are sent to a dead address to simulate a real loss
     * @param amount Amount of WETH to remove as loss
     */
    function simulateLoss(uint256 amount) external {
        require(amount > 0, "Amount must be positive");
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        require(amount <= balance, "Cannot lose more than vault balance");

        // Transfer WETH to dead address to simulate loss
        IERC20(asset()).safeTransfer(DEAD, amount);
        // Casting is safe: amount is uint256 and int256 max is 2^255-1
        // forge-lint: disable-next-line(unsafe-typecast)
        emit YieldSimulated(msg.sender, -int256(amount));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    VIEW FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Get the current total assets (WETH) in the vault
     * @dev Includes all deposited assets plus any simulated yield/loss
     * @return Total WETH available in the vault
     */
    function totalAssets() public view virtual override(ERC4626, IERC4626) returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                  INTERNAL FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Internal helper to send ETH to a receiver
     * @param to The address to send ETH to
     * @param amount The amount of ETH to send
     */
    function _sendETH(address to, uint256 amount) internal {
        (bool success,) = to.call{value: amount}("");
        if (!success) revert ETHTransferFailed();
    }

    /**
     * @notice Receive ETH from WETH unwrapping
     * @dev Only accepts ETH from the WETH contract
     */
    receive() external payable {
        if (msg.sender != address(weth)) revert ReceiveNotAllowed();
    }

    /**
     * @notice Reject any other ETH transfers
     */
    fallback() external payable {
        revert FallbackNotAllowed();
    }
}
