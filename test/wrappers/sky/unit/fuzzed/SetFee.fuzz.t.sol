// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title SetFeeFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the setFee function.
 */
contract SetFeeFuzzTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Fuzz test setFee with valid fee values.
     * @param fee The fee value to set.
     */
    function testFuzz_setFee_validFees(uint24 fee) public {
        fee = _boundFee(fee);

        vm.prank(owner);
        wrapper.setFee(fee);

        assertEq(wrapper.getFee(), fee, "Fee should be set correctly");
    }

    /**
     * @notice Fuzz test setFee reverts for non-owner.
     * @param caller Random caller address.
     * @param fee The fee value to set.
     */
    function testFuzz_setFee_nonOwner_reverts(address caller, uint24 fee) public {
        vm.assume(caller != owner && caller != address(0));
        fee = _boundFee(fee);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        wrapper.setFee(fee);
    }

    /**
     * @notice Fuzz test setFee reverts for fees above max.
     * @param fee Fee value above max.
     */
    function testFuzz_setFee_exceedsMax_reverts(uint24 fee) public {
        fee = uint24(bound(fee, MAX_FEE + 1, type(uint24).max));

        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.FeeTooHigh.selector);
        wrapper.setFee(fee);
    }

    /**
     * @notice Fuzz test that setFee accrues yield before update.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     * @param newFee New fee value.
     */
    function testFuzz_setFee_accruesYieldFirst(uint256 depositMultiplier, uint256 yieldPercent, uint24 newFee) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        newFee = _boundFee(newFee);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        uint256 claimableFeesBefore = wrapper.getClaimableFees();

        // Change fee
        vm.prank(owner);
        wrapper.setFee(newFee);

        // Yield should have been accrued before fee change
        uint256 claimableFeesAfter = wrapper.getClaimableFees();
        assertGe(claimableFeesAfter, claimableFeesBefore, "Yield should be accrued before fee change");
    }

    /**
     * @notice Fuzz test multiple fee changes.
     * @param fees Array of fee values.
     */
    function testFuzz_setFee_multipleChanges(uint24[5] memory fees) public {
        for (uint256 i = 0; i < fees.length; i++) {
            fees[i] = _boundFee(fees[i]);

            vm.prank(owner);
            wrapper.setFee(fees[i]);

            assertEq(wrapper.getFee(), fees[i], "Fee should update");
        }
    }

    /**
     * @notice Fuzz test fee change maintains solvency.
     * @param depositMultiplier Deposit amount.
     * @param yieldPercent Yield percentage.
     * @param newFee New fee value.
     */
    function testFuzz_setFee_maintainsSolvency(uint256 depositMultiplier, uint256 yieldPercent, uint24 newFee) public {
        depositMultiplier = bound(depositMultiplier, 1, 100_000_000);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%
        newFee = _boundFee(newFee);
        uint256 depositAmount = depositMultiplier * 1e18;

        _depositAsHook(depositAmount, alphixHook);
        _simulateYieldPercent(yieldPercent);

        vm.prank(owner);
        wrapper.setFee(newFee);

        _assertSolvent();
    }
}
