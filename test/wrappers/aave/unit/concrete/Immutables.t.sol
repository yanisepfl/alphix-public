// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title ImmutablesTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave immutable getters.
 */
contract ImmutablesTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that POOL_ADDRESSES_PROVIDER returns correct address.
     */
    function test_POOL_ADDRESSES_PROVIDER_returnsCorrect() public view {
        assertEq(
            address(wrapper.POOL_ADDRESSES_PROVIDER()),
            address(poolAddressesProvider),
            "Pool addresses provider mismatch"
        );
    }

    /**
     * @notice Tests that AAVE_POOL returns correct address.
     */
    function test_AAVE_POOL_returnsCorrect() public view {
        assertEq(address(wrapper.AAVE_POOL()), address(aavePool), "Aave pool mismatch");
    }

    /**
     * @notice Tests that ATOKEN returns correct address.
     */
    function test_ATOKEN_returnsCorrect() public view {
        assertEq(address(wrapper.ATOKEN()), address(aToken), "AToken mismatch");
    }

    /**
     * @notice Tests that ASSET returns correct address.
     */
    function test_ASSET_returnsCorrect() public view {
        assertEq(address(wrapper.ASSET()), address(asset), "Asset mismatch");
    }

    /**
     * @notice Tests that asset() returns the same as ASSET.
     */
    function test_asset_matchesASSET() public view {
        assertEq(wrapper.asset(), address(wrapper.ASSET()), "asset() should match ASSET");
    }

    /**
     * @notice Tests immutables are consistent across calls.
     */
    function test_immutables_areConsistent() public view {
        // Call each getter twice to ensure consistency
        assertEq(
            address(wrapper.POOL_ADDRESSES_PROVIDER()),
            address(wrapper.POOL_ADDRESSES_PROVIDER()),
            "POOL_ADDRESSES_PROVIDER inconsistent"
        );
        assertEq(address(wrapper.AAVE_POOL()), address(wrapper.AAVE_POOL()), "AAVE_POOL inconsistent");
        assertEq(address(wrapper.ATOKEN()), address(wrapper.ATOKEN()), "ATOKEN inconsistent");
        assertEq(address(wrapper.ASSET()), address(wrapper.ASSET()), "ASSET inconsistent");
    }
}
