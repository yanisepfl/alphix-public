// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title DepositTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave deposit function.
 * @dev Note: Caller must be hook or owner, AND receiver must equal msg.sender.
 */
contract DepositTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that the hook can deposit to itself successfully.
     */
    function test_deposit_asHook_toSelf_succeeds() public {
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        uint256 sharesBefore = wrapper.balanceOf(alphixHook);
        uint256 shares = wrapper.deposit(depositAmount, alphixHook);
        uint256 sharesAfter = wrapper.balanceOf(alphixHook);

        assertGt(shares, 0, "No shares minted");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that hook cannot deposit to the owner (receiver != msg.sender).
     */
    function test_deposit_asHook_toOwner_reverts() public {
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, owner);
        vm.stopPrank();
    }

    /**
     * @notice Tests that the owner can deposit to itself successfully.
     */
    function test_deposit_asOwner_toSelf_succeeds() public {
        uint256 depositAmount = 100e6;
        asset.mint(owner, depositAmount);

        vm.startPrank(owner);
        asset.approve(address(wrapper), depositAmount);

        uint256 sharesBefore = wrapper.balanceOf(owner);
        uint256 shares = wrapper.deposit(depositAmount, owner);
        uint256 sharesAfter = wrapper.balanceOf(owner);

        assertGt(shares, 0, "No shares minted");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that owner cannot deposit to hook (receiver != msg.sender).
     */
    function test_deposit_asOwner_toHook_reverts() public {
        uint256 depositAmount = 100e6;
        asset.mint(owner, depositAmount);

        vm.startPrank(owner);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that unauthorized callers cannot deposit.
     */
    function test_deposit_unauthorizedCaller_reverts() public {
        uint256 depositAmount = 100e6;
        asset.mint(unauthorized, depositAmount);

        vm.startPrank(unauthorized);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.deposit(depositAmount, unauthorized);
        vm.stopPrank();
    }

    /**
     * @notice Tests that alice (not hook or owner) cannot deposit.
     */
    function test_deposit_asAlice_reverts() public {
        uint256 depositAmount = 100e6;

        vm.startPrank(alice);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.deposit(depositAmount, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that hook cannot deposit to unauthorized receiver (InvalidReceiver before DepositExceedsMax).
     */
    function test_deposit_asHook_toUnauthorizedReceiver_reverts() public {
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, alice);
        vm.stopPrank();
    }

    /**
     * @notice Tests that owner cannot deposit to unauthorized receiver (InvalidReceiver before DepositExceedsMax).
     */
    function test_deposit_asOwner_toUnauthorizedReceiver_reverts() public {
        uint256 depositAmount = 100e6;
        asset.mint(owner, depositAmount);

        vm.startPrank(owner);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, bob);
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit emits the correct event.
     */
    function test_deposit_emitsEvent() public {
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        // Calculate expected shares
        uint256 expectedShares = wrapper.previewDeposit(depositAmount);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alphixHook, alphixHook, depositAmount, expectedShares);

        wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit reverts when trying to mint zero shares.
     */
    function test_deposit_zeroShares_reverts() public {
        uint256 tinyAmount = 0;

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), tinyAmount);

        vm.expectRevert(IAlphix4626WrapperAave.ZeroShares.selector);
        wrapper.deposit(tinyAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit transfers assets from caller to wrapper.
     */
    function test_deposit_transfersAssets() public {
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        uint256 hookBalanceBefore = asset.balanceOf(alphixHook);
        wrapper.deposit(depositAmount, alphixHook);
        uint256 hookBalanceAfter = asset.balanceOf(alphixHook);

        assertEq(hookBalanceBefore - hookBalanceAfter, depositAmount, "Assets not transferred");
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit supplies assets to Aave.
     */
    function test_deposit_suppliesToAave() public {
        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        uint256 aTokenBefore = aToken.balanceOf(address(wrapper));
        wrapper.deposit(depositAmount, alphixHook);
        uint256 aTokenAfter = aToken.balanceOf(address(wrapper));

        assertEq(aTokenAfter - aTokenBefore, depositAmount, "Assets not supplied to Aave");
        vm.stopPrank();
    }

    /**
     * @notice Tests multiple deposits accumulate correctly.
     */
    function test_deposit_multipleDeposits() public {
        uint256 deposit1 = 100e6;
        uint256 deposit2 = 200e6;

        // First deposit (hook to self)
        uint256 shares1 = _depositAsHookToSelf(deposit1);

        // Second deposit (hook to self)
        uint256 shares2 = _depositAsHookToSelf(deposit2);

        uint256 totalShares = wrapper.balanceOf(alphixHook);
        assertEq(totalShares, shares1 + shares2, "Total shares mismatch");
    }

    /**
     * @notice Tests that wrapper remains solvent after deposit.
     */
    function test_deposit_maintainsSolvency() public {
        uint256 depositAmount = 100e6;
        _depositAsHookToSelf(depositAmount);

        _assertSolvent();
    }

    /* MULTI-HOOK TESTS */

    /**
     * @notice Tests that a second hook can be added and deposit to itself.
     */
    function test_deposit_secondHook_toSelf_succeeds() public {
        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        uint256 depositAmount = 100e6;
        asset.mint(hook2, depositAmount);

        vm.startPrank(hook2);
        asset.approve(address(wrapper), depositAmount);

        uint256 shares = wrapper.deposit(depositAmount, hook2);
        assertGt(shares, 0, "No shares minted");
        assertEq(wrapper.balanceOf(hook2), shares, "Share balance mismatch");
        vm.stopPrank();
    }

    /**
     * @notice Tests that hook1 cannot deposit to hook2 (receiver must equal msg.sender).
     */
    function test_deposit_hook1ToHook2_reverts() public {
        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        uint256 depositAmount = 100e6;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, hook2);
        vm.stopPrank();
    }

    /**
     * @notice Tests that hook2 cannot deposit to hook1 (receiver must equal msg.sender).
     */
    function test_deposit_hook2ToHook1_reverts() public {
        address hook2 = makeAddr("hook2");

        // Add second hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        uint256 depositAmount = 100e6;
        asset.mint(hook2, depositAmount);

        vm.startPrank(hook2);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that multiple hooks can each deposit to themselves.
     */
    function test_deposit_multipleHooks_eachToSelf_succeeds() public {
        address hook2 = makeAddr("hook2");
        address hook3 = makeAddr("hook3");

        // Add multiple hooks
        vm.startPrank(owner);
        wrapper.addAlphixHook(hook2);
        wrapper.addAlphixHook(hook3);
        vm.stopPrank();

        uint256 depositAmount = 100e6;

        // Hook1 deposits to self
        asset.mint(alphixHook, depositAmount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares1 = wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();

        // Hook2 deposits to self
        asset.mint(hook2, depositAmount);
        vm.startPrank(hook2);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares2 = wrapper.deposit(depositAmount, hook2);
        vm.stopPrank();

        // Hook3 deposits to self
        asset.mint(hook3, depositAmount);
        vm.startPrank(hook3);
        asset.approve(address(wrapper), depositAmount);
        uint256 shares3 = wrapper.deposit(depositAmount, hook3);
        vm.stopPrank();

        assertGt(shares1, 0, "No shares to hook1");
        assertGt(shares2, 0, "No shares to hook2");
        assertGt(shares3, 0, "No shares to hook3");
    }

    /**
     * @notice Tests that owner cannot deposit to any hook (receiver must equal msg.sender).
     */
    function test_deposit_ownerToHooks_reverts() public {
        address hook2 = makeAddr("hook2");

        // Add hook
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        uint256 depositAmount = 100e6;
        asset.mint(owner, depositAmount);

        vm.startPrank(owner);
        asset.approve(address(wrapper), type(uint256).max);

        // Owner cannot deposit to hook2 (only to self)
        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        wrapper.deposit(depositAmount, hook2);
        vm.stopPrank();
    }

    /**
     * @notice Tests that a removed hook cannot deposit.
     */
    function test_deposit_removedHook_reverts() public {
        address hook2 = makeAddr("hook2");

        // Add and then remove hook
        vm.startPrank(owner);
        wrapper.addAlphixHook(hook2);
        wrapper.removeAlphixHook(hook2);
        vm.stopPrank();

        uint256 depositAmount = 100e6;
        asset.mint(hook2, depositAmount);

        vm.startPrank(hook2);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wrapper.deposit(depositAmount, hook2);
        vm.stopPrank();
    }

    /* SUPPLY CAP TESTS */

    /**
     * @notice Tests that deposit reverts when assets exceed maxDeposit (supply cap).
     */
    function test_deposit_revertsIfExceedsMaxDeposit() public {
        // Set a supply cap of 2 tokens (2e6 for 6 decimals)
        // After seed liquidity (1e6), only 1e6 more can be deposited
        aavePool.setReserveConfig(true, false, false, 2);

        uint256 remainingCap = wrapper.maxDeposit(alphixHook);
        // remainingCap should be 2e6 - 1e6 (seed) = 1e6

        // Try to deposit more than remaining cap
        uint256 depositAmount = remainingCap + 1;
        asset.mint(alphixHook, depositAmount);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), depositAmount);

        vm.expectRevert(IAlphix4626WrapperAave.DepositExceedsMax.selector);
        wrapper.deposit(depositAmount, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit succeeds when exactly at maxDeposit.
     */
    function test_deposit_succeedsAtExactMax() public {
        // Set a supply cap of 2 tokens
        aavePool.setReserveConfig(true, false, false, 2);

        uint256 remainingCap = wrapper.maxDeposit(alphixHook);

        // Deposit exactly the remaining cap
        asset.mint(alphixHook, remainingCap);

        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), remainingCap);

        uint256 shares = wrapper.deposit(remainingCap, alphixHook);
        assertGt(shares, 0, "Should mint shares at exact max");
        vm.stopPrank();

        // Now maxDeposit should be 0
        assertEq(wrapper.maxDeposit(alphixHook), 0, "maxDeposit should be 0 after reaching cap");
    }

    /* HELPER */

    /**
     * @notice Helper to deposit as hook to self (respecting receiver == msg.sender constraint).
     */
    function _depositAsHookToSelf(uint256 amount) internal returns (uint256 shares) {
        asset.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, alphixHook);
        vm.stopPrank();
    }
}
