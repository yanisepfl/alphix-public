// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title PreviewDepositTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave previewDeposit function.
 * @dev previewDeposit is a view function that returns the estimated shares for a given asset amount.
 */
contract PreviewDepositTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that previewDeposit does not revert for various inputs.
     */
    function test_previewDeposit_doesNotRevert() public view {
        wrapper.previewDeposit(0);
        wrapper.previewDeposit(1);
        wrapper.previewDeposit(100e6);
        wrapper.previewDeposit(type(uint128).max);
    }

    /**
     * @notice Tests that previewDeposit returns zero for zero assets.
     */
    function test_previewDeposit_zeroAssets_returnsZero() public view {
        uint256 shares = wrapper.previewDeposit(0);
        assertEq(shares, 0, "Zero assets should return zero shares");
    }

    /**
     * @notice Tests that previewDeposit returns non-zero for non-zero assets.
     */
    function test_previewDeposit_nonZeroAssets_returnsNonZero() public view {
        uint256 assets = 100e6;
        uint256 shares = wrapper.previewDeposit(assets);
        assertGt(shares, 0, "Non-zero assets should return non-zero shares");
    }

    /**
     * @notice Tests that previewDeposit maintains ~1:1 ratio after seed deposit.
     */
    function test_previewDeposit_afterSeed_maintainsRatio() public view {
        uint256 assets = 100e6;
        uint256 shares = wrapper.previewDeposit(assets);

        // After seed deposit at 1:1, conversion should be ~1:1
        _assertApproxEq(shares, assets, 1, "Preview should be ~1:1 after seed");
    }

    /**
     * @notice Tests that previewDeposit matches convertToShares for rounding down.
     */
    function test_previewDeposit_matchesConvertToShares() public view {
        uint256 assets = 100e6;
        uint256 previewedShares = wrapper.previewDeposit(assets);
        uint256 convertedShares = wrapper.convertToShares(assets);

        assertEq(previewedShares, convertedShares, "previewDeposit should match convertToShares");
    }

    /**
     * @notice Tests that previewDeposit is monotonically increasing.
     */
    function test_previewDeposit_monotonicIncrease() public view {
        uint256 shares1 = wrapper.previewDeposit(50e6);
        uint256 shares2 = wrapper.previewDeposit(100e6);
        uint256 shares3 = wrapper.previewDeposit(150e6);

        assertLt(shares1, shares2, "More assets should give more shares");
        assertLt(shares2, shares3, "More assets should give more shares");
    }

    /**
     * @notice Tests that previewDeposit is approximately proportional.
     */
    function test_previewDeposit_proportional() public view {
        uint256 shares100 = wrapper.previewDeposit(100e6);
        uint256 shares200 = wrapper.previewDeposit(200e6);

        // 2x assets should give ~2x shares (within rounding)
        _assertApproxEq(shares200, shares100 * 2, 1, "Preview should be proportional");
    }

    /**
     * @notice Tests that previewDeposit matches actual deposit shares.
     */
    function test_previewDeposit_matchesActualDeposit() public {
        uint256 depositAmount = 100e6;

        uint256 previewedShares = wrapper.previewDeposit(depositAmount);

        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 actualShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Actual deposit should match preview");
    }

    /**
     * @notice Tests that previewDeposit stays consistent after deposit (no yield).
     */
    function test_previewDeposit_consistentAfterDeposit() public {
        uint256 previewBefore = wrapper.previewDeposit(100e6);

        // Deposit some assets (no yield)
        _depositAsHook(50e6, alphixHook);

        // Preview should remain the same without yield
        uint256 previewAfter = wrapper.previewDeposit(100e6);

        assertEq(previewAfter, previewBefore, "Preview should be consistent without yield");
    }

    /**
     * @notice Tests that previewDeposit decreases after yield accrual.
     */
    function test_previewDeposit_decreasesAfterYield() public {
        _depositAsHook(100e6, alphixHook);

        uint256 previewBefore = wrapper.previewDeposit(100e6);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 previewAfter = wrapper.previewDeposit(100e6);

        // After yield, each share is worth more assets, so same assets = fewer shares
        assertLt(previewAfter, previewBefore, "Preview should decrease after yield");
    }

    /**
     * @notice Tests that previewDeposit is independent of the caller.
     */
    function test_previewDeposit_independentOfCaller() public {
        uint256 assets = 100e6;

        vm.prank(alice);
        uint256 sharesAlice = wrapper.previewDeposit(assets);

        vm.prank(bob);
        uint256 sharesBob = wrapper.previewDeposit(assets);

        vm.prank(alphixHook);
        uint256 sharesHook = wrapper.previewDeposit(assets);

        assertEq(sharesAlice, sharesBob, "Preview should be same for different callers");
        assertEq(sharesBob, sharesHook, "Preview should be same for different callers");
    }

    /**
     * @notice Tests previewDeposit with maximum fee (100%).
     */
    function test_previewDeposit_withMaxFee() public {
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        _depositAsHook(100e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Preview should still work correctly
        uint256 shares = wrapper.previewDeposit(100e6);
        assertGt(shares, 0, "Should return non-zero shares with max fee");

        // totalAssets should not have changed due to max fee taking all yield
        // Preview should reflect the same share price
    }

    /**
     * @notice Tests previewDeposit with zero fee.
     */
    function test_previewDeposit_withZeroFee() public {
        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(100e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Preview should still work correctly
        uint256 shares = wrapper.previewDeposit(100e6);
        assertGt(shares, 0, "Should return non-zero shares with zero fee");
    }

    /**
     * @notice Tests that previewDeposit handles small amounts correctly.
     */
    function test_previewDeposit_smallAmounts() public view {
        uint256 shares1 = wrapper.previewDeposit(1);
        uint256 shares10 = wrapper.previewDeposit(10);
        uint256 shares100 = wrapper.previewDeposit(100);

        // Even small amounts should give reasonable results
        assertLe(shares1, shares10, "Monotonic for small amounts");
        assertLe(shares10, shares100, "Monotonic for small amounts");
    }

    /**
     * @notice Tests that previewDeposit handles large amounts correctly.
     */
    function test_previewDeposit_largeAmounts() public view {
        uint256 largeAmount = 1_000_000_000e6; // 1 billion tokens
        uint256 shares = wrapper.previewDeposit(largeAmount);

        assertGt(shares, 0, "Should handle large amounts");
        // Large amounts should still be approximately proportional
        uint256 smallerShares = wrapper.previewDeposit(largeAmount / 2);
        _assertApproxEq(shares, smallerShares * 2, 1, "Large amounts should be proportional");
    }

    /**
     * @notice Tests previewDeposit after multiple deposits and yield accruals.
     */
    function test_previewDeposit_afterMultipleDepositsAndYield() public {
        // First deposit
        _depositAsHook(100e6, alphixHook);
        uint256 preview1 = wrapper.previewDeposit(100e6);

        // Simulate yield
        _simulateYieldPercent(5);
        uint256 preview2 = wrapper.previewDeposit(100e6);
        assertLt(preview2, preview1, "Preview should decrease after yield");

        // Second deposit
        _depositAsHook(200e6, alphixHook);
        uint256 preview3 = wrapper.previewDeposit(100e6);
        // After deposit without yield, preview should remain same
        assertEq(preview3, preview2, "Preview should stay same after deposit without yield");

        // More yield
        _simulateYieldPercent(5);
        uint256 preview4 = wrapper.previewDeposit(100e6);
        assertLt(preview4, preview3, "Preview should decrease after more yield");
    }

    /**
     * @notice Tests that previewDeposit rounds down (favors the vault).
     */
    function test_previewDeposit_roundsDown() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate yield to create non-1:1 ratio
        _simulateYieldPercent(33); // 33% yield for interesting ratio

        uint256 assets = 1000e6;
        uint256 previewedShares = wrapper.previewDeposit(assets);

        // Actually deposit and verify we get exactly the previewed amount
        asset.mint(alphixHook, assets);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), assets);
        uint256 actualShares = wrapper.deposit(assets, alphixHook);
        vm.stopPrank();

        // ERC4626 requires previewDeposit <= actual shares minted (rounds down)
        assertEq(actualShares, previewedShares, "Should get exactly previewed shares");
    }

    /**
     * @notice Tests previewDeposit maintains solvency relationship with totalAssets.
     */
    function test_previewDeposit_solvencyRelationship() public {
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);

        uint256 totalAssets = wrapper.totalAssets();
        uint256 totalSupply = wrapper.totalSupply();

        // Preview for totalAssets should give approximately totalSupply
        uint256 sharesForTotalAssets = wrapper.previewDeposit(totalAssets);

        // Due to rounding, should be close but not necessarily exact
        _assertApproxEq(sharesForTotalAssets, totalSupply, totalSupply / 1000, "Should maintain ratio with total");
    }
}
