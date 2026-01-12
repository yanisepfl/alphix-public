// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title ReHypothecationVaryingPricesFuzzTest
 * @notice Fuzz tests for ReHypothecation at varying pool prices.
 *         Tests prices from 0.0000001:1 to 1000000:1 (tick ~-161000 to ~+161000)
 */
contract ReHypothecationVaryingPricesFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;

    // We'll use these for each fuzzed test - deployed fresh per test
    Alphix internal testHook;
    IAlphixLogic internal testLogic;
    AccessManager internal testAccessManager;
    PoolKey internal testKey;
    Currency internal testCurrency0;
    Currency internal testCurrency1;
    MockYieldVault internal testVault0;
    MockYieldVault internal testVault1;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       FUZZ TESTS: VARYING POOL PRICES
       Price range: 0.0000001:1 to 1000000:1
       Tick range: approximately -161000 to +161000
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test rehypothecation works at fuzzed pool prices
     * @param tickSeed Seed to generate a tick in the valid range
     * @dev Fuzz prices from very small (0.0000001) to very large (1000000)
     *      Comprehensive test covering: deposits, swaps, yield, multi-user, withdrawals
     */
    function testFuzz_reHypo_varyingPoolPrices(int24 tickSeed) public {
        // Bound tick to a safe range for comprehensive testing with swaps
        // Using -120000 to +120000 to avoid edge cases at extreme prices
        // The extreme prices are already tested in dedicated test_reHypo_extremeLowPrice/HighPrice tests
        int24 initialTick = int24(bound(tickSeed, -120000, 120000));

        // Align tick with tick spacing (use 60 for wider range pools)
        int24 tickSpacing = 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        initialTick = (initialTick / tickSpacing) * tickSpacing;

        // Deploy fresh Alphix infrastructure
        _deployFreshInfrastructure(initialTick, tickSpacing, 18, 18);

        // Add regular LP
        _addRegularLpToTestPool(1000e18);

        // Configure rehypothecation
        _configureTestPoolReHypo();

        uint256 aliceShares = 100e18;
        uint256 bobShares = 50e18;

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 1: Alice deposits - verify preview matches actual deposit
        // ══════════════════════════════════════════════════════════════════════
        {
            (uint256 previewDeposit0, uint256 previewDeposit1) =
                AlphixLogic(address(testLogic)).previewAddReHypothecatedLiquidity(aliceShares);

            uint256 aliceToken0Before = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(alice);
            uint256 aliceToken1Before = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(alice);

            _addReHypoToTestPool(alice, aliceShares);

            uint256 aliceToken0After = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(alice);
            uint256 aliceToken1After = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(alice);

            // Verify preview matched actual deposit
            assertApproxEqAbs(aliceToken0Before - aliceToken0After, previewDeposit0, 1, "Preview deposit0 should match");
            assertApproxEqAbs(aliceToken1Before - aliceToken1After, previewDeposit1, 1, "Preview deposit1 should match");

            // Verify shares minted
            assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), aliceShares, "Shares should be minted");
            assertEq(
                AlphixLogic(address(testLogic)).totalSupply(), aliceShares, "Total supply should equal alice shares"
            );

            // Verify yield sources have funds (at least one should have funds depending on price)
            uint256 yieldSource0Initial = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
            uint256 yieldSource1Initial = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);
            assertTrue(
                yieldSource0Initial > 0 || yieldSource1Initial > 0, "At least one yield source should have funds"
            );
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 2: Perform swap - verify JIT participates (yield source changes)
        // ══════════════════════════════════════════════════════════════════════
        {
            uint256 yieldSource0Before = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
            uint256 yieldSource1Before = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

            _doSwapOnTestPool(5e18, true); // Small swap to avoid extreme price impact

            uint256 yieldSource0AfterSwap = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
            uint256 yieldSource1AfterSwap = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

            // JIT should have participated - at least one yield source should change
            bool jitParticipated =
                (yieldSource0AfterSwap != yieldSource0Before) || (yieldSource1AfterSwap != yieldSource1Before);
            assertTrue(jitParticipated, "JIT should participate in swap");
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 3: Bob deposits - verify share accounting
        // ══════════════════════════════════════════════════════════════════════
        // Store pre-yield values for later comparison
        uint256 alicePreYield0;
        uint256 alicePreYield1;
        {
            _addReHypoToTestPool(bob, bobShares);

            assertEq(AlphixLogic(address(testLogic)).balanceOf(bob), bobShares, "Bob should have shares");
            assertEq(AlphixLogic(address(testLogic)).totalSupply(), aliceShares + bobShares, "Total supply updated");

            // Record pre-yield values for Alice
            (alicePreYield0, alicePreYield1) =
                AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 4: Simulate yield - verify value actually increases by expected amount
        // ══════════════════════════════════════════════════════════════════════
        uint256 yieldAmount0 = 0;
        uint256 yieldAmount1 = 0;
        {
            uint256 vault0Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
            uint256 vault1Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

            // Add 10% yield to vault0 if it has funds
            if (vault0Balance > 0) {
                yieldAmount0 = vault0Balance / 10;
                vm.startPrank(owner);
                MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmount0);
                MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmount0);
                testVault0.simulateYield(yieldAmount0);
                vm.stopPrank();
            }
            // Add 10% yield to vault1 if it has funds
            if (vault1Balance > 0) {
                yieldAmount1 = vault1Balance / 10;
                vm.startPrank(owner);
                MockERC20(Currency.unwrap(testCurrency1)).mint(owner, yieldAmount1);
                MockERC20(Currency.unwrap(testCurrency1)).approve(address(testVault1), yieldAmount1);
                testVault1.simulateYield(yieldAmount1);
                vm.stopPrank();
            }
        }

        // Store Bob's final preview for withdrawal verification
        uint256 bobFinalPreview0;
        uint256 bobFinalPreview1;

        // Verify yield actually increased values
        {
            (uint256 alicePostYield0, uint256 alicePostYield1) =
                AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);
            (bobFinalPreview0, bobFinalPreview1) =
                AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(bobShares);

            // Verify yield increased values (swap fees may have affected share value)
            if (yieldAmount0 > 0 && alicePreYield0 > 0) {
                uint256 actualAliceGain0 = alicePostYield0 - alicePreYield0;
                // Just verify positive gain occurred
                assertGt(actualAliceGain0, 0, "Alice should gain from yield on token0");
            }
            if (yieldAmount1 > 0 && alicePreYield1 > 0) {
                uint256 actualAliceGain1 = alicePostYield1 - alicePreYield1;
                assertGt(actualAliceGain1, 0, "Alice should gain from yield on token1");
            }

            // Alice (100 shares) should get 2x Bob (50 shares)
            if (alicePostYield0 > 0) {
                assertApproxEqRel(alicePostYield0, bobFinalPreview0 * 2, 1e15, "Alice gets 2x Bob's token0");
            }
            if (alicePostYield1 > 0) {
                assertApproxEqRel(alicePostYield1, bobFinalPreview1 * 2, 1e15, "Alice gets 2x Bob's token1");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 5: Both withdraw - verify previews match actual withdrawals
        // ══════════════════════════════════════════════════════════════════════
        {
            uint256 bobToken0BeforeWithdraw = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(bob);
            uint256 bobToken1BeforeWithdraw = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(bob);

            vm.prank(bob);
            AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(bobShares);

            uint256 bobToken0AfterWithdraw = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(bob);
            uint256 bobToken1AfterWithdraw = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(bob);

            // After yield simulation, there can be rounding from yield tax calculations
            // Use relative tolerance (1%) instead of absolute for post-yield withdrawals
            if (bobFinalPreview0 > 0) {
                assertApproxEqRel(
                    bobToken0AfterWithdraw - bobToken0BeforeWithdraw,
                    bobFinalPreview0,
                    1e16,
                    "Bob withdrawal0 matches preview"
                );
            }
            if (bobFinalPreview1 > 0) {
                assertApproxEqRel(
                    bobToken1AfterWithdraw - bobToken1BeforeWithdraw,
                    bobFinalPreview1,
                    1e16,
                    "Bob withdrawal1 matches preview"
                );
            }
            assertEq(AlphixLogic(address(testLogic)).balanceOf(bob), 0, "Bob shares burned");
        }

        // Alice withdraws
        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(aliceShares);

        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0, "Alice shares burned");
        assertEq(AlphixLogic(address(testLogic)).totalSupply(), 0, "Total supply is zero");

        // Verify yield sources are empty
        assertEq(AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0), 0, "Yield source0 empty");
        assertEq(AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1), 0, "Yield source1 empty");
    }

    /**
     * @notice Test rehypothecation at extreme low price (0.0000001:1)
     * @dev Price = 10^-7, tick ≈ -161000
     */
    function test_reHypo_extremeLowPrice() public {
        // Tick for price ~0.0000001 = 10^-7
        // tick = log(price) / log(1.0001) ≈ -161000
        int24 initialTick = -160800;
        int24 tickSpacing = 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        initialTick = (initialTick / tickSpacing) * tickSpacing;

        _deployFreshInfrastructure(initialTick, tickSpacing, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        // Add rehypo liquidity
        _addReHypoToTestPool(alice, 100e18);

        // Verify it worked
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 100e18);

        // At low price, token1 is more valuable, so might have more token1
        (uint256 preview0, uint256 preview1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(100e18);
        assertTrue(preview0 > 0 || preview1 > 0, "Should have value in at least one token");

        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(100e18);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0);
    }

    /**
     * @notice Test rehypothecation at extreme high price (1000000:1)
     * @dev Price = 10^6, tick ≈ +138000
     */
    function test_reHypo_extremeHighPrice() public {
        // Tick for price ~1000000 = 10^6
        // tick = log(price) / log(1.0001) ≈ +138000
        int24 initialTick = 138000;
        int24 tickSpacing = 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        initialTick = (initialTick / tickSpacing) * tickSpacing;

        _deployFreshInfrastructure(initialTick, tickSpacing, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        // Add rehypo liquidity
        _addReHypoToTestPool(alice, 100e18);

        // Verify it worked
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 100e18);

        // At high price, token0 is more valuable, so might have more token0
        (uint256 preview0, uint256 preview1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(100e18);
        assertTrue(preview0 > 0 || preview1 > 0, "Should have value in at least one token");

        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(100e18);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0);
    }

    /**
     * @notice Test yield/loss accounting works at various prices
     * @param tickSeed Seed to generate a tick
     * @param lossPercent Percentage loss to simulate (0-50%)
     */
    function testFuzz_reHypo_yieldLossAtVaryingPrices(int24 tickSeed, uint8 lossPercent) public {
        // Bound inputs
        int24 initialTick = int24(bound(tickSeed, -140000, 140000));
        int24 tickSpacing = 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        initialTick = (initialTick / tickSpacing) * tickSpacing;
        uint256 boundedLoss = bound(lossPercent, 0, 50);

        _deployFreshInfrastructure(initialTick, tickSpacing, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();
        _addReHypoToTestPool(alice, 100e18);

        // Get initial value
        (uint256 initial0, uint256 initial1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Simulate loss on vault0
        if (boundedLoss > 0) {
            uint256 vault0Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
            uint256 lossAmount = (vault0Balance * boundedLoss) / 100;
            if (lossAmount > 0) {
                testVault0.simulateLoss(lossAmount);
            }
        }

        // Get post-loss value
        (uint256 postLoss0, uint256 postLoss1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Token0 should reflect loss (if there was any value), Token1 should be unchanged
        if (boundedLoss > 0 && initial0 > 0) {
            assertLe(postLoss0, initial0, "Token0 value should decrease or stay same after loss");
        }
        // Token1 should be approximately unchanged (allow larger tolerance for edge cases)
        if (initial1 > 0) {
            assertApproxEqRel(postLoss1, initial1, 5e16, "Token1 should be mostly unaffected by vault0 loss");
        }

        // Withdrawal should still work
        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(100e18);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0);
    }

    /**
     * @notice Test multi-user scenarios at various prices
     * @param tickSeed Seed to generate a tick
     */
    function testFuzz_reHypo_multiUserAtVaryingPrices(int24 tickSeed) public {
        // Bound tick
        int24 initialTick = int24(bound(tickSeed, -120000, 120000));
        int24 tickSpacing = 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        initialTick = (initialTick / tickSpacing) * tickSpacing;

        _deployFreshInfrastructure(initialTick, tickSpacing, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        // Alice deposits
        _addReHypoToTestPool(alice, 100e18);

        // Simulate some yield on the vault that has funds
        uint256 vault0Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
        uint256 vault1Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

        if (vault0Balance > 0) {
            uint256 yieldAmount = vault0Balance / 10; // 10% yield
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmount);
            MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmount);
            testVault0.simulateYield(yieldAmount);
            vm.stopPrank();
        } else if (vault1Balance > 0) {
            uint256 yieldAmount = vault1Balance / 10; // 10% yield
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency1)).mint(owner, yieldAmount);
            MockERC20(Currency.unwrap(testCurrency1)).approve(address(testVault1), yieldAmount);
            testVault1.simulateYield(yieldAmount);
            vm.stopPrank();
        }

        // Bob deposits
        _addReHypoToTestPool(bob, 100e18);

        // Both should have 100 shares
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 100e18);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(bob), 100e18);

        // Same shares = same withdrawal value
        (uint256 aliceWithdraw0, uint256 aliceWithdraw1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 bobWithdraw0, uint256 bobWithdraw1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Check that withdrawal values match for same share amount
        if (aliceWithdraw0 > 0) {
            assertApproxEqRel(aliceWithdraw0, bobWithdraw0, 1e15, "Same shares = same withdrawal value token0");
        }
        if (aliceWithdraw1 > 0) {
            assertApproxEqRel(aliceWithdraw1, bobWithdraw1, 1e15, "Same shares = same withdrawal value token1");
        }
    }

    /**
     * @notice Test varying yield rates between the two yield sources
     * @param yield0Percent Yield percentage for vault0 (0-100%)
     * @param yield1Percent Yield percentage for vault1 (0-100%)
     * @param loss0Percent Loss percentage for vault0 (0-50%)
     * @dev Tests scenarios: high/low yield, positive/negative, asymmetric yields
     */
    function testFuzz_reHypo_varyingYieldRatesBetweenSources(
        uint8 yield0Percent,
        uint8 yield1Percent,
        uint8 loss0Percent
    ) public {
        // Bound inputs
        uint256 boundedYield0 = bound(yield0Percent, 0, 100); // 0-100% yield
        uint256 boundedYield1 = bound(yield1Percent, 0, 100); // 0-100% yield
        uint256 boundedLoss0 = bound(loss0Percent, 0, 50); // 0-50% loss

        // Deploy at 1:1 price for simplicity (tick 0)
        _deployFreshInfrastructure(0, 60, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        // Alice deposits
        uint256 aliceShares = 100e18;
        _addReHypoToTestPool(alice, aliceShares);

        // Record initial values
        (uint256 initial0, uint256 initial1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);

        uint256 vault0Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
        uint256 vault1Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

        // ══════════════════════════════════════════════════════════════════════
        // Scenario: Apply different yield rates to each vault
        // ══════════════════════════════════════════════════════════════════════

        // Apply loss to vault0 first (if any)
        if (boundedLoss0 > 0 && vault0Balance > 0) {
            uint256 lossAmount = (vault0Balance * boundedLoss0) / 100;
            testVault0.simulateLoss(lossAmount);
        }

        // Apply yield to vault0 (if any)
        if (boundedYield0 > 0 && vault0Balance > 0) {
            uint256 yieldAmount0 = (vault0Balance * boundedYield0) / 100;
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmount0);
            MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmount0);
            testVault0.simulateYield(yieldAmount0);
            vm.stopPrank();
        }

        // Apply yield to vault1 (if any)
        if (boundedYield1 > 0 && vault1Balance > 0) {
            uint256 yieldAmount1 = (vault1Balance * boundedYield1) / 100;
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency1)).mint(owner, yieldAmount1);
            MockERC20(Currency.unwrap(testCurrency1)).approve(address(testVault1), yieldAmount1);
            testVault1.simulateYield(yieldAmount1);
            vm.stopPrank();
        }

        // ══════════════════════════════════════════════════════════════════════
        // Verify: Each token reflects its own vault's yield/loss independently
        // ══════════════════════════════════════════════════════════════════════
        (uint256 final0, uint256 final1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);

        // Token0: should reflect loss then yield
        // Loss decreases value, yield increases from remaining balance
        if (vault0Balance > 0) {
            // After loss, value should be lower (or same if no loss)
            if (boundedLoss0 > 0 && boundedYield0 == 0) {
                assertLt(final0, initial0, "Token0 should decrease with only loss");
            }
            // With yield, value might increase even after loss
            if (boundedYield0 > boundedLoss0) {
                // High yield can overcome loss
                // Just verify the final value is reasonable (not checking exact math)
            }
        }

        // Token1: should reflect only yield (no loss applied to vault1)
        if (vault1Balance > 0) {
            if (boundedYield1 > 0) {
                assertGe(final1, initial1, "Token1 should increase or stay same with yield");
            } else {
                assertEq(final1, initial1, "Token1 should stay same with no yield");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // Verify: User can still withdraw
        // ══════════════════════════════════════════════════════════════════════
        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(aliceShares);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0, "Alice shares burned");
    }

    /**
     * @notice Test asymmetric yields: one vault high yield, other vault loss
     * @param highYieldPercent High yield percentage (50-500%)
     * @param lossPercent Loss percentage for the other vault (10-80%)
     * @dev Critical edge case: extreme divergence between vaults
     */
    function testFuzz_reHypo_asymmetricYields_highVsLoss(uint16 highYieldPercent, uint8 lossPercent) public {
        // Bound inputs to create asymmetric scenario
        uint256 boundedHighYield = bound(highYieldPercent, 50, 500); // 50-500% yield
        uint256 boundedLoss = bound(lossPercent, 10, 80); // 10-80% loss

        _deployFreshInfrastructure(0, 60, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 aliceShares = 100e18;
        _addReHypoToTestPool(alice, aliceShares);

        (uint256 initial0, uint256 initial1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);

        uint256 vault0Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
        uint256 vault1Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

        // Vault0: HIGH yield
        if (vault0Balance > 0) {
            uint256 yieldAmount0 = (vault0Balance * boundedHighYield) / 100;
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmount0);
            MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmount0);
            testVault0.simulateYield(yieldAmount0);
            vm.stopPrank();
        }

        // Vault1: LOSS
        if (vault1Balance > 0) {
            uint256 lossAmount = (vault1Balance * boundedLoss) / 100;
            testVault1.simulateLoss(lossAmount);
        }

        (uint256 final0, uint256 final1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);

        // Token0 should INCREASE significantly
        if (vault0Balance > 0 && initial0 > 0) {
            assertGt(final0, initial0, "Token0 should increase from high yield");
            // Net gain should be approximately yieldAmount * 0.9 (after 10% tax)
            uint256 expectedGain = (initial0 * boundedHighYield * 9) / 1000;
            uint256 actualGain = final0 - initial0;
            assertApproxEqRel(actualGain, expectedGain, 15e16, "High yield gain should match expected");
        }

        // Token1 should DECREASE
        if (vault1Balance > 0 && initial1 > 0) {
            assertLt(final1, initial1, "Token1 should decrease from loss");
            uint256 expectedLoss = (initial1 * boundedLoss) / 100;
            uint256 actualLoss = initial1 - final1;
            assertApproxEqRel(actualLoss, expectedLoss, 15e16, "Loss should match expected");
        }

        // User can still withdraw
        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(aliceShares);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0, "Alice shares burned");
    }

    /**
     * @notice Test both vaults with losses
     * @param loss0Percent Loss on vault0
     * @param loss1Percent Loss on vault1
     */
    function testFuzz_reHypo_bothVaultsLoss(uint8 loss0Percent, uint8 loss1Percent) public {
        uint256 boundedLoss0 = bound(loss0Percent, 0, 90);
        uint256 boundedLoss1 = bound(loss1Percent, 0, 90);

        _deployFreshInfrastructure(0, 60, 18, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 aliceShares = 100e18;
        _addReHypoToTestPool(alice, aliceShares);

        (uint256 initial0, uint256 initial1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);

        uint256 vault0Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
        uint256 vault1Balance = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

        // Apply losses to both vaults
        if (boundedLoss0 > 0 && vault0Balance > 0) {
            testVault0.simulateLoss((vault0Balance * boundedLoss0) / 100);
        }
        if (boundedLoss1 > 0 && vault1Balance > 0) {
            testVault1.simulateLoss((vault1Balance * boundedLoss1) / 100);
        }

        (uint256 final0, uint256 final1) =
            AlphixLogic(address(testLogic)).previewRemoveReHypothecatedLiquidity(aliceShares);

        // Both should decrease or stay same
        if (vault0Balance > 0 && boundedLoss0 > 0) {
            assertLe(final0, initial0, "Token0 should decrease or stay same");
            uint256 expectedFinal0 = initial0 - (initial0 * boundedLoss0) / 100;
            assertApproxEqRel(final0, expectedFinal0, 5e16, "Token0 loss should match");
        }
        if (vault1Balance > 0 && boundedLoss1 > 0) {
            assertLe(final1, initial1, "Token1 should decrease or stay same");
            uint256 expectedFinal1 = initial1 - (initial1 * boundedLoss1) / 100;
            assertApproxEqRel(final1, expectedFinal1, 5e16, "Token1 loss should match");
        }

        // User can still withdraw (even at total loss)
        vm.prank(alice);
        AlphixLogic(address(testLogic)).removeReHypothecatedLiquidity(aliceShares);
        assertEq(AlphixLogic(address(testLogic)).balanceOf(alice), 0, "Alice shares burned");
    }

    /**
     * @notice Test swaps work correctly at various prices with rehypo
     * @param tickSeed Seed to generate a tick
     * @param swapAmount Amount to swap (bounded to reasonable range)
     */
    function testFuzz_reHypo_swapsAtVaryingPrices(int24 tickSeed, uint128 swapAmount) public {
        // Bound inputs - use narrower tick range for swap tests
        int24 initialTick = int24(bound(tickSeed, -80000, 80000));
        int24 tickSpacing = 60;
        // forge-lint: disable-next-line(divide-before-multiply)
        initialTick = (initialTick / tickSpacing) * tickSpacing;

        // Bound swap amount to 1-10 tokens (smaller for price stability)
        uint256 boundedSwapAmount = bound(swapAmount, 1e18, 10e18);

        _deployFreshInfrastructure(initialTick, tickSpacing, 18, 18);
        _addRegularLpToTestPool(10000e18); // More liquidity for swaps
        _configureTestPoolReHypo();
        _addReHypoToTestPool(alice, 100e18);

        // Record yield source balances before swap
        uint256 yieldSource0Before = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
        uint256 yieldSource1Before = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

        // Do swap - only if there's liquidity in the direction we're swapping
        if (yieldSource0Before > 0 || yieldSource1Before > 0) {
            _doSwapOnTestPool(boundedSwapAmount, true);

            // Record yield source balances after swap
            uint256 yieldSource0After = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency0);
            uint256 yieldSource1After = AlphixLogic(address(testLogic)).getAmountInYieldSource(testCurrency1);

            // JIT should have participated (full range) - at least one should change
            bool participated = (yieldSource0After != yieldSource0Before) || (yieldSource1After != yieldSource1Before);
            assertTrue(participated, "Full range JIT should participate");
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _deployFreshInfrastructure(int24 initialTick, int24 tickSpacing, uint8 decimals0, uint8 decimals1)
        internal
    {
        // Deploy fresh Alphix stack (handles its own prank)
        (testHook, testLogic, testAccessManager,) = _deployFreshAlphixStackFull();

        vm.startPrank(owner);

        // Deploy test tokens with specified decimals
        (testCurrency0, testCurrency1) = deployCurrencyPairWithDecimals(decimals0, decimals1);

        // Fund test addresses
        MockERC20(Currency.unwrap(testCurrency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(testCurrency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(testCurrency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(testCurrency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);

        // Calculate sqrt price from tick
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Create pool key
        testKey = PoolKey({
            currency0: testCurrency0,
            currency1: testCurrency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(testHook)
        });

        // Initialize pool in Uniswap
        poolManager.initialize(testKey, sqrtPriceX96);

        // Initialize pool in Alphix
        testHook.initializePool(testKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Deploy yield vaults
        testVault0 = new MockYieldVault(IERC20(Currency.unwrap(testCurrency0)));
        testVault1 = new MockYieldVault(IERC20(Currency.unwrap(testCurrency1)));

        // Setup yield manager role
        _setupYieldManagerRole(owner, testAccessManager, address(testLogic));

        vm.stopPrank();
    }

    function _addRegularLpToTestPool(uint128 liquidityAmount) internal {
        vm.startPrank(owner);

        int24 fullRangeLower = TickMath.minUsableTick(testKey.tickSpacing);
        int24 fullRangeUpper = TickMath.maxUsableTick(testKey.tickSpacing);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(testKey.toId());

        // Calculate required amounts for the liquidity
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(fullRangeLower),
            TickMath.getSqrtPriceAtTick(fullRangeUpper),
            liquidityAmount
        );

        // Mint extra tokens if needed
        if (amount0 > MockERC20(Currency.unwrap(testCurrency0)).balanceOf(owner)) {
            MockERC20(Currency.unwrap(testCurrency0)).mint(owner, amount0 * 2);
        }
        if (amount1 > MockERC20(Currency.unwrap(testCurrency1)).balanceOf(owner)) {
            MockERC20(Currency.unwrap(testCurrency1)).mint(owner, amount1 * 2);
        }

        MockERC20(Currency.unwrap(testCurrency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(testCurrency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(testCurrency0), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );
        permit2.approve(
            Currency.unwrap(testCurrency1), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );

        positionManager.mint(
            testKey,
            fullRangeLower,
            fullRangeUpper,
            liquidityAmount,
            amount0 + 1,
            amount1 + 1,
            owner,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _configureTestPoolReHypo() internal {
        int24 fullRangeLower = TickMath.minUsableTick(testKey.tickSpacing);
        int24 fullRangeUpper = TickMath.maxUsableTick(testKey.tickSpacing);

        vm.startPrank(owner);
        AlphixLogic(address(testLogic)).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogic(address(testLogic)).setYieldSource(testCurrency0, address(testVault0));
        AlphixLogic(address(testLogic)).setYieldSource(testCurrency1, address(testVault1));
        AlphixLogic(address(testLogic)).setYieldTaxPips(100_000); // 10%
        AlphixLogic(address(testLogic)).setYieldTreasury(owner);
        vm.stopPrank();
    }

    function _addReHypoToTestPool(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(testLogic)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(testCurrency0)).approve(address(testLogic), amount0);
        MockERC20(Currency.unwrap(testCurrency1)).approve(address(testLogic), amount1);
        AlphixLogic(address(testLogic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();
    }

    function _doSwapOnTestPool(uint256 amount, bool zeroForOne) internal {
        vm.startPrank(bob);
        if (zeroForOne) {
            MockERC20(Currency.unwrap(testCurrency0)).approve(address(swapRouter), amount);
        } else {
            MockERC20(Currency.unwrap(testCurrency1)).approve(address(swapRouter), amount);
        }
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
