// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title TotalAssetsFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the totalAssets view function.
 */
contract TotalAssetsFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test totalAssets with varying deposits.
     * @param depositMultiplier Deposit amount multiplier.
     */
    function testFuzz_totalAssets_varyingDeposits(uint256 depositMultiplier) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        uint256 totalAssetsBefore = wrapper.totalAssets();

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should increase by approximately the deposit amount
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore + depositAmount, 0.01e18, "Total assets should increase");
    }

    /**
     * @notice Fuzz test totalAssets equals sUSDS value minus fees.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_totalAssets_equalsSusdsMinusFees(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 totalAssets = wrapper.totalAssets();

        uint256 netSusds = susdsBalance - claimableFees;
        uint256 expectedUsds = _susdsToUsds(netSusds);

        _assertApproxEq(totalAssets, expectedUsds, 2, "totalAssets should equal sUSDS value minus fees");
    }

    /**
     * @notice Fuzz test totalAssets with zero fee.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_totalAssets_zeroFee(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        // All sUSDS value should be totalAssets (no fees)
        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 expectedUsds = _susdsToUsds(susdsBalance);

        _assertApproxEq(totalAssets, expectedUsds, 2, "All sUSDS value should be totalAssets");
    }

    /**
     * @notice Fuzz test totalAssets decreases on withdraw.
     * @param depositMultiplier Deposit amount.
     * @param withdrawPercent Percentage to withdraw.
     */
    function testFuzz_totalAssets_decreasesOnWithdraw(uint256 depositMultiplier, uint256 withdrawPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

            uint256 totalAssetsAfter = wrapper.totalAssets();

            assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease");
        }
    }

    /**
     * @notice Fuzz test totalAssets after yield.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_totalAssets_afterYield(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        _simulateYieldPercent(yieldPercent);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase with yield");
    }

    /**
     * @notice Fuzz test totalAssets after fee collection.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_totalAssets_afterFeeCollection(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        vm.prank(owner);
        wrapper.collectFees();

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should be unchanged after fee collection
        assertEq(totalAssetsAfter, totalAssetsBefore, "Total assets unchanged after fee collection");
    }

    /**
     * @notice Fuzz test multiple deposits and withdraws.
     * @param deposits Array of deposit amounts.
     * @param withdrawPercent Withdraw percentage.
     */
    function testFuzz_totalAssets_multipleOperations(uint256[3] memory deposits, uint256 withdrawPercent) public {
        withdrawPercent = bound(withdrawPercent, 1, 50);

        uint256 totalDeposited;

        for (uint256 i = 0; i < deposits.length; i++) {
            deposits[i] = bound(deposits[i], 1, 100_000_000);
            uint256 amount = deposits[i] * 1e18;

            usds.mint(alphixHook, amount);
            vm.startPrank(alphixHook);
            usds.approve(address(wrapper), amount);
            wrapper.deposit(amount, alphixHook);
            vm.stopPrank();

            totalDeposited += amount;
        }

        // Withdraw some
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        // Verify solvency
        _assertSolvent();
    }
}
