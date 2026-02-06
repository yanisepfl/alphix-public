// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title MaxDepositFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave maxDeposit function.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract MaxDepositFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test that maxDeposit returns zero for unauthorized receivers.
     * @param decimals The asset decimals (6-18).
     * @param receiver Random receiver address.
     */
    function testFuzz_maxDeposit_unauthorizedReceiver_returnsZero(uint8 decimals, address receiver) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.assume(receiver != alphixHook && receiver != owner);

        uint256 maxDeposit = d.wrapper.maxDeposit(receiver);
        assertEq(maxDeposit, 0, "Unauthorized receiver should have zero max deposit");
    }

    /**
     * @notice Fuzz test that maxDeposit never reverts.
     * @param decimals The asset decimals (6-18).
     * @param receiver Random receiver address.
     */
    function testFuzz_maxDeposit_neverReverts(uint8 decimals, address receiver) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        // This should never revert per ERC4626 spec
        d.wrapper.maxDeposit(receiver);
    }

    /**
     * @notice Fuzz test that maxDeposit respects supply cap.
     * @param decimals The asset decimals (6-18).
     * @param supplyCap The supply cap in whole units.
     */
    function testFuzz_maxDeposit_respectsSupplyCap(uint8 decimals, uint256 supplyCap) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        supplyCap = bound(supplyCap, 10, 1_000_000); // 10 to 1M tokens

        d.aavePool.setReserveConfig(true, false, false, supplyCap);

        uint256 maxDeposit = d.wrapper.maxDeposit(alphixHook);
        uint256 expectedMax = (supplyCap * 10 ** d.decimals) - d.seedLiquidity;

        assertEq(maxDeposit, expectedMax, "Max deposit should respect supply cap");
    }

    /**
     * @notice Fuzz test that maxDeposit returns zero when reserve is frozen/paused.
     * @param decimals The asset decimals (6-18).
     * @param frozen Whether reserve is frozen.
     * @param paused Whether reserve is paused.
     */
    function testFuzz_maxDeposit_frozenOrPaused_returnsZero(uint8 decimals, bool frozen, bool paused) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        vm.assume(frozen || paused);

        d.aavePool.setReserveConfig(true, frozen, paused, 0);

        uint256 maxDeposit = d.wrapper.maxDeposit(alphixHook);
        assertEq(maxDeposit, 0, "Frozen or paused reserve should return zero");
    }
}
