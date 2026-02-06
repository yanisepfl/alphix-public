// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";

/**
 * @title DepositETHFlowTest
 * @author Alphix
 * @notice Integration tests for complete ETH deposit user flows.
 */
contract DepositETHFlowTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Tests a complete ETH deposit flow from hook.
     */
    function test_depositETHFlow_hookDepositAndCheckBalances() public {
        uint256 depositAmount = 10 ether;

        // Initial state
        uint256 initialTotalAssets = wethWrapper.totalAssets();
        uint256 initialTotalSupply = wethWrapper.totalSupply();
        uint256 initialHookShares = wethWrapper.balanceOf(alphixHook);
        uint256 initialHookEth = alphixHook.balance;

        // Hook deposits ETH
        vm.prank(alphixHook);
        uint256 shares = wethWrapper.depositETH{value: depositAmount}(alphixHook);

        // Verify state changes
        assertEq(wethWrapper.totalAssets(), initialTotalAssets + depositAmount, "Total assets should increase");
        assertEq(wethWrapper.totalSupply(), initialTotalSupply + shares, "Total supply should increase");
        assertEq(wethWrapper.balanceOf(alphixHook), initialHookShares + shares, "Hook shares should increase");
        assertEq(alphixHook.balance, initialHookEth - depositAmount, "Hook ETH should decrease");

        // Verify aToken balance
        assertEq(
            aToken.balanceOf(address(wethWrapper)), initialTotalAssets + depositAmount, "aToken balance should match"
        );

        // Verify no WETH left in wrapper
        assertEq(weth.balanceOf(address(wethWrapper)), 0, "No WETH should remain in wrapper");
    }

    /**
     * @notice Tests ETH deposit flow with yield accrual between deposits.
     */
    function test_depositETHFlow_multipleDepositsWithYield() public {
        // First deposit
        uint256 deposit1 = 10 ether;
        uint256 shares1 = _depositETHAsHook(deposit1);

        // Simulate yield
        _simulateYieldPercent(10);

        // Second deposit (should get fewer shares due to yield)
        uint256 deposit2 = 10 ether;
        vm.deal(owner, deposit2);
        vm.prank(owner);
        uint256 shares2 = wethWrapper.depositETH{value: deposit2}(owner);

        // After yield, the share price is higher, so same deposit gets fewer shares
        assertLt(shares2, shares1, "Second deposit should get fewer shares after yield");

        // Total shares
        assertEq(wethWrapper.balanceOf(alphixHook), shares1, "Hook should have first deposit shares");
        assertEq(
            wethWrapper.balanceOf(owner),
            shares2 + DEFAULT_SEED_LIQUIDITY,
            "Owner should have second deposit shares + seed"
        );
    }

    /**
     * @notice Tests ETH deposit flow with fee change.
     */
    function test_depositETHFlow_depositAfterFeeChange() public {
        // First deposit at default fee
        uint256 deposit1 = 10 ether;
        _depositETHAsHook(deposit1);

        // Simulate yield
        _simulateYieldPercent(10);

        // Change fee to 50%
        vm.prank(owner);
        wethWrapper.setFee(500_000);

        // Second deposit
        uint256 deposit2 = 10 ether;
        vm.deal(owner, deposit2);
        vm.prank(owner);
        wethWrapper.depositETH{value: deposit2}(owner);

        // Verify fee was applied to first yield
        assertGt(wethWrapper.getClaimableFees(), 0, "Fees should have been accrued");
    }

    /**
     * @notice Tests ETH deposit flow from owner.
     */
    function test_depositETHFlow_ownerDeposit() public {
        uint256 depositAmount = 5 ether;

        uint256 sharesBefore = wethWrapper.balanceOf(owner);

        vm.prank(owner);
        uint256 shares = wethWrapper.depositETH{value: depositAmount}(owner);

        uint256 sharesAfter = wethWrapper.balanceOf(owner);

        // Owner already has shares from seed deposit
        assertGt(sharesBefore, 0, "Owner should have seed shares");
        assertEq(sharesAfter, sharesBefore + shares, "Owner shares should increase");
    }

    /**
     * @notice Tests that ETH deposit wraps correctly and supplies to Aave.
     */
    function test_depositETHFlow_wrapAndSupplyToAave() public {
        uint256 depositAmount = 5 ether;

        uint256 aTokenBefore = aToken.balanceOf(address(wethWrapper));
        uint256 wethInWrapper = weth.balanceOf(address(wethWrapper));

        assertEq(wethInWrapper, 0, "No WETH should be in wrapper before");

        vm.prank(alphixHook);
        wethWrapper.depositETH{value: depositAmount}(alphixHook);

        uint256 aTokenAfter = aToken.balanceOf(address(wethWrapper));
        uint256 wethInWrapperAfter = weth.balanceOf(address(wethWrapper));

        assertEq(aTokenAfter, aTokenBefore + depositAmount, "aToken balance should increase");
        assertEq(wethInWrapperAfter, 0, "No WETH should remain in wrapper after");
    }

    /**
     * @notice Tests depositETH followed by standard WETH deposit.
     */
    function test_depositETHFlow_mixedETHAndWETHDeposits() public {
        // ETH deposit
        uint256 ethDeposit = 5 ether;
        uint256 ethShares = _depositETHAsHook(ethDeposit);

        // WETH deposit (standard deposit)
        uint256 wethDeposit = 5 ether;
        vm.deal(alphixHook, wethDeposit);
        vm.startPrank(alphixHook);
        weth.deposit{value: wethDeposit}();
        uint256 wethShares = wethWrapper.deposit(wethDeposit, alphixHook);
        vm.stopPrank();

        // Both should give same shares (no yield in between)
        assertEq(ethShares, wethShares, "ETH and WETH deposits should give same shares");
        assertEq(wethWrapper.balanceOf(alphixHook), ethShares + wethShares, "Total shares should match");
    }

    /**
     * @notice Tests complete round-trip: deposit ETH -> withdraw ETH.
     */
    function test_depositETHFlow_roundTrip() public {
        uint256 depositAmount = 10 ether;
        uint256 initialEth = alphixHook.balance;

        // Deposit ETH
        vm.prank(alphixHook);
        wethWrapper.depositETH{value: depositAmount}(alphixHook);

        // Withdraw all
        uint256 maxWithdraw = wethWrapper.maxWithdraw(alphixHook);

        vm.prank(alphixHook);
        wethWrapper.withdrawETH(maxWithdraw, alphixHook, alphixHook);

        // Should have received back (almost) all ETH
        uint256 finalEth = alphixHook.balance;
        assertEq(finalEth, initialEth - depositAmount + maxWithdraw, "ETH balance should match");
        assertApproxEqRel(maxWithdraw, depositAmount, 0.001e18, "Should withdraw ~100% of deposit");
    }
}
