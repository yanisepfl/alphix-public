// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title DepositETHFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperWethAave depositETH function.
 */
contract DepositETHFuzzTest is BaseAlphix4626WrapperWethAave {
    /**
     * @notice Fuzz test for depositETH with varying amounts.
     * @param amountMultiplier The deposit amount multiplier (1 wei to 10000 ETH).
     */
    function testFuzz_depositETH_varyingAmounts(uint256 amountMultiplier) public {
        amountMultiplier = bound(amountMultiplier, 1, 10_000 ether);

        vm.deal(alphixHook, amountMultiplier);

        uint256 sharesBefore = wethWrapper.balanceOf(alphixHook);

        vm.prank(alphixHook);
        uint256 shares = wethWrapper.depositETH{value: amountMultiplier}(alphixHook);

        uint256 sharesAfter = wethWrapper.balanceOf(alphixHook);

        assertGt(shares, 0, "Should mint non-zero shares");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance should increase by minted shares");
    }

    /**
     * @notice Fuzz test that unauthorized callers always revert.
     * @param caller Random caller address.
     * @param amount The deposit amount.
     */
    function testFuzz_depositETH_unauthorizedCaller_reverts(address caller, uint256 amount) public {
        // Exclude authorized callers
        vm.assume(caller != alphixHook && caller != owner && caller != address(0));
        amount = bound(amount, 1, 100 ether);

        vm.deal(caller, amount);

        vm.prank(caller);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wethWrapper.depositETH{value: amount}(caller);
    }

    /**
     * @notice Fuzz test that deposit to different receiver reverts (receiver != msg.sender).
     * @param receiver Random receiver address.
     * @param amount The deposit amount.
     */
    function testFuzz_depositETH_differentReceiver_reverts(address receiver, uint256 amount) public {
        // Receiver must be different from caller (alphixHook)
        vm.assume(receiver != alphixHook && receiver != address(0));
        amount = bound(amount, 1, 100 ether);

        vm.deal(alphixHook, amount);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wethWrapper.depositETH{value: amount}(receiver);
    }

    /**
     * @notice Fuzz test that depositETH maintains solvency.
     * @param amount The deposit amount.
     */
    function testFuzz_depositETH_maintainsSolvency(uint256 amount) public {
        amount = bound(amount, 1, 10_000 ether);

        vm.deal(alphixHook, amount);

        vm.prank(alphixHook);
        wethWrapper.depositETH{value: amount}(alphixHook);

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test that previewDeposit matches actual depositETH.
     * @param amount The deposit amount.
     */
    function testFuzz_depositETH_matchesPreview(uint256 amount) public {
        amount = bound(amount, 1, 10_000 ether);

        uint256 previewedShares = wethWrapper.previewDeposit(amount);

        vm.deal(alphixHook, amount);

        vm.prank(alphixHook);
        uint256 actualShares = wethWrapper.depositETH{value: amount}(alphixHook);

        assertEq(actualShares, previewedShares, "Actual shares should match preview");
    }

    /**
     * @notice Fuzz test multiple sequential ETH deposits.
     * @param amounts Array of deposit amounts.
     */
    function testFuzz_depositETH_multipleDeposits(uint256[5] memory amounts) public {
        uint256 totalShares;

        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 0.01 ether, 100 ether);

            vm.deal(alphixHook, amounts[i]);

            vm.prank(alphixHook);
            totalShares += wethWrapper.depositETH{value: amounts[i]}(alphixHook);
        }

        assertEq(wethWrapper.balanceOf(alphixHook), totalShares, "Total shares should match sum of deposits");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test depositETH after yield.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_depositETH_afterYield(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 0.1 ether, 100 ether);
        yieldPercent = bound(yieldPercent, 1, 50);

        // Initial deposit
        vm.deal(alphixHook, depositAmount);
        vm.prank(alphixHook);
        uint256 shares1 = wethWrapper.depositETH{value: depositAmount}(alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Second deposit should get fewer shares
        vm.deal(owner, depositAmount);
        vm.prank(owner);
        uint256 shares2 = wethWrapper.depositETH{value: depositAmount}(owner);

        assertLt(shares2, shares1, "Second deposit should get fewer shares after yield");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wethWrapper));
        uint256 totalAssets = wethWrapper.totalAssets();
        uint256 claimableFees = wethWrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test that ETH is correctly wrapped and supplied.
     * @param amount The deposit amount.
     */
    function testFuzz_depositETH_ethCorrectlyWrapped(uint256 amount) public {
        amount = bound(amount, 0.01 ether, 100 ether);

        uint256 wethBalanceBefore = weth.balanceOf(address(wethWrapper));
        uint256 aTokenBalanceBefore = aToken.balanceOf(address(wethWrapper));

        vm.deal(alphixHook, amount);

        vm.prank(alphixHook);
        wethWrapper.depositETH{value: amount}(alphixHook);

        // WETH balance should be 0 (all supplied to Aave)
        assertEq(weth.balanceOf(address(wethWrapper)), wethBalanceBefore, "WETH should not remain in wrapper");

        // aToken balance should increase
        assertEq(aToken.balanceOf(address(wethWrapper)), aTokenBalanceBefore + amount, "aToken balance should increase");
    }
}
