// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title ImmutablesFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave immutable getters.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract ImmutablesFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that immutables are consistent across calls.
     * @param decimals The asset decimals (6-18).
     * @param caller Random caller address.
     */
    function testFuzz_immutables_consistentAcrossCalls(uint8 decimals, address caller) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.startPrank(caller);

        // Call each getter twice and verify consistency
        assertEq(
            address(d.wrapper.POOL_ADDRESSES_PROVIDER()),
            address(d.wrapper.POOL_ADDRESSES_PROVIDER()),
            "POOL_ADDRESSES_PROVIDER inconsistent"
        );
        assertEq(address(d.wrapper.AAVE_POOL()), address(d.wrapper.AAVE_POOL()), "AAVE_POOL inconsistent");
        assertEq(address(d.wrapper.ATOKEN()), address(d.wrapper.ATOKEN()), "ATOKEN inconsistent");
        assertEq(address(d.wrapper.ASSET()), address(d.wrapper.ASSET()), "ASSET inconsistent");
        assertEq(d.wrapper.asset(), d.wrapper.asset(), "asset() inconsistent");

        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that asset() never reverts.
     * @param decimals The asset decimals (6-18).
     * @param caller Random caller address.
     */
    function testFuzz_asset_neverReverts(uint8 decimals, address caller) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.prank(caller);
        d.wrapper.asset();
    }

    /**
     * @notice Fuzz test that immutables don't change after state changes.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier Deposit amount multiplier.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_immutables_unchangedAfterStateChanges(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 0, 100);

        // Record immutables before
        address poolProviderBefore = address(d.wrapper.POOL_ADDRESSES_PROVIDER());
        address aavePoolBefore = address(d.wrapper.AAVE_POOL());
        address aTokenBefore = address(d.wrapper.ATOKEN());
        address assetBefore = address(d.wrapper.ASSET());

        // Make state changes
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        if (yieldPercent > 0) {
            _simulateYieldOnDeployment(d, yieldPercent);
        }

        vm.prank(owner);
        d.wrapper.setFee(500_000);

        // Verify immutables unchanged
        assertEq(address(d.wrapper.POOL_ADDRESSES_PROVIDER()), poolProviderBefore, "POOL_ADDRESSES_PROVIDER changed");
        assertEq(address(d.wrapper.AAVE_POOL()), aavePoolBefore, "AAVE_POOL changed");
        assertEq(address(d.wrapper.ATOKEN()), aTokenBefore, "ATOKEN changed");
        assertEq(address(d.wrapper.ASSET()), assetBefore, "ASSET changed");
    }
}
