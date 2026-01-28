// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title ConvertToSharesTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky convertToShares function.
 * @dev Tests the ERC4626 standard convertToShares function.
 */
contract ConvertToSharesTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests convertToShares at 1:1 rate (initial state).
     */
    function test_convertToShares_atParRate() public view {
        uint256 assets = 1000e18;
        uint256 shares = wrapper.convertToShares(assets);

        // At 1:1 rate, shares should equal assets
        assertEq(shares, assets, "Shares should equal assets at par rate");
    }

    /**
     * @notice Tests convertToShares after yield (rate > 1).
     */
    function test_convertToShares_afterYield() public {
        _depositAsHook(1000e18, alphixHook);

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 assets = 1000e18;
        uint256 shares = wrapper.convertToShares(assets);

        // After yield, same assets should give fewer shares
        assertLt(shares, assets, "Should get fewer shares after yield");
    }

    /**
     * @notice Tests convertToShares with zero assets.
     */
    function test_convertToShares_zeroAssets() public view {
        uint256 shares = wrapper.convertToShares(0);
        assertEq(shares, 0, "Zero assets should give zero shares");
    }

    /**
     * @notice Tests convertToShares does not revert with large amount.
     */
    function test_convertToShares_largeAmount() public view {
        uint256 assets = 1_000_000_000e18; // 1 billion
        uint256 shares = wrapper.convertToShares(assets);
        assertGt(shares, 0, "Should return non-zero shares for large amount");
    }

    /**
     * @notice Tests convertToShares after multiple deposits and yield.
     */
    function test_convertToShares_afterMultipleDepositsAndYield() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);
        _depositAsHook(500e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 assets = 100e18;
        uint256 shares = wrapper.convertToShares(assets);

        // Should be less than assets due to accumulated yield
        assertLt(shares, assets, "Should get fewer shares after yield");
    }

    /**
     * @notice Tests that convertToShares is consistent with previewDeposit.
     */
    function test_convertToShares_consistentWithPreviewDeposit() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 assets = 100e18;
        uint256 sharesFromConvert = wrapper.convertToShares(assets);
        uint256 sharesFromPreview = wrapper.previewDeposit(assets);

        assertEq(sharesFromConvert, sharesFromPreview, "convertToShares should match previewDeposit");
    }

    /**
     * @notice Tests convertToShares does not revert.
     */
    function test_convertToShares_doesNotRevert() public view {
        wrapper.convertToShares(1000e18);
    }
}
