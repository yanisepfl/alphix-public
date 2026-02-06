// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title MultiHookFlowTest
 * @author Alphix
 * @notice Integration tests for multi-hook scenarios.
 * @dev Tests complete user flows with multiple hooks interacting with the wrapper.
 */
contract MultiHookFlowTest is BaseAlphix4626WrapperAave {
    address internal hook2;
    address internal hook3;

    function setUp() public override {
        super.setUp();

        // Add additional hooks
        hook2 = makeAddr("hook2");
        hook3 = makeAddr("hook3");

        vm.startPrank(owner);
        wrapper.addAlphixHook(hook2);
        wrapper.addAlphixHook(hook3);
        vm.stopPrank();

        // Fund hooks (alphixHook is already approved in base setUp but needs more balance)
        asset.mint(alphixHook, 1_000_000e6);
        asset.mint(hook2, 1_000_000e6);
        asset.mint(hook3, 1_000_000e6);

        // Approve for hooks
        vm.prank(hook2);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(hook3);
        asset.approve(address(wrapper), type(uint256).max);
    }

    /**
     * @notice Tests complete flow with multiple hooks depositing and yield accrual.
     */
    function test_multiHookFlow_depositsAndYield() public {
        uint256 depositAmount = 100_000e6;

        // Each hook deposits
        vm.prank(alphixHook);
        uint256 shares1 = wrapper.deposit(depositAmount, alphixHook);

        vm.prank(hook2);
        uint256 shares2 = wrapper.deposit(depositAmount, hook2);

        vm.prank(hook3);
        uint256 shares3 = wrapper.deposit(depositAmount, hook3);

        // All got same shares (same rate)
        assertEq(shares1, shares2, "Same deposit should give same shares");
        assertEq(shares2, shares3, "Same deposit should give same shares");

        // Simulate yield
        _simulateYieldPercent(10);

        // All hooks benefit proportionally
        uint256 value1 = wrapper.convertToAssets(wrapper.balanceOf(alphixHook));
        uint256 value2 = wrapper.convertToAssets(wrapper.balanceOf(hook2));
        uint256 value3 = wrapper.convertToAssets(wrapper.balanceOf(hook3));

        // Values should be approximately equal (within rounding)
        assertApproxEqAbs(value1, value2, 1, "Values should be equal");
        assertApproxEqAbs(value2, value3, 1, "Values should be equal");

        _assertSolvent();
    }

    /**
     * @notice Tests each hook depositing to itself.
     * @dev Cross-deposit is no longer allowed (receiver must equal msg.sender).
     */
    function test_multiHookFlow_eachHookDepositsToSelf() public {
        uint256 depositAmount = 50_000e6;

        // Hook1 deposits to self
        vm.prank(alphixHook);
        wrapper.deposit(depositAmount, alphixHook);

        // Hook2 deposits to self
        vm.prank(hook2);
        wrapper.deposit(depositAmount, hook2);

        // Hook3 deposits to self
        vm.prank(hook3);
        wrapper.deposit(depositAmount, hook3);

        // Each should have received shares
        assertGt(wrapper.balanceOf(alphixHook), 0, "Hook1 should have shares");
        assertGt(wrapper.balanceOf(hook2), 0, "Hook2 should have shares");
        assertGt(wrapper.balanceOf(hook3), 0, "Hook3 should have shares");

        _assertSolvent();
    }

    /**
     * @notice Tests removing a hook mid-flow doesn't affect other hooks.
     */
    function test_multiHookFlow_removeHookMidFlow() public {
        uint256 depositAmount = 100_000e6;

        // All hooks deposit
        vm.prank(alphixHook);
        wrapper.deposit(depositAmount, alphixHook);

        vm.prank(hook2);
        wrapper.deposit(depositAmount, hook2);

        vm.prank(hook3);
        wrapper.deposit(depositAmount, hook3);

        // Record balances
        uint256 hook2Shares = wrapper.balanceOf(hook2);

        // Remove hook2
        vm.prank(owner);
        wrapper.removeAlphixHook(hook2);

        // Hook2's shares are unaffected
        assertEq(wrapper.balanceOf(hook2), hook2Shares, "Shares should remain");

        // Other hooks can still deposit
        vm.prank(alphixHook);
        wrapper.deposit(depositAmount, alphixHook);

        vm.prank(hook3);
        wrapper.deposit(depositAmount, hook3);

        // Yield still works
        _simulateYieldPercent(5);

        _assertSolvent();
    }

    /**
     * @notice Tests owner can only deposit to itself (receiver == msg.sender constraint).
     */
    function test_multiHookFlow_ownerDepositsToSelf() public {
        uint256 depositAmount = 100_000e6;
        asset.mint(owner, depositAmount);

        vm.startPrank(owner);

        // Owner deposits to self (only allowed deposit)
        uint256 ownerSharesBefore = wrapper.balanceOf(owner);
        wrapper.deposit(depositAmount, owner);

        vm.stopPrank();

        // Owner should have more shares
        assertGt(wrapper.balanceOf(owner), ownerSharesBefore, "Owner should have more shares");

        _assertSolvent();
    }

    /**
     * @notice Tests sequential add/remove with deposits.
     */
    function test_multiHookFlow_sequentialAddRemove() public {
        uint256 depositAmount = 50_000e6;

        // Initial deposit from hook1
        vm.prank(alphixHook);
        wrapper.deposit(depositAmount, alphixHook);

        // Add a new hook4
        address hook4 = makeAddr("hook4");
        asset.mint(hook4, depositAmount);

        vm.prank(owner);
        wrapper.addAlphixHook(hook4);

        vm.startPrank(hook4);
        asset.approve(address(wrapper), depositAmount);
        wrapper.deposit(depositAmount, hook4);
        vm.stopPrank();

        // Remove hook2 and hook3
        vm.startPrank(owner);
        wrapper.removeAlphixHook(hook2);
        wrapper.removeAlphixHook(hook3);
        vm.stopPrank();

        // Only hook1, hook4, and owner should be able to deposit now
        address[] memory hooks = wrapper.getAllAlphixHooks();
        assertEq(hooks.length, 2, "Should have 2 hooks");

        assertTrue(wrapper.isAlphixHook(alphixHook), "Hook1 should be authorized");
        assertTrue(wrapper.isAlphixHook(hook4), "Hook4 should be authorized");
        assertFalse(wrapper.isAlphixHook(hook2), "Hook2 should not be authorized");
        assertFalse(wrapper.isAlphixHook(hook3), "Hook3 should not be authorized");

        _assertSolvent();
    }

    /**
     * @notice Tests yield distribution with unequal deposits from hooks.
     */
    function test_multiHookFlow_unequalDepositsYieldDistribution() public {
        // Hook1 deposits 100k
        vm.prank(alphixHook);
        wrapper.deposit(100_000e6, alphixHook);

        // Hook2 deposits 200k
        vm.prank(hook2);
        wrapper.deposit(200_000e6, hook2);

        // Hook3 deposits 300k
        vm.prank(hook3);
        wrapper.deposit(300_000e6, hook3);

        // Record share balances
        uint256 shares1 = wrapper.balanceOf(alphixHook);
        uint256 shares2 = wrapper.balanceOf(hook2);
        uint256 shares3 = wrapper.balanceOf(hook3);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        // Check proportional value increase
        uint256 value1 = wrapper.convertToAssets(shares1);
        uint256 value2 = wrapper.convertToAssets(shares2);
        uint256 value3 = wrapper.convertToAssets(shares3);

        // Values should be roughly proportional to deposits (accounting for fee)
        // Hook2 should have ~2x Hook1's value, Hook3 should have ~3x Hook1's value
        assertApproxEqRel(value2, value1 * 2, 0.01e18, "Hook2 should have ~2x Hook1's value");
        assertApproxEqRel(value3, value1 * 3, 0.01e18, "Hook3 should have ~3x Hook1's value");

        _assertSolvent();
    }

    /**
     * @notice Tests fee collection doesn't affect hooks' share values.
     */
    function test_multiHookFlow_feeCollectionNoImpact() public {
        uint256 depositAmount = 100_000e6;

        // All hooks deposit
        vm.prank(alphixHook);
        wrapper.deposit(depositAmount, alphixHook);
        vm.prank(hook2);
        wrapper.deposit(depositAmount, hook2);
        vm.prank(hook3);
        wrapper.deposit(depositAmount, hook3);

        // Simulate yield
        _simulateYieldPercent(20);

        // Record values before fee collection
        uint256 value1Before = wrapper.convertToAssets(wrapper.balanceOf(alphixHook));
        uint256 value2Before = wrapper.convertToAssets(wrapper.balanceOf(hook2));
        uint256 value3Before = wrapper.convertToAssets(wrapper.balanceOf(hook3));

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Values should be unchanged
        uint256 value1After = wrapper.convertToAssets(wrapper.balanceOf(alphixHook));
        uint256 value2After = wrapper.convertToAssets(wrapper.balanceOf(hook2));
        uint256 value3After = wrapper.convertToAssets(wrapper.balanceOf(hook3));

        assertEq(value1After, value1Before, "Hook1 value unchanged");
        assertEq(value2After, value2Before, "Hook2 value unchanged");
        assertEq(value3After, value3Before, "Hook3 value unchanged");

        _assertSolvent();
    }

    /**
     * @notice Tests complete lifecycle with all operations.
     * @dev Cross-deposit removed (receiver == msg.sender constraint).
     */
    function test_multiHookFlow_completeLifecycle() public {
        // Phase 1: Initial deposits
        vm.prank(alphixHook);
        wrapper.deposit(100_000e6, alphixHook);
        vm.prank(hook2);
        wrapper.deposit(100_000e6, hook2);

        // Phase 2: Yield accrual
        _simulateYieldPercent(5);

        // Phase 3: hook3 deposits to self
        vm.prank(hook3);
        wrapper.deposit(50_000e6, hook3);

        // Phase 4: Add new hook
        address hook4 = makeAddr("hook4");
        asset.mint(hook4, 100_000e6);
        vm.prank(owner);
        wrapper.addAlphixHook(hook4);

        vm.startPrank(hook4);
        asset.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(100_000e6, hook4);
        vm.stopPrank();

        // Phase 5: More yield
        _simulateYieldPercent(10);

        // Phase 6: Fee change
        vm.prank(owner);
        wrapper.setFee(200_000); // 20%

        // Phase 7: More deposits
        vm.prank(hook2);
        wrapper.deposit(50_000e6, hook2);

        // Phase 8: Remove a hook
        vm.prank(owner);
        wrapper.removeAlphixHook(hook3);

        // Phase 9: Final yield
        _simulateYieldPercent(5);

        // Phase 10: Fee collection
        vm.prank(owner);
        wrapper.collectFees();

        // Verify final state
        assertEq(wrapper.getAllAlphixHooks().length, 3, "Should have 3 hooks");
        assertTrue(wrapper.isAlphixHook(alphixHook), "Hook1 authorized");
        assertTrue(wrapper.isAlphixHook(hook2), "Hook2 authorized");
        assertFalse(wrapper.isAlphixHook(hook3), "Hook3 not authorized");
        assertTrue(wrapper.isAlphixHook(hook4), "Hook4 authorized");

        _assertSolvent();
    }
}
