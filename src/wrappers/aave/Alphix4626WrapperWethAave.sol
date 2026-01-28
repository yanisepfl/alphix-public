// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Alphix4626WrapperAave} from "./Alphix4626WrapperAave.sol";
import {IAlphix4626WrapperWethAave} from "./interfaces/IAlphix4626WrapperWethAave.sol";
import {IWETH} from "@aave-v3-core/misc/interfaces/IWETH.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title Alphix4626WrapperWethAave
 * @author Alphix
 * @notice WETH-specific Alphix 4626 Wrapper for Aave V3 with native ETH support.
 * @dev Extends Alphix4626WrapperAave with ETH wrap/unwrap functionality.
 *
 * ## Additional Functions
 * - `depositETH()`: Wraps native ETH to WETH and deposits into the vault
 * - `withdrawETH()`: Withdraws from vault, unwraps WETH to ETH, sends to receiver
 * - `redeemETH()`: Redeems shares, unwraps WETH to ETH, sends to receiver
 *
 * ## Compatibility
 * The standard ERC4626 functions (`deposit`, `withdraw`, `redeem`) still work with WETH directly.
 * Users can choose to interact with either ETH (via ETH functions) or WETH (via standard functions).
 *
 * ## ETH Handling
 * - Only the WETH contract can send ETH to this contract (during unwrap operations)
 * - Accidental ETH sends from other addresses will revert
 * - All ETH functions are protected by reentrancy guards
 *
 * All other behavior (fees, access control, ERC4626 deviations) is inherited from the parent.
 */
contract Alphix4626WrapperWethAave is Alphix4626WrapperAave, IAlphix4626WrapperWethAave {
    using Math for uint256;

    /* STORAGE */

    /**
     * @notice The WETH contract.
     * @dev Same as ASSET, but stored as IWETH for interface clarity.
     */
    IWETH public immutable WETH;

    /* CONSTRUCTOR */

    /**
     * @notice Constructs the WETH 4626 Wrapper.
     * @param weth_ The WETH contract address (also the underlying asset).
     * @param yieldTreasury_ The address where fees are sent when collected.
     * @param poolAddressesProvider_ The Aave V3 Pool Addresses Provider.
     * @param shareName The name of the share token.
     * @param shareSymbol The symbol of the share token.
     * @param initialFee The initial fee (in hundredths of a bip).
     * @param seedLiquidity The seed amount of WETH to deposit (must be pre-wrapped).
     * @dev Deployer must have WETH and approve it before deployment.
     */
    constructor(
        address weth_,
        address yieldTreasury_,
        address poolAddressesProvider_,
        string memory shareName,
        string memory shareSymbol,
        uint24 initialFee,
        uint256 seedLiquidity
    )
        Alphix4626WrapperAave(
            weth_, yieldTreasury_, poolAddressesProvider_, shareName, shareSymbol, initialFee, seedLiquidity
        )
    {
        WETH = IWETH(weth_);
    }

    /* ETH DEPOSIT */

    /**
     * @inheritdoc IAlphix4626WrapperWethAave
     * @dev Slither flags reentrancy-eth due to state writes after external calls (WETH.deposit, AAVE_POOL.supply).
     *      This is a FALSE POSITIVE: the `nonReentrant` modifier from OpenZeppelin's ReentrancyGuard prevents
     *      any reentrant calls by setting a lock at function entry and reverting if already locked.
     *      The receiver must be the caller (receiver == msg.sender).
     */
    // slither-disable-next-line reentrancy-eth
    function depositETH(address receiver)
        external
        payable
        onlyAlphixHookOrOwner
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (receiver != msg.sender) revert InvalidReceiver();
        if (msg.value == 0) revert ZeroAmount();
        if (msg.value > maxDeposit(msg.sender)) revert DepositExceedsMax();

        // Wrap ETH to WETH
        WETH.deposit{value: msg.value}();

        // Accrue yield and calculate shares
        _accrueYield();
        shares = _convertToShares(msg.value, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();

        // Supply WETH to Aave (already in contract, no transferFrom needed)
        AAVE_POOL.supply(address(ASSET), msg.value, address(this), REFERRAL_CODE);
        _lastWrapperBalance = uint128(ATOKEN.balanceOf(address(this)));
        _mint(receiver, shares);

        emit DepositETH(msg.sender, msg.sender, msg.value, shares);
    }

    /* ETH WITHDRAW */

    /**
     * @inheritdoc IAlphix4626WrapperWethAave
     * @dev The caller must be the owner of the shares (owner_ == msg.sender).
     */
    function withdrawETH(uint256 assets, address receiver, address owner_)
        external
        onlyAlphixHookOrOwner
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (owner_ != msg.sender) revert CallerNotOwner();
        _accrueYield();
        if (assets > maxWithdraw(msg.sender)) revert WithdrawExceedsMax();
        shares = _convertToShares(assets, Math.Rounding.Ceil);
        if (shares == 0) revert ZeroShares();

        // Burn shares
        _burn(msg.sender, shares);

        // Withdraw WETH from Aave to this contract
        AAVE_POOL.withdraw(address(ASSET), assets, address(this));
        _lastWrapperBalance = uint128(ATOKEN.balanceOf(address(this)));

        // Unwrap WETH to ETH and send to receiver
        WETH.withdraw(assets);
        _safeTransferETH(receiver, assets);

        emit WithdrawETH(msg.sender, receiver, msg.sender, assets, shares);
    }

    /* ETH REDEEM */

    /**
     * @inheritdoc IAlphix4626WrapperWethAave
     * @dev The caller must be the owner of the shares (owner_ == msg.sender).
     */
    function redeemETH(uint256 shares, address receiver, address owner_)
        external
        onlyAlphixHookOrOwner
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (owner_ != msg.sender) revert CallerNotOwner();
        _accrueYield();
        if (shares > maxRedeem(msg.sender)) revert RedeemExceedsMax();
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        if (assets == 0) revert ZeroAssets();

        // Burn shares
        _burn(msg.sender, shares);

        // Withdraw WETH from Aave to this contract
        AAVE_POOL.withdraw(address(ASSET), assets, address(this));
        _lastWrapperBalance = uint128(ATOKEN.balanceOf(address(this)));

        // Unwrap WETH to ETH and send to receiver
        WETH.withdraw(assets);
        _safeTransferETH(receiver, assets);

        emit WithdrawETH(msg.sender, receiver, msg.sender, assets, shares);
    }

    /* ETH RECEIVE */

    /**
     * @notice Only WETH contract can send ETH to this contract.
     * @dev This is called by WETH.withdraw() when unwrapping WETH to ETH.
     *      Reverts if called by any other address to prevent accidental ETH sends.
     */
    receive() external payable {
        if (msg.sender != address(WETH)) revert ReceiveNotAllowed();
    }

    /**
     * @notice Rejects any fallback calls with data.
     * @dev Prevents accidental calls to non-existent functions.
     */
    fallback() external payable {
        revert FallbackNotAllowed();
    }

    /* INTERNAL HELPERS */

    /**
     * @notice Safely transfers ETH to an address.
     * @param to The recipient address.
     * @param value The amount of ETH to transfer.
     * @dev Reverts with ETHTransferFailed if the transfer fails.
     */
    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        if (!success) revert ETHTransferFailed();
    }
}
