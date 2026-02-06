// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PausableFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave pausable functionality.
 */
contract PausableFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that non-owner cannot pause.
     * @param caller Random caller address.
     */
    function testFuzz_pause_revertsIfNotOwner(address caller) public {
        vm.assume(caller != owner);

        vm.prank(caller);
        vm.expectRevert();
        wrapper.pause();
    }

    /**
     * @notice Fuzz test that non-owner cannot unpause.
     * @param caller Random caller address.
     */
    function testFuzz_unpause_revertsIfNotOwner(address caller) public {
        vm.assume(caller != owner);

        // First pause the contract
        vm.prank(owner);
        wrapper.pause();

        vm.prank(caller);
        vm.expectRevert();
        wrapper.unpause();
    }

    /**
     * @notice Fuzz test that deposit reverts when paused for any amount.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_deposit_revertsWhenPaused(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 1_000_000_000e6);

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Try to deposit as hook
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that deposit reverts when paused for any hook.
     * @param hookAddress Random hook address.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_deposit_revertsWhenPausedForAnyHook(address hookAddress, uint256 depositAmount) public {
        vm.assume(hookAddress != address(0));
        vm.assume(hookAddress != alphixHook);
        depositAmount = bound(depositAmount, 1, 1_000_000e6);

        // Add the hook
        vm.prank(owner);
        wrapper.addAlphixHook(hookAddress);

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Try to deposit
        asset.mint(hookAddress, depositAmount);

        vm.startPrank(hookAddress);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.deposit(depositAmount, hookAddress);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that withdraw reverts when paused for any amount.
     * @param depositAmount The deposit amount.
     * @param withdrawPercent The withdrawal percentage.
     */
    function testFuzz_withdraw_revertsWhenPaused(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // First deposit
        _depositAsHook(depositAmount, alphixHook);

        // Calculate withdraw amount
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) withdrawAmount = 1;

        // Pause the contract
        vm.prank(owner);
        wrapper.pause();

        // Try to withdraw
        vm.prank(alphixHook);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);
    }

    /**
     * @notice Fuzz test that deposit works after unpause with any amount.
     * @param depositAmount The deposit amount.
     */
    function testFuzz_deposit_succeedsAfterUnpause(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 1_000_000_000e6);

        // Pause and unpause
        vm.startPrank(owner);
        wrapper.pause();
        wrapper.unpause();
        vm.stopPrank();

        // Deposit should work
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares after unpause");
    }

    /**
     * @notice Fuzz test that withdraw works after unpause.
     * @param depositAmount The deposit amount.
     * @param withdrawPercent The withdrawal percentage.
     */
    function testFuzz_withdraw_succeedsAfterUnpause(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1e6, 1_000_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // First deposit
        _depositAsHook(depositAmount, alphixHook);

        // Pause and unpause
        vm.startPrank(owner);
        wrapper.pause();
        wrapper.unpause();
        vm.stopPrank();

        // Calculate and execute withdraw
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        uint256 withdrawAmount = maxWithdraw * withdrawPercent / 100;
        if (withdrawAmount == 0) return; // Skip if too small

        uint256 assetsBefore = asset.balanceOf(alphixHook);
        vm.prank(alphixHook);
        wrapper.withdraw(withdrawAmount, alphixHook, alphixHook);

        assertEq(asset.balanceOf(alphixHook), assetsBefore + withdrawAmount, "Should receive assets after unpause");
    }

    /**
     * @notice Fuzz test that setFee works when paused.
     * @param newFee The new fee.
     */
    function testFuzz_setFee_succeedsWhenPaused(uint24 newFee) public {
        newFee = uint24(bound(newFee, 0, MAX_FEE));

        vm.startPrank(owner);
        wrapper.pause();
        wrapper.setFee(newFee);
        vm.stopPrank();

        assertEq(wrapper.getFee(), newFee, "Fee should be updated while paused");
    }

    /**
     * @notice Fuzz test that collectFees works when paused after yield.
     * @param depositAmount The deposit amount.
     * @param yieldPercent The yield percentage.
     */
    function testFuzz_collectFees_succeedsWhenPaused(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 1e6, 100_000e6);
        yieldPercent = bound(yieldPercent, 1, 100);

        // Deposit and generate yield
        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        vm.startPrank(owner);
        wrapper.pause();

        uint256 feesBefore = wrapper.getClaimableFees();
        if (feesBefore > 0) {
            wrapper.collectFees();
            assertEq(wrapper.getClaimableFees(), 0, "Fees should be collected while paused");
        }
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that addAlphixHook works when paused.
     * @param hookAddress Random hook address.
     */
    function testFuzz_addAlphixHook_succeedsWhenPaused(address hookAddress) public {
        vm.assume(hookAddress != address(0));
        vm.assume(hookAddress != alphixHook);

        vm.startPrank(owner);
        wrapper.pause();
        wrapper.addAlphixHook(hookAddress);
        vm.stopPrank();

        assertTrue(wrapper.isAlphixHook(hookAddress), "Hook should be added while paused");
    }

    /**
     * @notice Fuzz test that removeAlphixHook works when paused.
     * @param hookAddress Random hook address.
     */
    function testFuzz_removeAlphixHook_succeedsWhenPaused(address hookAddress) public {
        vm.assume(hookAddress != address(0));
        vm.assume(hookAddress != alphixHook);

        vm.startPrank(owner);
        wrapper.addAlphixHook(hookAddress);
        wrapper.pause();
        wrapper.removeAlphixHook(hookAddress);
        vm.stopPrank();

        assertFalse(wrapper.isAlphixHook(hookAddress), "Hook should be removed while paused");
    }

    /**
     * @notice Fuzz test multiple pause/unpause cycles.
     * @param cycles Number of cycles.
     */
    function testFuzz_pauseUnpause_multipleCycles(uint8 cycles) public {
        cycles = uint8(bound(cycles, 1, 10));

        for (uint8 i = 0; i < cycles; i++) {
            vm.prank(owner);
            wrapper.pause();
            assertTrue(wrapper.paused(), "Should be paused");

            vm.prank(owner);
            wrapper.unpause();
            assertFalse(wrapper.paused(), "Should be unpaused");
        }

        // Contract should work normally after cycles
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        assertGt(shares, 0, "Should mint shares after multiple pause/unpause cycles");
    }
}
