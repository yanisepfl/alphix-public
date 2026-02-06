// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../src/BaseDynamicFee.sol";

/**
 * @title MockBaseDynamicFee
 * @notice Mock implementation of BaseDynamicFee for testing
 * @dev Provides concrete implementation of abstract functions
 */
contract MockBaseDynamicFee is BaseDynamicFee {
    uint24 private _mockFee;

    constructor(IPoolManager _poolManager) BaseDynamicFee(_poolManager) {
        _mockFee = 3000; // Default 0.3%
    }

    function setMockFee(uint24 fee) external {
        _mockFee = fee;
    }

    function getFee() external view returns (uint24) {
        return _mockFee;
    }

    function poke(uint256) external override {
        // Mock implementation - does nothing
    }
}
