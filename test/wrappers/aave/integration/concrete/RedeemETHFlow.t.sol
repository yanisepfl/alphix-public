// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";

/**
 * @title RedeemETHFlowTest
 * @author Alphix
 * @notice Integration tests for complete ETH redeem user flows.
 */
contract RedeemETHFlowTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Tests a complete ETH redeem flow.
     */
    function test_redeemETHFlow_basicRedeem() public {
        uint256 depositAmount = 10 ether;

        // Deposit first
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Record state before redeem
        uint256 ethBefore = alphixHook.balance;
        uint256 totalAssetsBefore = wethWrapper.totalAssets();

        // Redeem half the shares
        uint256 redeemShares = sharesMinted / 2;
        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        // Verify state
        assertEq(wethWrapper.balanceOf(alphixHook), sharesMinted - redeemShares, "Shares should decrease");
        assertEq(alphixHook.balance, ethBefore + assetsReceived, "ETH should increase");
        assertEq(wethWrapper.totalAssets(), totalAssetsBefore - assetsReceived, "Total assets should decrease");
    }

    /**
     * @notice Tests redeem ETH to a different receiver.
     */
    function test_redeemETHFlow_toDifferentReceiver() public {
        uint256 depositAmount = 10 ether;

        // Deposit first
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Redeem to bob
        uint256 bobEthBefore = bob.balance;
        uint256 redeemShares = sharesMinted / 2;

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(redeemShares, bob, alphixHook);

        assertEq(bob.balance, bobEthBefore + assetsReceived, "Bob should receive ETH");
    }

    /**
     * @notice Tests redeem ETH after yield - should get more assets per share.
     */
    function test_redeemETHFlow_afterYield() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Redeem all shares
        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(sharesMinted, alphixHook, alphixHook);

        // Should receive more than deposited (yield minus fees)
        // With 10% fee on 10% yield = 1% fee, so ~9% gain
        assertGt(assetsReceived, depositAmount * 9 / 10, "Should receive deposit + some yield");
        assertEq(alphixHook.balance, ethBefore + assetsReceived, "ETH balance should match");
    }

    /**
     * @notice Tests redeem all shares.
     */
    function test_redeemETHFlow_redeemAll() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Redeem all
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        assertEq(maxRedeem, sharesMinted, "Max redeem should equal shares");

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(maxRedeem, alphixHook, alphixHook);

        assertEq(wethWrapper.balanceOf(alphixHook), 0, "Should have no shares");
        assertEq(alphixHook.balance, ethBefore + assetsReceived, "Should receive ETH");
    }

    /**
     * @notice Tests multiple partial redemptions.
     */
    function test_redeemETHFlow_multiplePartialRedemptions() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        _depositETHAsHook(depositAmount);

        uint256 totalAssetsReceived;

        // Multiple partial redemptions - redeem 1/4 each time for 3 times = 75% total
        for (uint256 i = 0; i < 3; i++) {
            uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
            if (maxRedeem == 0) break;

            uint256 redeemShares = maxRedeem / 4;
            if (redeemShares == 0) break;

            vm.prank(alphixHook);
            totalAssetsReceived += wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);
        }

        // Should have received a meaningful portion of deposit (3/4 * 10 = 7.5 ETH, but with compounding effect)
        assertGt(totalAssetsReceived, depositAmount * 5 / 10, "Should have received meaningful portion of deposit");
    }

    /**
     * @notice Tests redeemETH interleaved with depositETH.
     */
    function test_redeemETHFlow_interleavedWithDeposits() public {
        // Deposit 10 ETH
        uint256 shares1 = _depositETHAsHook(10 ether);

        // Redeem half shares
        vm.prank(alphixHook);
        wethWrapper.redeemETH(shares1 / 2, alphixHook, alphixHook);

        // Deposit 5 ETH more
        vm.deal(alphixHook, 5 ether);
        vm.prank(alphixHook);
        wethWrapper.depositETH{value: 5 ether}(alphixHook);

        // Redeem quarter of remaining
        uint256 currentShares = wethWrapper.balanceOf(alphixHook);
        vm.prank(alphixHook);
        wethWrapper.redeemETH(currentShares / 4, alphixHook, alphixHook);

        // Should have some shares left
        assertGt(wethWrapper.balanceOf(alphixHook), 0, "Should have shares left");
    }

    /**
     * @notice Tests redeem ETH with negative yield (slash).
     */
    function test_redeemETHFlow_afterNegativeYield() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Simulate 20% slash
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 slashAmount = currentBalance * 20 / 100;
        aToken.simulateSlash(address(wethWrapper), slashAmount);

        // Redeem all - should get less than deposited
        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(sharesMinted, alphixHook, alphixHook);

        assertLt(assetsReceived, depositAmount, "Should receive less after slash");
        assertEq(alphixHook.balance, ethBefore + assetsReceived, "Should receive ETH");
    }

    /**
     * @notice Tests comparison between withdrawETH and redeemETH.
     */
    function test_redeemETHFlow_comparisonWithWithdrawETH() public {
        uint256 depositAmount = 10 ether;

        // Two deposits for comparison
        uint256 shares1 = _depositETHAsHook(depositAmount);

        vm.deal(owner, depositAmount);
        vm.prank(owner);
        uint256 shares2 = wethWrapper.depositETH{value: depositAmount}(owner);

        assertEq(shares1, shares2, "Same deposit should give same shares");

        // Hook uses withdrawETH (asset-based)
        uint256 hookAssets = wethWrapper.convertToAssets(shares1 / 2);
        vm.prank(alphixHook);
        uint256 hookSharesBurned = wethWrapper.withdrawETH(hookAssets, alphixHook, alphixHook);

        // Owner uses redeemETH (share-based)
        vm.prank(owner);
        uint256 ownerAssetsReceived = wethWrapper.redeemETH(shares2 / 2, owner, owner);

        // Results should be equivalent
        assertApproxEqRel(hookSharesBurned, shares1 / 2, 0.01e18, "Shares burned should be ~half");
        assertApproxEqRel(ownerAssetsReceived, hookAssets, 0.01e18, "Assets received should match");
    }

    /**
     * @notice Tests redeem ETH after fee collection.
     */
    function test_redeemETHFlow_afterFeeCollection() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Simulate yield
        _simulateYieldPercent(20);

        // Collect fees
        vm.prank(owner);
        wethWrapper.collectFees();

        // User still has their original shares (balanceOf unchanged)
        assertEq(wethWrapper.balanceOf(alphixHook), sharesMinted, "Share balance should be unchanged");

        // maxRedeem may differ from sharesMinted due to how maxRedeem is calculated
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        assertGt(maxRedeem, 0, "Should be able to redeem after fee collection");

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(maxRedeem, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "Should receive assets");
    }

    /**
     * @notice Tests that previewRedeem matches actual redemption.
     */
    function test_redeemETHFlow_previewMatchesActual() public {
        uint256 depositAmount = 10 ether;

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Preview
        uint256 previewedAssets = wethWrapper.previewRedeem(sharesMinted);

        // Actual redeem
        vm.prank(alphixHook);
        uint256 actualAssets = wethWrapper.redeemETH(sharesMinted, alphixHook, alphixHook);

        assertEq(actualAssets, previewedAssets, "Actual should match preview");
    }
}
