// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.26;

/**
 * @title IRateProvider
 * @notice Interface for the Spark rate provider on Base.
 * @dev Returns the sUSDS/USDS conversion rate in 27 decimal precision.
 *      Rate represents USDS per sUSDS (e.g., 1.05e27 means 1 sUSDS = 1.05 USDS).
 */
interface IRateProvider {
    /**
     * @notice Returns the current sUSDS to USDS conversion rate.
     * @return rate The conversion rate in 27 decimal precision (1e27 = 1:1).
     */
    function getConversionRate() external view returns (uint256 rate);
}
