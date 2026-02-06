// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

/**
 * @title IReHypothecation.
 * @notice Interface for ReHypothecation functionality in Alphix.
 * @dev Defines the external API for yield source management with JIT liquidity provisioning.
 *      All management functions are gated by YIELD_MANAGER_ROLE via AccessManager.
 *
 *      SINGLE POOL DESIGN:
 *      - Each Alphix instance serves exactly one pool (stored in _poolKey)
 *      - Shares are ERC20 tokens (Alphix inherits ERC20)
 *      - Use IERC20.totalSupply() and IERC20.balanceOf() for share accounting
 *
 *      JIT LIQUIDITY FLOW:
 *      1. Users deposit assets → assets go to ERC-4626 yield sources
 *      2. beforeSwap: compute JIT params → add liquidity to pool (no settlement)
 *      3. Swap executes using the liquidity
 *      4. afterSwap: remove liquidity from pool → resolve deltas → deposit/withdraw yield sources
 */
interface IReHypothecation is IERC20 {
    /* STRUCTS */

    /**
     * @dev Configuration for the pool's rehypothecation settings.
     * @param tickLower Lower tick boundary for JIT liquidity position.
     * @param tickUpper Upper tick boundary for JIT liquidity position.
     */
    struct ReHypothecationConfig {
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @dev State for tracking yield source deposits per currency.
     * @param yieldSource The ERC-4626 vault address for this currency.
     * @param sharesOwned The amount of ERC-4626 vault shares owned by the hook.
     */
    struct YieldSourceState {
        address yieldSource;
        uint256 sharesOwned;
    }

    /* EVENTS */

    /**
     * @dev Emitted when a yield source is set or updated for a currency.
     */
    event YieldSourceUpdated(Currency indexed currency, address oldYieldSource, address newYieldSource);

    /**
     * @dev Emitted when rehypothecated liquidity is added.
     */
    event ReHypothecatedLiquidityAdded(address indexed sender, uint256 shares, uint256 amount0, uint256 amount1);

    /**
     * @dev Emitted when rehypothecated liquidity is removed.
     */
    event ReHypothecatedLiquidityRemoved(address indexed sender, uint256 shares, uint256 amount0, uint256 amount1);

    /* ERRORS */

    /**
     * @dev Thrown when attempting to set an invalid yield source (not ERC-4626 compliant).
     */
    error InvalidYieldSource();

    /**
     * @dev Thrown when attempting to interact without a yield source configured.
     */
    error YieldSourceNotConfigured();

    /**
     * @dev Thrown when attempting operations with zero shares.
     */
    error ZeroShares();

    /**
     * @dev Thrown when both deposit amounts are zero (nothing to deposit).
     */
    error ZeroAmounts();

    /**
     * @dev Thrown when tick range is invalid.
     */
    error InvalidTickRange();

    /**
     * @dev Thrown when msg.value doesn't match expected amount for native ETH.
     */
    error InvalidMsgValue();

    /**
     * @dev Thrown when a refund fails.
     */
    error RefundFailed();

    /**
     * @dev Thrown when user has insufficient shares.
     */
    error InsufficientShares();

    /**
     * @dev Thrown when attempting to use ETH in the ERC20-only variant.
     */
    error UnsupportedNativeCurrency();

    /**
     * @dev Thrown when price moved beyond acceptable slippage tolerance.
     * @param expectedPrice The price the user expected.
     * @param actualPrice The actual price at execution time.
     * @param maxSlippage The maximum slippage tolerance (same scale as LP fee, 1000000 = 100%).
     */
    error PriceSlippageExceeded(uint160 expectedPrice, uint160 actualPrice, uint24 maxSlippage);

    /* YIELD MANAGER FUNCTIONS (gated by AccessManager YIELD_MANAGER_ROLE) */

    /**
     * @notice Set the yield source for a currency.
     * @dev If a yield source already exists, harvests accrued yield first, then migrates.
     *      Gated by YIELD_MANAGER_ROLE via AccessManager.
     * @param currency The currency to set the yield source for.
     * @param yieldSource The ERC-4626 vault address.
     */
    function setYieldSource(Currency currency, address yieldSource) external;

    /* VIEW FUNCTIONS */

    /**
     * @notice Get the pool key this contract serves.
     */
    function getPoolKey() external view returns (PoolKey memory);

    /**
     * @notice Get the yield source for a currency.
     */
    function getCurrencyYieldSource(Currency currency) external view returns (address yieldSource);

    /**
     * @notice Get the amount of assets in the yield source for a currency.
     */
    function getAmountInYieldSource(Currency currency) external view returns (uint256 amount);

    /**
     * @notice Get the rehypothecation configuration.
     */
    function getReHypothecationConfig() external view returns (ReHypothecationConfig memory config);

    /**
     * @notice Preview amounts required to add a given number of shares.
     * @dev For users who want to specify shares and see required token amounts for deposit.
     *      Rounds up (protocol-favorable for deposits).
     */
    function previewAddReHypothecatedLiquidity(uint256 shares) external view returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Preview amounts received for removing a given number of shares.
     * @dev For users who want to specify shares and see token amounts they'll receive.
     *      Rounds down (protocol-favorable for withdrawals).
     */
    function previewRemoveReHypothecatedLiquidity(uint256 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Preview deposit by specifying amount0.
     * @dev For users who want to specify amount0 and see the required amount1 and resulting shares.
     *      Guarantees that calling addReHypothecatedLiquidity(shares) will require at most amount0 and amount1.
     * @param amount0 The amount of currency0 the user wants to deposit.
     * @return amount1 The required amount of currency1 for a proportional deposit.
     * @return shares The shares that will be minted.
     */
    function previewAddFromAmount0(uint256 amount0) external view returns (uint256 amount1, uint256 shares);

    /**
     * @notice Preview deposit by specifying amount1.
     * @dev For users who want to specify amount1 and see the required amount0 and resulting shares.
     *      Guarantees that calling addReHypothecatedLiquidity(shares) will require at most amount0 and amount1.
     * @param amount1 The amount of currency1 the user wants to deposit.
     * @return amount0 The required amount of currency0 for a proportional deposit.
     * @return shares The shares that will be minted.
     */
    function previewAddFromAmount1(uint256 amount1) external view returns (uint256 amount0, uint256 shares);

    /* LIQUIDITY OPERATIONS (permissionless, but pool must be active) */

    /**
     * @notice Add rehypothecated liquidity with slippage protection.
     * @dev Deposits assets into yield sources and mints shares to sender.
     *      Pool must be active (uses existing poolActivated modifier).
     * @param shares Number of shares to mint.
     * @param expectedSqrtPriceX96 Expected price (pass 0 to skip slippage check).
     * @param maxPriceSlippage Max allowed price deviation, same scale as LP fee (1000000 = 100%).
     * @return delta Balance delta representing assets deposited.
     */
    function addReHypothecatedLiquidity(uint256 shares, uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage)
        external
        payable
        returns (BalanceDelta delta);

    /**
     * @notice Remove rehypothecated liquidity with slippage protection.
     * @dev Burns shares and withdraws assets from yield sources to sender.
     *      Pool must be active (uses existing poolActivated modifier).
     * @param shares Number of shares to burn.
     * @param expectedSqrtPriceX96 Expected price (pass 0 to skip slippage check).
     * @param maxPriceSlippage Max allowed price deviation, same scale as LP fee (1000000 = 100%).
     * @return delta Balance delta representing assets withdrawn.
     */
    function removeReHypothecatedLiquidity(uint256 shares, uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage)
        external
        returns (BalanceDelta delta);
}
