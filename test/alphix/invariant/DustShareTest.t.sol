// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Test.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {BaseAlphixTest} from "../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../src/AlphixLogic.sol";
import {MockYieldVault} from "../../utils/mocks/MockYieldVault.sol";

contract DustShareTest is BaseAlphixTest {
    MockYieldVault public vault0;
    MockYieldVault public vault1;

    function setUp() public override {
        super.setUp();

        vm.startPrank(owner);
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        _setupYieldManagerRole(owner, accessManager, address(logic));

        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);
        AlphixLogic(address(logic)).setYieldTaxPips(100_000);
        AlphixLogic(address(logic)).setYieldTreasury(owner);
        vm.stopPrank();
    }

    function test_dustSharesScenario() public {
        // User1 deposits a large amount
        uint256 largeShares = 1000e18;
        (uint256 amount0Large, uint256 amount1Large) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(largeShares);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0Large);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1Large);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0Large);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1Large);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(largeShares);
        vm.stopPrank();

        console.log("After large deposit:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0 in vault:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1 in vault:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // Now user1 withdraws almost all, leaving 1 wei of shares
        uint256 toWithdraw = largeShares - 1; // Leave 1 wei of shares

        console.log("\nWithdrawing all but 1 share...");

        (uint256 preview0, uint256 preview1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(toWithdraw);
        console.log("  Preview withdraw amount0:", preview0);
        console.log("  Preview withdraw amount1:", preview1);

        vm.prank(user1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(toWithdraw);

        console.log("\nAfter withdrawing all but 1 share:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  User1 balance:", AlphixLogic(address(logic)).balanceOf(user1));
        console.log("  Amount0 in vault:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1 in vault:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // Now try to withdraw the last 1 share
        (uint256 preview0Last, uint256 preview1Last) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(1);
        console.log("\nPreview for last 1 share:");
        console.log("  Preview amount0:", preview0Last);
        console.log("  Preview amount1:", preview1Last);

        // The issue: if preview is 0, user burns shares but gets nothing
        if (preview0Last == 0 && preview1Last == 0) {
            console.log("  WARNING: 1 share would give 0 assets (dust scenario)");
        }
    }

    function test_manySmallWithdrawals_leaveDust() public {
        // User1 deposits
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        console.log("Initial state:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // Withdraw in chunks, but leave 1 wei each time
        uint256 currentBalance = AlphixLogic(address(logic)).balanceOf(user1);
        uint256 withdrawCount = 0;

        while (currentBalance > 1) {
            uint256 toWithdraw = currentBalance - 1;
            vm.prank(user1);
            AlphixLogic(address(logic)).removeReHypothecatedLiquidity(toWithdraw);

            currentBalance = AlphixLogic(address(logic)).balanceOf(user1);
            withdrawCount++;

            if (withdrawCount > 10) break; // Safety limit
        }

        console.log("\nAfter", withdrawCount, "withdrawals:");
        console.log("  Remaining shares:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0 left:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1 left:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // Check what 1 share is worth
        (uint256 finalPreview0, uint256 finalPreview1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(1);
        console.log("  1 share worth: amount0 =", finalPreview0, ", amount1 =", finalPreview1);
    }

    function test_dustFromLoss() public {
        // User1 and User2 both deposit
        uint256 shares = 100e18;

        // User1 deposits
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // User2 deposits
        (uint256 amount0User2, uint256 amount1User2) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).mint(user2, amount0User2);
        MockERC20(Currency.unwrap(currency1)).mint(user2, amount1User2);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User2);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User2);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        console.log("Before loss:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // Simulate 99% loss on both currencies
        uint256 vault0Bal = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 vault1Bal = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);
        vault0.simulateLoss((vault0Bal * 99) / 100);
        vault1.simulateLoss((vault1Bal * 99) / 100);

        console.log("\nAfter 99% loss:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // User1 withdraws all their shares
        uint256 user1Shares = AlphixLogic(address(logic)).balanceOf(user1);
        (uint256 preview0, uint256 preview1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(user1Shares);
        console.log("\nUser1 preview for", user1Shares, "shares:");
        console.log("  amount0:", preview0);
        console.log("  amount1:", preview1);

        vm.prank(user1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(user1Shares);

        console.log("\nAfter User1 withdrawal:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // User2 should still have backing
        uint256 user2Shares = AlphixLogic(address(logic)).balanceOf(user2);
        (uint256 preview0User2, uint256 preview1User2) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(user2Shares);
        console.log("  User2 shares:", user2Shares);
        console.log("  User2 worth amount0:", preview0User2);
        console.log("  User2 worth amount1:", preview1User2);
    }

    function test_extremeDust_partialWithdrawal() public {
        // Scenario: After multiple operations, totalSupply >> totalAssets due to rounding losses

        // User1 deposits large amount
        uint256 largeShares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(largeShares);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(largeShares);
        vm.stopPrank();

        // Simulate many partial withdrawals to accumulate rounding errors
        for (uint256 i = 0; i < 50; i++) {
            uint256 balance = AlphixLogic(address(logic)).balanceOf(user1);
            if (balance <= 1e18) break;

            // Withdraw random amounts
            uint256 toWithdraw = balance / 3;
            if (toWithdraw == 0) break;

            vm.prank(user1);
            AlphixLogic(address(logic)).removeReHypothecatedLiquidity(toWithdraw);
        }

        console.log("After many partial withdrawals:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  User1 shares:", AlphixLogic(address(logic)).balanceOf(user1));
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        uint256 finalShares = AlphixLogic(address(logic)).balanceOf(user1);
        (uint256 finalPreview0, uint256 finalPreview1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(finalShares);
        console.log("  Final shares worth: amount0 =", finalPreview0, ", amount1 =", finalPreview1);

        // Now the key question: can 1 share have 0 backing?
        if (finalShares >= 1) {
            (uint256 oneShareWorth0, uint256 oneShareWorth1) =
                AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(1);
            console.log("  1 share worth: amount0 =", oneShareWorth0, ", amount1 =", oneShareWorth1);

            // This is when the invariant could fail
            if (oneShareWorth0 == 0 && oneShareWorth1 == 0) {
                console.log("  FOUND: 1 share has no backing!");
            }
        }
    }

    /**
     * @notice Test: multi-user scenario where one user gets 0 from withdrawal
     * @dev This tests your exact concern: user burns shares but gets nothing back
     */
    function test_userGetsZeroFromWithdrawal() public {
        // Setup: User1 deposits large amount, User2 deposits tiny amount
        uint256 largeShares = 1000e18;
        uint256 tinyShares = 1; // 1 wei of shares

        // User1 large deposit
        (uint256 amount0Large, uint256 amount1Large) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(largeShares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0Large);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1Large);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0Large);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1Large);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(largeShares);
        vm.stopPrank();

        console.log("After User1 large deposit:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));

        // User2 tiny deposit (1 wei of shares)
        // Need to preview first
        (uint256 amount0Tiny, uint256 amount1Tiny) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(tinyShares);
        console.log("\nUser2 wants 1 wei of shares, needs:");
        console.log("  amount0:", amount0Tiny);
        console.log("  amount1:", amount1Tiny);

        if (amount0Tiny > 0 || amount1Tiny > 0) {
            vm.startPrank(user2);
            MockERC20(Currency.unwrap(currency0)).mint(user2, amount0Tiny);
            MockERC20(Currency.unwrap(currency1)).mint(user2, amount1Tiny);
            MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0Tiny);
            MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1Tiny);
            AlphixLogic(address(logic)).addReHypothecatedLiquidity(tinyShares);
            vm.stopPrank();
        }

        // User2 tries to withdraw their 1 share
        uint256 user2Balance = AlphixLogic(address(logic)).balanceOf(user2);
        console.log("\nUser2 balance:", user2Balance);

        if (user2Balance > 0) {
            (uint256 preview0, uint256 preview1) =
                AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(user2Balance);
            console.log("User2 withdrawal preview:");
            console.log("  amount0:", preview0);
            console.log("  amount1:", preview1);

            // This is the key check: can user2 burn shares but get 0 back?
            if (preview0 == 0 && preview1 == 0) {
                console.log("  DANGER: User would burn shares but get 0 assets!");
            }
        }
    }

    /**
     * @notice Test: Combined loss + rounding creates unbacked shares
     */
    function test_lossAndRounding_createsUnbackedShares() public {
        // User1 deposits large amount
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).mint(user1, amount0);
        MockERC20(Currency.unwrap(currency1)).mint(user1, amount1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate near-total loss
        uint256 vault0Bal = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 vault1Bal = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);
        vault0.simulateLoss(vault0Bal - 1); // Leave only 1 wei
        vault1.simulateLoss(vault1Bal - 1); // Leave only 1 wei

        console.log("After near-total loss:");
        console.log("  Total supply:", AlphixLogic(address(logic)).totalSupply());
        console.log("  Amount0:", AlphixLogic(address(logic)).getAmountInYieldSource(currency0));
        console.log("  Amount1:", AlphixLogic(address(logic)).getAmountInYieldSource(currency1));

        // Now: 1000e18 shares backed by only 2 wei total (1 wei each currency)
        // 1 share is worth: 1 * 1 / 1000e18 = 0 (rounds down)
        (uint256 oneShareWorth0, uint256 oneShareWorth1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(1);
        console.log("\n1 share worth:");
        console.log("  amount0:", oneShareWorth0);
        console.log("  amount1:", oneShareWorth1);

        // With 1000e18 shares and only 1 wei of each asset:
        // To get 1 wei, you need at least 1000e18 shares
        // So any withdrawal < 1000e18 shares rounds to 0

        // What about 1e18 shares (1 full share)?
        (uint256 fullShareWorth0, uint256 fullShareWorth1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(1e18);
        console.log("\n1e18 shares (1 full share) worth:");
        console.log("  amount0:", fullShareWorth0);
        console.log("  amount1:", fullShareWorth1);

        // What about half the supply?
        (uint256 halfWorth0, uint256 halfWorth1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(500e18);
        console.log("\n500e18 shares worth:");
        console.log("  amount0:", halfWorth0);
        console.log("  amount1:", halfWorth1);

        // What about exactly totalSupply (all shares)?
        (uint256 allWorth0, uint256 allWorth1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares);
        console.log("\nAll 1000e18 shares worth:");
        console.log("  amount0:", allWorth0);
        console.log("  amount1:", allWorth1);
    }
}
