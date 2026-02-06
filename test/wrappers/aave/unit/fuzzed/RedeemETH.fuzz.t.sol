// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title RedeemETHFuzzTest
 * @author Alphix
 * @notice Fuzz tests for redeemETH functionality in Alphix4626WrapperWethAave.
 */
contract RedeemETHFuzzTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Fuzz test: redeemETH valid shares.
     * @param depositAmount The deposit amount to fuzz.
     * @param redeemPercent The percentage of shares to redeem (1-100).
     */
    function testFuzz_redeemETH_validShares(uint256 depositAmount, uint256 redeemPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deal ETH and deposit
        vm.deal(alphixHook, depositAmount);
        _depositETHAsHook(depositAmount);

        // Calculate redeem shares
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 ethBalanceBefore = alphixHook.balance;

        // Redeem ETH
        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        assertGt(assets, 0, "Should receive assets");
        assertEq(alphixHook.balance, ethBalanceBefore + assets, "Should receive ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: redeemETH after yield.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_redeemETH_afterYield(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit ETH
        uint256 shares = _depositETHAsHook(depositAmount);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Redeem half of shares
        uint256 redeemShares = shares / 2;
        if (redeemShares == 0) return;

        uint256 ethBalanceBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        // After yield, same shares should get more assets
        assertGt(assets, 0, "Should receive assets");
        assertEq(alphixHook.balance, ethBalanceBefore + assets, "Should receive ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: maxRedeem returns valid amounts.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_maxRedeem_valid(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);

        // Deal ETH and deposit
        vm.deal(alphixHook, depositAmount);
        uint256 shares = _depositETHAsHook(depositAmount);

        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);

        // maxRedeem should be <= shares minted
        assertLe(maxRedeem, shares, "Max redeem should not exceed shares");
        assertGt(maxRedeem, 0, "Max redeem should be positive");
    }

    /**
     * @notice Fuzz test: redeemETH exactly maxRedeem.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_redeemETH_exactMax(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        uint256 ethBalanceBefore = alphixHook.balance;

        // Redeem exactly max
        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(maxRedeem, alphixHook, alphixHook);

        assertGt(assets, 0, "Should receive assets");
        assertEq(alphixHook.balance, ethBalanceBefore + assets, "Should receive ETH");
        assertEq(wethWrapper.balanceOf(alphixHook), 0, "Should have no shares left");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: redeemETH exceeds max reverts.
     * @param depositAmount The deposit amount.
     * @param excess The excess shares above max.
     */
    function testFuzz_redeemETH_exceedsMax_reverts(uint256 depositAmount, uint256 excess) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        excess = bound(excess, 1, 1000 ether);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem + excess;

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.RedeemExceedsMax.selector);
        wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);
    }

    /**
     * @notice Fuzz test: multiple redemptions maintain solvency.
     * @param numRedemptions Number of redemptions.
     */
    function testFuzz_redeemETH_multipleMaintainSolvency(uint8 numRedemptions) public {
        numRedemptions = uint8(bound(numRedemptions, 1, 10));

        // Deposit a large amount
        _depositETHAsHook(100 ether);

        vm.startPrank(alphixHook);
        for (uint8 i = 0; i < numRedemptions; i++) {
            uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
            if (maxRedeem == 0) break;

            uint256 redeemShares = maxRedeem / (numRedemptions - i);
            if (redeemShares == 0) redeemShares = 1;
            if (redeemShares > maxRedeem) redeemShares = maxRedeem;

            wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);
        }
        vm.stopPrank();

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: redeemETH to any receiver address.
     * @param depositAmount The deposit amount.
     * @param receiver The receiver address.
     * @param redeemPercent The percentage of shares to redeem.
     */
    function testFuzz_redeemETH_toAnyReceiver(uint256 depositAmount, address receiver, uint256 redeemPercent) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wethWrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(aavePool));
        vm.assume(receiver != address(weth));
        // Ensure receiver can accept ETH (exclude contracts and precompiles 0x01-0x09)
        vm.assume(receiver.code.length == 0);
        vm.assume(uint160(receiver) > 10);
        // Exclude Foundry's console.log precompile which cannot receive ETH
        vm.assume(receiver != 0x000000000000000000636F6e736F6c652e6c6f67);

        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        // Calculate redeem shares
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 receiverBalanceBefore = receiver.balance;

        // Redeem ETH to any receiver
        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, receiver, alphixHook);

        assertEq(receiver.balance, receiverBalanceBefore + assets, "Receiver should get ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: unauthorized address maxRedeem returns 0.
     * @param unauthorizedAddr Random unauthorized address.
     */
    function testFuzz_maxRedeem_unauthorizedReturnsZero(address unauthorizedAddr) public view {
        vm.assume(unauthorizedAddr != alphixHook);
        vm.assume(unauthorizedAddr != owner);
        vm.assume(unauthorizedAddr != address(0));

        assertEq(wethWrapper.maxRedeem(unauthorizedAddr), 0, "Unauthorized should have 0 maxRedeem");
    }

    /**
     * @notice Fuzz test: redeemETH after negative yield (slash).
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_redeemETH_afterNegativeYield(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        slashPercent = bound(slashPercent, 1, 50); // Max 50% slash

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wethWrapper), slashAmount);

        // maxRedeem should still equal shares (we still own the shares)
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);

        // Redeem should work but return less assets
        if (maxRedeem > 0) {
            uint256 ethBalanceBefore = alphixHook.balance;

            vm.prank(alphixHook);
            uint256 assets = wethWrapper.redeemETH(maxRedeem, alphixHook, alphixHook);

            // Assets should be less than original deposit due to slash
            assertLt(assets, depositAmount, "Assets should be less after slash");
            assertEq(alphixHook.balance, ethBalanceBefore + assets, "Should receive ETH");
        }

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: previewRedeem matches actual redeemETH.
     * @param depositAmount The deposit amount.
     * @param redeemPercent The percentage of shares to redeem.
     */
    function testFuzz_redeemETH_matchesPreview(uint256 depositAmount, uint256 redeemPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit ETH
        _depositETHAsHook(depositAmount);

        // Calculate redeem shares
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 previewedAssets = wethWrapper.previewRedeem(redeemShares);

        vm.prank(alphixHook);
        uint256 actualAssets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        assertEq(actualAssets, previewedAssets, "Actual assets should match preview");
    }
}
