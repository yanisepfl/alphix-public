// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title ConvertToSharesTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave convertToShares function.
 */
contract ConvertToSharesTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that seed liquidity was deposited at 1:1 ratio.
     */
    function test_seedDeposit_wasOneToOne() public view {
        // After seed deposit, totalSupply and totalAssets should be equal
        uint256 totalSupply = wrapper.totalSupply();
        uint256 totalAssets = wrapper.totalAssets();

        assertEq(totalSupply, DEFAULT_SEED_LIQUIDITY, "Total supply should equal seed liquidity");
        assertEq(totalAssets, DEFAULT_SEED_LIQUIDITY, "Total assets should equal seed liquidity");
        assertEq(totalSupply, totalAssets, "Seed deposit should be 1:1");
    }

    /**
     * @notice Tests that conversion maintains 1:1 ratio after seed (no yield).
     */
    function test_convertToShares_afterSeed_maintainsRatio() public view {
        // With equal totalSupply and totalAssets, ratio should be ~1:1
        uint256 assets = 100e6;
        uint256 shares = wrapper.convertToShares(assets);

        // Should be very close to 1:1, allowing for virtual offset rounding
        _assertApproxEq(shares, assets, 1, "Conversion should be ~1:1 after seed");
    }

    /**
     * @notice Tests conversion with zero assets returns zero shares.
     */
    function test_convertToShares_zeroAssets_returnsZero() public view {
        uint256 shares = wrapper.convertToShares(0);
        assertEq(shares, 0, "Zero assets should return zero shares");
    }

    /**
     * @notice Tests conversion returns non-zero for non-zero assets.
     */
    function test_convertToShares_nonZeroAssets_returnsNonZero() public view {
        uint256 assets = 100e6;
        uint256 shares = wrapper.convertToShares(assets);
        assertGt(shares, 0, "Should return non-zero shares for non-zero assets");
    }

    /**
     * @notice Tests convertToShares does not revert.
     */
    function test_convertToShares_doesNotRevert() public view {
        wrapper.convertToShares(0);
        wrapper.convertToShares(1);
        wrapper.convertToShares(type(uint128).max);
    }

    /**
     * @notice Tests that conversion is monotonically increasing.
     */
    function test_convertToShares_monotonicIncrease() public view {
        uint256 shares1 = wrapper.convertToShares(50e6);
        uint256 shares2 = wrapper.convertToShares(100e6);
        uint256 shares3 = wrapper.convertToShares(150e6);

        assertLt(shares1, shares2, "More assets should give more shares");
        assertLt(shares2, shares3, "More assets should give more shares");
    }

    /**
     * @notice Tests conversion ratio stays consistent after deposit (no yield).
     */
    function test_convertToShares_consistentAfterDeposit() public {
        uint256 sharesBefore = wrapper.convertToShares(100e6);

        // Deposit at current ratio
        _depositAsHook(50e6, alphixHook);

        // Without yield, the ratio should remain the same
        uint256 sharesAfter = wrapper.convertToShares(100e6);

        assertEq(sharesAfter, sharesBefore, "Conversion should be consistent without yield");
    }

    /**
     * @notice Tests that yield increases assets per share (fewer shares for same assets).
     */
    function test_convertToShares_decreasesAfterYield() public {
        _depositAsHook(100e6, alphixHook);

        uint256 sharesBefore = wrapper.convertToShares(100e6);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 sharesAfter = wrapper.convertToShares(100e6);

        // After yield, each share is worth more assets, so same assets = fewer shares
        assertLt(sharesAfter, sharesBefore, "Should get fewer shares after yield accrual");
    }

    /**
     * @notice Tests proportional conversion.
     */
    function test_convertToShares_proportional() public view {
        uint256 shares100 = wrapper.convertToShares(100e6);
        uint256 shares200 = wrapper.convertToShares(200e6);

        // 2x assets should give ~2x shares (within rounding)
        _assertApproxEq(shares200, shares100 * 2, 1, "Conversion should be proportional");
    }
}
