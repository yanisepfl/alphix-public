// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title MaxDepositTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave maxDeposit function.
 */
contract MaxDepositTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that maxDeposit returns max for the hook.
     */
    function test_maxDeposit_forHook_returnsMax() public view {
        uint256 maxDeposit = wrapper.maxDeposit(alphixHook);
        assertEq(maxDeposit, type(uint256).max, "Hook should have unlimited deposit");
    }

    /**
     * @notice Tests that maxDeposit returns max for the owner.
     */
    function test_maxDeposit_forOwner_returnsMax() public view {
        uint256 maxDeposit = wrapper.maxDeposit(owner);
        assertEq(maxDeposit, type(uint256).max, "Owner should have unlimited deposit");
    }

    /**
     * @notice Tests that maxDeposit returns zero for unauthorized addresses.
     */
    function test_maxDeposit_forUnauthorized_returnsZero() public view {
        uint256 maxDeposit = wrapper.maxDeposit(alice);
        assertEq(maxDeposit, 0, "Unauthorized should have zero max deposit");
    }

    /**
     * @notice Tests that maxDeposit returns zero for zero address.
     */
    function test_maxDeposit_forZeroAddress_returnsZero() public view {
        uint256 maxDeposit = wrapper.maxDeposit(address(0));
        assertEq(maxDeposit, 0, "Zero address should have zero max deposit");
    }

    /**
     * @notice Tests maxDeposit when Aave reserve is frozen.
     */
    function test_maxDeposit_reserveFrozen_returnsZero() public {
        // Set reserve to frozen
        aavePool.setReserveConfig(true, true, false, 0); // active, frozen, not paused

        uint256 maxDeposit = wrapper.maxDeposit(alphixHook);
        assertEq(maxDeposit, 0, "Frozen reserve should return zero");
    }

    /**
     * @notice Tests maxDeposit when Aave reserve is paused.
     */
    function test_maxDeposit_reservePaused_returnsZero() public {
        // Set reserve to paused
        aavePool.setReserveConfig(true, false, true, 0); // active, not frozen, paused

        uint256 maxDeposit = wrapper.maxDeposit(alphixHook);
        assertEq(maxDeposit, 0, "Paused reserve should return zero");
    }

    /**
     * @notice Tests maxDeposit when Aave reserve is not active.
     */
    function test_maxDeposit_reserveNotActive_returnsZero() public {
        // Set reserve to not active
        aavePool.setReserveConfig(false, false, false, 0); // not active

        uint256 maxDeposit = wrapper.maxDeposit(alphixHook);
        assertEq(maxDeposit, 0, "Inactive reserve should return zero");
    }

    /**
     * @notice Tests maxDeposit with supply cap.
     */
    function test_maxDeposit_withSupplyCap() public {
        // Set supply cap to 1000 tokens (in whole units)
        uint256 supplyCap = 1000;
        aavePool.setReserveConfig(true, false, false, supplyCap);

        uint256 maxDeposit = wrapper.maxDeposit(alphixHook);
        // Should be supply cap minus current supply
        // Current supply is DEFAULT_SEED_LIQUIDITY (1e6)
        uint256 expectedMax = (supplyCap * 10 ** DEFAULT_DECIMALS) - DEFAULT_SEED_LIQUIDITY;
        assertEq(maxDeposit, expectedMax, "Max deposit with supply cap mismatch");
    }

    /**
     * @notice Tests maxDeposit does not revert (ERC4626 requirement).
     */
    function test_maxDeposit_doesNotRevert() public view {
        // This should never revert per ERC4626 spec
        wrapper.maxDeposit(alice);
        wrapper.maxDeposit(alphixHook);
        wrapper.maxDeposit(owner);
        wrapper.maxDeposit(address(0));
    }
}
