// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title PreviewDepositFlowFuzzTest
 * @author Alphix
 * @notice Fuzz integration tests for previewDeposit in user flows.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract PreviewDepositFlowFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test previewDeposit matches actual deposit.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     */
    function testFuzz_previewDepositFlow_matchesActual(uint8 decimals, uint256 depositMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Preview
        uint256 previewedShares = d.wrapper.previewDeposit(depositAmount);

        // Actual deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        uint256 actualShares = d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Preview should match actual");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test previewDeposit behavior with yield.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param previewMultiplier The preview amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_previewDepositFlow_withYield(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 previewMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        previewMultiplier = bound(previewMultiplier, 1, 1_000_000_000);
        yieldPercent = bound(yieldPercent, 1, 50);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        uint256 previewAmount = previewMultiplier * 10 ** d.decimals;

        // Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Preview before yield
        uint256 previewBefore = d.wrapper.previewDeposit(previewAmount);

        // Simulate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // Preview after yield
        uint256 previewAfter = d.wrapper.previewDeposit(previewAmount);

        // After yield, same assets should give fewer or equal shares
        assertLe(previewAfter, previewBefore, "Preview should not increase after yield");

        // Verify actual deposit matches preview
        d.asset.mint(alphixHook, previewAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), previewAmount);
        uint256 actualShares = d.wrapper.deposit(previewAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewAfter, "Actual should match post-yield preview");
    }

    /**
     * @notice Fuzz test previewDeposit with fee changes.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param fee1 First fee rate.
     * @param fee2 Second fee rate.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_previewDepositFlow_withFeeChanges(
        uint8 decimals,
        uint256 depositMultiplier,
        uint24 fee1,
        uint24 fee2,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        fee1 = _boundFee(fee1);
        fee2 = _boundFee(fee2);
        yieldPercent = bound(yieldPercent, 5, 50);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Set first fee
        vm.prank(owner);
        d.wrapper.setFee(fee1);

        // Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Simulate yield at fee1
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 previewAtFee1 = d.wrapper.previewDeposit(depositAmount);

        // Change fee
        vm.prank(owner);
        d.wrapper.setFee(fee2);

        // Preview immediately after fee change (should be same - no new yield yet)
        uint256 previewAfterFeeChange = d.wrapper.previewDeposit(depositAmount);
        assertEq(previewAfterFeeChange, previewAtFee1, "Preview unchanged immediately after fee change");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test previewDeposit with negative yield.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param previewMultiplier The preview amount multiplier.
     * @param slashPercent The slash percentage.
     */
    function testFuzz_previewDepositFlow_withNegativeYield(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 previewMultiplier,
        uint256 slashPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        previewMultiplier = bound(previewMultiplier, 1, 1_000_000_000);
        slashPercent = bound(slashPercent, 1, 30); // Max 30% slash

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        uint256 previewAmount = previewMultiplier * 10 ** d.decimals;

        // Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Preview before slash
        uint256 previewBefore = d.wrapper.previewDeposit(previewAmount);

        // Simulate slash
        _simulateSlashOnDeployment(d, slashPercent);

        // Preview after slash
        uint256 previewAfter = d.wrapper.previewDeposit(previewAmount);

        // After slash, same assets should give more shares (each share worth less)
        assertGe(previewAfter, previewBefore, "Preview should not decrease after slash");

        // Verify solvency
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Fuzz test previewDeposit with multiple operations.
     * @param decimals The asset decimals (6-18).
     * @param operations Array of deposit multipliers.
     * @param yieldPercents Array of yield percentages.
     */
    function testFuzz_previewDepositFlow_multipleOperations(
        uint8 decimals,
        uint256[3] memory operations,
        uint8[3] memory yieldPercents
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        for (uint256 i = 0; i < operations.length; i++) {
            operations[i] = bound(operations[i], 1, 100_000_000);
            yieldPercents[i] = uint8(bound(yieldPercents[i], 0, 30));

            uint256 depositAmount = operations[i] * 10 ** d.decimals;

            // Preview
            uint256 previewedShares = d.wrapper.previewDeposit(depositAmount);

            // Deposit
            d.asset.mint(alphixHook, depositAmount);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), depositAmount);
            uint256 actualShares = d.wrapper.deposit(depositAmount, alphixHook);
            vm.stopPrank();

            assertEq(actualShares, previewedShares, "Preview should match actual for each deposit");

            // Apply yield if non-zero
            if (yieldPercents[i] > 0) {
                _simulateYieldOnDeployment(d, yieldPercents[i]);
            }

            // Verify solvency after each operation
            uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
            uint256 totalAssets = d.wrapper.totalAssets();
            uint256 claimableFees = d.wrapper.getClaimableFees();
            assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
        }
    }

    /**
     * @notice Fuzz test previewDeposit with collectFees.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_previewDepositFlow_withCollectFees(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        yieldPercent = bound(yieldPercent, 5, 50);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Simulate yield to generate fees
        _simulateYieldOnDeployment(d, yieldPercent);

        // Preview before fee collection
        uint256 previewBefore = d.wrapper.previewDeposit(depositAmount);

        // Collect fees
        vm.prank(owner);
        d.wrapper.collectFees();

        // Preview after fee collection (should be same - totalAssets unchanged)
        uint256 previewAfter = d.wrapper.previewDeposit(depositAmount);
        assertEq(previewAfter, previewBefore, "Preview unchanged after fee collection");

        // Verify actual deposit matches
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        uint256 actualShares = d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewAfter, "Actual should match preview after collectFees");
    }

    /**
     * @notice Fuzz test previewDeposit at extreme fee rates.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The deposit amount multiplier.
     * @param useMaxFee Whether to use max fee (true) or zero fee (false).
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_previewDepositFlow_extremeFees(
        uint8 decimals,
        uint256 depositMultiplier,
        bool useMaxFee,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        yieldPercent = bound(yieldPercent, 5, 50);
        uint24 fee = useMaxFee ? MAX_FEE : 0;

        // Set extreme fee
        vm.prank(owner);
        d.wrapper.setFee(fee);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;

        // Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Preview before yield
        uint256 previewBefore = d.wrapper.previewDeposit(depositAmount);

        // Simulate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        // Preview after yield
        uint256 previewAfter = d.wrapper.previewDeposit(depositAmount);

        if (useMaxFee) {
            // At max fee (100%), all yield goes to fees, totalAssets unchanged
            assertEq(previewAfter, previewBefore, "Preview unchanged at max fee");
        } else {
            // At zero fee, all yield goes to depositors
            assertLt(previewAfter, previewBefore, "Preview should decrease at zero fee");
        }

        // Verify actual matches preview
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        uint256 actualShares = d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewAfter, "Actual should match preview");
    }
}
