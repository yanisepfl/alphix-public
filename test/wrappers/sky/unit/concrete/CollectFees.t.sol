// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollectFeesTest
 * @author Alphix
 * @notice Unit tests for the collectFees function.
 * @dev Fees are collected in sUSDS for the Sky wrapper.
 */
contract CollectFeesTest is BaseAlphix4626WrapperSky {
    /* ACCESS CONTROL */

    /**
     * @notice Test that only owner can collect fees.
     */
    function test_collectFees_asOwner_succeeds() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees to collect");

        // Collect as owner
        vm.prank(owner);
        wrapper.collectFees();

        // Verify fees were transferred (in sUSDS)
        assertEq(susds.balanceOf(treasury), claimableFees, "Fees not transferred correctly");
    }

    /**
     * @notice Test that non-owner cannot collect fees.
     */
    function test_collectFees_nonOwner_reverts() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        wrapper.collectFees();
    }

    /**
     * @notice Test that hook cannot collect fees.
     */
    function test_collectFees_asHook_reverts() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

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
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Get claimable fees (includes pending yield)
        uint256 claimableFees = wrapper.getClaimableFees();

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Receiver should get all fees including recently accrued
        assertEq(susds.balanceOf(treasury), claimableFees, "Should receive all accrued fees");
    }

    /**
     * @notice Test that collectFees resets accumulated fees to zero.
     */
    function test_collectFees_resetsFees() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

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
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 claimableFees = wrapper.getClaimableFees();

        vm.expectEmit(true, true, true, true);
        emit FeesCollected(claimableFees);

        vm.prank(owner);
        wrapper.collectFees();
    }

    /**
     * @notice Test that collectFees with zero fees reverts.
     */
    function test_collectFees_zeroFees_reverts() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        // Deposit (no fees will accrue)
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        assertEq(wrapper.getClaimableFees(), 0, "Should have no fees");

        // Should revert with ZeroAmount
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.ZeroAmount.selector);
        wrapper.collectFees();
    }

    /* SOLVENCY AFTER COLLECTION */

    /**
     * @notice Test that solvency is maintained after collection.
     */
    function test_collectFees_maintainsSolvency() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Verify solvency
        _assertSolvent();
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero");
    }

    /**
     * @notice Test that totalAssets is unchanged after collection.
     */
    function test_collectFees_totalAssetsUnchanged() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

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
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // First collection
        vm.prank(owner);
        wrapper.collectFees();

        uint256 firstCollection = susds.balanceOf(treasury);

        // Generate more yield
        _simulateYieldPercent(1);

        // Second collection
        vm.prank(owner);
        wrapper.collectFees();

        uint256 totalCollected = susds.balanceOf(treasury);
        assertGt(totalCollected, firstCollection, "Should have collected more fees");
    }

    /**
     * @notice Test collection to different addresses via setYieldTreasury.
     */
    function test_collectFees_withTreasuryChange() public {
        address newTreasury = makeAddr("newTreasury");

        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Collect to original treasury
        vm.prank(owner);
        wrapper.collectFees();

        uint256 treasuryBalance = susds.balanceOf(treasury);
        assertGt(treasuryBalance, 0, "treasury should have fees");

        // Generate more yield
        _simulateYieldPercent(1);

        // Change treasury and collect
        vm.prank(owner);
        wrapper.setYieldTreasury(newTreasury);

        vm.prank(owner);
        wrapper.collectFees();

        uint256 newTreasuryBalance = susds.balanceOf(newTreasury);
        assertGt(newTreasuryBalance, 0, "newTreasury should have fees");
    }

    /* INTERACTION WITH OTHER OPERATIONS */

    /**
     * @notice Test collection after negative yield.
     * @dev Accumulated fees are NOT reduced by negative yield - they represent past yield.
     */
    function test_collectFees_afterNegativeYield() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();

        // Slash (simulate rate decrease)
        _simulateSlashPercent(1);

        // Trigger accrual for rate update
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Fees should NOT be reduced (accumulated fees represent past yield)
        uint256 feesAfterSlash = wrapper.getClaimableFees();
        assertEq(feesAfterSlash, feesBeforeSlash, "Fees should NOT be reduced by slash");

        // Collect should work
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), feesAfterSlash, "Should collect full fees");
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero after collection");
    }

    /**
     * @notice Test deposit after collection.
     */
    function test_deposit_afterCollectFees() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Collect fees
        vm.prank(owner);
        wrapper.collectFees();

        // Deposit should still work
        uint256 totalAssetsBefore = wrapper.totalAssets();
        _depositAsHook(500e18, alphixHook);
        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Allow small rounding difference due to PSM swap
        assertApproxEqRel(
            totalAssetsAfter, totalAssetsBefore + 500e18, 0.001e18, "Deposit should work after collection"
        );
    }

    /* SET YIELD TREASURY TESTS */

    /**
     * @notice Test that setYieldTreasury reverts on zero address.
     */
    function test_setYieldTreasury_revertsIfZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.InvalidAddress.selector);
        wrapper.setYieldTreasury(address(0));
    }

    /**
     * @notice Test that setYieldTreasury emits event.
     */
    function test_setYieldTreasury_emitsEvent() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, false, false);
        emit YieldTreasuryUpdated(treasury, newTreasury);

        vm.prank(owner);
        wrapper.setYieldTreasury(newTreasury);
    }

    /**
     * @notice Test that only owner can set yield treasury.
     */
    function test_setYieldTreasury_nonOwner_reverts() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wrapper.setYieldTreasury(newTreasury);
    }

    /* EDGE CASES - ZERO TREASURY */

    /**
     * @notice Test that collectFees reverts if treasury is set to zero address.
     * @dev This tests the branch at line 439: `if (_yieldTreasury == address(0)) revert InvalidAddress()`
     *      We need to deploy a wrapper with a valid treasury, then use vm.store to set it to zero.
     */
    function test_collectFees_zeroTreasury_reverts() public {
        // Setup: deposit and generate yield
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        // Use vm.store to set _yieldTreasury to address(0)
        // Storage layout: _yieldTreasury is at slot 8, offset 4 (packed with _paused and _fee)
        // We need to clear only the _yieldTreasury bytes while preserving _paused and _fee
        bytes32 slot8 = vm.load(address(wrapper), bytes32(uint256(8)));
        // Clear bytes 4-23 (address is 20 bytes) while keeping bytes 0-3 (_paused + _fee)
        bytes32 mask = bytes32(uint256(0xFFFFFFFF)); // Keep first 4 bytes
        bytes32 newSlot8 = slot8 & mask; // Zero out the address part
        vm.store(address(wrapper), bytes32(uint256(8)), newSlot8);

        // Verify treasury is now zero
        assertEq(wrapper.getYieldTreasury(), address(0), "Treasury should be zero");

        // collectFees should revert with InvalidAddress
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.InvalidAddress.selector);
        wrapper.collectFees();
    }

    /**
     * @notice Test getClaimableFees when netSusds is zero (all sUSDS is fees).
     * @dev This tests the branch at line 536: `if (netSusds == 0) return _accumulatedFees`
     *      This is an extreme edge case where accumulated fees >= totalSusds.
     *      We simulate this by using vm.store to set _accumulatedFees very high.
     */
    function test_getClaimableFees_netSusdsZero_returnsAccumulatedFees() public {
        // Setup: deposit some USDS
        _depositAsHook(1000e18, alphixHook);

        // Get current sUSDS balance
        uint256 totalSusds = susds.balanceOf(address(wrapper));

        // Generate some yield so currentRate > lastRate
        _simulateYieldPercent(1);

        // Use vm.store to set _accumulatedFees >= totalSusds
        // Storage slot for _accumulatedFees is slot 12 (from forge inspect storage-layout)
        // _accumulatedFees is uint128, stored at offset 0 of slot 12
        bytes32 accumulatedFeesSlot = bytes32(uint256(12));
        // Set accumulated fees to be equal to totalSusds (extreme case)
        vm.store(address(wrapper), accumulatedFeesSlot, bytes32(totalSusds));

        // Now getClaimableFees should return just the accumulated fees (since netSusds = 0)
        uint256 claimableFees = wrapper.getClaimableFees();

        // The claimable fees should equal what we stored (totalSusds)
        // Note: since netSusds = 0, there are no pending fees from yield
        assertEq(claimableFees, totalSusds, "Should return accumulated fees when netSusds is 0");
    }
}
