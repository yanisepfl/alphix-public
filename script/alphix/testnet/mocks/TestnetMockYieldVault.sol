// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TestnetMockYieldVault
 * @notice A mock ERC-4626 yield vault for testnet deployments
 * @dev Allows anyone to simulate yield (positive or negative) for testing
 *
 * TESTNET ONLY - DO NOT USE IN PRODUCTION
 *
 * Features:
 * - Standard ERC-4626 vault interface
 * - Anyone can simulate positive yield (increases share value)
 * - Anyone can simulate negative yield/loss (decreases share value)
 * - Yield simulation doesn't require holding shares
 *
 * How it works:
 * - Positive yield: Caller transfers additional assets to the vault
 * - Negative yield: Vault burns some of its assets (transfers out to dead address)
 */
contract TestnetMockYieldVault is ERC4626 {
    using SafeERC20 for IERC20;

    /// @notice Dead address for simulating losses
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event YieldSimulated(address indexed caller, int256 amount);

    /**
     * @notice Deploy a new mock yield vault
     * @param asset_ The underlying ERC20 asset for this vault
     * @param name_ Vault share token name (e.g., "Alphix Testnet USDC Vault")
     * @param symbol_ Vault share token symbol (e.g., "atUSDC-V")
     */
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    /**
     * @notice Simulate positive yield by adding assets to the vault
     * @dev Caller must have approved the vault to transfer assets
     *      This increases the value of all shares proportionally
     * @param amount Amount of underlying assets to add as yield
     */
    function simulateYield(uint256 amount) external {
        require(amount > 0, "Amount must be positive");
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
        // Casting is safe: amount is uint256 and int256 max is 2^255-1, which is plenty for token amounts
        // forge-lint: disable-next-line(unsafe-typecast)
        emit YieldSimulated(msg.sender, int256(amount));
    }

    /**
     * @notice Simulate negative yield (loss) by removing assets from the vault
     * @dev This decreases the value of all shares proportionally
     *      Assets are sent to a dead address to simulate a real loss
     * @param amount Amount of underlying assets to remove as loss
     */
    function simulateLoss(uint256 amount) external {
        require(amount > 0, "Amount must be positive");
        uint256 balance = IERC20(asset()).balanceOf(address(this));
        require(amount <= balance, "Cannot lose more than vault balance");

        // Transfer assets to dead address to simulate loss
        IERC20(asset()).safeTransfer(DEAD, amount);
        // Casting is safe: amount is uint256 and int256 max is 2^255-1, which is plenty for token amounts
        // forge-lint: disable-next-line(unsafe-typecast)
        emit YieldSimulated(msg.sender, -int256(amount));
    }

    /**
     * @notice Get the current total assets in the vault
     * @dev Includes all deposited assets plus any simulated yield/loss
     * @return Total assets available in the vault
     */
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
