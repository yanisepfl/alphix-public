// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";

/**
 * @title RedeemETHFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for ETH redeem flows.
 */
contract RedeemETHFlowFuzzTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Fuzz test: deposit-yield-redeem flow.
     * @param depositAmount Deposit amount.
     * @param yieldPercent Yield percentage.
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_redeemETHFlow_depositYieldRedeem(
        uint256 depositAmount,
        uint256 yieldPercent,
        uint256 redeemPercent
    ) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        yieldPercent = bound(yieldPercent, 0, 50);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deal ETH and deposit
        vm.deal(alphixHook, depositAmount);
        _depositETHAsHook(depositAmount);

        // Simulate yield
        if (yieldPercent > 0) {
            _simulateYieldPercent(yieldPercent);
        }

        // Redeem based on actual maxRedeem to ensure validity
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);
        uint256 redeemShares = maxRedeem * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;
        if (redeemShares > maxRedeem) redeemShares = maxRedeem;

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        assertGt(assets, 0, "Should receive assets");
        assertEq(alphixHook.balance, ethBefore + assets, "Should receive correct ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: deposit-slash-redeem flow.
     * @param depositAmount Deposit amount.
     * @param slashPercent Slash percentage.
     * @param redeemPercent Percentage of shares to redeem.
     */
    function testFuzz_redeemETHFlow_depositSlashRedeem(
        uint256 depositAmount,
        uint256 slashPercent,
        uint256 redeemPercent
    ) public {
        depositAmount = bound(depositAmount, 1 ether, 100 ether);
        slashPercent = bound(slashPercent, 1, 50);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Simulate slash
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        aToken.simulateSlash(address(wethWrapper), slashAmount);

        // Redeem
        uint256 redeemShares = sharesMinted * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBefore + assets, "Should receive correct ETH");

        // Assets should be less than proportional deposit due to slash
        uint256 expectedWithoutSlash = depositAmount * redeemPercent / 100;
        assertLt(assets, expectedWithoutSlash, "Assets should be less after slash");
    }

    /**
     * @notice Fuzz test: multiple deposits then partial redeem.
     * @param deposits Array of deposit amounts.
     * @param redeemPercent Percentage to redeem.
     */
    function testFuzz_redeemETHFlow_multipleDepositsThenRedeem(uint256[3] memory deposits, uint256 redeemPercent)
        public
    {
        redeemPercent = bound(redeemPercent, 1, 100);

        uint256 totalShares;

        // Multiple deposits
        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] = bound(deposits[i], 0.1 ether, 10 ether);
            vm.deal(alphixHook, deposits[i]);
            vm.prank(alphixHook);
            totalShares += wethWrapper.depositETH{value: deposits[i]}(alphixHook);
        }

        // Redeem percentage
        uint256 redeemShares = totalShares * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        assertEq(alphixHook.balance, ethBefore + assets, "Should receive correct ETH");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: redeem to random receiver.
     * @param depositAmount Deposit amount.
     * @param receiver Receiver address.
     * @param redeemPercent Percentage to redeem.
     */
    function testFuzz_redeemETHFlow_toRandomReceiver(uint256 depositAmount, address receiver, uint256 redeemPercent)
        public
    {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(wethWrapper));
        vm.assume(receiver != address(aToken));
        vm.assume(receiver != address(weth));
        // Ensure receiver can accept ETH (exclude contracts and precompiles 0x01-0x09)
        vm.assume(receiver.code.length == 0);
        vm.assume(uint160(receiver) > 10);
        // Exclude Foundry's console.log precompile which cannot receive ETH
        vm.assume(receiver != 0x000000000000000000636F6e736F6c652e6c6f67);

        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Redeem to receiver
        uint256 redeemShares = sharesMinted * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        uint256 receiverBefore = receiver.balance;

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(redeemShares, receiver, alphixHook);

        assertEq(receiver.balance, receiverBefore + assets, "Receiver should get ETH");
    }

    /**
     * @notice Fuzz test: preview matches actual for various amounts.
     * @param depositAmount Deposit amount.
     * @param redeemPercent Percentage to redeem.
     */
    function testFuzz_redeemETHFlow_previewMatchesActual(uint256 depositAmount, uint256 redeemPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        redeemPercent = bound(redeemPercent, 1, 100);

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Calculate redeem shares
        uint256 redeemShares = sharesMinted * redeemPercent / 100;
        if (redeemShares == 0) redeemShares = 1;

        // Preview
        uint256 previewedAssets = wethWrapper.previewRedeem(redeemShares);

        // Actual redeem
        vm.prank(alphixHook);
        uint256 actualAssets = wethWrapper.redeemETH(redeemShares, alphixHook, alphixHook);

        assertEq(actualAssets, previewedAssets, "Actual should match preview");
    }

    /**
     * @notice Fuzz test: redeem all shares.
     * @param depositAmount Deposit amount.
     */
    function testFuzz_redeemETHFlow_redeemAll(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);

        // Deposit
        uint256 sharesMinted = _depositETHAsHook(depositAmount);

        // Redeem all
        uint256 ethBefore = alphixHook.balance;

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(sharesMinted, alphixHook, alphixHook);

        assertEq(wethWrapper.balanceOf(alphixHook), 0, "Should have no shares");
        assertEq(alphixHook.balance, ethBefore + assets, "Should receive ETH");
        assertApproxEqRel(assets, depositAmount, 0.001e18, "Should receive ~100% of deposit");
    }

    /**
     * @notice Fuzz test: comparison with standard redeem.
     * @param depositAmount Deposit amount.
     */
    function testFuzz_redeemETHFlow_comparisonWithStandardRedeem(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 50 ether);

        // Two users deposit same amount
        uint256 hookShares = _depositETHAsHook(depositAmount);

        vm.deal(owner, depositAmount);
        vm.prank(owner);
        uint256 ownerShares = wethWrapper.depositETH{value: depositAmount}(owner);

        assertEq(hookShares, ownerShares, "Same deposit should give same shares");

        // Hook uses redeemETH
        uint256 hookEthBefore = alphixHook.balance;
        vm.prank(alphixHook);
        uint256 hookAssets = wethWrapper.redeemETH(hookShares, alphixHook, alphixHook);

        // Owner uses standard redeem (gets WETH)
        uint256 ownerWethBefore = weth.balanceOf(owner);
        vm.prank(owner);
        uint256 ownerAssets = wethWrapper.redeem(ownerShares, owner, owner);

        // Both should get same assets
        assertEq(hookAssets, ownerAssets, "Both methods should return same assets");
        assertEq(alphixHook.balance, hookEthBefore + hookAssets, "Hook receives ETH");
        assertEq(weth.balanceOf(owner), ownerWethBefore + ownerAssets, "Owner receives WETH");
    }
}
