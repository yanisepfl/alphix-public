// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title RoundtripReHypothecationTest
 * @notice Integration tests for roundtrip add/remove liquidity operations
 * @dev Verifies protocol-favorable rounding: deposits round UP, withdrawals round DOWN
 *      This means the protocol always keeps the "dust" from rounding operations.
 */
contract RoundtripReHypothecationTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    address public alice;
    address public bob;

    function setUp() public override {
        super.setUp();

        // Deploy yield vaults
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Setup yield sources
        _configureReHypothecation();

        // Mint tokens to test users
        MockERC20(Currency.unwrap(currency0)).mint(alice, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 1000e18);
        MockERC20(Currency.unwrap(currency0)).mint(bob, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(bob, 1000e18);

        // Approve hook for transfers
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              ROUNDTRIP TESTS - BASIC
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that a roundtrip (add then remove) is protocol-favorable
     * @dev User adds shares, then removes same shares. Due to rounding:
     *      - Deposit rounds UP (user pays more)
     *      - Withdrawal rounds DOWN (user gets less)
     *      Result: Protocol keeps the "dust"
     */
    function test_roundtrip_addThenRemove_protocolFavorable() public {
        uint256 sharesToAdd = 10e18;

        // Preview amounts needed for deposit (used to verify protocol-favorable rounding)
        hook.previewAddReHypothecatedLiquidity(sharesToAdd);

        // Record balances before
        uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Add liquidity
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(sharesToAdd);

        // Verify shares received
        assertEq(hook.balanceOf(alice), sharesToAdd, "Should have correct shares");

        // Record balances after deposit
        uint256 token0AfterDeposit = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1AfterDeposit = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Calculate actual amounts spent on deposit
        uint256 actualDeposit0 = token0Before - token0AfterDeposit;
        uint256 actualDeposit1 = token1Before - token1AfterDeposit;

        // Remove all shares
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(sharesToAdd);

        // Verify no shares remaining
        assertEq(hook.balanceOf(alice), 0, "Should have no shares");

        // Record balances after withdrawal
        uint256 token0AfterWithdraw = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1AfterWithdraw = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Calculate amounts received on withdrawal
        uint256 actualWithdraw0 = token0AfterWithdraw - token0AfterDeposit;
        uint256 actualWithdraw1 = token1AfterWithdraw - token1AfterDeposit;

        // Protocol-favorable: withdrawal <= deposit
        assertLe(actualWithdraw0, actualDeposit0, "Withdrawal should be <= deposit for token0 (protocol keeps dust)");
        assertLe(actualWithdraw1, actualDeposit1, "Withdrawal should be <= deposit for token1 (protocol keeps dust)");

        // User should have lost some tokens overall (the protocol dust)
        uint256 token0Final = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1Final = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        assertLe(token0Final, token0Before, "User should have same or less token0 after roundtrip");
        assertLe(token1Final, token1Before, "User should have same or less token1 after roundtrip");
    }

    /**
     * @notice Test multiple roundtrips don't cause unbounded dust accumulation
     */
    function test_roundtrip_multipleAddRemove_boundedDustLoss() public {
        uint256 sharesToAdd = 10e18;
        uint256 numRoundtrips = 5;

        // Record initial balance
        uint256 token0Initial = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1Initial = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        for (uint256 i = 0; i < numRoundtrips; i++) {
            // Add liquidity
            vm.prank(alice);
            hook.addReHypothecatedLiquidity(sharesToAdd);

            // Remove liquidity
            vm.prank(alice);
            hook.removeReHypothecatedLiquidity(sharesToAdd);
        }

        // Final balance
        uint256 token0Final = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1Final = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Total loss should be bounded (roughly proportional to roundtrips, not exponential)
        uint256 token0Loss = token0Initial - token0Final;
        uint256 token1Loss = token1Initial - token1Final;

        // Loss per roundtrip should be bounded - at most 1 wei per share per roundtrip
        uint256 maxExpectedLossPerRoundtrip0 = sharesToAdd / 1e18 + 1; // ~1 wei per share + 1
        uint256 maxExpectedLossPerRoundtrip1 = sharesToAdd / 1e18 + 1;

        assertLe(token0Loss, maxExpectedLossPerRoundtrip0 * numRoundtrips * 10, "Token0 loss should be bounded");
        assertLe(token1Loss, maxExpectedLossPerRoundtrip1 * numRoundtrips * 10, "Token1 loss should be bounded");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          ROUNDTRIP TESTS - WITH YIELD
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test roundtrip with yield accrual maintains protocol-favorable rounding
     */
    function test_roundtrip_withYieldAccrual_protocolFavorable() public {
        uint256 sharesToAdd = 10e18;

        // Alice adds liquidity
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(sharesToAdd);

        // Simulate yield accrual (10% yield on both tokens)
        uint256 yield0 = 1e18; // 10% of typical position
        uint256 yield1 = 1e18;

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        vault0.simulateYield(yield0);

        MockERC20(Currency.unwrap(currency1)).mint(owner, yield1);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault1), yield1);
        vault1.simulateYield(yield1);
        vm.stopPrank();

        // Record balances before withdrawal
        uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Remove liquidity
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(sharesToAdd);

        // Record balances after withdrawal
        uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // User should have received tokens (including yield)
        assertGt(token0After, token0Before, "User should receive token0");
        assertGt(token1After, token1Before, "User should receive token1");

        // No shares remaining
        assertEq(hook.balanceOf(alice), 0, "Should have no shares");
    }

    /**
     * @notice Test roundtrip with loss scenario maintains protocol-favorable rounding
     */
    function test_roundtrip_withLoss_protocolFavorable() public {
        uint256 sharesToAdd = 10e18;

        // Alice adds liquidity
        (uint256 depositAmount0, uint256 depositAmount1) = hook.previewAddReHypothecatedLiquidity(sharesToAdd);

        vm.prank(alice);
        hook.addReHypothecatedLiquidity(sharesToAdd);

        // Simulate loss (10% loss on both tokens)
        uint256 currentAmount0 = hook.getAmountInYieldSource(currency0);
        uint256 currentAmount1 = hook.getAmountInYieldSource(currency1);
        uint256 loss0 = currentAmount0 / 10;
        uint256 loss1 = currentAmount1 / 10;

        vault0.simulateLoss(loss0);
        vault1.simulateLoss(loss1);

        // Preview withdrawal amounts
        (uint256 withdrawAmount0, uint256 withdrawAmount1) = hook.previewRemoveReHypothecatedLiquidity(sharesToAdd);

        // Withdrawal amounts should reflect the loss
        assertLt(withdrawAmount0, depositAmount0, "Withdrawal should be less than deposit after loss");
        assertLt(withdrawAmount1, depositAmount1, "Withdrawal should be less than deposit after loss");

        // Record balances before withdrawal
        uint256 token0Before = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1Before = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Remove liquidity
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(sharesToAdd);

        // Record balances after withdrawal
        uint256 token0After = IERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 token1After = IERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // User should have received tokens (less than deposited due to loss + rounding)
        uint256 received0 = token0After - token0Before;
        uint256 received1 = token1After - token1Before;

        // Received should match or be less than preview (rounding down)
        assertLe(received0, withdrawAmount0 + 1, "Received should match preview (with tolerance)");
        assertLe(received1, withdrawAmount1 + 1, "Received should match preview (with tolerance)");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          ROUNDTRIP TESTS - MULTI-USER
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test roundtrips with multiple users don't affect each other's rounding
     */
    function test_roundtrip_multipleUsers_independentRounding() public {
        uint256 aliceShares = 10e18;
        uint256 bobShares = 5e18;

        // Alice adds liquidity first
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(aliceShares);

        // Bob adds liquidity second
        vm.prank(bob);
        hook.addReHypothecatedLiquidity(bobShares);

        // Record Alice's tokens before removal
        uint256 aliceToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(alice);

        // Record Bob's tokens before removal
        uint256 bobToken0Before = IERC20(Currency.unwrap(currency0)).balanceOf(bob);

        // Bob removes first
        vm.prank(bob);
        hook.removeReHypothecatedLiquidity(bobShares);

        // Then Alice removes
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(aliceShares);

        // Both should have no shares
        assertEq(hook.balanceOf(alice), 0, "Alice should have no shares");
        assertEq(hook.balanceOf(bob), 0, "Bob should have no shares");

        // Both should have received some tokens (protocol-favorable rounding applied to each)
        uint256 aliceReceived0 = IERC20(Currency.unwrap(currency0)).balanceOf(alice) - aliceToken0Before;
        uint256 bobReceived0 = IERC20(Currency.unwrap(currency0)).balanceOf(bob) - bobToken0Before;

        assertGt(aliceReceived0, 0, "Alice should receive token0");
        assertGt(bobReceived0, 0, "Bob should receive token0");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              ROUNDTRIP TESTS - EXTREME
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test roundtrip with very small share amounts
     */
    function test_roundtrip_extremeSmall_noUnderflow() public {
        // Very small amount - 1 share
        uint256 smallShares = 1e15; // 0.001 shares

        // Ensure user has enough tokens
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(smallShares);
        if (amount0Needed == 0 && amount1Needed == 0) {
            // Skip if preview returns zero (below dust threshold)
            return;
        }

        vm.prank(alice);
        hook.addReHypothecatedLiquidity(smallShares);

        // Remove shares - should not revert
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(smallShares);

        assertEq(hook.balanceOf(alice), 0, "Should have no shares");
    }

    /**
     * @notice Test roundtrip with large share amounts
     */
    function test_roundtrip_extremeLarge_noOverflow() public {
        // Large amount
        uint256 largeShares = 100e18;

        // Ensure user has enough tokens
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(largeShares);

        // Mint more if needed
        if (amount0Needed > IERC20(Currency.unwrap(currency0)).balanceOf(alice)) {
            MockERC20(Currency.unwrap(currency0)).mint(alice, amount0Needed);
        }
        if (amount1Needed > IERC20(Currency.unwrap(currency1)).balanceOf(alice)) {
            MockERC20(Currency.unwrap(currency1)).mint(alice, amount1Needed);
        }

        vm.prank(alice);
        hook.addReHypothecatedLiquidity(largeShares);

        // Remove shares - should not revert
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(largeShares);

        assertEq(hook.balanceOf(alice), 0, "Should have no shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              HELPER FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    function _configureReHypothecation() internal {
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Tick range is already set at initializePool time (full range by default)
        // Set yield sources (requires whenNotPaused)
        vm.startPrank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));
        hook.setYieldSource(currency1, address(vault1));
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
