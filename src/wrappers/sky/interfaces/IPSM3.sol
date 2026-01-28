// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.26;

/**
 * @title IPSM3
 * @notice Interface for the Spark PSM3 (Peg Stability Module) on Base.
 * @dev PSM3 allows swaps between USDC, USDS, and sUSDS with no slippage or fees.
 *      USDC↔USDS swaps are 1:1 (decimal adjusted).
 *      USDS↔sUSDS swaps use the rate provider for conversion.
 */
interface IPSM3 {
    /* SWAP FUNCTIONS */

    /**
     * @notice Swaps an exact amount of `assetIn` for `assetOut`.
     * @param assetIn The asset to swap from.
     * @param assetOut The asset to swap to.
     * @param amountIn The exact amount of `assetIn` to swap.
     * @param minAmountOut The minimum amount of `assetOut` to receive.
     * @param receiver The address to receive the output.
     * @param referralCode The referral code (use 0).
     * @return amountOut The actual amount of `assetOut` received.
     */
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountOut);

    /**
     * @notice Swaps `assetIn` for an exact amount of `assetOut`.
     * @param assetIn The asset to swap from.
     * @param assetOut The asset to swap to.
     * @param amountOut The exact amount of `assetOut` to receive.
     * @param maxAmountIn The maximum amount of `assetIn` to spend.
     * @param receiver The address to receive the output.
     * @param referralCode The referral code (use 0).
     * @return amountIn The actual amount of `assetIn` spent.
     */
    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 amountIn);

    /* PREVIEW FUNCTIONS */

    /**
     * @notice Previews the output amount for an exact input swap.
     * @param assetIn The asset to swap from.
     * @param assetOut The asset to swap to.
     * @param amountIn The exact amount of `assetIn` to swap.
     * @return amountOut The expected amount of `assetOut` to receive.
     */
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut);

    /**
     * @notice Previews the input amount required for an exact output swap.
     * @param assetIn The asset to swap from.
     * @param assetOut The asset to swap to.
     * @param amountOut The exact amount of `assetOut` to receive.
     * @return amountIn The expected amount of `assetIn` required.
     */
    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external
        view
        returns (uint256 amountIn);

    /* VIEW FUNCTIONS */

    /**
     * @notice Returns the USDC token address.
     */
    function usdc() external view returns (address);

    /**
     * @notice Returns the USDS token address.
     */
    function usds() external view returns (address);

    /**
     * @notice Returns the sUSDS token address.
     */
    function susds() external view returns (address);

    /**
     * @notice Returns the rate provider address.
     */
    function rateProvider() external view returns (address);
}
