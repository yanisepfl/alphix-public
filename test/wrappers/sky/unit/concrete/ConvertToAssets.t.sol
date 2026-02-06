// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title ConvertToAssetsTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky convertToAssets function.
 * @dev Tests the ERC4626 standard convertToAssets function.
 */
contract ConvertToAssetsTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests convertToAssets at 1:1 rate (initial state).
     */
    function test_convertToAssets_atParRate() public view {
        uint256 shares = 1000e18;
        uint256 assets = wrapper.convertToAssets(shares);

        // At 1:1 rate, assets should equal shares
        assertEq(assets, shares, "Assets should equal shares at par rate");
    }

    /**
     * @notice Tests convertToAssets after yield (rate > 1).
     */
    function test_convertToAssets_afterYield() public {
        _depositAsHook(1000e18, alphixHook);

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 shares = 1000e18;
        uint256 assets = wrapper.convertToAssets(shares);

        // After yield, same shares should give more assets
        assertGt(assets, shares, "Should get more assets after yield");
    }

    /**
     * @notice Tests convertToAssets with zero shares.
     */
    function test_convertToAssets_zeroShares() public view {
        uint256 assets = wrapper.convertToAssets(0);
        assertEq(assets, 0, "Zero shares should give zero assets");
    }

    /**
     * @notice Tests convertToAssets does not revert with large amount.
     */
    function test_convertToAssets_largeAmount() public view {
        uint256 shares = 1_000_000_000e18; // 1 billion
        uint256 assets = wrapper.convertToAssets(shares);
        assertGt(assets, 0, "Should return non-zero assets for large amount");
    }

    /**
     * @notice Tests convertToAssets after multiple deposits and yield.
     */
    function test_convertToAssets_afterMultipleDepositsAndYield() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);
        _depositAsHook(500e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 shares = 100e18;
        uint256 assets = wrapper.convertToAssets(shares);

        // Should be more than shares due to accumulated yield
        assertGt(assets, shares, "Should get more assets after yield");
    }

    /**
     * @notice Tests that convertToAssets is consistent with previewRedeem.
     */
    function test_convertToAssets_consistentWithPreviewRedeem() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 shares = 100e18;
        uint256 assetsFromConvert = wrapper.convertToAssets(shares);
        uint256 assetsFromPreview = wrapper.previewRedeem(shares);

        assertEq(assetsFromConvert, assetsFromPreview, "convertToAssets should match previewRedeem");
    }

    /**
     * @notice Tests convertToAssets does not revert.
     */
    function test_convertToAssets_doesNotRevert() public view {
        wrapper.convertToAssets(1000e18);
    }

    /**
     * @notice Tests roundtrip: convertToShares then convertToAssets.
     * @dev The Sky wrapper has 4 floor divisions in a full roundtrip:
     *      - convertToShares: assets → sUSDS (1 div), sUSDS → shares (1 div)
     *      - convertToAssets: shares → sUSDS (1 div), sUSDS → assets (1 div)
     *      This is inherent to any vault with rate conversion (USDS ↔ sUSDS).
     *      Maximum expected loss: 3-4 wei (1 wei per floor division, minus 1 for cancellation).
     */
    function test_convertRoundtrip() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 originalAssets = 100e18;
        uint256 shares = wrapper.convertToShares(originalAssets);
        uint256 recoveredAssets = wrapper.convertToAssets(shares);

        // Due to rounding, recovered should be <= original
        assertLe(recoveredAssets, originalAssets, "Recovered assets should be <= original");
        // With 4 floor divisions (2 per direction), expect up to 3-4 wei loss
        uint256 diff = originalAssets - recoveredAssets;
        assertLe(diff, 4, "Roundtrip loss should be at most 4 wei");
    }
}
