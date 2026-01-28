// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockAToken
 * @author Alphix
 * @notice Mock Aave aToken for testing purposes.
 * @dev Simple 1:1 aToken implementation without rebasing complexity.
 *      Yield is simulated by minting new aTokens directly.
 */
contract MockAToken is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable UNDERLYING_ASSET;
    address public pool;
    address public incentivesController;

    uint8 private immutable TOKEN_DECIMALS;

    /**
     * @notice Constructs the mock aToken.
     * @param name_ The token name.
     * @param symbol_ The token symbol.
     * @param decimals_ The token decimals.
     * @param underlying_ The underlying asset address.
     * @param pool_ The pool address.
     */
    constructor(string memory name_, string memory symbol_, uint8 decimals_, address underlying_, address pool_)
        ERC20(name_, symbol_)
    {
        TOKEN_DECIMALS = decimals_;
        UNDERLYING_ASSET = IERC20(underlying_);
        pool = pool_;
    }

    /**
     * @notice Returns the token decimals.
     * @return The number of decimals.
     */
    function decimals() public view override returns (uint8) {
        return TOKEN_DECIMALS;
    }

    /**
     * @notice Returns the scaled total supply (same as totalSupply for this mock).
     * @return The total supply.
     */
    function scaledTotalSupply() external view returns (uint256) {
        return totalSupply();
    }

    /**
     * @notice Returns the scaled balance of an account (same as balanceOf for this mock).
     * @param account The account address.
     * @return The balance.
     */
    function scaledBalanceOf(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /**
     * @notice Mints aTokens to an address (called by pool on supply).
     * @param onBehalfOf The recipient address.
     * @param amount The amount to mint.
     * @return True if successful.
     */
    function mint(address, address onBehalfOf, uint256 amount, uint256) external returns (bool) {
        _mint(onBehalfOf, amount);
        return true;
    }

    /**
     * @notice Burns aTokens from an address (called by pool on withdraw).
     * @param from The address to burn from.
     * @param receiverOfUnderlying The receiver of underlying assets.
     * @param amount The amount to burn.
     */
    function burn(address from, address receiverOfUnderlying, uint256 amount, uint256) external {
        _burn(from, amount);
        // Transfer underlying to receiver
        UNDERLYING_ASSET.safeTransfer(receiverOfUnderlying, amount);
    }

    /**
     * @notice Sets the pool address (for testing flexibility).
     * @param pool_ The new pool address.
     */
    function setPool(address pool_) external {
        pool = pool_;
    }

    /**
     * @notice Simulates yield by minting aTokens to an address.
     * @param account The account to receive yield.
     * @param amount The amount of yield to simulate.
     * @dev For testing purposes only.
     */
    function simulateYield(address account, uint256 amount) external {
        _mint(account, amount);
    }

    /**
     * @notice Simulates negative yield (slashing) by burning aTokens from an address.
     * @param account The account to slash.
     * @param amount The amount to slash.
     * @dev For testing purposes only. Simulates events like Aave slashing.
     */
    function simulateSlash(address account, uint256 amount) external {
        _burn(account, amount);
    }

    /**
     * @notice Sets the incentives controller address (for testing).
     * @param controller_ The new incentives controller address.
     */
    function setIncentivesController(address controller_) external {
        incentivesController = controller_;
    }

    /**
     * @notice Returns the incentives controller address.
     * @return The incentives controller address.
     */
    function getIncentivesController() external view returns (address) {
        return incentivesController;
    }
}
