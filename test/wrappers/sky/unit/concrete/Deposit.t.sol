// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title DepositTest
 * @author Alphix
 * @notice Unit tests for the deposit function.
 */
contract DepositTest is BaseAlphix4626WrapperSky {
    /* ACCESS CONTROL */

    /**
     * @notice Test that hook can deposit to self.
     */
    function test_deposit_asHook_toSelf_succeeds() public {
        uint256 amount = 100e18;
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);

        uint256 shares = _depositAsHook(amount, alphixHook);

        assertGt(shares, 0, "Should mint shares");
        assertEq(wrapper.balanceOf(alphixHook), sharesBefore + shares, "Shares not credited");
    }

    /**
     * @notice Test that owner can deposit to self.
     */
    function test_deposit_asOwner_toSelf_succeeds() public {
        uint256 amount = 100e18;
        uint256 sharesBefore = wrapper.balanceOf(owner);

        uint256 shares = _depositAsOwner(amount, owner);

        assertGt(shares, 0, "Should mint shares");
        assertEq(wrapper.balanceOf(owner), sharesBefore + shares, "Shares not credited");
    }

    /**
     * @notice Test that unauthorized caller cannot deposit.
     */
    function test_deposit_asUnauthorized_reverts() public {
        uint256 amount = 100e18;
        usds.mint(unauthorized, amount);

        vm.startPrank(unauthorized);
        usds.approve(address(wrapper), amount);
        vm.expectRevert(IAlphix4626WrapperSky.UnauthorizedCaller.selector);
        wrapper.deposit(amount, unauthorized);
        vm.stopPrank();
    }

    /* RECEIVER CONSTRAINT */

    /**
     * @notice Test that deposit reverts if receiver != msg.sender.
     */
    function test_deposit_toOther_reverts() public {
        uint256 amount = 100e18;
        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        vm.expectRevert(IAlphix4626WrapperSky.InvalidReceiver.selector);
        wrapper.deposit(amount, alice); // Try to deposit to alice
        vm.stopPrank();
    }

    /* SHARE CALCULATIONS */

    /**
     * @notice Test that shares are calculated correctly at 1:1 rate.
     */
    function test_deposit_sharesCalculation_atParRate() public {
        uint256 amount = 100e18;
        uint256 expectedShares = wrapper.previewDeposit(amount);

        uint256 shares = _depositAsHook(amount, alphixHook);

        assertEq(shares, expectedShares, "Shares should match preview");
        // At 1:1 rate with no prior deposits, should be approximately 1:1
        assertApproxEqRel(shares, amount, 0.01e18, "Shares should be close to amount at 1:1 rate");
    }

    /**
     * @notice Test that shares are calculated correctly after rate increase.
     */
    function test_deposit_sharesCalculation_afterYield() public {
        // Initial deposit
        _depositAsHook(100e18, alphixHook);

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        // Second deposit - should get fewer shares per USDS
        uint256 amount = 100e18;
        uint256 sharesBefore = wrapper.totalSupply();
        uint256 totalAssetsBefore = wrapper.totalAssets();

        usds.mint(owner, amount);
        vm.startPrank(owner);
        usds.approve(address(wrapper), amount);
        uint256 shares = wrapper.deposit(amount, owner);
        vm.stopPrank();

        // Shares should be less than amount due to increased totalAssets
        assertLt(shares, amount, "Shares should be less than amount after yield");

        // Verify proportion: shares/totalSupply = assets/totalAssets
        uint256 expectedShares = (amount * sharesBefore) / totalAssetsBefore;
        assertApproxEqRel(shares, expectedShares, 0.01e18, "Share calculation incorrect");
    }

    /* STATE CHANGES */

    /**
     * @notice Test that deposit transfers USDS from caller.
     */
    function test_deposit_transfersUsdsFromCaller() public {
        uint256 amount = 100e18;
        usds.mint(alphixHook, amount);
        uint256 balanceBefore = usds.balanceOf(alphixHook);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        assertEq(usds.balanceOf(alphixHook), balanceBefore - amount, "USDS not transferred");
    }

    /**
     * @notice Test that deposit swaps USDS to sUSDS via PSM.
     */
    function test_deposit_swapsToSusds() public {
        uint256 amount = 100e18;
        uint256 susdsBalanceBefore = susds.balanceOf(address(wrapper));

        _depositAsHook(amount, alphixHook);

        uint256 susdsBalanceAfter = susds.balanceOf(address(wrapper));
        assertGt(susdsBalanceAfter, susdsBalanceBefore, "Wrapper should hold more sUSDS");
    }

    /**
     * @notice Test that deposit increases totalAssets.
     */
    function test_deposit_increasesTotalAssets() public {
        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 amount = 100e18;

        _depositAsHook(amount, alphixHook);

        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore + amount, 0.01e18, "Total assets should increase");
    }

    /**
     * @notice Test that deposit increases totalSupply.
     */
    function test_deposit_increasesTotalSupply() public {
        uint256 totalSupplyBefore = wrapper.totalSupply();

        uint256 shares = _depositAsHook(100e18, alphixHook);

        assertEq(wrapper.totalSupply(), totalSupplyBefore + shares, "Total supply should increase");
    }

    /* EVENTS */

    /**
     * @notice Test that deposit emits Deposit event.
     */
    function test_deposit_emitsEvent() public {
        uint256 amount = 100e18;
        usds.mint(alphixHook, amount);
        uint256 expectedShares = wrapper.previewDeposit(amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);

        vm.expectEmit(true, true, true, true);
        emit Deposit(alphixHook, alphixHook, amount, expectedShares);

        wrapper.deposit(amount, alphixHook);
        vm.stopPrank();
    }

    /* EDGE CASES */

    /**
     * @notice Test that zero deposit reverts.
     */
    function test_deposit_zeroAmount_reverts() public {
        vm.startPrank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperSky.ZeroShares.selector);
        wrapper.deposit(0, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Test that deposit reverts when paused.
     */
    function test_deposit_whenPaused_reverts() public {
        vm.prank(owner);
        wrapper.pause();

        uint256 amount = 100e18;
        usds.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        vm.expectRevert(); // EnforcedPause
        wrapper.deposit(amount, alphixHook);
        vm.stopPrank();
    }

    /* SOLVENCY */

    /**
     * @notice Test that wrapper remains solvent after deposit.
     */
    function test_deposit_maintainsSolvency() public {
        _depositAsHook(100e18, alphixHook);
        _assertSolvent();
    }

    /**
     * @notice Test multiple deposits maintain solvency.
     */
    function test_deposit_multipleDeposits_maintainsSolvency() public {
        // Multiple deposits
        _depositAsHook(100e18, alphixHook);
        _depositAsOwner(200e18, owner);
        _depositAsHook(50e18, alphixHook);

        _assertSolvent();
    }
}
