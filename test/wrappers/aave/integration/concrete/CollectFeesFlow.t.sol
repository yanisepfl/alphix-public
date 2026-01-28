// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title CollectFeesFlowTest
 * @author Alphix
 * @notice Integration tests for fee collection scenarios.
 */
contract CollectFeesFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Test complete fee collection flow: deposit, yield, collect fees.
     */
    function test_collectFeesFlow_completeCollection() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Generate yield
        _simulateYieldPercent(20);

        // Check claimable fees
        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees to claim");

        // Collect fees to treasury
        vm.prank(owner);
        wrapper.collectFees();

        // Verify treasury received fees as aTokens
        assertEq(aToken.balanceOf(treasury), claimableFees, "Treasury should receive fees");

        // Verify solvency: totalAssets + fees should equal aToken balance
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertEq(totalAssetsAfter, aTokenBalance, "All balance should be user assets after collection");
        assertGt(totalAssetsAfter, totalAssetsBefore, "totalAssets should increase from yield");

        // Fees should be zero
        assertEq(wrapper.getClaimableFees(), 0, "No more fees to claim");
    }

    /**
     * @notice Test periodic fee collection.
     */
    function test_collectFeesFlow_periodicCollection() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);

        uint256 totalCollected;

        // Simulate 3 periods of yield and collection
        for (uint256 i = 0; i < 3; i++) {
            // Generate yield
            _simulateYieldPercent(10);

            uint256 claimableFees = wrapper.getClaimableFees();

            // Collect fees
            vm.prank(owner);
            wrapper.collectFees();

            totalCollected += claimableFees;
        }

        // Verify all fees collected
        assertEq(aToken.balanceOf(treasury), totalCollected, "Should collect all periodic fees");

        // Verify wrapper state
        assertEq(wrapper.getClaimableFees(), 0, "No pending fees");

        // Solvency check
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All balance should be user assets");
    }

    /**
     * @notice Test fee collection with varying fee rates.
     */
    function test_collectFeesFlow_varyingFeeRates() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);

        // Period 1: 10% fee
        vm.prank(owner);
        wrapper.setFee(100_000); // 10%

        _simulateYieldPercent(10);
        vm.prank(owner);
        wrapper.collectFees();

        uint256 feesAt10Percent = aToken.balanceOf(treasury);

        // Period 2: 50% fee
        vm.prank(owner);
        wrapper.setFee(500_000); // 50%

        _simulateYieldPercent(10);
        vm.prank(owner);
        wrapper.collectFees();

        uint256 feesAt50Percent = aToken.balanceOf(treasury) - feesAt10Percent;

        // 50% fee should collect ~5x more than 10% fee on same yield
        assertApproxEqRel(feesAt50Percent, feesAt10Percent * 5, 0.1e18, "Higher fee should collect more");
    }

    /**
     * @notice Test fee collection after negative yield.
     */
    function test_collectFeesFlow_afterSlash() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);

        // Generate yield
        _simulateYieldPercent(30);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesBeforeSlash = wrapper.getClaimableFees();

        // Slash 40%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 40 / 100);

        // Fees should be reduced
        uint256 feesAfterSlash = wrapper.getClaimableFees();
        assertLt(feesAfterSlash, feesBeforeSlash, "Fees reduced by slash");

        // Collect reduced fees
        vm.prank(owner);
        wrapper.collectFees();

        assertEq(aToken.balanceOf(treasury), feesAfterSlash, "Should collect reduced fees");

        // Verify solvency
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All balance is user assets after collection");
    }

    /**
     * @notice Test fee collection interleaved with deposits.
     */
    function test_collectFeesFlow_interleavedWithDeposits() public {
        // First deposit
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);

        // Collect first fees
        vm.prank(owner);
        wrapper.collectFees();

        uint256 firstCollection = aToken.balanceOf(treasury);

        // Second deposit
        _depositAsHook(200e6, alphixHook);
        _simulateYieldPercent(10);

        // Collect second fees
        vm.prank(owner);
        wrapper.collectFees();

        uint256 secondCollection = aToken.balanceOf(treasury) - firstCollection;

        // Second collection should be larger (more TVL)
        assertGt(secondCollection, firstCollection, "More TVL should generate more fees");

        // Verify solvency
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained");
    }

    /**
     * @notice Test collecting fees after changing treasury to owner.
     */
    function test_collectFeesFlow_toOwner() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(20);

        // Change treasury to owner
        vm.prank(owner);
        wrapper.setYieldTreasury(owner);

        uint256 ownerATokenBefore = aToken.balanceOf(owner);
        uint256 claimableFees = wrapper.getClaimableFees();

        // Collect to self
        vm.prank(owner);
        wrapper.collectFees();

        uint256 ownerATokenAfter = aToken.balanceOf(owner);
        assertEq(ownerATokenAfter - ownerATokenBefore, claimableFees, "Owner should receive fees");
    }

    /**
     * @notice Test complete lifecycle: deposit, yield, fees, slash, recover, fees.
     */
    function test_collectFeesFlow_completeLifecycle() public {
        // Phase 1: Initial deposit
        _depositAsHook(100e6, alphixHook);

        // Phase 2: First yield cycle
        _simulateYieldPercent(15);
        vm.prank(owner);
        wrapper.collectFees();
        uint256 collection1 = aToken.balanceOf(treasury);

        // Phase 3: Slashing event - trigger accrual first to update lastWrapperBalance
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 25 / 100);
        // Trigger accrual to process negative yield and update lastWrapperBalance
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 4: Second yield cycle (recovery) - now yield is relative to post-slash balance
        _simulateYieldPercent(20);
        vm.prank(owner);
        wrapper.collectFees();
        uint256 collection2 = aToken.balanceOf(treasury) - collection1;

        // Phase 5: Additional deposit
        _depositAsHook(50e6, alphixHook);

        // Phase 6: Third yield cycle
        _simulateYieldPercent(10);
        vm.prank(owner);
        wrapper.collectFees();
        uint256 collection3 = aToken.balanceOf(treasury) - collection1 - collection2;

        // All collections should be positive
        assertGt(collection1, 0, "First collection positive");
        assertGt(collection2, 0, "Second collection positive");
        assertGt(collection3, 0, "Third collection positive");

        // Final solvency check
        uint256 finalATokenBalance = aToken.balanceOf(address(wrapper));
        uint256 finalTotalAssets = wrapper.totalAssets();
        uint256 finalFees = wrapper.getClaimableFees();

        assertEq(finalFees, 0, "All fees collected");
        assertEq(finalTotalAssets, finalATokenBalance, "All balance is user assets");
    }

    /**
     * @notice Test zero fee setting doesn't accumulate fees and collect reverts.
     */
    function test_collectFeesFlow_zeroFee() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        // Deposit
        _depositAsHook(100e6, alphixHook);

        // Generate yield
        _simulateYieldPercent(50);

        // No fees should accumulate
        assertEq(wrapper.getClaimableFees(), 0, "No fees with 0% fee");

        // Collect should revert with ZeroAmount since no fees
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroAmount.selector);
        wrapper.collectFees();

        // All yield goes to depositors
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        assertEq(totalAssets, aTokenBalance, "All yield goes to depositors");
    }
}
