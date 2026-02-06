// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/**
 * @title RescueTokensTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky rescueTokens functionality.
 */
contract RescueTokensTest is BaseAlphix4626WrapperSky {
    /* STATE */

    MockERC20 internal stuckToken;

    /* SETUP */

    function setUp() public override {
        super.setUp();

        // Deploy a token that could accidentally be sent to the wrapper
        stuckToken = new MockERC20("Stuck Token", "STUCK", 18);
    }

    /* HELPER */

    /**
     * @notice Simulates tokens being accidentally sent to the wrapper.
     * @param amount The amount of tokens to send.
     */
    function _simulateStuckTokens(uint256 amount) internal {
        stuckToken.mint(address(wrapper), amount);
    }

    /* RESCUE TOKENS TESTS */

    /**
     * @notice Tests that owner can rescue stuck tokens successfully.
     */
    function test_rescueTokens_succeeds() public {
        uint256 stuckAmount = 100e18;
        _simulateStuckTokens(stuckAmount);

        uint256 treasuryBalanceBefore = stuckToken.balanceOf(treasury);
        uint256 wrapperBalanceBefore = stuckToken.balanceOf(address(wrapper));

        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), stuckAmount);

        uint256 treasuryBalanceAfter = stuckToken.balanceOf(treasury);
        uint256 wrapperBalanceAfter = stuckToken.balanceOf(address(wrapper));

        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, stuckAmount, "Treasury should receive rescued tokens");
        assertEq(wrapperBalanceBefore - wrapperBalanceAfter, stuckAmount, "Wrapper balance should decrease");
        assertEq(wrapperBalanceAfter, 0, "Wrapper should have no stuck tokens left");
    }

    /**
     * @notice Tests that rescueTokens emits TokensRescued event.
     */
    function test_rescueTokens_emitsEvent() public {
        uint256 stuckAmount = 100e18;
        _simulateStuckTokens(stuckAmount);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit TokensRescued(address(stuckToken), stuckAmount);
        wrapper.rescueTokens(address(stuckToken), stuckAmount);
    }

    /**
     * @notice Tests that non-owner cannot rescue tokens.
     */
    function test_rescueTokens_revertsIfNotOwner() public {
        _simulateStuckTokens(100e18);

        vm.prank(unauthorized);
        vm.expectRevert();
        wrapper.rescueTokens(address(stuckToken), 100e18);
    }

    /**
     * @notice Tests that rescueTokens reverts if trying to rescue sUSDS.
     */
    function test_rescueTokens_revertsIfSusds() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.InvalidToken.selector);
        wrapper.rescueTokens(address(susds), 100e18);
    }

    /**
     * @notice Tests that rescueTokens reverts if amount is zero.
     */
    function test_rescueTokens_revertsIfZeroAmount() public {
        _simulateStuckTokens(100e18);

        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.ZeroAmount.selector);
        wrapper.rescueTokens(address(stuckToken), 0);
    }

    /**
     * @notice Tests that rescueTokens can rescue partial amounts.
     */
    function test_rescueTokens_partialAmount_succeeds() public {
        uint256 stuckAmount = 100e18;
        uint256 rescueAmount = 40e18;
        _simulateStuckTokens(stuckAmount);

        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), rescueAmount);

        assertEq(stuckToken.balanceOf(treasury), rescueAmount, "Treasury should receive partial amount");
        assertEq(stuckToken.balanceOf(address(wrapper)), stuckAmount - rescueAmount, "Wrapper should have remaining");
    }

    /**
     * @notice Tests that rescueTokens can be called multiple times.
     */
    function test_rescueTokens_multipleCalls_succeeds() public {
        uint256 stuckAmount = 100e18;
        _simulateStuckTokens(stuckAmount);

        // First rescue
        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), 30e18);

        // Second rescue
        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), 30e18);

        // Third rescue
        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), 40e18);

        assertEq(stuckToken.balanceOf(treasury), stuckAmount, "Treasury should receive all rescued tokens");
        assertEq(stuckToken.balanceOf(address(wrapper)), 0, "Wrapper should have no stuck tokens");
    }

    /**
     * @notice Tests that hook cannot rescue tokens.
     */
    function test_rescueTokens_hookCannotRescue() public {
        _simulateStuckTokens(100e18);

        vm.prank(alphixHook);
        vm.expectRevert();
        wrapper.rescueTokens(address(stuckToken), 100e18);
    }

    /**
     * @notice Tests that rescueTokens works with the underlying asset USDS.
     */
    function test_rescueTokens_underlyingAsset_succeeds() public {
        // Someone accidentally sends USDS directly to wrapper (not through deposit)
        uint256 stuckAmount = 50e18;
        usds.mint(address(wrapper), stuckAmount);

        uint256 treasuryUsdsBefore = usds.balanceOf(treasury);

        vm.prank(owner);
        wrapper.rescueTokens(address(usds), stuckAmount);

        assertEq(usds.balanceOf(treasury) - treasuryUsdsBefore, stuckAmount, "Treasury should receive USDS");
    }

    /**
     * @notice Tests that rescueTokens sends to correct treasury after treasury change.
     */
    function test_rescueTokens_afterTreasuryChange_sendsToNewTreasury() public {
        uint256 stuckAmount = 100e18;
        _simulateStuckTokens(stuckAmount);

        // Change treasury
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        wrapper.setYieldTreasury(newTreasury);

        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), stuckAmount);

        assertEq(stuckToken.balanceOf(treasury), 0, "Old treasury should not receive tokens");
        assertEq(stuckToken.balanceOf(newTreasury), stuckAmount, "New treasury should receive tokens");
    }

    /**
     * @notice Tests that rescueTokens works when contract is paused.
     */
    function test_rescueTokens_succeedsWhenPaused() public {
        uint256 stuckAmount = 100e18;
        _simulateStuckTokens(stuckAmount);

        vm.prank(owner);
        wrapper.pause();

        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), stuckAmount);

        assertEq(stuckToken.balanceOf(treasury), stuckAmount, "Should rescue tokens even when paused");
    }

    /**
     * @notice Tests that rescueTokens doesn't affect wrapper state (totalAssets, fees, etc.).
     */
    function test_rescueTokens_doesNotAffectWrapperState() public {
        // Setup some deposits first
        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 totalAssetsBefore = wrapper.totalAssets();
        uint256 feesBefore = wrapper.getClaimableFees();
        uint256 susdsBalanceBefore = susds.balanceOf(address(wrapper));
        uint256 sharesBefore = wrapper.balanceOf(alphixHook);

        // Rescue stuck tokens
        _simulateStuckTokens(100e18);
        vm.prank(owner);
        wrapper.rescueTokens(address(stuckToken), 100e18);

        // Verify wrapper state unchanged
        assertEq(wrapper.totalAssets(), totalAssetsBefore, "totalAssets should not change");
        assertEq(wrapper.getClaimableFees(), feesBefore, "Claimable fees should not change");
        assertEq(susds.balanceOf(address(wrapper)), susdsBalanceBefore, "sUSDS balance should not change");
        assertEq(wrapper.balanceOf(alphixHook), sharesBefore, "Share balance should not change");
    }

    /**
     * @notice Tests that rescueTokens reverts if insufficient balance.
     */
    function test_rescueTokens_revertsIfInsufficientBalance() public {
        uint256 stuckAmount = 100e18;
        _simulateStuckTokens(stuckAmount);

        vm.prank(owner);
        vm.expectRevert(); // Will revert on transfer
        wrapper.rescueTokens(address(stuckToken), stuckAmount + 1);
    }

    /**
     * @notice Tests rescueTokens with different token decimals.
     */
    function test_rescueTokens_differentDecimals_succeeds() public {
        // Create a token with 8 decimals (like WBTC)
        MockERC20 wbtcLike = new MockERC20("WBTC-like", "WBTC", 8);
        uint256 stuckAmount = 1e8; // 1 token

        wbtcLike.mint(address(wrapper), stuckAmount);

        vm.prank(owner);
        wrapper.rescueTokens(address(wbtcLike), stuckAmount);

        assertEq(wbtcLike.balanceOf(treasury), stuckAmount, "Treasury should receive tokens");
    }

    /**
     * @notice Tests that rescueTokens works with wrapper's own share token (edge case).
     */
    function test_rescueTokens_wrapperShareToken_succeeds() public {
        // Someone accidentally sends wrapper shares to the wrapper itself
        // First, get some shares
        _depositAsHook(1000e18, alphixHook);

        // Transfer shares to wrapper (simulating accidental send)
        uint256 sharesToRescue = wrapper.balanceOf(alphixHook) / 2;
        vm.prank(alphixHook);
        assertTrue(wrapper.transfer(address(wrapper), sharesToRescue), "Transfer should succeed");

        uint256 treasurySharesBefore = wrapper.balanceOf(treasury);

        vm.prank(owner);
        wrapper.rescueTokens(address(wrapper), sharesToRescue);

        assertEq(wrapper.balanceOf(treasury) - treasurySharesBefore, sharesToRescue, "Treasury should receive shares");
    }

    /* EDGE CASES - ZERO TREASURY */

    /**
     * @notice Tests that rescueTokens reverts if treasury is set to zero address.
     * @dev This tests the branch at line 645: `if (_yieldTreasury == address(0)) revert InvalidAddress()`
     */
    function test_rescueTokens_zeroTreasury_reverts() public {
        _simulateStuckTokens(100e18);

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

        // rescueTokens should revert with InvalidAddress
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperSky.InvalidAddress.selector);
        wrapper.rescueTokens(address(stuckToken), 100e18);
    }
}
