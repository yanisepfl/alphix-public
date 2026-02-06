// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title RedeemFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for redeem flow scenarios.
 */
contract RedeemFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test deposit then partial redeem flow.
     * @param depositAmount The deposit amount.
     * @param redeemPercent The percentage of shares to redeem (1-99).
     */
    function testFuzz_flow_depositThenPartialRedeem(uint256 depositAmount, uint256 redeemPercent) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        redeemPercent = bound(redeemPercent, 1, 99);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        // Redeem
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertEq(sharesBefore - sharesAfter, redeemShares, "Shares burned mismatch");
        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Assets received mismatch");
        assertGt(sharesAfter, 0, "Should have remaining shares after partial redeem");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit, yield, then redeem flow.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     * @param redeemPercent The percentage of max to redeem.
     */
    function testFuzz_flow_depositYieldRedeem(uint256 depositAmount, uint256 yieldPercent, uint256 redeemPercent)
        public
    {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        yieldPercent = bound(yieldPercent, 1, 100);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Calculate redeem
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        // Redeem
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should receive assets");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple deposits then single redeem.
     * @param deposit1 First deposit amount.
     * @param deposit2 Second deposit amount.
     * @param deposit3 Third deposit amount.
     */
    function testFuzz_flow_multipleDepositsSingleRedeem(uint256 deposit1, uint256 deposit2, uint256 deposit3) public {
        deposit1 = bound(deposit1, 1e6, 100_000e6);
        deposit2 = bound(deposit2, 1e6, 100_000e6);
        deposit3 = bound(deposit3, 1e6, 100_000e6);

        // Multiple deposits
        _depositAsHook(deposit1, alphixHook);
        _depositAsHook(deposit2, alphixHook);
        _depositAsHook(deposit3, alphixHook);

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
     * @notice Fuzz test single deposit then multiple redemptions.
     * @param depositAmount The deposit amount.
     * @param numRedemptions Number of redemptions (1-5).
     */
    function testFuzz_flow_singleDepositMultipleRedeems(uint256 depositAmount, uint8 numRedemptions) public {
        depositAmount = bound(depositAmount, 10e6, 1_000_000e6);
        numRedemptions = uint8(bound(numRedemptions, 1, 5));

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsReceived;

        // Multiple redemptions
        vm.startPrank(alphixHook);
        for (uint8 i = 0; i < numRedemptions; i++) {
            uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
            if (maxRedeem == 0) break;

            uint256 redeemShares = maxRedeem / (numRedemptions - i);
            if (redeemShares == 0) redeemShares = 1;
            if (redeemShares > maxRedeem) redeemShares = maxRedeem;

            uint256 assets = wrapper.redeem(redeemShares, alphixHook, alphixHook);
            totalAssetsReceived += assets;
        }
        vm.stopPrank();

        assertEq(asset.balanceOf(alphixHook), totalAssetsReceived, "Total assets received mismatch");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test interleaved deposits and redemptions.
     * @param amounts Array of amounts for operations.
     */
    function testFuzz_flow_interleavedOperations(uint256[6] memory amounts) public {
        // Bound all amounts
        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1e6, 100_000e6);
        }

        // Deposit
        _depositAsHook(amounts[0], alphixHook);

        // Redeem some (up to max shares)
        uint256 max1 = wrapper.maxRedeem(alphixHook);
        uint256 redeem1 = max1 / 4;
        if (redeem1 > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(redeem1, alphixHook, alphixHook);
        }

        // Deposit more
        _depositAsHook(amounts[2], alphixHook);

        // Simulate yield
        _simulateYieldPercent(5);

        // Redeem some
        uint256 max2 = wrapper.maxRedeem(alphixHook);
        uint256 redeem2 = max2 / 4;
        if (redeem2 > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(redeem2, alphixHook, alphixHook);
        }

        // Deposit more
        _depositAsHook(amounts[4], alphixHook);

        // Final redeem
        uint256 max3 = wrapper.maxRedeem(alphixHook);
        uint256 redeem3 = max3 / 4;
        if (redeem3 > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(redeem3, alphixHook, alphixHook);
        }

        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have shares");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem after negative yield.
     * @param depositAmount The deposit amount.
     * @param slashPercent The slash percentage (1-50).
     */
    function testFuzz_flow_redeemAfterSlash(uint256 depositAmount, uint256 slashPercent) public {
        depositAmount = bound(depositAmount, 10e6, 1_000_000e6);
        slashPercent = bound(slashPercent, 1, 50);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wrapper), slashAmount);

        // Redeem max
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);

        if (maxRedeem > 0) {
            vm.prank(alphixHook);
            uint256 assetsReceived = wrapper.redeem(maxRedeem, alphixHook, alphixHook);

            assertEq(asset.balanceOf(alphixHook), assetsReceived, "Should receive assets");
        }
        _assertSolvent();
    }

    /**
     * @notice Fuzz test multi-user redeem flow.
     * @param hook1Deposit Hook1's deposit amount.
     * @param hook2Deposit Hook2's deposit amount.
     * @param redeemPercent Percentage each redeems.
     */
    function testFuzz_flow_multiUserRedeem(uint256 hook1Deposit, uint256 hook2Deposit, uint256 redeemPercent) public {
        hook1Deposit = bound(hook1Deposit, 1e6, 100_000e6);
        hook2Deposit = bound(hook2Deposit, 1e6, 100_000e6);
        redeemPercent = bound(redeemPercent, 1, 100);

        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Both deposit
        _depositAsHook(hook1Deposit, alphixHook);

        asset.mint(hook2, hook2Deposit);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), hook2Deposit);
        wrapper.deposit(hook2Deposit, hook2);
        vm.stopPrank();

        // Simulate yield
        _simulateYieldPercent(10);

        // Both redeem
        uint256 hook1Max = wrapper.maxRedeem(alphixHook);
        uint256 hook1Redeem = hook1Max * redeemPercent / 100;
        if (hook1Redeem > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(hook1Redeem, alphixHook, alphixHook);
        }

        uint256 hook2Max = wrapper.maxRedeem(hook2);
        uint256 hook2Redeem = hook2Max * redeemPercent / 100;
        if (hook2Redeem > 0) {
            vm.prank(hook2);
            wrapper.redeem(hook2Redeem, hook2, hook2);
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem with various decimals.
     * @param decimals Token decimals.
     * @param depositMultiplier Deposit amount in tokens.
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_flow_redeemVariousDecimals(uint8 decimals, uint256 depositMultiplier, uint256 redeemPercent)
        public
    {
        decimals = uint8(bound(decimals, 6, 18));
        depositMultiplier = bound(depositMultiplier, 1, 1_000_000);
        redeemPercent = bound(redeemPercent, 1, 100);

        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Deposit
        _depositAsHookOnDeployment(d, depositAmount);

        // Calculate redeem
        uint256 maxRedeem = d.wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) return;

        // Redeem
        vm.prank(alphixHook);
        uint256 assetsReceived = d.wrapper.redeem(redeemShares, alphixHook, alphixHook);

        assertEq(d.asset.balanceOf(alphixHook), assetsReceived, "Should receive assets");
    }

    /**
     * @notice Fuzz test mixed withdraw and redeem operations.
     * @param depositAmount Initial deposit.
     * @param withdrawPercent Percentage to withdraw.
     * @param redeemPercent Percentage of remaining shares to redeem.
     */
    function testFuzz_flow_mixedWithdrawAndRedeem(uint256 depositAmount, uint256 withdrawPercent, uint256 redeemPercent)
        public
    {
        depositAmount = bound(depositAmount, 10e6, 1_000_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 50);
        redeemPercent = bound(redeemPercent, 1, 50);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Withdraw some by assets
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        // Simulate yield
        _simulateYieldPercent(5);

        // Redeem some by shares
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares > 0) {
            vm.prank(alphixHook);
            wrapper.redeem(redeemShares, alphixHook, alphixHook);
        }

        assertGt(wrapper.balanceOf(alphixHook), 0, "Should have remaining shares");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test redeem to different receiver.
     * @param depositAmount The deposit amount.
     * @param redeemPercent Percentage to redeem.
     * @param receiver The receiver address.
     */
    function testFuzz_flow_redeemToDifferentReceiver(uint256 depositAmount, uint256 redeemPercent, address receiver)
        public
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(aavePool));
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        _depositAsHook(depositAmount, alphixHook);

        // Calculate redeem
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 receiverBalanceBefore = asset.balanceOf(receiver);

        // Redeem to different receiver
        vm.prank(alphixHook);
        uint256 assetsReceived = wrapper.redeem(redeemShares, receiver, alphixHook);

        uint256 receiverBalanceAfter = asset.balanceOf(receiver);

        assertEq(receiverBalanceAfter - receiverBalanceBefore, assetsReceived, "Receiver should get assets");
        _assertSolvent();
    }
}
