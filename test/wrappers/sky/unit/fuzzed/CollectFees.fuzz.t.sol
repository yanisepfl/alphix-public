// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CollectFeesFuzzTest
 * @author Alphix
 * @notice Fuzz tests for fee collection.
 */
contract CollectFeesFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test fee collection with varying amounts.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_collectFees_varyingAmounts(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees to collect");

        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), claimableFees, "Treasury should receive fees");
        assertEq(wrapper.getClaimableFees(), 0, "Fees should be zero after collection");
    }

    /**
     * @notice Fuzz test fee collection reverts for non-owner.
     * @param caller Random caller address.
     */
    function testFuzz_collectFees_nonOwner_reverts(address caller) public {
        vm.assume(caller != owner && caller != address(0));

        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1); // Circuit breaker limits to 1%

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        wrapper.collectFees();
    }

    /**
     * @notice Fuzz test multiple fee collections.
     * @param depositMultiplier Deposit amount.
     * @param yields Array of yield percentages.
     */
    function testFuzz_collectFees_multipleCollections(uint256 depositMultiplier, uint8[3] memory yields) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalCollected;

        for (uint256 i = 0; i < yields.length; i++) {
            uint256 yieldPercent = bound(yields[i], 1, 1); // Circuit breaker limits to 1%
            _simulateYieldPercent(yieldPercent);

            uint256 claimableFees = wrapper.getClaimableFees();

            vm.prank(owner);
            wrapper.collectFees();

            totalCollected += claimableFees;
        }

        assertEq(susds.balanceOf(treasury), totalCollected, "Total fees should match");
        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection maintains solvency.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_collectFees_maintainsSolvency(uint256 depositMultiplier, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        vm.prank(owner);
        wrapper.collectFees();

        _assertSolvent();
    }

    /**
     * @notice Fuzz test fee collection with varying fee rates.
     * @param depositMultiplier Deposit amount.
     * @param fee Fee rate.
     * @param yieldPercent Yield percentage.
     */
    function testFuzz_collectFees_varyingFeeRates(uint256 depositMultiplier, uint24 fee, uint256 yieldPercent) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        fee = uint24(bound(fee, 1, MAX_FEE)); // At least 1 to generate some fees
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        uint256 depositAmount = depositMultiplier * 1e18;

        vm.prank(owner);
        wrapper.setFee(fee);

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFees = wrapper.getClaimableFees();
        assertGt(claimableFees, 0, "Should have fees with non-zero fee rate");

        vm.prank(owner);
        wrapper.collectFees();

        assertEq(susds.balanceOf(treasury), claimableFees, "Treasury should receive correct fees");
    }
}
