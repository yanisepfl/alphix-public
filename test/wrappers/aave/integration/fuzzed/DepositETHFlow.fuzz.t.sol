// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";

/**
 * @title DepositETHFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for ETH deposit flows.
 */
contract DepositETHFlowFuzzTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Fuzz test: complete deposit-yield-deposit flow.
     * @param deposit1 First deposit amount.
     * @param yieldPercent Yield percentage.
     * @param deposit2 Second deposit amount.
     */
    function testFuzz_depositETHFlow_depositYieldDeposit(uint256 deposit1, uint256 yieldPercent, uint256 deposit2)
        public
    {
        deposit1 = bound(deposit1, 0.1 ether, 100 ether);
        yieldPercent = bound(yieldPercent, 1, 50);
        deposit2 = bound(deposit2, 0.1 ether, 100 ether);

        // First deposit
        uint256 shares1 = _depositETHAsHook(deposit1);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Second deposit
        vm.deal(owner, deposit2);
        vm.prank(owner);
        uint256 shares2 = wethWrapper.depositETH{value: deposit2}(owner);

        // After yield, same amount should get fewer shares
        if (deposit1 == deposit2) {
            assertLt(shares2, shares1, "Second deposit should get fewer shares after yield");
        }

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: deposit-fee change-deposit flow.
     * @param deposit1 First deposit amount.
     * @param newFee New fee to set.
     * @param yieldPercent Yield percentage.
     * @param deposit2 Second deposit amount.
     */
    function testFuzz_depositETHFlow_depositFeeChangeDeposit(
        uint256 deposit1,
        uint24 newFee,
        uint256 yieldPercent,
        uint256 deposit2
    ) public {
        deposit1 = bound(deposit1, 0.1 ether, 100 ether);
        newFee = uint24(bound(newFee, 0, MAX_FEE));
        yieldPercent = bound(yieldPercent, 1, 50);
        deposit2 = bound(deposit2, 0.1 ether, 100 ether);

        // First deposit
        _depositETHAsHook(deposit1);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Change fee
        vm.prank(owner);
        wethWrapper.setFee(newFee);

        // Second deposit
        vm.deal(owner, deposit2);
        vm.prank(owner);
        wethWrapper.depositETH{value: deposit2}(owner);

        // Fees should have been accrued
        assertGt(wethWrapper.getClaimableFees(), 0, "Fees should be accrued");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test: multiple sequential deposits with varying amounts.
     * @param amounts Array of deposit amounts.
     */
    function testFuzz_depositETHFlow_multipleSequentialDeposits(uint256[5] memory amounts) public {
        uint256 totalShares;
        uint256 totalDeposited;

        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 0.01 ether, 10 ether);

            vm.deal(alphixHook, amounts[i]);
            vm.prank(alphixHook);
            totalShares += wethWrapper.depositETH{value: amounts[i]}(alphixHook);
            totalDeposited += amounts[i];
        }

        assertEq(wethWrapper.balanceOf(alphixHook), totalShares, "Total shares mismatch");

        // Max withdraw should be close to total deposited (no yield)
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        assertApproxEqRel(maxWithdraw, totalDeposited, 0.01e18, "Max withdraw should match deposits");
    }

    /**
     * @notice Fuzz test: deposit ETH round-trip (deposit then withdraw all).
     * @param depositAmount The deposit amount.
     */
    function testFuzz_depositETHFlow_roundTrip(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);

        // Deposit
        vm.prank(alphixHook);
        wethWrapper.depositETH{value: depositAmount}(alphixHook);

        // Withdraw all
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);
        vm.prank(alphixHook);
        wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

        // Should get back ~100% (small rounding losses possible)
        assertApproxEqRel(maxWithdraw, depositAmount, 0.001e18, "Should withdraw ~100% of deposit");
    }

    /**
     * @notice Fuzz test: mixed ETH and WETH deposits.
     * @param ethAmount ETH deposit amount.
     * @param wethAmount WETH deposit amount.
     */
    function testFuzz_depositETHFlow_mixedEthAndWeth(uint256 ethAmount, uint256 wethAmount) public {
        ethAmount = bound(ethAmount, 0.1 ether, 50 ether);
        wethAmount = bound(wethAmount, 0.1 ether, 50 ether);

        // ETH deposit
        vm.deal(alphixHook, ethAmount);
        vm.prank(alphixHook);
        uint256 ethShares = wethWrapper.depositETH{value: ethAmount}(alphixHook);

        // WETH deposit
        vm.deal(alphixHook, wethAmount);
        vm.startPrank(alphixHook);
        weth.deposit{value: wethAmount}();
        uint256 wethShares = wethWrapper.deposit(wethAmount, alphixHook);
        vm.stopPrank();

        // Total shares should be sum
        assertEq(wethWrapper.balanceOf(alphixHook), ethShares + wethShares, "Total shares mismatch");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }
}
