// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperWethAave} from "../../BaseAlphix4626WrapperWethAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title RedeemETHTest
 * @author Alphix
 * @notice Unit tests for Alphix4626WrapperWethAave.redeemETH().
 */
contract RedeemETHTest is BaseAlphix4626WrapperWethAave {
    /* SETUP */

    function setUp() public override {
        super.setUp();
        // Deposit some ETH first so we have shares to redeem
        _depositETHAsHook(10 ether);
    }

    /* SUCCESS CASES */

    /**
     * @notice Test basic redeemETH success.
     */
    function test_redeemETH_success() public {
        uint256 sharesToRedeem = 1 ether; // 1 share
        uint256 hookBalanceBefore = alphixHook.balance;
        uint256 sharesBefore = wethWrapper.balanceOf(alphixHook);

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(sharesToRedeem, alphixHook, alphixHook);

        // Shares should be burned
        assertEq(wethWrapper.balanceOf(alphixHook), sharesBefore - sharesToRedeem, "Shares not burned");

        // ETH should be received
        assertGt(assetsReceived, 0, "No assets received");
        assertEq(alphixHook.balance, hookBalanceBefore + assetsReceived, "ETH not received");
    }

    /**
     * @notice Test redeemETH to different receiver.
     */
    function test_redeemETH_toDifferentReceiver() public {
        uint256 sharesToRedeem = 1 ether;
        uint256 bobBalanceBefore = bob.balance;

        vm.prank(alphixHook);
        uint256 assetsReceived = wethWrapper.redeemETH(sharesToRedeem, bob, alphixHook);

        // Bob should receive ETH
        assertEq(bob.balance, bobBalanceBefore + assetsReceived, "Bob did not receive ETH");
    }

    /**
     * @notice Test redeemETH emits correct event.
     */
    function test_redeemETH_emitsEvent() public {
        uint256 sharesToRedeem = 1 ether;
        uint256 expectedAssets = wethWrapper.previewRedeem(sharesToRedeem);

        vm.expectEmit(true, true, true, true);
        emit WithdrawETH(alphixHook, alphixHook, alphixHook, expectedAssets, sharesToRedeem);

        vm.prank(alphixHook);
        wethWrapper.redeemETH(sharesToRedeem, alphixHook, alphixHook);
    }

    /**
     * @notice Test redeemETH all shares.
     */
    function test_redeemETH_allShares() public {
        uint256 allShares = wethWrapper.balanceOf(alphixHook);

        vm.prank(alphixHook);
        uint256 assets = wethWrapper.redeemETH(allShares, alphixHook, alphixHook);

        assertGt(assets, 0, "No assets received");
        assertEq(wethWrapper.balanceOf(alphixHook), 0, "Shares not fully burned");
    }

    /* REVERT CASES */

    /**
     * @notice Test redeemETH reverts if owner != msg.sender.
     * @dev Uses owner (authorized) trying to redeem alphixHook's shares.
     */
    function test_redeemETH_revertsIfOwnerNotMsgSender() public {
        // Owner is authorized but trying to redeem alphixHook's shares
        vm.prank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.CallerNotOwner.selector);
        wethWrapper.redeemETH(1 ether, owner, alphixHook);
    }

    /**
     * @notice Test redeemETH reverts if exceeds max.
     */
    function test_redeemETH_revertsIfExceedsMax() public {
        uint256 maxRedeem = wethWrapper.maxRedeem(alphixHook);

        vm.prank(alphixHook);
        vm.expectRevert(IAlphix4626WrapperAave.RedeemExceedsMax.selector);
        wethWrapper.redeemETH(maxRedeem + 1, alphixHook, alphixHook);
    }

    /**
     * @notice Test redeemETH reverts if unauthorized.
     */
    function test_redeemETH_revertsIfUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        wethWrapper.redeemETH(1 ether, unauthorized, unauthorized);
    }

    /**
     * @notice Test redeemETH reverts if paused.
     */
    function test_redeemETH_revertsIfPaused() public {
        vm.prank(owner);
        wethWrapper.pause();

        vm.prank(alphixHook);
        vm.expectRevert();
        wethWrapper.redeemETH(1 ether, alphixHook, alphixHook);
    }

    /* INTEGRATION WITH YIELD */

    /**
     * @notice Test redeemETH after yield gives more assets.
     */
    function test_redeemETH_afterYield() public {
        uint256 sharesToRedeem = 1 ether;

        // Get assets before yield
        uint256 assetsBefore = wethWrapper.previewRedeem(sharesToRedeem);

        // Simulate 20% yield
        _simulateYieldPercent(20);

        // Get assets after yield
        uint256 assetsAfter = wethWrapper.previewRedeem(sharesToRedeem);

        // Should get more assets after yield (accounting for fee)
        assertGt(assetsAfter, assetsBefore, "Should get more assets after yield");
    }
}
