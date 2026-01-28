// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title SetFeeFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave setFee function.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract SetFeeFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test for setFee with valid fees.
     * @param decimals The asset decimals (6-18).
     * @param newFee The fee to set.
     */
    function testFuzz_setFee_validFee_succeeds(uint8 decimals, uint24 newFee) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        newFee = _boundFee(newFee);

        vm.prank(owner);
        d.wrapper.setFee(newFee);

        assertEq(d.wrapper.getFee(), newFee, "Fee should be updated");
    }

    /**
     * @notice Fuzz test that setFee reverts for fees above max.
     * @param decimals The asset decimals (6-18).
     * @param newFee The fee to set.
     */
    function testFuzz_setFee_aboveMax_reverts(uint8 decimals, uint24 newFee) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        newFee = uint24(bound(newFee, MAX_FEE + 1, type(uint24).max));

        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.FeeTooHigh.selector);
        d.wrapper.setFee(newFee);
    }

    /**
     * @notice Fuzz test that non-owner cannot set fee.
     * @param decimals The asset decimals (6-18).
     * @param caller Random caller address.
     * @param newFee The fee to set.
     */
    function testFuzz_setFee_nonOwner_reverts(uint8 decimals, address caller, uint24 newFee) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.assume(caller != owner);
        newFee = _boundFee(newFee);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        d.wrapper.setFee(newFee);
    }

    /**
     * @notice Fuzz test that setFee emits correct event.
     * @param decimals The asset decimals (6-18).
     * @param newFee The fee to set.
     */
    function testFuzz_setFee_emitsEvent(uint8 decimals, uint24 newFee) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        newFee = _boundFee(newFee);

        uint256 oldFee = d.wrapper.getFee();

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit FeeUpdated(uint24(oldFee), newFee); // Safe: getFee() always returns value <= MAX_FEE (1_000_000)

        vm.prank(owner);
        d.wrapper.setFee(newFee);
    }

    /**
     * @notice Fuzz test multiple fee changes.
     * @param decimals The asset decimals (6-18).
     * @param fees Array of fees to set.
     */
    function testFuzz_setFee_multipleChanges(uint8 decimals, uint24[5] memory fees) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.startPrank(owner);

        for (uint256 i = 0; i < fees.length; i++) {
            fees[i] = _boundFee(fees[i]);
            d.wrapper.setFee(fees[i]);
            assertEq(d.wrapper.getFee(), fees[i], "Fee should match");
        }

        vm.stopPrank();
    }
}
