// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollectFeesTest
 * @author Alphix
 * @notice Unit tests for the collectFees function.
 */
contract CollectFeesTest is BaseAlphix4626WrapperAave {
    /* ACCESS CONTROL */

    /**
     * @notice Test that only owner can collect fees.
     */
    function test_collectFees_asOwner_succeeds() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees to collect");

        // Collect as owner
        vm.prank(owner);
        wrapper.collectFees();

        // Verify fees were transferred
        assertEq(aToken.balanceOf(treasury), claimableFees, "Fees not transferred correctly");
    }

    /**
     * @notice Test that non-owner cannot collect fees.
     */
    function test_collectFees_nonOwner_reverts() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wrapper.collectFees();
    }

    /**
     * @notice Test that hook cannot collect fees.
     */
    function test_collectFees_asHook_reverts() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alphixHook));
        vm.prank(alphixHook);
        wrapper.collectFees();
    }

    /* FEE COLLECTION BEHAVIOR */

    /**
     * @notice Test that collectFees accrues yield first.
     */
    function test_collectFees_accruesYieldFirst() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Get claimable fees (includes pending yield)
        uint256 claimableFees = wrapper.getClaimableFees();

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Receiver should get all fees including recently accrued
        assertEq(aToken.balanceOf(treasury), claimableFees, "Should receive all accrued fees");
    }

    /**
     * @notice Test that collectFees resets accumulated fees to zero.
     */
    function test_collectFees_resetsFees() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        assertGt(wrapper.getClaimableFees(), 0, "Should have fees before collection");

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Fees should be zero after collection
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero after collection");
    }

    /**
     * @notice Test that collectFees emits FeesCollected event.
     */
    function test_collectFees_emitsEvent() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 expectedBalance = aToken.balanceOf(address(wrapper)) - claimableFees;

        vm.expectEmit(true, true, true, true);
        emit IAlphix4626WrapperAave.FeesCollected(claimableFees, expectedBalance);

        vm.prank(owner);
        wrapper.collectFees();
    }

    /**
     * @notice Test that collectFees updates lastWrapperBalance.
     */
    function test_collectFees_updatesLastWrapperBalance() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // lastWrapperBalance should equal current aToken balance
        uint256 lastBalance = wrapper.getLastWrapperBalance();
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));

        assertEq(lastBalance, aTokenBalance, "lastWrapperBalance should be updated");
    }

    /**
     * @notice Test that collectFees with zero fees reverts.
     */
    function test_collectFees_zeroFees_reverts() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        // Deposit (no fees will accrue)
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        assertEq(wrapper.getClaimableFees(), 0, "Should have no fees");

        // Should revert with ZeroAmount
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroAmount.selector);
        wrapper.collectFees();
    }

    /* SOLVENCY AFTER COLLECTION */

    /**
     * @notice Test that solvency is maintained after collection.
     */
    function test_collectFees_maintainsSolvency() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Verify solvency
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertEq(claimableFees, 0, "Fees should be zero");
        assertEq(totalAssets, aTokenBalance, "totalAssets should equal aToken balance");
    }

    /**
     * @notice Test that totalAssets is unchanged after collection.
     */
    function test_collectFees_totalAssetsUnchanged() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        uint256 totalAssetsAfter = wrapper.totalAssets();

        assertEq(totalAssetsAfter, totalAssetsBefore, "totalAssets should not change");
    }

    /* MULTIPLE COLLECTIONS */

    /**
     * @notice Test multiple consecutive collections.
     */
    function test_collectFees_multipleCollections() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);

        // First collection
        vm.prank(owner);
        wrapper.collectFees();

        uint256 firstCollection = aToken.balanceOf(treasury);

        // Generate more yield
        _simulateYieldPercent(10);

        // Second collection
        vm.prank(owner);
        wrapper.collectFees();

        uint256 totalCollected = aToken.balanceOf(treasury);
        assertGt(totalCollected, firstCollection, "Should have collected more fees");
    }

    /**
     * @notice Test collection to different addresses via setYieldTreasury.
     */
    function test_collectFees_withTreasuryChange() public {
        address newTreasury = makeAddr("newTreasury");

        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);

        // Collect to original treasury
        vm.prank(owner);
        wrapper.collectFees();

        uint256 treasuryBalance = aToken.balanceOf(treasury);
        assertGt(treasuryBalance, 0, "treasury should have fees");

        // Generate more yield
        _simulateYieldPercent(10);

        // Change treasury and collect
        vm.prank(owner);
        wrapper.setYieldTreasury(newTreasury);

        vm.prank(owner);
        wrapper.collectFees();

        uint256 newTreasuryBalance = aToken.balanceOf(newTreasury);
        assertGt(newTreasuryBalance, 0, "newTreasury should have fees");
    }

    /* INTERACTION WITH OTHER OPERATIONS */

    /**
     * @notice Test collection after negative yield.
     */
    function test_collectFees_afterNegativeYield() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();

        // Slash 50%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 50 / 100);

        // Fees should be reduced
        uint256 feesAfterSlash = wrapper.getClaimableFees();
        assertLt(feesAfterSlash, feesBeforeSlash, "Fees should be reduced by slash");

        // Collect should work
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(aToken.balanceOf(treasury), feesAfterSlash, "Should collect reduced fees");
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero after collection");
    }

    /**
     * @notice Test deposit after collection.
     */
    function test_deposit_afterCollectFees() public {
        // Setup: deposit and generate yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Deposit should still work
        uint256 totalAssetsBefore = wrapper.totalAssets();
        _depositAsHook(50e6, alphixHook);
        uint256 totalAssetsAfter = wrapper.totalAssets();

        assertEq(totalAssetsAfter, totalAssetsBefore + 50e6, "Deposit should work after collection");
    }

    /* SET YIELD TREASURY TESTS */

    /**
     * @notice Test that setYieldTreasury reverts on zero address.
     */
    function test_setYieldTreasury_revertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.InvalidAddress.selector);
        wrapper.setYieldTreasury(address(0));
    }
}
