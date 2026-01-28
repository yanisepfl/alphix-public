// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title MultiHookFlowTest
 * @author Alphix
 * @notice Integration tests for multiple hook interactions.
 */
contract MultiHookFlowTest is BaseAlphix4626WrapperSky {
    address internal hook2;
    address internal hook3;

    function setUp() public override {
        super.setUp();

        // Create additional hooks
        hook2 = makeAddr("hook2");
        hook3 = makeAddr("hook3");

        // Add them as authorized hooks
        vm.startPrank(owner);
        wrapper.addAlphixHook(hook2);
        wrapper.addAlphixHook(hook3);
        vm.stopPrank();

        // Approve wrapper for new hooks
        vm.prank(hook2);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(hook3);
        usds.approve(address(wrapper), type(uint256).max);
    }

    /**
     * @notice Tests multiple hooks depositing and withdrawing.
     */
    function test_multiHookFlow_depositsAndWithdrawals() public {
        // All hooks deposit
        _depositAsHook(100e18, alphixHook);

        usds.mint(hook2, 200e18);
        vm.prank(hook2);
        wrapper.deposit(200e18, hook2);

        usds.mint(hook3, 300e18);
        vm.prank(hook3);
        wrapper.deposit(300e18, hook3);

        // Total should be 600 + seed
        assertApproxEqAbs(
            wrapper.totalAssets(), DEFAULT_SEED_LIQUIDITY + 600e18, 2, "Total assets should be sum of deposits"
        );

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Each hook withdraws half
        uint256 hook1Max = wrapper.maxWithdraw(alphixHook);
        uint256 hook2Max = wrapper.maxWithdraw(hook2);
        uint256 hook3Max = wrapper.maxWithdraw(hook3);

        vm.prank(alphixHook);
        wrapper.withdraw(hook1Max / 2, alphixHook, alphixHook);

        vm.prank(hook2);
        wrapper.withdraw(hook2Max / 2, hook2, hook2);

        vm.prank(hook3);
        wrapper.withdraw(hook3Max / 2, hook3, hook3);

        // All hooks should still have shares
        assertGt(wrapper.balanceOf(alphixHook), 0, "Hook1 should have shares");
        assertGt(wrapper.balanceOf(hook2), 0, "Hook2 should have shares");
        assertGt(wrapper.balanceOf(hook3), 0, "Hook3 should have shares");

        _assertSolvent();
    }

    /**
     * @notice Tests hooks depositing at different times with yield between.
     */
    function test_multiHookFlow_sequentialDepositsWithYield() public {
        // Hook1 deposits first
        uint256 hook1Shares = _depositAsHook(100e18, alphixHook);

        // 1% yield (respects circuit breaker)
        _simulateYieldPercent(1);

        // Hook2 deposits (should get fewer shares per USDS)
        usds.mint(hook2, 100e18);
        vm.prank(hook2);
        uint256 hook2Shares = wrapper.deposit(100e18, hook2);

        // 1% more yield (respects circuit breaker)
        _simulateYieldPercent(1);

        // Hook3 deposits (should get even fewer shares)
        usds.mint(hook3, 100e18);
        vm.prank(hook3);
        uint256 hook3Shares = wrapper.deposit(100e18, hook3);

        // Later depositors should have gotten fewer shares
        assertGt(hook1Shares, hook2Shares, "Hook1 should have more shares than Hook2");
        assertGt(hook2Shares, hook3Shares, "Hook2 should have more shares than Hook3");

        // But early depositors benefited from more yield cycles
        // Hook1 should have highest value (most yield accumulated)
        assertGt(
            wrapper.convertToAssets(hook1Shares), wrapper.convertToAssets(hook2Shares), "Hook1 should have more value"
        );
        assertGt(wrapper.convertToAssets(hook3Shares), 0, "Hook3 should have value");

        _assertSolvent();
    }

    /**
     * @notice Tests removing a hook mid-operation.
     * @dev When a hook is removed, it cannot withdraw or deposit anymore (maxWithdraw returns 0).
     *      The shares remain but are effectively frozen until the hook is re-added.
     */
    function test_multiHookFlow_removeHookMidOperation() public {
        // All hooks deposit
        _depositAsHook(100e18, alphixHook);

        usds.mint(hook2, 100e18);
        vm.prank(hook2);
        wrapper.deposit(100e18, hook2);

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        uint256 hook2SharesBefore = wrapper.balanceOf(hook2);
        assertGt(hook2SharesBefore, 0, "Hook2 should have shares");

        // Remove hook2
        vm.prank(owner);
        wrapper.removeAlphixHook(hook2);

        // hook2's maxWithdraw is now 0 (unauthorized)
        uint256 hook2Max = wrapper.maxWithdraw(hook2);
        assertEq(hook2Max, 0, "Removed hook should have 0 maxWithdraw");

        // hook2 cannot withdraw anymore (unauthorized)
        vm.prank(hook2);
        vm.expectRevert();
        wrapper.withdraw(1e18, hook2, hook2);

        // hook2 cannot deposit anymore (unauthorized)
        usds.mint(hook2, 50e18);
        vm.prank(hook2);
        vm.expectRevert();
        wrapper.deposit(50e18, hook2);

        // But hook2 still has shares (can be recovered if re-added)
        assertEq(wrapper.balanceOf(hook2), hook2SharesBefore, "Hook2 should still have shares");

        // Re-add hook2
        vm.prank(owner);
        wrapper.addAlphixHook(hook2);

        // Now hook2 can withdraw again
        uint256 hook2MaxAfterReAdd = wrapper.maxWithdraw(hook2);
        assertGt(hook2MaxAfterReAdd, 0, "Re-added hook should have maxWithdraw > 0");

        vm.prank(hook2);
        wrapper.withdraw(hook2MaxAfterReAdd, hook2, hook2);

        _assertSolvent();
    }

    /**
     * @notice Tests yield distribution is proportional to shares.
     */
    function test_multiHookFlow_proportionalYieldDistribution() public {
        // Different deposit amounts
        _depositAsHook(100e18, alphixHook); // 100

        usds.mint(hook2, 200e18);
        vm.prank(hook2);
        wrapper.deposit(200e18, hook2); // 200

        usds.mint(hook3, 300e18);
        vm.prank(hook3);
        wrapper.deposit(300e18, hook3); // 300

        uint256 hook1Shares = wrapper.balanceOf(alphixHook);
        uint256 hook2Shares = wrapper.balanceOf(hook2);
        uint256 hook3Shares = wrapper.balanceOf(hook3);

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Get proportional values
        uint256 hook1Value = wrapper.convertToAssets(hook1Shares);
        uint256 hook2Value = wrapper.convertToAssets(hook2Shares);
        uint256 hook3Value = wrapper.convertToAssets(hook3Shares);

        // Ratios should be approximately 1:2:3
        _assertApproxEq(hook2Value * 100 / hook1Value, 200, 5, "Hook2 should have 2x Hook1");
        _assertApproxEq(hook3Value * 100 / hook1Value, 300, 5, "Hook3 should have 3x Hook1");

        _assertSolvent();
    }

    /**
     * @notice Tests simultaneous operations from multiple hooks.
     */
    function test_multiHookFlow_simultaneousOperations() public {
        // All hooks deposit
        _depositAsHook(100e18, alphixHook);

        usds.mint(hook2, 100e18);
        vm.prank(hook2);
        wrapper.deposit(100e18, hook2);

        usds.mint(hook3, 100e18);
        vm.prank(hook3);
        wrapper.deposit(100e18, hook3);

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Hook1 withdraws
        vm.prank(alphixHook);
        wrapper.withdraw(50e18, alphixHook, alphixHook);

        // Hook2 redeems
        uint256 hook2Shares = wrapper.balanceOf(hook2);
        vm.prank(hook2);
        wrapper.redeem(hook2Shares / 2, hook2, hook2);

        // Hook3 deposits more
        usds.mint(hook3, 50e18);
        vm.prank(hook3);
        wrapper.deposit(50e18, hook3);

        // All operations should maintain solvency
        _assertSolvent();
    }

    /**
     * @notice Tests adding hooks dynamically.
     */
    function test_multiHookFlow_addHooksDynamically() public {
        // Initial deposit
        _depositAsHook(100e18, alphixHook);

        // Generate yield (1% respects circuit breaker)
        _simulateYieldPercent(1);

        // Add new hook
        address newHook = makeAddr("newHook");
        vm.prank(owner);
        wrapper.addAlphixHook(newHook);

        // New hook deposits
        usds.mint(newHook, 100e18);
        vm.startPrank(newHook);
        usds.approve(address(wrapper), 100e18);
        uint256 newHookShares = wrapper.deposit(100e18, newHook);
        vm.stopPrank();

        // New hook should have shares
        assertGt(newHookShares, 0, "New hook should have shares");

        // Both can withdraw
        uint256 hook1Max = wrapper.maxWithdraw(alphixHook);
        uint256 newHookMax = wrapper.maxWithdraw(newHook);

        assertGt(hook1Max, 0, "Original hook can withdraw");
        assertGt(newHookMax, 0, "New hook can withdraw");

        _assertSolvent();
    }

    /**
     * @notice Tests that getAllAlphixHooks returns correct list.
     */
    function test_multiHookFlow_getAllHooks() public view {
        // Should have alphixHook, hook2, hook3
        assertEq(wrapper.getAllAlphixHooks().length, 3, "Should have 3 hooks");

        // Verify each is authorized
        assertTrue(wrapper.isAlphixHook(alphixHook), "Hook1 should be authorized");
        assertTrue(wrapper.isAlphixHook(hook2), "Hook2 should be authorized");
        assertTrue(wrapper.isAlphixHook(hook3), "Hook3 should be authorized");
    }
}
