// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title AccrueYieldTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave yield accrual mechanism.
 * @dev Tests the _accrueYield internal function through public interfaces (deposit, setFee).
 */
contract AccrueYieldTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that yield accrual emits event.
     */
    function test_accrueYield_emitsEvent() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Trigger accrual via setFee - expect YieldAccrued to be emitted somewhere in the tx
        vm.recordLogs();

        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Check that YieldAccrued was emitted
        bool yieldAccruedEmitted = false;
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                yieldAccruedEmitted = true;
                break;
            }
        }
        assertTrue(yieldAccruedEmitted, "YieldAccrued event not emitted");
    }

    /**
     * @notice Tests that yield accrual is triggered on deposit.
     */
    function test_accrueYield_triggeredOnDeposit() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Record logs during deposit
        vm.recordLogs();
        _depositAsHook(50e6, alphixHook);

        // Check that YieldAccrued was emitted
        bool yieldAccruedEmitted = false;
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                yieldAccruedEmitted = true;
                break;
            }
        }
        assertTrue(yieldAccruedEmitted, "YieldAccrued event not emitted on deposit");
    }

    /**
     * @notice Tests that yield accrual is triggered on setFee.
     */
    function test_accrueYield_triggeredOnSetFee() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Record logs during setFee
        vm.recordLogs();

        vm.prank(owner);
        wrapper.setFee(50_000);

        // Check that YieldAccrued was emitted
        bool yieldAccruedEmitted = false;
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                yieldAccruedEmitted = true;
                break;
            }
        }
        assertTrue(yieldAccruedEmitted, "YieldAccrued event not emitted on setFee");
    }

    /**
     * @notice Tests that no event is emitted when no yield.
     */
    function test_accrueYield_noYield_noEvent() public {
        _depositAsHook(100e6, alphixHook);

        // No yield simulation, just trigger accrual
        // Should not emit YieldAccrued event since no new yield

        vm.recordLogs();
        _depositAsHook(50e6, alphixHook);

        // Check that YieldAccrued was NOT emitted
        bool yieldAccruedEmitted = false;
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                yieldAccruedEmitted = true;
                break;
            }
        }
        assertFalse(yieldAccruedEmitted, "YieldAccrued event should not be emitted when no yield");
    }

    /**
     * @notice Tests yield accrual with zero fee.
     */
    function test_accrueYield_zeroFee_noFeesAccumulated() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(100e6, alphixHook);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Trigger accrual - with 0% fee, feeAmount should be 0
        vm.recordLogs();
        _depositAsHook(50e6, alphixHook);

        // Check that YieldAccrued was emitted with 0 fee
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                // Decode event data - (yieldAmount, feeAmount, newWrapperBalance)
                (uint256 yieldAmount, uint256 feeAmount,) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                assertGt(yieldAmount, 0, "Yield should be greater than 0");
                assertEq(feeAmount, 0, "Fee should be 0 with 0% fee");
                return;
            }
        }
        fail("YieldAccrued event not emitted");
    }

    /**
     * @notice Tests yield accrual with max fee.
     */
    function test_accrueYield_maxFee() public {
        // Set fee to 100%
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        _depositAsHook(100e6, alphixHook);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Trigger accrual - with 100% fee, all yield goes to fees
        vm.recordLogs();
        _depositAsHook(50e6, alphixHook);

        // Check that YieldAccrued was emitted with fee == yield
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                // Decode event data - (yieldAmount, feeAmount, newWrapperBalance)
                (uint256 yieldAmount, uint256 feeAmount,) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                assertGt(yieldAmount, 0, "Yield should be greater than 0");
                assertEq(feeAmount, yieldAmount, "Fee should equal yield with 100% fee");
                return;
            }
        }
        fail("YieldAccrued event not emitted");
    }

    /**
     * @notice Tests multiple yield accruals.
     */
    function test_accrueYield_multipleAccruals() public {
        _depositAsHook(100e6, alphixHook);

        // First yield
        _simulateYieldPercent(5);

        vm.recordLogs();
        _depositAsHook(50e6, alphixHook);

        bool firstYieldEmitted = false;
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                firstYieldEmitted = true;
                break;
            }
        }
        assertTrue(firstYieldEmitted, "First YieldAccrued event not emitted");

        // Second yield
        _simulateYieldPercent(5);

        vm.recordLogs();
        _depositAsHook(25e6, alphixHook);

        bool secondYieldEmitted = false;
        entries = vm.getRecordedLogs();
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                secondYieldEmitted = true;
                break;
            }
        }
        assertTrue(secondYieldEmitted, "Second YieldAccrued event not emitted");
    }

    /**
     * @notice Tests that solvency is maintained after yield accrual.
     */
    function test_accrueYield_maintainsSolvency() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10);

        // Trigger accrual
        _depositAsHook(50e6, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests that fee-owned aTokens earn yield for treasury (Issue #1 fix).
     * @dev When fees are accumulated, those fee-owned aTokens should earn 100% of their yield
     *      to the treasury, while user-owned aTokens only contribute _fee% to treasury.
     *      This test verifies the fix for Sherlock audit Issue #1.
     */
    function test_accrueYield_feeOwnedYieldGoesToTreasury() public {
        // Set 50% fee rate
        vm.prank(owner);
        wrapper.setFee(500_000); // 50%

        // Deposit and generate first round of yield
        _depositAsHook(1000e6, alphixHook);
        _simulateYieldPercent(10); // 10% yield = 100e6 yield, 50e6 goes to fees

        // Trigger accrual
        _depositAsHook(1e6, alphixHook); // small deposit to trigger accrual

        uint256 feesAfterFirstYield = wrapper.getClaimableFees();
        assertGt(feesAfterFirstYield, 0, "Should have accumulated fees");

        // Now generate more yield - the fee-owned portion should earn 100% to treasury
        // while the user-owned portion should earn 50% to treasury
        _simulateYieldPercent(10);

        uint256 feesAfterSecondYield = wrapper.getClaimableFees();
        uint256 newFees = feesAfterSecondYield - feesAfterFirstYield;

        // The fee-owned portion (feesAfterFirstYield) earned 10% yield, ALL of which goes to fees
        // The user-owned portion earned 10% yield, 50% of which goes to fees
        // So newFees should be: (feesAfterFirstYield * 0.10) + (userPortion * 0.10 * 0.50)

        // Fee portion yield should be approximately: feesAfterFirstYield * 10%
        uint256 expectedFeePortionYield = feesAfterFirstYield * 10 / 100;

        // The newFees should be greater than just 50% of total yield (old behavior)
        // because fee-owned portion earns 100% to treasury
        assertGt(newFees, 0, "Should have new fees from second yield");

        // Verify solvency
        _assertSolvent();

        // Verify that fee portion yield is included (approximately)
        // This is a rough check - the actual math depends on the exact balances
        assertGe(newFees, expectedFeePortionYield, "Fee portion yield should be included in new fees");
    }

    /**
     * @notice Tests that setting fee to zero still lets existing fee portion earn yield.
     * @dev After accumulating fees, setting fee rate to 0% should still allow the
     *      fee-owned aTokens to earn yield for treasury (100% of their portion).
     */
    function test_accrueYield_zeroFeeStillEarnsFeePortionYield() public {
        // Start with 50% fee
        vm.prank(owner);
        wrapper.setFee(500_000);

        _depositAsHook(1000e6, alphixHook);

        // Generate yield at 50% fee
        _simulateYieldPercent(10);
        _depositAsHook(1e6, alphixHook); // trigger accrual

        uint256 feesBeforeZeroRate = wrapper.getClaimableFees();
        assertGt(feesBeforeZeroRate, 0, "Should have fees before setting to zero");

        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        // Generate more yield
        _simulateYieldPercent(10);
        _depositAsHook(1e6, alphixHook); // trigger accrual

        uint256 feesAfterZeroRate = wrapper.getClaimableFees();

        // Fees should INCREASE because the fee-owned aTokens (feesBeforeZeroRate)
        // still earn yield, and 100% of that goes to treasury
        assertGt(feesAfterZeroRate, feesBeforeZeroRate, "Fee-owned portion should still earn yield at 0% fee rate");

        // The increase should be approximately 10% of the fee-owned balance
        uint256 expectedIncrease = feesBeforeZeroRate * 10 / 100;
        uint256 actualIncrease = feesAfterZeroRate - feesBeforeZeroRate;

        // Allow 1% tolerance for rounding
        _assertApproxEq(actualIncrease, expectedIncrease, 1, "Fee portion yield should be 100% of its yield");

        _assertSolvent();
    }

    /**
     * @notice Tests yield accrual when lastBalance is 0.
     * @dev This edge case can occur when:
     *      1. Owner redeems all seed liquidity (emptying wrapper)
     *      2. Someone directly transfers aTokens to the wrapper
     *      3. setFee() triggers _accrueYield() with lastBalance == 0
     */
    function test_accrueYield_withZeroLastBalance() public {
        // Get owner's seed shares
        uint256 ownerShares = wrapper.balanceOf(owner);

        // Owner redeems all their seed shares
        vm.prank(owner);
        wrapper.redeem(ownerShares, owner, owner);

        // Verify _lastWrapperBalance is 0
        assertEq(wrapper.getLastWrapperBalance(), 0, "lastWrapperBalance should be 0");

        // Simulate "yield" by directly minting aTokens to the wrapper
        // This simulates aTokens being sent directly to the contract
        uint256 directTransferAmount = 100e6;
        aToken.simulateYield(address(wrapper), directTransferAmount);

        // Trigger _accrueYield via setFee
        // This should hit the else branch: lastBalance == 0, newWrapperBalance > 0
        vm.recordLogs();
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify YieldAccrued event was emitted
        bytes32 yieldAccruedSelector = keccak256("YieldAccrued(uint256,uint256,uint256)");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool found = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == yieldAccruedSelector) {
                (uint256 yieldAmount, uint256 feeAmount,) = abi.decode(entries[i].data, (uint256, uint256, uint256));
                // With lastBalance == 0, standard fee is applied: feeAmount = totalYield * fee / MAX_FEE
                assertEq(yieldAmount, directTransferAmount, "Yield should equal direct transfer");
                uint256 expectedFee = directTransferAmount * DEFAULT_FEE / MAX_FEE;
                assertEq(feeAmount, expectedFee, "Fee should be standard rate on yield");
                found = true;
                break;
            }
        }
        assertTrue(found, "YieldAccrued event not emitted");

        // Also verify getClaimableFees() works correctly
        // At this point, _lastWrapperBalance has been updated by _accrueYield()
        uint256 expectedTotalFees = directTransferAmount * DEFAULT_FEE / MAX_FEE;
        assertEq(wrapper.getClaimableFees(), expectedTotalFees, "Claimable fees should match");
    }

    /**
     * @notice Tests _getClaimableFees when lastBalance is 0 (before any accrual).
     */
    function test_getClaimableFees_withZeroLastBalance() public {
        // Get owner's seed shares
        uint256 ownerShares = wrapper.balanceOf(owner);

        // Owner redeems all their seed shares
        vm.prank(owner);
        wrapper.redeem(ownerShares, owner, owner);

        // Verify _lastWrapperBalance is 0
        assertEq(wrapper.getLastWrapperBalance(), 0, "lastWrapperBalance should be 0");

        // Simulate yield by directly minting aTokens
        uint256 directTransferAmount = 100e6;
        aToken.simulateYield(address(wrapper), directTransferAmount);

        // Call getClaimableFees BEFORE triggering _accrueYield
        // This exercises _getClaimableFees with lastBalance == 0
        uint256 claimableFees = wrapper.getClaimableFees();

        // With lastBalance == 0, standard fee applies
        uint256 expectedFees = directTransferAmount * DEFAULT_FEE / MAX_FEE;
        assertEq(claimableFees, expectedFees, "Claimable fees with zero lastBalance");
    }
}
