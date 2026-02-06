// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title WithdrawFlowFuzzTest
 * @author Alphix
 * @notice Fuzz tests for withdraw flow integration scenarios.
 */
contract WithdrawFlowFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test withdraw varying percentages of deposits.
     */
    function testFuzz_withdrawFlow_varyingAmounts(uint256 depositMultiplier, uint256 withdrawPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            uint256 assetsBefore = usds.balanceOf(alphixHook);

            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

            assertApproxEqAbs(
                usds.balanceOf(alphixHook), assetsBefore + withdrawAmount, 1, "Should receive correct assets"
            );
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test withdraw after yield.
     */
    function testFuzz_withdrawFlow_afterYield(uint256 depositMultiplier, uint256 yieldPercent, uint256 withdrawPercent)
        public
    {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        withdrawPercent = bound(withdrawPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Generate yield
        _simulateYieldPercent(yieldPercent);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test multiple sequential withdrawals.
     */
    function testFuzz_withdrawFlow_multiple(uint256 depositMultiplier, uint8[3] memory withdrawPercents) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        for (uint256 i = 0; i < withdrawPercents.length; i++) {
            uint256 percent = bound(withdrawPercents[i], 1, 30); // Max 30% each
            uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
            uint256 withdrawAmount = maxWithdraw * percent / 100;

            if (withdrawAmount > 0) {
                vm.prank(alphixHook);
                wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
            }
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test withdraw after negative yield.
     */
    function testFuzz_withdrawFlow_afterNegativeYield(
        uint256 depositMultiplier,
        uint256 slashPercent,
        uint256 withdrawPercent
    ) public {
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);
        slashPercent = bound(slashPercent, 1, 1); // Circuit breaker limits to 1%
        withdrawPercent = bound(withdrawPercent, 1, 100);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        // Negative yield
        _simulateSlashPercent(slashPercent);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test withdraw to different receiver.
     */
    function testFuzz_withdrawFlow_toDifferentReceiver(uint256 depositMultiplier, address receiver) public {
        vm.assume(receiver != address(0) && receiver != address(wrapper) && receiver != address(psm));
        depositMultiplier = bound(depositMultiplier, 1, 10_000_000);

        uint256 depositAmount = depositMultiplier * 1e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw / 2;

        if (withdrawAmount > 0) {
            uint256 receiverBefore = usds.balanceOf(receiver);

            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, receiver, alphixHook);

            assertApproxEqAbs(
                usds.balanceOf(receiver), receiverBefore + withdrawAmount, 1, "Receiver should get assets"
            );
        }

        _assertSolvent();
    }

    /**
     * @notice Fuzz test interleaved deposit and withdraw operations.
     */
    function testFuzz_withdrawFlow_interleaved(
        uint256 deposit1Multiplier,
        uint256 deposit2Multiplier,
        uint256 withdrawPercent
    ) public {
        deposit1Multiplier = bound(deposit1Multiplier, 1, 1_000_000);
        deposit2Multiplier = bound(deposit2Multiplier, 1, 1_000_000);
        withdrawPercent = bound(withdrawPercent, 1, 50);

        // Deposit
        _depositAsHook(deposit1Multiplier * 1e18, alphixHook);

        // Withdraw some
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        // Yield
        _simulateYieldPercent(1);

        // Deposit more
        _depositAsHook(deposit2Multiplier * 1e18, alphixHook);

        // Withdraw more
        maxWithdraw = wrapper.maxWithdraw(alphixHook);
        withdrawAmount = maxWithdraw * withdrawPercent / 100;

        if (withdrawAmount > 0) {
            vm.prank(alphixHook);
            wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
        }

        _assertSolvent();
    }
}
