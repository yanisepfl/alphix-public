// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title DepositFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperSky deposit function.
 * @dev Fuzzes amounts and rates to ensure robust behavior.
 */
contract DepositFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test for deposit with varying amounts.
     * @param amountMultiplier The deposit amount multiplier (1-1B tokens).
     */
    function testFuzz_deposit_varyingAmounts(uint256 amountMultiplier) public {
        // Bound to reasonable range (1 to 1B tokens)
        amountMultiplier = bound(amountMultiplier, 1, 100_000_000);
        uint256 amount = amountMultiplier * 1e18;

        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 shares = wrapper.deposit(amount, alphixHook);
        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertGt(shares, 0, "Should mint non-zero shares");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance should increase by minted shares");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that unauthorized callers always revert.
     * @param caller Random caller address.
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_unauthorizedCaller_reverts(address caller, uint256 amountMultiplier) public {
        // Exclude authorized callers
        vm.assume(caller != alphixHook && caller != owner && caller != address(0));
        amountMultiplier = bound(amountMultiplier, 1, 1_000_000);
        uint256 amount = amountMultiplier * 1e18;

        usds.mint(caller, amount);

        vm.startPrank(caller);
        usds.approve(address(wrapper), amount);

        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.deposit(amount, caller);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that deposit to different receiver reverts (receiver != msg.sender).
     * @param receiver Random receiver address.
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_differentReceiver_reverts(address receiver, uint256 amountMultiplier) public {
        // Receiver must be different from caller (alphixHook)
        vm.assume(receiver != alphixHook && receiver != address(0));
        amountMultiplier = bound(amountMultiplier, 1, 1_000_000);
        uint256 amount = amountMultiplier * 1e18;

        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);

        // InvalidReceiver because receiver != msg.sender
        vm.expectRevert(IAlphix4626WrapperSky.InvalidReceiver.selector);
        wrapper.deposit(amount, receiver);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that deposit maintains solvency.
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_maintainsSolvency(uint256 amountMultiplier) public {
        amountMultiplier = bound(amountMultiplier, 1, 100_000_000);
        uint256 amount = amountMultiplier * 1e18;

        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        _assertSolvent();
    }

    /**
     * @notice Fuzz test that previewDeposit matches actual deposit.
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_matchesPreview(uint256 amountMultiplier) public {
        amountMultiplier = bound(amountMultiplier, 1, 100_000_000);
        uint256 amount = amountMultiplier * 1e18;

        uint256 previewedShares = wrapper.previewDeposit(amount);

        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        uint256 actualShares = wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Actual shares should match preview");
    }

    /**
     * @notice Fuzz test multiple sequential deposits.
     * @param amountMultipliers Array of deposit amount multipliers.
     */
    function testFuzz_deposit_multipleDeposits(uint256[5] memory amountMultipliers) public {
        uint256 totalShares;

        for (uint256 i = 0; i < amountMultipliers.length; i++) {
            amountMultipliers[i] = bound(amountMultipliers[i], 1, 100_000_000);
            uint256 amount = amountMultipliers[i] * 1e18;

            usds.mint(alphixHook, amount);

            vm.startPrank(alphixHook);
            usds.approve(address(wrapper), amount);
            totalShares += wrapper.deposit(amount, alphixHook);
            vm.stopPrank();
        }

        assertEq(wrapper.balanceOf(alphixHook), totalShares, "Total shares should match sum of deposits");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit at varying rates.
     * @param amountMultiplier The deposit amount multiplier.
     * @param rateMultiplier Rate multiplier (100 = 1x, 200 = 2x, etc.).
     */
    function testFuzz_deposit_atVaryingRates(uint256 amountMultiplier, uint256 rateMultiplier) public {
        amountMultiplier = bound(amountMultiplier, 1, 100_000_000);
        rateMultiplier = bound(rateMultiplier, 100, 101); // 1x to 1.01x rate (circuit breaker limits to 1%)
        uint256 amount = amountMultiplier * 1e18;

        // Set a different rate
        uint256 newRate = INITIAL_RATE * rateMultiplier / 100;
        _setRate(newRate);

        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        uint256 shares = wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint non-zero shares");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test deposit after yield accrual.
     * @param initialDeposit Initial deposit amount multiplier.
     * @param yieldPercent Yield percentage (1-100).
     * @param secondDeposit Second deposit amount multiplier.
     */
    function testFuzz_deposit_afterYield(uint256 initialDeposit, uint256 yieldPercent, uint256 secondDeposit) public {
        initialDeposit = bound(initialDeposit, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        secondDeposit = bound(secondDeposit, 1, 100_000_000);

        uint256 amount1 = initialDeposit * 1e18;
        uint256 amount2 = secondDeposit * 1e18;

        // First deposit
        usds.mint(alphixHook, amount1);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount1);
        uint256 shares1 = wrapper.deposit(amount1, alphixHook);
        vm.stopPrank();

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Second deposit
        usds.mint(alphixHook, amount2);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount2);
        uint256 shares2 = wrapper.deposit(amount2, alphixHook);
        vm.stopPrank();

        assertGt(shares1, 0, "First deposit should mint shares");
        assertGt(shares2, 0, "Second deposit should mint shares");
        _assertSolvent();
    }
}
