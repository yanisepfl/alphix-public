// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title SetFeeTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave setFee function.
 */
contract SetFeeTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that owner can set fee successfully.
     */
    function test_setFee_asOwner_succeeds() public {
        uint24 newFee = 200_000; // 20%

        vm.prank(owner);
        wrapper.setFee(newFee);

        // Fee was updated (we can't directly read _fee, but we can verify via event)
    }

    /**
     * @notice Tests that setFee emits the correct event.
     */
    function test_setFee_emitsEvent() public {
        uint24 newFee = 200_000; // 20%

        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(DEFAULT_FEE, newFee);

        vm.prank(owner);
        wrapper.setFee(newFee);
    }

    /**
     * @notice Tests that non-owner cannot set fee.
     */
    function test_setFee_nonOwner_reverts() public {
        uint24 newFee = 200_000;

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        wrapper.setFee(newFee);
    }

    /**
     * @notice Tests that hook cannot set fee (only owner).
     */
    function test_setFee_asHook_reverts() public {
        uint24 newFee = 200_000;

        vm.prank(alphixHook);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alphixHook));
        wrapper.setFee(newFee);
    }

    /**
     * @notice Tests that fee exceeding max reverts.
     */
    function test_setFee_exceedsMax_reverts() public {
        uint24 invalidFee = MAX_FEE + 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.FeeTooHigh.selector);
        wrapper.setFee(invalidFee);
    }

    /**
     * @notice Tests that fee can be set to zero.
     */
    function test_setFee_toZero_succeeds() public {
        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(DEFAULT_FEE, 0);

        vm.prank(owner);
        wrapper.setFee(0);
    }

    /**
     * @notice Tests that fee can be set to max.
     */
    function test_setFee_toMax_succeeds() public {
        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(DEFAULT_FEE, MAX_FEE);

        vm.prank(owner);
        wrapper.setFee(MAX_FEE);
    }

    /**
     * @notice Tests that setFee accrues yield before updating.
     */
    function test_setFee_accruesYieldFirst() public {
        // Make a deposit first (to alphixHook, an authorized receiver)
        _depositAsHook(100e6, alphixHook);

        // Simulate yield
        _simulateYieldPercent(10); // 10% yield

        // Setting fee should trigger yield accrual
        vm.expectEmit(false, false, false, false);
        emit YieldAccrued(0, 0, 0); // We just check the event is emitted

        vm.prank(owner);
        wrapper.setFee(200_000);
    }

    /**
     * @notice Tests multiple fee changes.
     */
    function test_setFee_multipleChanges() public {
        uint24 fee1 = 50_000;
        uint24 fee2 = 150_000;
        uint24 fee3 = 0;

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(DEFAULT_FEE, fee1);
        wrapper.setFee(fee1);

        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(fee1, fee2);
        wrapper.setFee(fee2);

        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(fee2, fee3);
        wrapper.setFee(fee3);

        vm.stopPrank();
    }
}
