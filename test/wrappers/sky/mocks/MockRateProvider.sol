// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IRateProvider} from "../../../../src/wrappers/sky/interfaces/IRateProvider.sol";

/**
 * @title MockRateProvider
 * @author Alphix
 * @notice Mock rate provider for testing purposes.
 * @dev Returns a configurable sUSDS/USDS conversion rate in 27 decimal precision.
 *      Rate represents USDS per sUSDS (e.g., 1.05e27 means 1 sUSDS = 1.05 USDS).
 */
contract MockRateProvider is IRateProvider {
    /// @notice Rate precision (27 decimals)
    uint256 private constant RATE_PRECISION = 1e27;

    /// @notice Current conversion rate (USDS per sUSDS)
    uint256 private _conversionRate;

    /// @notice Event emitted when rate is updated
    event RateUpdated(uint256 oldRate, uint256 newRate);

    /**
     * @notice Deploys the mock rate provider with initial rate of 1:1.
     */
    constructor() {
        _conversionRate = RATE_PRECISION; // 1:1 initial rate
    }

    /**
     * @inheritdoc IRateProvider
     */
    function getConversionRate() external view override returns (uint256 rate) {
        return _conversionRate;
    }

    /**
     * @notice Sets the conversion rate directly.
     * @param newRate The new rate in 27 decimal precision.
     */
    function setConversionRate(uint256 newRate) external {
        emit RateUpdated(_conversionRate, newRate);
        _conversionRate = newRate;
    }

    /**
     * @notice Simulates yield by increasing the rate by a percentage.
     * @param yieldPercent The yield percentage (e.g., 10 for 10%).
     */
    function simulateYield(uint256 yieldPercent) external {
        uint256 oldRate = _conversionRate;
        uint256 yieldAmount = (_conversionRate * yieldPercent) / 100;
        _conversionRate = _conversionRate + yieldAmount;
        emit RateUpdated(oldRate, _conversionRate);
    }

    /**
     * @notice Simulates negative yield (slashing) by decreasing the rate by a percentage.
     * @param slashPercent The slash percentage (e.g., 10 for 10%).
     */
    function simulateSlash(uint256 slashPercent) external {
        uint256 oldRate = _conversionRate;
        uint256 slashAmount = (_conversionRate * slashPercent) / 100;
        _conversionRate = _conversionRate - slashAmount;
        emit RateUpdated(oldRate, _conversionRate);
    }
}
