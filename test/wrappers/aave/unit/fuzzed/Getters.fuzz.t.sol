// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title GettersFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave getter functions.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract GettersFuzzTest is BaseAlphix4626WrapperAave {
    /* getClaimableFees */

    /**
     * @notice Fuzz test that claimable fees are correct after yield.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     * @param feeRate The fee rate.
     */
    function testFuzz_getClaimableFees_correct(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent,
        uint24 feeRate
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);
        feeRate = _boundFee(feeRate);

        vm.prank(owner);
        d.wrapper.setFee(feeRate);

        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 balanceBefore = d.aToken.balanceOf(address(d.wrapper));
        _simulateYieldOnDeployment(d, yieldPercent);
        uint256 balanceAfter = d.aToken.balanceOf(address(d.wrapper));

        uint256 actualYield = balanceAfter - balanceBefore;
        uint256 expectedFees = actualYield * feeRate / MAX_FEE;
        uint256 claimableFees = d.wrapper.getClaimableFees();

        _assertApproxEq(claimableFees, expectedFees, 1, "Claimable fees should match expected");
    }

    /**
     * @notice Fuzz test that fees accumulate correctly.
     * @param decimals The asset decimals (6-18).
     * @param depositMultipliers Array of deposit multipliers.
     * @param yieldPercents Array of yield percentages.
     */
    function testFuzz_getClaimableFees_accumulates(
        uint8 decimals,
        uint256[3] memory depositMultipliers,
        uint256[3] memory yieldPercents
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 previousFees;

        for (uint256 i = 0; i < 3; i++) {
            depositMultipliers[i] = bound(depositMultipliers[i], 1, 100_000_000);
            uint256 depositAmount = depositMultipliers[i] * 10 ** d.decimals;
            yieldPercents[i] = bound(yieldPercents[i], 1, 20);

            d.asset.mint(alphixHook, depositAmount);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), depositAmount);
            d.wrapper.deposit(depositAmount, alphixHook);
            vm.stopPrank();

            _simulateYieldOnDeployment(d, yieldPercents[i]);

            uint256 currentFees = d.wrapper.getClaimableFees();
            assertGe(currentFees, previousFees, "Fees should not decrease");
            previousFees = currentFees;
        }
    }

    /* getLastWrapperBalance */

    /**
     * @notice Fuzz test that last wrapper balance updates after deposit.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     */
    function testFuzz_getLastWrapperBalance_updatesAfterDeposit(uint8 decimals, uint256 depositMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        uint256 balanceBefore = d.wrapper.getLastWrapperBalance();

        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 balanceAfter = d.wrapper.getLastWrapperBalance();
        assertEq(balanceAfter, balanceBefore + depositAmount, "Last balance should update");
    }

    /**
     * @notice Fuzz test that last wrapper balance equals aToken after accrual.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_getLastWrapperBalance_equalsATokenAfterAccrual(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        yieldPercent = bound(yieldPercent, 1, 100);

        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        _simulateYieldOnDeployment(d, yieldPercent);

        // Trigger accrual
        vm.prank(owner);
        d.wrapper.setFee(DEFAULT_FEE);

        uint256 lastBalance = d.wrapper.getLastWrapperBalance();
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));

        assertEq(lastBalance, aTokenBalance, "Last balance should equal aToken after accrual");
    }

    /* getFee */

    /**
     * @notice Fuzz test that getFee returns set fee.
     * @param decimals The asset decimals (6-18).
     * @param feeRate The fee rate.
     */
    function testFuzz_getFee_returnsSetFee(uint8 decimals, uint24 feeRate) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        feeRate = _boundFee(feeRate);

        vm.prank(owner);
        d.wrapper.setFee(feeRate);

        assertEq(d.wrapper.getFee(), feeRate, "getFee should return set fee");
    }

    /**
     * @notice Fuzz test fee changes.
     * @param decimals The asset decimals (6-18).
     * @param fees Array of fees.
     */
    function testFuzz_getFee_multipleChanges(uint8 decimals, uint24[5] memory fees) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.startPrank(owner);
        for (uint256 i = 0; i < fees.length; i++) {
            fees[i] = _boundFee(fees[i]);
            d.wrapper.setFee(fees[i]);
            assertEq(d.wrapper.getFee(), fees[i], "Fee should match");
        }
        vm.stopPrank();
    }
}
