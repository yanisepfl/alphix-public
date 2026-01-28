// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title PreviewDepositFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave previewDeposit function.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract PreviewDepositFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that previewDeposit never reverts.
     * @param decimals The asset decimals (6-18).
     * @param assets The asset amount to preview.
     */
    function testFuzz_previewDeposit_neverReverts(uint8 decimals, uint256 assets) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        // Bound to reasonable range to avoid overflow
        assets = bound(assets, 0, type(uint128).max);

        // Should never revert
        d.wrapper.previewDeposit(assets);
    }

    /**
     * @notice Fuzz test that previewDeposit returns zero for zero assets.
     * @param decimals The asset decimals (6-18).
     */
    function testFuzz_previewDeposit_zeroAssets_returnsZero(uint8 decimals) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 shares = d.wrapper.previewDeposit(0);
        assertEq(shares, 0, "Zero assets should return zero shares");
    }

    /**
     * @notice Fuzz test that previewDeposit returns non-zero for non-zero assets.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The amount multiplier (1-1B tokens).
     */
    function testFuzz_previewDeposit_nonZeroAssets_returnsNonZero(uint8 decimals, uint256 amountMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        uint256 assets = amountMultiplier * 10 ** d.decimals;

        uint256 shares = d.wrapper.previewDeposit(assets);
        assertGt(shares, 0, "Non-zero assets should return non-zero shares");
    }

    /**
     * @notice Fuzz test that previewDeposit matches actual deposit.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The amount multiplier (1-1B tokens).
     */
    function testFuzz_previewDeposit_matchesActualDeposit(uint8 decimals, uint256 amountMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        uint256 assets = amountMultiplier * 10 ** d.decimals;

        uint256 previewedShares = d.wrapper.previewDeposit(assets);

        d.asset.mint(alphixHook, assets);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), assets);
        uint256 actualShares = d.wrapper.deposit(assets, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Actual deposit should match preview");
    }

    /**
     * @notice Fuzz test that previewDeposit is monotonically increasing.
     * @param decimals The asset decimals (6-18).
     * @param amount1Multiplier First amount multiplier.
     * @param amount2Multiplier Second amount multiplier.
     */
    function testFuzz_previewDeposit_monotonic(uint8 decimals, uint256 amount1Multiplier, uint256 amount2Multiplier)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amount1Multiplier = bound(amount1Multiplier, 1, 1_000_000_000);
        amount2Multiplier = bound(amount2Multiplier, amount1Multiplier + 1, 2_000_000_000);

        uint256 assets1 = amount1Multiplier * 10 ** d.decimals;
        uint256 assets2 = amount2Multiplier * 10 ** d.decimals;

        uint256 shares1 = d.wrapper.previewDeposit(assets1);
        uint256 shares2 = d.wrapper.previewDeposit(assets2);

        assertLt(shares1, shares2, "More assets should give more shares");
    }

    /**
     * @notice Fuzz test that previewDeposit matches convertToShares.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The amount multiplier.
     */
    function testFuzz_previewDeposit_matchesConvertToShares(uint8 decimals, uint256 amountMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amountMultiplier = bound(amountMultiplier, 0, 1_000_000_000);
        uint256 assets = amountMultiplier * 10 ** d.decimals;

        uint256 previewedShares = d.wrapper.previewDeposit(assets);
        uint256 convertedShares = d.wrapper.convertToShares(assets);

        assertEq(previewedShares, convertedShares, "previewDeposit should match convertToShares");
    }

    /**
     * @notice Fuzz test previewDeposit after yield accrual.
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The initial deposit multiplier.
     * @param previewMultiplier The preview amount multiplier.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_previewDeposit_afterYield(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 previewMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 1_000_000_000);
        previewMultiplier = bound(previewMultiplier, 1, 1_000_000_000);
        yieldPercent = bound(yieldPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        uint256 previewAmount = previewMultiplier * 10 ** d.decimals;

        // Deposit first
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        uint256 previewBefore = d.wrapper.previewDeposit(previewAmount);

        // Simulate yield
        _simulateYieldOnDeployment(d, yieldPercent);

        uint256 previewAfter = d.wrapper.previewDeposit(previewAmount);

        // After yield, shares per asset should decrease (each share worth more)
        assertLe(previewAfter, previewBefore, "Preview should not increase after yield");
    }

    /**
     * @notice Fuzz test previewDeposit with various fee rates.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The amount multiplier.
     * @param fee The fee rate.
     */
    function testFuzz_previewDeposit_withVaryingFees(uint8 decimals, uint256 amountMultiplier, uint24 fee) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        fee = _boundFee(fee);

        vm.prank(owner);
        d.wrapper.setFee(fee);

        uint256 assets = amountMultiplier * 10 ** d.decimals;
        uint256 shares = d.wrapper.previewDeposit(assets);

        // Fee doesn't affect preview directly (only affects yield distribution)
        // But preview should still work correctly
        assertGt(shares, 0, "Should return non-zero shares regardless of fee");
    }

    /**
     * @notice Fuzz test previewDeposit is independent of caller.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The amount multiplier.
     * @param caller Random caller address.
     */
    function testFuzz_previewDeposit_independentOfCaller(uint8 decimals, uint256 amountMultiplier, address caller)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.assume(caller != address(0));
        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        uint256 assets = amountMultiplier * 10 ** d.decimals;

        // Preview from different callers
        vm.prank(caller);
        uint256 sharesFromCaller = d.wrapper.previewDeposit(assets);

        vm.prank(alphixHook);
        uint256 sharesFromHook = d.wrapper.previewDeposit(assets);

        vm.prank(owner);
        uint256 sharesFromOwner = d.wrapper.previewDeposit(assets);

        assertEq(sharesFromCaller, sharesFromHook, "Preview should be same for different callers");
        assertEq(sharesFromHook, sharesFromOwner, "Preview should be same for different callers");
    }

    /**
     * @notice Fuzz test previewDeposit approximately proportional.
     * @param decimals The asset decimals (6-18).
     * @param baseMultiplier The base amount multiplier.
     * @param multipleFactor The factor to multiply by (2-10).
     */
    function testFuzz_previewDeposit_proportional(uint8 decimals, uint256 baseMultiplier, uint256 multipleFactor)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        baseMultiplier = bound(baseMultiplier, 1, 100_000_000);
        multipleFactor = bound(multipleFactor, 2, 10);

        uint256 baseAssets = baseMultiplier * 10 ** d.decimals;
        uint256 multipliedAssets = baseAssets * multipleFactor;

        uint256 baseShares = d.wrapper.previewDeposit(baseAssets);
        uint256 multipliedShares = d.wrapper.previewDeposit(multipliedAssets);

        // Should be approximately proportional (within rounding)
        uint256 expectedShares = baseShares * multipleFactor;
        uint256 tolerance = multipleFactor; // Allow rounding tolerance

        if (multipliedShares > expectedShares) {
            assertLe(multipliedShares - expectedShares, tolerance, "Should be proportional within tolerance");
        } else {
            assertLe(expectedShares - multipliedShares, tolerance, "Should be proportional within tolerance");
        }
    }

    /**
     * @notice Fuzz test previewDeposit after multiple operations.
     * @param decimals The asset decimals (6-18).
     * @param operations Array of operation multipliers.
     * @param yieldPercents Array of yield percentages.
     */
    function testFuzz_previewDeposit_multipleOperations(
        uint8 decimals,
        uint256[3] memory operations,
        uint8[3] memory yieldPercents
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 lastPreview = d.wrapper.previewDeposit(10 ** d.decimals);

        for (uint256 i = 0; i < operations.length; i++) {
            operations[i] = bound(operations[i], 1, 100_000_000);
            yieldPercents[i] = uint8(bound(yieldPercents[i], 0, 50));

            uint256 depositAmount = operations[i] * 10 ** d.decimals;

            // Deposit
            d.asset.mint(alphixHook, depositAmount);
            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), depositAmount);
            d.wrapper.deposit(depositAmount, alphixHook);
            vm.stopPrank();

            // Without yield, preview should stay same
            uint256 currentPreview = d.wrapper.previewDeposit(10 ** d.decimals);
            assertEq(currentPreview, lastPreview, "Preview should stay same without yield");

            // Apply yield if non-zero
            if (yieldPercents[i] > 0) {
                _simulateYieldOnDeployment(d, yieldPercents[i]);
                currentPreview = d.wrapper.previewDeposit(10 ** d.decimals);
                assertLe(currentPreview, lastPreview, "Preview should not increase after yield");
                lastPreview = currentPreview;
            }
        }
    }

    /**
     * @notice Fuzz test that previewDeposit rounds down (ERC4626 requirement).
     * @param decimals The asset decimals (6-18).
     * @param depositMultiplier The initial deposit multiplier.
     * @param previewMultiplier The preview amount multiplier.
     * @param yieldPercent The yield percentage to create non-1:1 ratio.
     */
    function testFuzz_previewDeposit_roundsDown(
        uint8 decimals,
        uint256 depositMultiplier,
        uint256 previewMultiplier,
        uint256 yieldPercent
    ) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        previewMultiplier = bound(previewMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 50);

        uint256 depositAmount = depositMultiplier * 10 ** d.decimals;
        uint256 previewAmount = previewMultiplier * 10 ** d.decimals;

        // Initial deposit
        d.asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), depositAmount);
        d.wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Simulate yield to create non-1:1 ratio
        _simulateYieldOnDeployment(d, yieldPercent);

        // Get preview
        uint256 previewedShares = d.wrapper.previewDeposit(previewAmount);

        // Actually deposit
        d.asset.mint(alphixHook, previewAmount);
        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), previewAmount);
        uint256 actualShares = d.wrapper.deposit(previewAmount, alphixHook);
        vm.stopPrank();

        // ERC4626: previewDeposit MUST return <= actual shares (rounds down to favor vault)
        assertEq(actualShares, previewedShares, "Should get exactly previewed shares");
    }
}
