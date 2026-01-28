// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPSM3} from "../../../../src/wrappers/sky/interfaces/IPSM3.sol";
import {MockRateProvider} from "./MockRateProvider.sol";

/**
 * @title MockPSM3
 * @author Alphix
 * @notice Mock Spark PSM3 for testing purposes.
 * @dev Simulates the PSM3 swap functionality:
 *      - USDS ↔ sUSDS swaps use the rate provider for conversion
 *      - Rate is USDS per sUSDS in 27 decimals
 *
 *      The mock holds both USDS and sUSDS to facilitate swaps.
 *      Use fundWithUsds() and fundWithSusds() to provide liquidity.
 */
contract MockPSM3 is IPSM3 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Rate precision (27 decimals)
    uint256 private constant RATE_PRECISION = 1e27;

    /// @notice USDS token (18 decimals)
    address private immutable _usds;

    /// @notice sUSDS token (18 decimals)
    address private immutable _susds;

    /// @notice Rate provider
    address private immutable _rateProvider;

    /// @notice Event emitted on swap
    event Swap(
        address indexed assetIn, address indexed assetOut, uint256 amountIn, uint256 amountOut, address indexed receiver
    );

    /**
     * @notice Deploys the mock PSM3.
     * @param usds_ The USDS token address.
     * @param susds_ The sUSDS token address.
     * @param rateProvider_ The rate provider address.
     */
    constructor(address usds_, address susds_, address rateProvider_) {
        _usds = usds_;
        _susds = susds_;
        _rateProvider = rateProvider_;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IPSM3
    function usdc() external pure override returns (address) {
        revert("USDC not supported in mock");
    }

    /// @inheritdoc IPSM3
    function usds() external view override returns (address) {
        return _usds;
    }

    /// @inheritdoc IPSM3
    function susds() external view override returns (address) {
        return _susds;
    }

    /// @inheritdoc IPSM3
    function rateProvider() external view override returns (address) {
        return _rateProvider;
    }

    /* PREVIEW FUNCTIONS */

    /// @inheritdoc IPSM3
    function previewSwapExactIn(address assetIn, address assetOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut)
    {
        return _calculateSwap(assetIn, assetOut, amountIn, true);
    }

    /// @inheritdoc IPSM3
    function previewSwapExactOut(address assetIn, address assetOut, uint256 amountOut)
        external
        view
        override
        returns (uint256 amountIn)
    {
        return _calculateSwap(assetIn, assetOut, amountOut, false);
    }

    /* SWAP FUNCTIONS */

    /// @inheritdoc IPSM3
    function swapExactIn(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address receiver,
        uint256 /* referralCode */
    ) external override returns (uint256 amountOut) {
        amountOut = _calculateSwap(assetIn, assetOut, amountIn, true);
        require(amountOut >= minAmountOut, "MockPSM3: slippage");

        // Transfer in
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Transfer out
        IERC20(assetOut).safeTransfer(receiver, amountOut);

        emit Swap(assetIn, assetOut, amountIn, amountOut, receiver);
    }

    /// @inheritdoc IPSM3
    function swapExactOut(
        address assetIn,
        address assetOut,
        uint256 amountOut,
        uint256 maxAmountIn,
        address receiver,
        uint256 /* referralCode */
    ) external override returns (uint256 amountIn) {
        amountIn = _calculateSwap(assetIn, assetOut, amountOut, false);
        require(amountIn <= maxAmountIn, "MockPSM3: slippage");

        // Transfer in
        IERC20(assetIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Transfer out
        IERC20(assetOut).safeTransfer(receiver, amountOut);

        emit Swap(assetIn, assetOut, amountIn, amountOut, receiver);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Calculates swap amounts based on rate provider.
     * @param assetIn The input asset.
     * @param assetOut The output asset.
     * @param amount The amount (input for exactIn, output for exactOut).
     * @param isExactIn True if exact input swap, false if exact output.
     * @return result The calculated amount (output for exactIn, input for exactOut).
     */
    function _calculateSwap(address assetIn, address assetOut, uint256 amount, bool isExactIn)
        internal
        view
        returns (uint256 result)
    {
        uint256 rate = MockRateProvider(_rateProvider).getConversionRate();

        if (assetIn == _usds && assetOut == _susds) {
            // USDS → sUSDS: susdsAmount = usdsAmount * 1e27 / rate
            if (isExactIn) {
                // Given USDS input, calculate sUSDS output
                result = amount.mulDiv(RATE_PRECISION, rate);
            } else {
                // Given sUSDS output, calculate USDS input
                result = amount.mulDiv(rate, RATE_PRECISION, Math.Rounding.Ceil);
            }
        } else if (assetIn == _susds && assetOut == _usds) {
            // sUSDS → USDS: usdsAmount = susdsAmount * rate / 1e27
            if (isExactIn) {
                // Given sUSDS input, calculate USDS output
                result = amount.mulDiv(rate, RATE_PRECISION);
            } else {
                // Given USDS output, calculate sUSDS input
                result = amount.mulDiv(RATE_PRECISION, rate, Math.Rounding.Ceil);
            }
        } else {
            revert("MockPSM3: unsupported swap pair");
        }
    }

    /* HELPER FUNCTIONS FOR TESTING */

    /**
     * @notice Funds the PSM with USDS for liquidity.
     * @param amount The amount of USDS to add.
     * @dev Mints USDS directly to the PSM. In production, use transferFrom.
     */
    function fundWithUsds(uint256 amount) external {
        // Assuming MockERC20 with mint function
        (bool success,) = _usds.call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
        require(success, "MockPSM3: fund USDS failed");
    }

    /**
     * @notice Funds the PSM with sUSDS for liquidity.
     * @param amount The amount of sUSDS to add.
     */
    function fundWithSusds(uint256 amount) external {
        (bool success,) = _susds.call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
        require(success, "MockPSM3: fund sUSDS failed");
    }

    /**
     * @notice Gets the current USDS balance of the PSM.
     */
    function getUsdsBalance() external view returns (uint256) {
        return IERC20(_usds).balanceOf(address(this));
    }

    /**
     * @notice Gets the current sUSDS balance of the PSM.
     */
    function getSusdsBalance() external view returns (uint256) {
        return IERC20(_susds).balanceOf(address(this));
    }
}
