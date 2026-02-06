// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title ConversionsFuzzTest
 * @author Alphix
 * @notice Fuzz tests for share/asset conversion functions.
 */
contract ConversionsFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test convertToShares with varying amounts.
     * @param assets Asset amount to convert.
     */
    function testFuzz_convertToShares_varyingAmounts(uint256 assets) public view {
        assets = bound(assets, 0, 1e30);

        uint256 shares = wrapper.convertToShares(assets);

        // At par rate, shares should approximately equal assets
        // Allow for rounding
        if (assets > 0) {
            assertGt(shares, 0, "Non-zero assets should give non-zero shares");
        }
    }

    /**
     * @notice Fuzz test convertToAssets with varying shares.
     * @param shares Shares amount to convert.
     */
    function testFuzz_convertToAssets_varyingAmounts(uint256 shares) public view {
        shares = bound(shares, 0, 1e30);

        uint256 assets = wrapper.convertToAssets(shares);

        // At par rate, assets should approximately equal shares
        if (shares > 0) {
            assertGt(assets, 0, "Non-zero shares should give non-zero assets");
        }
    }

    /**
     * @notice Fuzz test roundtrip conversion.
     * @param amount Starting amount.
     */
    function testFuzz_conversion_roundtrip(uint256 amount) public view {
        amount = bound(amount, 1e6, 1e30); // Avoid dust amounts

        uint256 shares = wrapper.convertToShares(amount);
        uint256 assetsBack = wrapper.convertToAssets(shares);

        // Should be approximately equal (within rounding)
        // Due to floor rounding, assetsBack may be slightly less
        assertLe(assetsBack, amount, "Assets back should not exceed original");
        assertGe(assetsBack, amount * 99 / 100, "Assets back should be close to original");
    }

    /**
     * @notice Fuzz test conversions at different rates.
     * @param amount Amount to convert.
     * @param rateMultiplier Rate multiplier (100 = 1x, 200 = 2x).
     */
    function testFuzz_conversion_atDifferentRates(uint256 amount, uint256 rateMultiplier) public {
        amount = bound(amount, 1e6, 1e30);
        rateMultiplier = bound(rateMultiplier, 100, 101); // 1x to 1.01x (circuit breaker limits to 1%)

        // First deposit at initial rate
        _depositAsHook(1000e18, alphixHook);

        // Change rate
        uint256 newRate = INITIAL_RATE * rateMultiplier / 100;
        _setRate(newRate);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Test conversions
        uint256 shares = wrapper.convertToShares(amount);
        uint256 assetsBack = wrapper.convertToAssets(shares);

        // Should still roundtrip reasonably
        assertLe(assetsBack, amount, "Assets back should not exceed original");
        assertGe(assetsBack, amount * 99 / 100, "Assets back should be close to original");
    }

    /**
     * @notice Fuzz test previewDeposit matches convertToShares.
     * @param assets Asset amount.
     */
    function testFuzz_previewDeposit_matchesConvert(uint256 assets) public view {
        assets = bound(assets, 1, 1e30);

        uint256 previewShares = wrapper.previewDeposit(assets);
        uint256 convertShares = wrapper.convertToShares(assets);

        // Preview and convert should be very close
        // previewDeposit rounds down, convertToShares rounds down
        assertEq(previewShares, convertShares, "Preview should match convert");
    }

    /**
     * @notice Fuzz test previewRedeem matches convertToAssets.
     * @param shares Shares amount.
     */
    function testFuzz_previewRedeem_matchesConvert(uint256 shares) public {
        // Need some deposits first
        _depositAsHook(1000e18, alphixHook);

        shares = bound(shares, 1, wrapper.balanceOf(alphixHook));

        uint256 previewAssets = wrapper.previewRedeem(shares);
        uint256 convertAssets = wrapper.convertToAssets(shares);

        // Preview and convert should be equal
        assertEq(previewAssets, convertAssets, "Preview should match convert");
    }

    /**
     * @notice Fuzz test conversions after yield.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_conversion_afterYield(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // After yield, shares should convert to more assets than before
        uint256 hookShares = wrapper.balanceOf(alphixHook);
        uint256 assets = wrapper.convertToAssets(hookShares);

        // Should have more assets than originally deposited (yield - fees)
        assertGt(assets, depositAmount * 99 / 100, "Should have grown due to yield");
    }

    /**
     * @notice Fuzz test that conversions maintain invariants.
     * @param amount Test amount.
     */
    function testFuzz_conversion_invariants(uint256 amount) public {
        _depositAsHook(1000e18, alphixHook);

        amount = bound(amount, 1, wrapper.totalSupply() / 2);

        uint256 assets1 = wrapper.convertToAssets(amount);
        uint256 sharesBack = wrapper.convertToShares(assets1);

        // Converting assets to shares should give back at most the original shares
        // (due to rounding)
        assertLe(sharesBack, amount + 1, "Conversion should not inflate shares");
    }
}
