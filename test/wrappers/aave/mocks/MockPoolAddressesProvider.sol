// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title MockPoolAddressesProvider
 * @author Alphix
 * @notice Mock Aave V3 Pool Addresses Provider for testing purposes.
 */
contract MockPoolAddressesProvider {
    address private _pool;

    /**
     * @notice Constructs the mock provider.
     * @param pool_ The pool address.
     */
    constructor(address pool_) {
        _pool = pool_;
    }

    /**
     * @notice Returns the pool address.
     * @return The pool address.
     */
    function getPool() external view returns (address) {
        return _pool;
    }

    /**
     * @notice Sets the pool address.
     * @param pool_ The new pool address.
     */
    function setPool(address pool_) external {
        _pool = pool_;
    }
}
