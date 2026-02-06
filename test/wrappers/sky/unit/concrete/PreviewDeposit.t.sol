// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title PreviewDepositTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky previewDeposit function.
 * @dev Tests the ERC4626 standard previewDeposit function.
 */
contract PreviewDepositTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests previewDeposit at 1:1 rate (initial state).
     */
    function test_previewDeposit_atParRate() public view {
        uint256 assets = 1000e18;
        uint256 shares = wrapper.previewDeposit(assets);

        // At 1:1 rate, shares should equal assets
        assertEq(shares, assets, "Shares should equal assets at par rate");
    }

    /**
     * @notice Tests previewDeposit after yield (rate > 1).
     */
    function test_previewDeposit_afterYield() public {
        _depositAsHook(1000e18, alphixHook);

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 assets = 1000e18;
        uint256 shares = wrapper.previewDeposit(assets);

        // After yield, same assets should give fewer shares
        assertLt(shares, assets, "Should get fewer shares after yield");
    }

    /**
     * @notice Tests previewDeposit with zero assets.
     */
    function test_previewDeposit_zeroAssets() public view {
        uint256 shares = wrapper.previewDeposit(0);
        assertEq(shares, 0, "Zero assets should give zero shares");
    }

    /**
     * @notice Tests previewDeposit does not revert with large amount.
     */
    function test_previewDeposit_largeAmount() public view {
        uint256 assets = 1_000_000_000e18; // 1 billion
        uint256 shares = wrapper.previewDeposit(assets);
        assertGt(shares, 0, "Should return non-zero shares for large amount");
    }

    /**
     * @notice Tests that previewDeposit matches actual deposit.
     */
    function test_previewDeposit_matchesActualDeposit() public {
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 assets = 500e18;
        uint256 expectedShares = wrapper.previewDeposit(assets);

        uint256 actualShares = _depositAsHook(assets, alphixHook);

        assertEq(actualShares, expectedShares, "Actual shares should match preview");
    }

    /**
     * @notice Tests previewDeposit does not revert.
     */
    function test_previewDeposit_doesNotRevert() public view {
        wrapper.previewDeposit(1000e18);
    }
}
