// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title PreviewDepositFlowTest
 * @author Alphix
 * @notice Integration tests for previewDeposit in complete user flows.
 * @dev Tests previewDeposit behavior across complex multi-step scenarios.
 */
contract PreviewDepositFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests previewDeposit accuracy in a complete deposit flow.
     */
    function test_previewDepositFlow_matchesActualDeposit() public {
        uint256 depositAmount = 1_000e6;

        // Preview before deposit
        uint256 previewedShares = wrapper.previewDeposit(depositAmount);

        // Actual deposit
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 actualShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Preview should match actual deposit");
        _assertSolvent();
    }

    /**
     * @notice Tests previewDeposit with yield accrual between preview and deposit.
     */
    function test_previewDepositFlow_withYieldBetweenPreviewAndDeposit() public {
        // Initial deposit to enable yield
        _depositAsHook(1_000e6, alphixHook);

        uint256 depositAmount = 500e6;

        // Preview shares
        uint256 previewBefore = wrapper.previewDeposit(depositAmount);

        // Simulate yield between preview and actual deposit
        _simulateYieldPercent(10);

        // Preview after yield (should be different)
        uint256 previewAfter = wrapper.previewDeposit(depositAmount);

        // Yield makes shares worth more, so same assets = fewer shares
        assertLt(previewAfter, previewBefore, "Preview should decrease after yield");

        // Actual deposit uses current rate
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 actualShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Actual should match preview after yield
        assertEq(actualShares, previewAfter, "Actual should match current preview");
        _assertSolvent();
    }

    /**
     * @notice Tests previewDeposit consistency across multiple deposits.
     */
    function test_previewDepositFlow_multipleDeposits() public {
        uint256 deposit1 = 100e6;
        uint256 deposit2 = 200e6;
        uint256 deposit3 = 300e6;

        // Preview all deposits upfront (without yield)
        uint256 preview1 = wrapper.previewDeposit(deposit1);
        uint256 preview2 = wrapper.previewDeposit(deposit2);
        uint256 preview3 = wrapper.previewDeposit(deposit3);

        // Execute deposits sequentially
        uint256 actual1 = _depositAsHook(deposit1, alphixHook);
        // Without yield, preview should remain same
        assertEq(wrapper.previewDeposit(deposit2), preview2, "Preview should be consistent");
        uint256 actual2 = _depositAsHook(deposit2, alphixHook);
        assertEq(wrapper.previewDeposit(deposit3), preview3, "Preview should be consistent");
        uint256 actual3 = _depositAsHook(deposit3, alphixHook);

        // All previews should match actuals
        assertEq(actual1, preview1, "Deposit 1 should match preview");
        assertEq(actual2, preview2, "Deposit 2 should match preview");
        assertEq(actual3, preview3, "Deposit 3 should match preview");

        _assertSolvent();
    }

    /**
     * @notice Tests previewDeposit with fee changes during flow.
     */
    function test_previewDepositFlow_withFeeChanges() public {
        _depositAsHook(1_000e6, alphixHook);

        uint256 depositAmount = 500e6;

        // Preview at 10% fee (before yield)
        uint256 previewBeforeYield = wrapper.previewDeposit(depositAmount);

        // Simulate yield (to make fee relevant)
        _simulateYieldPercent(20);

        // Preview after yield at 10% fee
        uint256 previewAfterYield10 = wrapper.previewDeposit(depositAmount);

        // Preview should decrease after yield
        assertLt(previewAfterYield10, previewBeforeYield, "Preview should decrease after yield");

        // Change fee to 50%
        vm.prank(owner);
        wrapper.setFee(500_000);

        // Preview at 50% fee (note: fee change accrues existing yield first)
        uint256 previewAfterFeeChange = wrapper.previewDeposit(depositAmount);

        // Preview should be same immediately after fee change (no new yield)
        assertEq(previewAfterFeeChange, previewAfterYield10, "Preview unchanged immediately after fee change");

        // Simulate more yield at higher fee
        _simulateYieldPercent(20);

        // Preview should decrease less because more yield goes to fees
        uint256 previewAfterMoreYield = wrapper.previewDeposit(depositAmount);
        assertLt(previewAfterMoreYield, previewAfterFeeChange, "Preview should decrease after yield");

        _assertSolvent();
    }

    /**
     * @notice Tests previewDeposit with negative yield (slashing).
     */
    function test_previewDepositFlow_withNegativeYield() public {
        _depositAsHook(1_000e6, alphixHook);

        uint256 depositAmount = 500e6;

        // Preview before slash
        uint256 previewBefore = wrapper.previewDeposit(depositAmount);

        // Simulate negative yield (slash)
        uint256 wrapperBalance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), wrapperBalance * 10 / 100); // 10% slash

        // Preview after slash (shares worth less, so same assets = more shares)
        uint256 previewAfter = wrapper.previewDeposit(depositAmount);
        assertGt(previewAfter, previewBefore, "Preview should increase after slash");

        // Actual deposit at new rate
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 actualShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewAfter, "Actual should match preview after slash");
        _assertSolvent();
    }

    /**
     * @notice Tests previewDeposit for different callers returns same value.
     */
    function test_previewDepositFlow_sameForAllCallers() public {
        _depositAsHook(1_000e6, alphixHook);
        _simulateYieldPercent(10);

        uint256 depositAmount = 500e6;

        // Preview from different accounts
        vm.prank(alice);
        uint256 previewAlice = wrapper.previewDeposit(depositAmount);

        vm.prank(bob);
        uint256 previewBob = wrapper.previewDeposit(depositAmount);

        vm.prank(alphixHook);
        uint256 previewHook = wrapper.previewDeposit(depositAmount);

        vm.prank(owner);
        uint256 previewOwner = wrapper.previewDeposit(depositAmount);

        assertEq(previewAlice, previewBob, "Preview should be same for alice and bob");
        assertEq(previewBob, previewHook, "Preview should be same for bob and hook");
        assertEq(previewHook, previewOwner, "Preview should be same for hook and owner");
    }

    /**
     * @notice Tests previewDeposit with max fee (100%).
     */
    function test_previewDepositFlow_maxFeeScenario() public {
        // Set max fee (100%)
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        _depositAsHook(1_000e6, alphixHook);

        uint256 depositAmount = 500e6;

        // Preview before yield
        uint256 previewBefore = wrapper.previewDeposit(depositAmount);

        // Simulate yield (all goes to fees at max fee)
        _simulateYieldPercent(10);

        // Preview after yield
        uint256 previewAfter = wrapper.previewDeposit(depositAmount);

        // At max fee, totalAssets doesn't increase (all yield is fees)
        // So preview should be same
        assertEq(previewAfter, previewBefore, "Preview unchanged at max fee");

        // Verify deposit works
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 actualShares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewAfter, "Actual should match preview");
        _assertSolvent();
    }

    /**
     * @notice Tests previewDeposit with zero fee.
     */
    function test_previewDepositFlow_zeroFeeScenario() public {
        // Set zero fee
        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(1_000e6, alphixHook);

        uint256 depositAmount = 500e6;

        // Preview before yield
        uint256 previewBefore = wrapper.previewDeposit(depositAmount);

        // Simulate yield (all goes to depositors at zero fee)
        _simulateYieldPercent(10);

        // Preview after yield
        uint256 previewAfter = wrapper.previewDeposit(depositAmount);

        // At zero fee, all yield goes to totalAssets
        // So preview should decrease (shares worth more)
        assertLt(previewAfter, previewBefore, "Preview should decrease at zero fee");

        _assertSolvent();
    }

    /**
     * @notice Tests complete lifecycle with previewDeposit at each step.
     */
    function test_previewDepositFlow_completeLifecycle() public {
        uint256 depositAmount = 500e6;

        // Step 1: Initial state
        uint256 preview1 = wrapper.previewDeposit(depositAmount);

        // Step 2: First deposit
        uint256 actual1 = _depositAsHook(depositAmount, alphixHook);
        assertEq(actual1, preview1, "Step 1: preview should match");

        // Step 3: Yield accrual
        _simulateYieldPercent(5);
        uint256 preview2 = wrapper.previewDeposit(depositAmount);
        assertLt(preview2, preview1, "Step 3: preview should decrease");

        // Step 4: Second deposit
        uint256 actual2 = _depositAsHook(depositAmount, alphixHook);
        assertEq(actual2, preview2, "Step 4: preview should match");

        // Step 5: Fee change
        vm.prank(owner);
        wrapper.setFee(200_000); // 20%

        // Step 6: More yield
        _simulateYieldPercent(5);
        uint256 preview3 = wrapper.previewDeposit(depositAmount);

        // Step 7: Third deposit
        uint256 actual3 = _depositAsHook(depositAmount, alphixHook);
        assertEq(actual3, preview3, "Step 7: preview should match");

        // Step 8: Fee collection
        vm.prank(owner);
        wrapper.collectFees();
        uint256 preview4 = wrapper.previewDeposit(depositAmount);
        assertEq(preview4, preview3, "Step 8: fee collection shouldn't change preview");

        _assertSolvent();
    }
}
