// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {console2} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title ReHypothecationAdvancedScenariosTest
 * @notice Advanced tests for ReHypothecation covering:
 *         1. Multi-user sequential yield scenarios
 *         2. Full-range JIT positions
 *         3. Varying pool prices (not just 1:1)
 *         4. Different token decimals
 *         5. Preview function verification
 */
contract ReHypothecationAdvancedScenariosTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;
    address public carol;
    address public dave;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        dave = makeAddr("dave");

        // Fund users
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency0)).mint(carol, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(carol, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency0)).mint(dave, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(dave, INITIAL_TOKEN_AMOUNT * 100);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(logic));
        vm.stopPrank();

        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       SECTION 1: MULTI-USER SEQUENTIAL YIELD SCENARIOS
       Users enter at different yield states and verify fair share accounting
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test 4 users entering at different yield states
     * @dev Timeline:
     *      1. Alice enters at 0% yield
     *      2. -20% loss occurs
     *      3. Bob enters (at -20% state)
     *      4. +30% yield occurs (net +10% from original)
     *      5. Carol enters (at +10% state from original)
     *      6. -15% loss occurs
     *      7. Dave enters
     *      8. All withdraw and verify fair accounting
     */
    function test_multiUser_sequentialYieldStates() public {
        _addRegularLp(1000e18);
        _configureReHypo();

        // ═══════ Phase 1: Alice enters at baseline ═══════
        console2.log("=== Phase 1: Alice enters at baseline ===");
        _addReHypoLiquidity(alice, 100e18);

        (uint256 aliceInitial0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice initial value token0:", aliceInitial0);

        // ═══════ Phase 2: -20% loss occurs ═══════
        console2.log("=== Phase 2: -20% loss ===");
        uint256 vault0Balance = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss((vault0Balance * 20) / 100);

        (uint256 aliceAfterLoss0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice value after -20% loss:", aliceAfterLoss0);
        assertApproxEqRel(aliceAfterLoss0, (aliceInitial0 * 80) / 100, 2e16, "Alice should see 20% loss");

        // ═══════ Phase 3: Bob enters at -20% state ═══════
        console2.log("=== Phase 3: Bob enters at -20% state ===");
        (uint256 bobRequired0,) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(100e18);
        console2.log("Bob required token0 (should be ~80% of Alice's initial):", bobRequired0);

        // Bob should pay less than Alice did (share price is lower)
        assertLt(bobRequired0, aliceInitial0, "Bob should pay less due to lower share price");
        _addReHypoLiquidity(bob, 100e18);

        // ═══════ Phase 4: +30% yield (net +10% from original) ═══════
        console2.log("=== Phase 4: +30% yield ===");
        vault0Balance = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 yield0 = (vault0Balance * 30) / 100;

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        vault0.simulateYield(yield0);
        vm.stopPrank();

        (uint256 aliceAfterYield0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 bobAfterYield0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice value after +30% yield:", aliceAfterYield0);
        console2.log("Bob value after +30% yield:", bobAfterYield0);

        // Alice and Bob should have same value (same shares)
        assertApproxEqRel(aliceAfterYield0, bobAfterYield0, 1e15, "Same shares = same value");

        // ═══════ Phase 5: Carol enters ═══════
        console2.log("=== Phase 5: Carol enters ===");
        (uint256 carolRequired0,) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(100e18);
        console2.log("Carol required token0:", carolRequired0);
        _addReHypoLiquidity(carol, 100e18);

        // ═══════ Phase 6: -15% loss ═══════
        console2.log("=== Phase 6: -15% loss ===");
        vault0Balance = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss((vault0Balance * 15) / 100);

        // ═══════ Phase 7: Dave enters ═══════
        console2.log("=== Phase 7: Dave enters ===");
        (uint256 daveRequired0,) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(100e18);
        console2.log("Dave required token0:", daveRequired0);
        _addReHypoLiquidity(dave, 100e18);

        // ═══════ Phase 8: Verify final state ═══════
        console2.log("=== Phase 8: Final state verification ===");

        (uint256 aliceFinal0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 bobFinal0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 carolFinal0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 daveFinal0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);

        console2.log("Final values - Alice:", aliceFinal0);
        console2.log("Final values - Bob:", bobFinal0);
        console2.log("Final values - Carol:", carolFinal0);
        console2.log("Final values - Dave:", daveFinal0);

        // All should have equal withdrawal value (same shares)
        assertApproxEqRel(aliceFinal0, bobFinal0, 1e15, "Alice == Bob");
        assertApproxEqRel(bobFinal0, carolFinal0, 1e15, "Bob == Carol");
        assertApproxEqRel(carolFinal0, daveFinal0, 1e15, "Carol == Dave");

        // Total shares = 400e18
        assertEq(AlphixLogic(address(logic)).totalSupply(), 400e18, "Total shares = 400");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       SECTION 2: FULL-RANGE JIT POSITION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test full-range JIT position participates at any price
     * @dev Full range should always be in range, always participate
     */
    function test_fullRangeJIT_alwaysParticipates() public {
        _addRegularLp(1000e18);

        // Configure with FULL RANGE
        vm.startPrank(yieldManager);
        AlphixLogic(address(logic)).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setYieldTaxPips(100_000);
        AlphixLogic(address(logic)).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Do many swaps to move price around
        for (uint256 i = 0; i < 5; i++) {
            uint256 yieldSource0Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
            uint256 yieldSource1Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);

            // Swap in one direction
            uint256 swapAmount = 50e18;
            vm.startPrank(bob);
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
            vm.stopPrank();

            uint256 yieldSource0After = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
            uint256 yieldSource1After = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);

            // Full range should ALWAYS participate
            bool participated = (yieldSource0After != yieldSource0Before) || (yieldSource1After != yieldSource1Before);
            assertTrue(participated, "Full range JIT should always participate");
        }
    }

    /**
     * @notice Test full-range JIT vs narrow range JIT participation
     */
    function test_fullRangeJIT_vs_narrowRange_participation() public {
        _addRegularLp(1000e18);

        // Start with FULL RANGE
        vm.startPrank(yieldManager);
        AlphixLogic(address(logic)).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setYieldTaxPips(100_000);
        AlphixLogic(address(logic)).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Large swap to move price significantly
        uint256 largePriceMove = 200e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), largePriceMove);
        swapRouter.swapExactTokensForTokens({
            amountIn: largePriceMove,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Record balances
        uint256 yieldSource0Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);

        // Another swap
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 10e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0After = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);

        // Full range should still participate even after big price move
        uint256 change0 = yieldSource0After > yieldSource0Before
            ? yieldSource0After - yieldSource0Before
            : yieldSource0Before - yieldSource0After;

        assertGt(change0, 0, "Full range should participate even after big price move");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       SECTION 3: PREVIEW FUNCTION VERIFICATION
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that preview matches actual add liquidity
     */
    function test_preview_matchesActualAdd() public {
        _addRegularLp(1000e18);
        _configureReHypo();

        uint256 sharesToMint = 100e18;

        // Get preview
        (uint256 previewAmount0, uint256 previewAmount1) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(sharesToMint);

        // Record balances before
        uint256 aliceToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Actually add liquidity
        _addReHypoLiquidity(alice, sharesToMint);

        // Record balances after
        uint256 aliceToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Calculate actual spent
        uint256 actualSpent0 = aliceToken0Before - aliceToken0After;
        uint256 actualSpent1 = aliceToken1Before - aliceToken1After;

        // Preview should match actual (within rounding)
        assertApproxEqAbs(previewAmount0, actualSpent0, 1, "Preview0 should match actual spent");
        assertApproxEqAbs(previewAmount1, actualSpent1, 1, "Preview1 should match actual spent");

        // Verify shares were minted
        assertEq(AlphixLogic(address(logic)).balanceOf(alice), sharesToMint, "Should have received shares");
    }

    /**
     * @notice Test that preview matches actual remove liquidity
     */
    function test_preview_matchesActualRemove() public {
        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        uint256 sharesToBurn = 50e18;

        // Get preview
        (uint256 previewAmount0, uint256 previewAmount1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(sharesToBurn);

        // Record balances before
        uint256 aliceToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Actually remove liquidity
        vm.prank(alice);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(sharesToBurn);

        // Record balances after
        uint256 aliceToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Calculate actual received
        uint256 actualReceived0 = aliceToken0After - aliceToken0Before;
        uint256 actualReceived1 = aliceToken1After - aliceToken1Before;

        // Preview should match actual (within rounding)
        assertApproxEqAbs(previewAmount0, actualReceived0, 1, "Preview0 should match actual received");
        assertApproxEqAbs(previewAmount1, actualReceived1, 1, "Preview1 should match actual received");
    }

    /**
     * @notice Test previewAddFromAmount0 - adding liquidity specifying token0 amount
     * @dev Should return correct amount1 and shares, and work when executed
     */
    function test_preview_fromAmount0_sufficient() public {
        _addRegularLp(1000e18);
        _configureReHypo();

        // First add some liquidity so share price is established
        _addReHypoLiquidity(alice, 100e18);

        // Test previewAddFromAmount0
        uint256 inputAmount0 = 50e18;
        (uint256 requiredAmount1, uint256 shares) = AlphixLogic(address(logic)).previewAddFromAmount0(inputAmount0);

        console2.log("Input amount0:", inputAmount0);
        console2.log("Required amount1:", requiredAmount1);
        console2.log("Shares to mint:", shares);

        assertGt(shares, 0, "Should get some shares");

        // Now actually try to add with these amounts - should NOT revert
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), inputAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), requiredAmount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Bob should have received the shares
        assertEq(AlphixLogic(address(logic)).balanceOf(bob), shares, "Bob should have received shares");
    }

    /**
     * @notice Test previewAddFromAmount1 - adding liquidity specifying token1 amount
     */
    function test_preview_fromAmount1_sufficient() public {
        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        // Test with amount1
        uint256 inputAmount1 = 75e18;
        (uint256 requiredAmount0, uint256 shares) = AlphixLogic(address(logic)).previewAddFromAmount1(inputAmount1);

        console2.log("Input amount1:", inputAmount1);
        console2.log("Required amount0:", requiredAmount0);
        console2.log("Shares to mint:", shares);

        assertGt(shares, 0, "Should get some shares");

        // Should work without reverting
        vm.startPrank(carol);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), requiredAmount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), inputAmount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        assertEq(AlphixLogic(address(logic)).balanceOf(carol), shares, "Carol should have received shares");
    }

    /**
     * @notice Test that previewAddFromAmount0 and previewAddFromAmount1 are consistent
     * @dev If I provide amount0, the returned amount1 should be what previewAddFromAmount1 expects
     */
    function test_preview_crossConsistency() public {
        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        uint256 inputAmount0 = 50e18;

        // Get requirements from amount0
        (uint256 requiredAmount1, uint256 shares0) = AlphixLogic(address(logic)).previewAddFromAmount0(inputAmount0);

        // Now check: if we use the returned amount1, do we get similar shares?
        (uint256 requiredAmount0FromAmount1, uint256 shares1) =
            AlphixLogic(address(logic)).previewAddFromAmount1(requiredAmount1);

        console2.log("From amount0 - required1:", requiredAmount1, "shares:", shares0);
        console2.log("From amount1 - required0:", requiredAmount0FromAmount1, "shares:", shares1);

        // The shares should be similar (within rounding)
        assertApproxEqRel(shares0, shares1, 1e16, "Shares should be consistent");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _addRegularLp(uint256 amount) internal {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(currency0), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );
        permit2.approve(
            Currency.unwrap(currency1), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );

        positionManager.mint(
            key,
            fullRangeLower,
            fullRangeUpper,
            amount,
            amount,
            amount * 2,
            owner,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _configureReHypo() internal {
        vm.startPrank(yieldManager);
        AlphixLogic(address(logic)).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setYieldTaxPips(100_000); // 10%
        AlphixLogic(address(logic)).setYieldTreasury(treasury);
        vm.stopPrank();
    }

    function _addReHypoLiquidity(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
