// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/* UNISWAP V4 IMPORTS */
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/**
 * @title ReHypothecationLib
 * @notice Library for managing rehypothecation of liquidity positions with ERC-4626 yield sources.
 * @dev Provides pure and internal functions for yield source interactions and JIT liquidity provisioning.
 *      This library is designed to be used by AlphixLogic to minimize contract size.
 *
 *      RATE-BASED YIELD TRACKING:
 *      Instead of tracking total assets, we track the exchange rate (assets per 1e18 shares).
 *      This simplifies yield calculation: yield = (currentRate - lastRate) * sharesOwned / 1e18
 *
 *      JIT LIQUIDITY PATTERN (following OpenZeppelin):
 *      - beforeSwap: Calculate liquidity from yield source balances, add to pool
 *      - afterSwap: Remove all liquidity, resolve deltas with yield sources
 */
library ReHypothecationLib {
    using SafeERC20 for IERC20;

    /* CONSTANTS */

    /**
     * @dev Default rate precision for yield tracking when vault has no decimals() function.
     */
    uint256 internal constant DEFAULT_RATE_PRECISION = 1e18;

    /* ERRORS */

    error InvalidYieldSource(address yieldSource);
    error ZeroShares();
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    error InvalidYieldTaxPips(uint24 yieldTaxPips);
    error AssetMismatch(address expected, address actual);

    /* VALIDATION FUNCTIONS */

    /**
     * @notice Validate that an address is a valid ERC-4626 vault for the given currency.
     * @dev Native ETH (currency == address(0)) is not supported since ERC-4626 vaults only hold ERC20 tokens.
     *      Pools with native ETH as one currency can still participate in rehypothecation for the other currency.
     * @param yieldSource The address to validate.
     * @param currency The currency the vault should accept.
     * @return isValid True if the yield source is valid.
     */
    function isValidYieldSource(address yieldSource, Currency currency) internal view returns (bool isValid) {
        if (yieldSource == address(0)) return false;
        if (yieldSource.code.length == 0) return false;

        // Native ETH is not supported - ERC-4626 vaults only hold ERC20 tokens
        if (currency.isAddressZero()) return false;

        // Check ERC-4626 asset matches currency
        try IERC4626(yieldSource).asset() returns (address asset) {
            return asset == Currency.unwrap(currency);
        } catch {
            return false;
        }
    }

    /**
     * @notice Validate tick range is valid for the pool's tick spacing.
     * @param tickLower Lower tick boundary.
     * @param tickUpper Upper tick boundary.
     * @param tickSpacing Pool's tick spacing.
     */
    function validateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) internal pure {
        if (tickLower >= tickUpper) revert InvalidTickRange(tickLower, tickUpper);
        if (tickLower < TickMath.MIN_TICK) revert InvalidTickRange(tickLower, tickUpper);
        if (tickUpper > TickMath.MAX_TICK) revert InvalidTickRange(tickLower, tickUpper);
        if (tickLower % tickSpacing != 0) revert InvalidTickRange(tickLower, tickUpper);
        if (tickUpper % tickSpacing != 0) revert InvalidTickRange(tickLower, tickUpper);
    }

    /**
     * @notice Validate yield tax is within bounds (uses Uniswap's MAX_LP_FEE = 1e6 = 100%).
     * @param yieldTaxPips Yield tax in pips.
     */
    function validateYieldTaxPips(uint24 yieldTaxPips) internal pure {
        if (yieldTaxPips > LPFeeLibrary.MAX_LP_FEE) revert InvalidYieldTaxPips(yieldTaxPips);
    }

    /* YIELD SOURCE OPERATIONS */

    /**
     * @notice Deposit assets into an ERC-4626 yield source.
     * @param yieldSource The ERC-4626 vault address.
     * @param currency The currency to deposit.
     * @param amount The amount to deposit.
     * @return sharesReceived The number of vault shares received.
     */
    function depositToYieldSource(address yieldSource, Currency currency, uint256 amount)
        internal
        returns (uint256 sharesReceived)
    {
        if (amount == 0) return 0;

        address asset = Currency.unwrap(currency);
        IERC20(asset).forceApprove(yieldSource, amount);
        sharesReceived = IERC4626(yieldSource).deposit(amount, address(this));
    }

    /**
     * @notice Withdraw assets from an ERC-4626 yield source to a recipient.
     * @param yieldSource The ERC-4626 vault address.
     * @param amount The amount of underlying assets to withdraw.
     * @param recipient The address to receive the withdrawn assets (use address(this) for self).
     * @return sharesRedeemed The number of vault shares redeemed.
     */
    function withdrawFromYieldSourceTo(address yieldSource, uint256 amount, address recipient)
        internal
        returns (uint256 sharesRedeemed)
    {
        if (amount == 0) return 0;
        sharesRedeemed = IERC4626(yieldSource).withdraw(amount, recipient, address(this));
    }

    /**
     * @notice Get the share unit for a yield source (10 ** decimals).
     * @param yieldSource The ERC-4626 vault address.
     * @return unit The share unit (e.g., 1e18 for 18 decimals, 1e6 for 6 decimals).
     */
    function getShareUnit(address yieldSource) internal view returns (uint256 unit) {
        if (yieldSource == address(0)) return DEFAULT_RATE_PRECISION;
        return 10 ** IERC4626(yieldSource).decimals();
    }

    /**
     * @notice Get the current exchange rate (assets per 1 share unit).
     * @dev Uses the vault's decimals to determine the share unit for rate calculation.
     * @param yieldSource The ERC-4626 vault address.
     * @return rate The current rate (assets per share unit).
     * @return shareUnit The share unit used for rate calculation.
     */
    function getCurrentRate(address yieldSource) internal view returns (uint256 rate, uint256 shareUnit) {
        if (yieldSource == address(0)) return (DEFAULT_RATE_PRECISION, DEFAULT_RATE_PRECISION);
        shareUnit = 10 ** IERC4626(yieldSource).decimals();
        rate = IERC4626(yieldSource).convertToAssets(shareUnit);
    }

    /**
     * @notice Get the amount of underlying assets for given shares.
     * @param yieldSource The ERC-4626 vault address.
     * @param sharesOwned The number of shares.
     * @return amount The underlying asset amount.
     */
    function getAmountInYieldSource(address yieldSource, uint256 sharesOwned) internal view returns (uint256 amount) {
        if (sharesOwned == 0 || yieldSource == address(0)) return 0;
        return IERC4626(yieldSource).convertToAssets(sharesOwned);
    }

    /**
     * @notice Migrate liquidity from one yield source to another.
     * @param oldYieldSource The current yield source.
     * @param newYieldSource The new yield source.
     * @param currency The currency being migrated.
     * @param sharesOwned The shares owned in the old yield source.
     * @return newSharesOwned The shares now owned in the new yield source.
     */
    function migrateYieldSource(address oldYieldSource, address newYieldSource, Currency currency, uint256 sharesOwned)
        internal
        returns (uint256 newSharesOwned)
    {
        if (sharesOwned == 0) return 0;

        // Redeem all shares from old yield source
        uint256 assetsWithdrawn = IERC4626(oldYieldSource).redeem(sharesOwned, address(this), address(this));

        // Deposit all assets into new yield source
        newSharesOwned = depositToYieldSource(newYieldSource, currency, assetsWithdrawn);
    }

    /* RATE-BASED YIELD CALCULATION */

    /**
     * @notice Calculate yield based on rate change.
     * @dev yield = (currentRate - lastRate) * sharesOwned / shareUnit
     *      If rate decreased (negative yield), returns 0.
     * @param yieldSource The ERC-4626 vault address.
     * @param sharesOwned The shares owned.
     * @param lastRecordedRate The last recorded rate.
     * @return yieldAmount The yield generated (0 if negative).
     * @return currentRate The current rate.
     */
    function calculateYieldFromRate(address yieldSource, uint256 sharesOwned, uint256 lastRecordedRate)
        internal
        view
        returns (uint256 yieldAmount, uint256 currentRate)
    {
        uint256 shareUnit;
        (currentRate, shareUnit) = getCurrentRate(yieldSource);

        if (currentRate > lastRecordedRate && sharesOwned > 0) {
            uint256 rateIncrease = currentRate - lastRecordedRate;
            yieldAmount = FullMath.mulDiv(rateIncrease, sharesOwned, shareUnit);
        }
    }

    /**
     * @notice Calculate tax amount from yield.
     * @param yieldAmount The yield amount.
     * @param yieldTaxPips Tax rate in pips (1e6 = 100%, same as Uniswap MAX_LP_FEE).
     * @return taxAmount The tax amount.
     */
    function calculateTaxFromYield(uint256 yieldAmount, uint24 yieldTaxPips) internal pure returns (uint256 taxAmount) {
        if (yieldAmount == 0 || yieldTaxPips == 0) return 0;
        taxAmount = FullMath.mulDiv(yieldAmount, yieldTaxPips, LPFeeLibrary.MAX_LP_FEE);
    }

    /* JIT LIQUIDITY FUNCTIONS (following OpenZeppelin pattern) */

    /**
     * @notice Calculate liquidity to use for JIT based on available assets.
     * @param currentSqrtPriceX96 The current sqrt price of the pool.
     * @param tickLower Lower tick boundary.
     * @param tickUpper Upper tick boundary.
     * @param amount0Available Amount of currency0 available.
     * @param amount1Available Amount of currency1 available.
     * @return liquidity The liquidity amount to use.
     */
    function getLiquidityToUse(
        uint160 currentSqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Available,
        uint256 amount1Available
    ) internal pure returns (uint128 liquidity) {
        return LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Available,
            amount1Available
        );
    }

    /* SHARE CALCULATIONS */

    /**
     * @notice Convert shares to underlying amounts based on pool balances (rounds down).
     * @dev Use for withdrawals where rounding down is protocol-favorable.
     * @param shares Number of shares.
     * @param totalShares Total shares outstanding.
     * @param totalAmount0 Total amount of currency0 in yield sources.
     * @param totalAmount1 Total amount of currency1 in yield sources.
     * @return amount0 Amount of currency0 for shares.
     * @return amount1 Amount of currency1 for shares.
     */
    function convertSharesToAmounts(uint256 shares, uint256 totalShares, uint256 totalAmount0, uint256 totalAmount1)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        if (totalShares == 0) return (0, 0);
        amount0 = FullMath.mulDiv(shares, totalAmount0, totalShares);
        amount1 = FullMath.mulDiv(shares, totalAmount1, totalShares);
    }

    /**
     * @notice Convert shares to underlying amounts based on pool balances (rounds up).
     * @dev Use for deposits where rounding up is protocol-favorable (user provides more).
     * @param shares Number of shares.
     * @param totalShares Total shares outstanding.
     * @param totalAmount0 Total amount of currency0 in yield sources.
     * @param totalAmount1 Total amount of currency1 in yield sources.
     * @return amount0 Amount of currency0 for shares.
     * @return amount1 Amount of currency1 for shares.
     */
    function convertSharesToAmountsRoundUp(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAmount0,
        uint256 totalAmount1
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (totalShares == 0) return (0, 0);
        amount0 = FullMath.mulDivRoundingUp(shares, totalAmount0, totalShares);
        amount1 = FullMath.mulDivRoundingUp(shares, totalAmount1, totalShares);
    }
}
