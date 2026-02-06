// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title ConvertToAssetsTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave convertToAssets function.
 */
contract ConvertToAssetsTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that conversion maintains 1:1 ratio after seed (no yield).
     */
    function test_convertToAssets_afterSeed_maintainsRatio() public view {
        // With equal totalSupply and totalAssets, ratio should be ~1:1
        uint256 shares = 100e6;
        uint256 assets = wrapper.convertToAssets(shares);

        // Should be very close to 1:1, allowing for virtual offset rounding
        _assertApproxEq(assets, shares, 1, "Conversion should be ~1:1 after seed");
    }

    /**
     * @notice Tests conversion with zero shares returns zero assets.
     */
    function test_convertToAssets_zeroShares_returnsZero() public view {
        uint256 assets = wrapper.convertToAssets(0);
        assertEq(assets, 0, "Zero shares should return zero assets");
    }

    /**
     * @notice Tests conversion returns non-zero for non-zero shares.
     */
    function test_convertToAssets_nonZeroShares_returnsNonZero() public view {
        uint256 shares = 100e6;
        uint256 assets = wrapper.convertToAssets(shares);
        assertGt(assets, 0, "Should return non-zero assets for non-zero shares");
    }

    /**
     * @notice Tests convertToAssets does not revert.
     */
    function test_convertToAssets_doesNotRevert() public view {
        wrapper.convertToAssets(0);
        wrapper.convertToAssets(1);
        wrapper.convertToAssets(type(uint128).max);
    }

    /**
     * @notice Tests that conversion is monotonically increasing.
     */
    function test_convertToAssets_monotonicIncrease() public view {
        uint256 assets1 = wrapper.convertToAssets(50e6);
        uint256 assets2 = wrapper.convertToAssets(100e6);
        uint256 assets3 = wrapper.convertToAssets(150e6);

        assertLt(assets1, assets2, "More shares should give more assets");
        assertLt(assets2, assets3, "More shares should give more assets");
    }

    /**
     * @notice Tests conversion ratio stays consistent after deposit (no yield).
     */
    function test_convertToAssets_consistentAfterDeposit() public {
        uint256 assetsBefore = wrapper.convertToAssets(100e6);

        // Deposit at current ratio
        _depositAsHook(50e6, alphixHook);

        // Without yield, the ratio should remain the same
        uint256 assetsAfter = wrapper.convertToAssets(100e6);

        assertEq(assetsAfter, assetsBefore, "Conversion should be consistent without yield");
    }

    /**
     * @notice Tests that yield increases assets per share.
     */
    function test_convertToAssets_increasesAfterYield() public {
        _depositAsHook(100e6, alphixHook);

        uint256 assetsBefore = wrapper.convertToAssets(100e6);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 assetsAfter = wrapper.convertToAssets(100e6);

        // After yield, each share is worth more assets
        assertGt(assetsAfter, assetsBefore, "Should get more assets per share after yield");
    }

    /**
     * @notice Tests that round-trip conversion preserves value (with rounding loss).
     */
    function test_convertToAssets_roundTripPreservesValue() public view {
        uint256 originalAssets = 100e6;

        uint256 shares = wrapper.convertToShares(originalAssets);
        uint256 assetsBack = wrapper.convertToAssets(shares);

        // Due to rounding down, we should get back at most what we put in
        assertLe(assetsBack, originalAssets, "Round-trip should not increase assets");
        // But should be very close
        _assertApproxEq(assetsBack, originalAssets, 1, "Round-trip should preserve value");
    }

    /**
     * @notice Tests proportional conversion.
     */
    function test_convertToAssets_proportional() public view {
        uint256 assets100 = wrapper.convertToAssets(100e6);
        uint256 assets200 = wrapper.convertToAssets(200e6);

        // 2x shares should give ~2x assets (within rounding)
        _assertApproxEq(assets200, assets100 * 2, 1, "Conversion should be proportional");
    }

    /**
     * @notice Tests that convertToShares and convertToAssets are inverses.
     */
    function test_convertToAssets_inverseOfConvertToShares() public view {
        uint256 originalShares = 100e6;

        uint256 assets = wrapper.convertToAssets(originalShares);
        uint256 sharesBack = wrapper.convertToShares(assets);

        // Round-trip should preserve value within rounding
        _assertApproxEq(sharesBack, originalShares, 1, "Should be inverse operations");
    }
}
