// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title ConversionsFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave conversion functions.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract ConversionsFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that convertToShares is monotonically increasing.
     * @param decimals The asset decimals (6-18).
     * @param assets1 First asset amount.
     * @param assets2 Second asset amount.
     */
    function testFuzz_convertToShares_monotonic(uint8 decimals, uint256 assets1, uint256 assets2) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        assets1 = bound(assets1, 0, type(uint128).max);
        assets2 = bound(assets2, 0, type(uint128).max);

        uint256 shares1 = d.wrapper.convertToShares(assets1);
        uint256 shares2 = d.wrapper.convertToShares(assets2);

        if (assets1 < assets2) {
            assertLe(shares1, shares2, "More assets should give >= shares");
        } else if (assets1 > assets2) {
            assertGe(shares1, shares2, "Fewer assets should give <= shares");
        }
    }

    /**
     * @notice Fuzz test that convertToAssets is monotonically increasing.
     * @param decimals The asset decimals (6-18).
     * @param shares1 First share amount.
     * @param shares2 Second share amount.
     */
    function testFuzz_convertToAssets_monotonic(uint8 decimals, uint256 shares1, uint256 shares2) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        shares1 = bound(shares1, 0, type(uint128).max);
        shares2 = bound(shares2, 0, type(uint128).max);

        uint256 assets1 = d.wrapper.convertToAssets(shares1);
        uint256 assets2 = d.wrapper.convertToAssets(shares2);

        if (shares1 < shares2) {
            assertLe(assets1, assets2, "More shares should give >= assets");
        } else if (shares1 > shares2) {
            assertGe(assets1, assets2, "Fewer shares should give <= assets");
        }
    }

    /**
     * @notice Fuzz test that round-trip conversion doesn't increase value.
     * @param decimals The asset decimals (6-18).
     * @param assets Original asset amount.
     */
    function testFuzz_convertRoundTrip_noInflation(uint8 decimals, uint256 assets) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        assets = bound(assets, 0, type(uint128).max);

        uint256 shares = d.wrapper.convertToShares(assets);
        uint256 assetsBack = d.wrapper.convertToAssets(shares);

        assertLe(assetsBack, assets, "Round-trip should not inflate assets");
    }

    /**
     * @notice Fuzz test that conversion is approximately linear.
     * @param decimals The asset decimals (6-18).
     * @param assetsMultiplier Base asset amount multiplier.
     * @param multiplier Multiplier to apply.
     */
    function testFuzz_convertToShares_approximatelyLinear(uint8 decimals, uint256 assetsMultiplier, uint256 multiplier)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        assetsMultiplier = bound(assetsMultiplier, 1, type(uint32).max);
        uint256 assets = assetsMultiplier * 10 ** d.decimals;
        multiplier = bound(multiplier, 1, 1000);

        uint256 shares1 = d.wrapper.convertToShares(assets);
        uint256 sharesN = d.wrapper.convertToShares(assets * multiplier);

        // sharesN should be approximately shares1 * multiplier (within rounding)
        uint256 expected = shares1 * multiplier;
        uint256 tolerance = multiplier; // Allow multiplier units of rounding error

        if (expected > 0) {
            assertLe(sharesN, expected + tolerance, "Shares should be approximately linear (upper)");
            assertGe(sharesN + tolerance, expected, "Shares should be approximately linear (lower)");
        }
    }

    /**
     * @notice Fuzz test conversion with deposits and yield.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier Deposit amount multiplier.
     * @param yieldPercent Yield percentage.
     * @param queryMultiplier Amount to query conversion for.
     */
    function testFuzz_conversion_withYield(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint256 queryMultiplier
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 0, 100);
        queryMultiplier = bound(queryMultiplier, 1, 1_000_000_000);
        uint256 queryAmount = queryMultiplier * 10 ** d.decimals;

        // Deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Simulate yield
        if (yieldPercent > 0) {
            _simulateYieldOnDeployment(d, yieldPercent);
        }

        // Conversions should not revert
        uint256 shares = d.wrapper.convertToShares(queryAmount);
        uint256 assets = d.wrapper.convertToAssets(queryAmount);

        assertGe(shares, 0, "Shares should be >= 0");
        assertGe(assets, 0, "Assets should be >= 0");
    }
}
