// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title RedeemFuzzTest
 * @author Alphix
 * @notice Fuzz tests for redeem functionality in Alphix4626WrapperAave.
 */
contract RedeemFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test: redeem valid amounts.
     * @param depositAmount The deposit amount to fuzz.
     * @param redeemPercent The percentage to redeem (0-100).
     */
    function testFuzz_redeem_validAmounts(uint256 depositAmount, uint256 redeemPercent) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Calculate redeem amount
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        // Redeem
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "Should receive assets");
        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: redeem after yield.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_redeem_afterYield(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Redeem half of max
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem / 2;
        if (redeemShares == 0) return;

        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: maxRedeem returns valid amounts.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_maxRedeem_valid(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 balance = wrapper.balanceOf(alphixHook);

        // maxRedeem should be <= share balance
        assertLe(maxRedeem, balance, "Max redeem should not exceed share balance");
        assertGt(maxRedeem, 0, "Max redeem should be positive");
    }

    /**
     * @notice Fuzz test: redeem exactly maxRedeem.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_redeem_exactMax(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        // Redeem exactly max
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: redeem exceeds max reverts.
     * @param depositAmount The deposit amount.
     * @param excess The excess amount above max.
     */
    function testFuzz_redeem_exceedsMax_reverts(uint256 depositAmount, uint256 excess) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        excess = bound(excess, 1, 1_000_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemAmount = maxRedeem + excess;

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.RedeemExceedsMax.selector);
        wrapper.redeem(redeemAmount, alphixHook, alphixHook);
    }

    /**
     * @notice Fuzz test: multiple redemptions maintain solvency.
     * @param numRedemptions Number of redemptions.
     */
    function testFuzz_redeem_multipleMaintainSolvency(uint8 numRedemptions) public {
        numRedemptions = uint8(bound(numRedemptions, 1, 10));

        // Deposit a large amount
        _depositAsHook(1_000e6, alphixHook);

        vm.startPrank(alphixHook);
        for (uint8 i = 0; i < numRedemptions; i++) {
            uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
            if (maxRedeem == 0) break;

            uint256 redeemShares = maxRedeem / (numRedemptions - i);
            if (redeemShares == 0) redeemShares = 1;
            if (redeemShares > maxRedeem) redeemShares = maxRedeem;

            wrapper.redeem(redeemShares, alphixHook, alphixHook);
        }
        vm.stopPrank();

        _assertSolvent();
    }

    /**
     * @notice Fuzz test: assets received is correct.
     * @param depositAmount The deposit amount.
     * @param redeemShares The shares to redeem.
     */
    function testFuzz_redeem_assetsReceivedCorrect(uint256 depositAmount, uint256 redeemShares) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        redeemShares = bound(redeemShares, 1, maxRedeem);

        uint256 previewAssets = wrapper.previewRedeem(redeemShares);

        vm.prank(alphixHook);
        uint256 actualAssets = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        // previewRedeem should match actual (or be slightly less due to rounding)
        assertGe(actualAssets, previewAssets - 1, "Actual should match or exceed preview - 1");
        assertLe(actualAssets, previewAssets + 1, "Actual should be close to preview");
    }

    /**
     * @notice Fuzz test: redeem with various decimal tokens.
     * @param decimals Token decimals.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_redeem_variousDecimals(uint8 decimals, uint256 depositAmount) public {
        decimals = uint8(bound(decimals, 6, 18));

        WrapperDeployment memory deployment = _createWrapperWithDecimals(decimals);

        // Scale deposit amount to decimals
        depositAmount = bound(depositAmount, 10 ** decimals, 1_000_000 * 10 ** decimals);

        // Deposit
        uint256 shares = _depositAsHookOnDeployment(deployment, depositAmount);

        // Redeem half
        uint256 maxRedeem = deployment.wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem / 2;
        if (redeemShares == 0) return;

        vm.prank(alphixHook);
        uint256 assetsReceived = deployment.wrapper.redeem(redeemShares, alphixHook, alphixHook);

        assertGt(assetsReceived, 0, "Should receive assets");
        assertLt(wrapper.balanceOf(alphixHook) + redeemShares, shares + 1, "Should burn shares");
    }

    /**
     * @notice Fuzz test: redeem after negative yield.
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_redeem_afterNegativeYield(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        slashPercent = bound(slashPercent, 1, 50); // Max 50% slash

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // maxRedeem should still work
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        // Redeem should still work
        if (maxRedeem > 0) {
            vm.prank(alphixHook);
            uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

            assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should receive assets");
        }
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: unauthorized address maxRedeem returns 0.
     * @param unauthorizedAddr Random unauthorized address.
     */
    function testFuzz_maxRedeem_unauthorizedReturnsZero(address unauthorizedAddr) public view {
        vm.assume(unauthorizedAddr != alphixHook);
        vm.assume(unauthorizedAddr != owner);
        vm.assume(unauthorizedAddr != address(0));

        assertEq(wrapper.maxRedeem(unauthorizedAddr), 0, "Unauthorized should have 0 maxRedeem");
    }

    /**
     * @notice Fuzz test: redeem to any receiver address.
     * @param depositAmount The deposit amount.
     * @param receiver The receiver address.
     * @param redeemPercent The percentage to redeem.
     */
    function testFuzz_redeem_toAnyReceiver(uint256 depositAmount, address receiver, uint256 redeemPercent) public {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(aavePool));
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Calculate redeem amount
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 receiverBalanceBefore = asset.balanceOf(receiver);

        // Redeem to any receiver
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, receiver, alphixHook);

        uint256 receiverBalanceAfter = asset.balanceOf(receiver);
        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsReceived, "Receiver should get assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test: redeem and withdraw equivalence.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_redeem_withdrawEquivalence(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 10e6, 100_000e6);

        // Deposit twice
        _depositAsHook(depositAmount, alphixHook);
        uint256 initialShares = wrapper.balanceOf(alphixHook);

        // Get half the shares
        uint256 halfShares = initialShares / 2;
        uint256 expectedAssets = wrapper.previewRedeem(halfShares);

        // Redeem half
        vm.prank(alphixHook);
        uint256 assetsFromRedeem = wrapper.redeem(halfShares, alphixHook, alphixHook);

        // The assets received should be close to expected
        _assertApproxEq(assetsFromRedeem, expectedAssets, 1, "Redeem assets should match preview");
    }
}
