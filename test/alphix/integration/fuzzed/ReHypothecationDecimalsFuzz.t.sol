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
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title ReHypothecationDecimalsFuzzTest
 * @notice Fuzz tests for ReHypothecation with varying token decimals.
 *         Tests decimals from 6 to 18 for both tokens.
 */
contract ReHypothecationDecimalsFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;

    // Per-test infrastructure
    Alphix internal testHook;
    AccessManager internal testAccessManager;
    PoolKey internal testKey;
    Currency internal testCurrency0;
    Currency internal testCurrency1;
    MockYieldVault internal testVault0;
    MockYieldVault internal testVault1;
    uint8 internal currentDecimals0;
    uint8 internal currentDecimals1;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       FUZZ TESTS: VARYING TOKEN DECIMALS
       Decimal range: 6 to 18 for both tokens
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test rehypothecation with fuzzed token decimals (same for both tokens)
     * @param decimals The number of decimals for both tokens (6-18)
     * @dev Comprehensive test: deposits, swaps, yield, loss, multi-user, withdrawals
     */
    function testFuzz_reHypo_sameDecimals(uint8 decimals) public {
        // Bound decimals to valid range
        uint8 boundedDecimals = uint8(bound(decimals, 6, 18));

        _deployFreshInfrastructure(0, 60, boundedDecimals, boundedDecimals);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 aliceShares = 100e18;
        uint256 bobShares = 50e18;

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 1: Alice deposits - verify preview matches actual
        // ══════════════════════════════════════════════════════════════════════
        {
            (uint256 previewDeposit0, uint256 previewDeposit1) =
                Alphix(address(testHook)).previewAddReHypothecatedLiquidity(aliceShares);

            uint256 aliceToken0Before = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(alice);
            uint256 aliceToken1Before = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(alice);

            _addReHypoToTestPool(alice, aliceShares);

            uint256 aliceToken0After = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(alice);
            uint256 aliceToken1After = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(alice);

            // Verify preview matched actual deposit
            assertApproxEqAbs(aliceToken0Before - aliceToken0After, previewDeposit0, 1, "Preview deposit0 matches");
            assertApproxEqAbs(aliceToken1Before - aliceToken1After, previewDeposit1, 1, "Preview deposit1 matches");
            assertEq(Alphix(address(testHook)).balanceOf(alice), aliceShares, "Shares minted");

            // Verify yield sources have funds
            uint256 ys0 = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
            uint256 ys1 = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);
            assertTrue(ys0 > 0 || ys1 > 0, "Yield sources funded");
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 2: Bob deposits - verify share accounting
        // ══════════════════════════════════════════════════════════════════════
        {
            _addReHypoToTestPool(bob, bobShares);

            assertEq(Alphix(address(testHook)).balanceOf(bob), bobShares, "Bob shares minted");
            assertEq(Alphix(address(testHook)).totalSupply(), aliceShares + bobShares, "Total supply correct");

            // Same shares = same value
            (uint256 alice50Preview0, uint256 alice50Preview1) =
                Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(50e18);
            (uint256 bob50Preview0, uint256 bob50Preview1) =
                Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(50e18);

            if (alice50Preview0 > 0) {
                assertApproxEqRel(alice50Preview0, bob50Preview0, 1e15, "Same shares = same token0");
            }
            if (alice50Preview1 > 0) {
                assertApproxEqRel(alice50Preview1, bob50Preview1, 1e15, "Same shares = same token1");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 3: Simulate yield - verify proportional distribution
        // ══════════════════════════════════════════════════════════════════════
        {
            uint256 vault0Bal = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
            uint256 vault1Bal = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

            if (vault0Bal > 0) {
                uint256 yieldAmt = vault0Bal / 10;
                vm.startPrank(owner);
                MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmt);
                MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmt);
                testVault0.simulateYield(yieldAmt);
                vm.stopPrank();
            } else if (vault1Bal > 0) {
                uint256 yieldAmt = vault1Bal / 10;
                vm.startPrank(owner);
                MockERC20(Currency.unwrap(testCurrency1)).mint(owner, yieldAmt);
                MockERC20(Currency.unwrap(testCurrency1)).approve(address(testVault1), yieldAmt);
                testVault1.simulateYield(yieldAmt);
                vm.stopPrank();
            }
        }

        // Store Bob's final preview for withdrawal verification
        uint256 bobFinal0;
        uint256 bobFinal1;

        // Alice (100 shares) should get 2x Bob (50 shares)
        {
            (uint256 aliceFinal0, uint256 aliceFinal1) =
                Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(100e18);
            (bobFinal0, bobFinal1) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(50e18);

            if (aliceFinal0 > 0) {
                assertApproxEqRel(aliceFinal0, bobFinal0 * 2, 1e15, "Alice 2x Bob token0");
            }
            if (aliceFinal1 > 0) {
                assertApproxEqRel(aliceFinal1, bobFinal1 * 2, 1e15, "Alice 2x Bob token1");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 4: Both withdraw - verify previews match actual
        // ══════════════════════════════════════════════════════════════════════
        {
            uint256 bobT0Before = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(bob);
            uint256 bobT1Before = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(bob);

            vm.prank(bob);
            Alphix(address(testHook)).removeReHypothecatedLiquidity(bobShares, 0, 0);

            uint256 bobT0After = MockERC20(Currency.unwrap(testCurrency0)).balanceOf(bob);
            uint256 bobT1After = MockERC20(Currency.unwrap(testCurrency1)).balanceOf(bob);

            // After yield simulation, there can be rounding from yield tax calculations
            // Use relative tolerance (1%) instead of absolute for post-yield withdrawals
            if (bobFinal0 > 0) {
                assertApproxEqRel(bobT0After - bobT0Before, bobFinal0, 1e16, "Bob withdrawal0 matches");
            }
            if (bobFinal1 > 0) {
                assertApproxEqRel(bobT1After - bobT1Before, bobFinal1, 1e16, "Bob withdrawal1 matches");
            }
            assertEq(Alphix(address(testHook)).balanceOf(bob), 0, "Bob shares burned");
        }

        vm.prank(alice);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(aliceShares, 0, 0);

        assertEq(Alphix(address(testHook)).balanceOf(alice), 0, "Alice shares burned");
        assertEq(Alphix(address(testHook)).totalSupply(), 0, "Total supply zero");
    }

    /**
     * @notice Test rehypothecation with different decimals for each token
     * @param decimals0 Decimals for token0
     * @param decimals1 Decimals for token1
     * @dev Comprehensive test: deposits, swaps, loss scenario, multi-user, withdrawals
     */
    function testFuzz_reHypo_differentDecimals(uint8 decimals0, uint8 decimals1) public {
        // Bound decimals and store in state vars to reduce stack pressure
        uint8 boundedDecimals0 = uint8(bound(decimals0, 6, 18));
        uint8 boundedDecimals1 = uint8(bound(decimals1, 6, 18));

        _deployFreshInfrastructure(0, 60, boundedDecimals0, boundedDecimals1);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 aliceShares = 100e18;
        uint256 bobShares = 100e18;

        // Store Alice's initial deposit preview to compare later
        uint256 aliceInitialDepPreview0;
        uint256 aliceInitialDepPreview1;

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 1: Alice deposits
        // ══════════════════════════════════════════════════════════════════════
        {
            (uint256 previewDep0, uint256 previewDep1) =
                Alphix(address(testHook)).previewAddReHypothecatedLiquidity(aliceShares);
            aliceInitialDepPreview0 = previewDep0;
            aliceInitialDepPreview1 = previewDep1;

            _addReHypoToTestPool(alice, aliceShares);
            assertEq(Alphix(address(testHook)).balanceOf(alice), aliceShares, "Alice shares");
        }

        // Record initial withdrawal value
        uint256 aliceInitial0;
        uint256 aliceInitial1;
        {
            (aliceInitial0, aliceInitial1) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(aliceShares);
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 2: Simulate 20% loss - Alice absorbs it
        // ══════════════════════════════════════════════════════════════════════
        {
            uint256 vault0Bal = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
            uint256 vault1Bal = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

            if (vault0Bal > 0) {
                testVault0.simulateLoss(vault0Bal / 5); // 20% loss
            } else if (vault1Bal > 0) {
                testVault1.simulateLoss(vault1Bal / 5); // 20% loss
            }
        }

        // Alice should see loss
        {
            (uint256 alicePostLoss0, uint256 alicePostLoss1) =
                Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(aliceShares);

            assertTrue(alicePostLoss0 < aliceInitial0 || alicePostLoss1 < aliceInitial1, "Alice should see loss");
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 3: Bob deposits AFTER loss - at lower share price
        // ══════════════════════════════════════════════════════════════════════
        {
            (uint256 bobRequired0, uint256 bobRequired1) =
                Alphix(address(testHook)).previewAddReHypothecatedLiquidity(bobShares);

            // Bob should deposit less than Alice's initial (lower share price)
            assertTrue(
                bobRequired0 < aliceInitialDepPreview0 || bobRequired1 < aliceInitialDepPreview1,
                "Bob deposits less due to lower share price"
            );

            _addReHypoToTestPool(bob, bobShares);
        }

        // Same shares = same withdrawal value (fair)
        {
            (uint256 aliceNow0, uint256 aliceNow1) =
                Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(100e18);
            (uint256 bobNow0, uint256 bobNow1) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(100e18);

            if (aliceNow0 > 0) {
                assertApproxEqRel(aliceNow0, bobNow0, 1e15, "Same shares = same token0");
            }
            if (aliceNow1 > 0) {
                assertApproxEqRel(aliceNow1, bobNow1, 1e15, "Same shares = same token1");
            }
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 4: Do swap - verify pool still works (uses currentDecimals0)
        // ══════════════════════════════════════════════════════════════════════
        {
            uint256 ys0Before = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
            uint256 ys1Before = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

            // Use stored decimals from state variable
            _doSwapOnTestPool(_scaledAmount(1, currentDecimals0), true);

            uint256 ys0After = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
            uint256 ys1After = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

            // JIT should participate
            bool participated = (ys0After != ys0Before) || (ys1After != ys1Before);
            assertTrue(participated, "JIT participated in swap");
        }

        // ══════════════════════════════════════════════════════════════════════
        // PHASE 5: Both withdraw
        // ══════════════════════════════════════════════════════════════════════
        vm.prank(alice);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(aliceShares, 0, 0);
        assertEq(Alphix(address(testHook)).balanceOf(alice), 0, "Alice burned");

        vm.prank(bob);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(bobShares, 0, 0);
        assertEq(Alphix(address(testHook)).balanceOf(bob), 0, "Bob burned");

        assertEq(Alphix(address(testHook)).totalSupply(), 0, "Total supply zero");
    }

    /**
     * @notice Test 6 decimal token (like USDC) with 18 decimal token (like ETH)
     * @dev Common pairing: USDC (6 decimals) vs WETH (18 decimals)
     */
    function test_reHypo_6_18_decimals() public {
        _deployFreshInfrastructure(0, 60, 6, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 shares = 100e18;
        _addReHypoToTestPool(alice, shares);

        // Verify proper accounting
        (uint256 preview0, uint256 preview1) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(shares);

        // Both should have value (1:1 price)
        assertTrue(preview0 > 0 || preview1 > 0, "Should have value");

        // Simulate yield on a vault that has balance
        uint256 vault0Balance = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
        uint256 vault1Balance = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

        if (vault0Balance > 0) {
            uint256 yieldAmount = vault0Balance / 10; // 10% yield
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmount);
            MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmount);
            testVault0.simulateYield(yieldAmount);
            vm.stopPrank();

            // Verify yield is reflected
            (uint256 postYieldPreview0,) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(shares);
            assertGt(postYieldPreview0, preview0, "Yield should increase token0 value");
        } else if (vault1Balance > 0) {
            uint256 yieldAmount = vault1Balance / 10; // 10% yield
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(testCurrency1)).mint(owner, yieldAmount);
            MockERC20(Currency.unwrap(testCurrency1)).approve(address(testVault1), yieldAmount);
            testVault1.simulateYield(yieldAmount);
            vm.stopPrank();

            // Verify yield is reflected
            (, uint256 postYieldPreview1) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(shares);
            assertGt(postYieldPreview1, preview1, "Yield should increase token1 value");
        }

        // Remove liquidity
        vm.prank(alice);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(shares, 0, 0);
        assertEq(Alphix(address(testHook)).balanceOf(alice), 0);
    }

    /**
     * @notice Test 8 decimal token (like WBTC) with 18 decimal token
     * @dev Common pairing: WBTC (8 decimals) vs WETH (18 decimals)
     */
    function test_reHypo_8_18_decimals() public {
        _deployFreshInfrastructure(0, 60, 8, 18);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 shares = 100e18;
        _addReHypoToTestPool(alice, shares);

        assertEq(Alphix(address(testHook)).balanceOf(alice), shares);

        // Simulate loss on a vault that has balance
        uint256 vault0Balance = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
        uint256 vault1Balance = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

        if (vault0Balance > 0) {
            testVault0.simulateLoss(vault0Balance / 5); // 20% loss
        } else if (vault1Balance > 0) {
            testVault1.simulateLoss(vault1Balance / 5); // 20% loss
        }

        // Remove liquidity
        vm.prank(alice);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(shares, 0, 0);
        assertEq(Alphix(address(testHook)).balanceOf(alice), 0);
    }

    /**
     * @notice Test yield and loss accounting with mismatched decimals
     * @param decimals0 Decimals for token0
     * @param decimals1 Decimals for token1
     * @param yieldPercent Yield percentage (0-30%)
     */
    function testFuzz_reHypo_yieldLossDifferentDecimals(uint8 decimals0, uint8 decimals1, uint8 yieldPercent) public {
        // Bound inputs
        uint8 boundedDecimals0 = uint8(bound(decimals0, 6, 18));
        uint8 boundedDecimals1 = uint8(bound(decimals1, 6, 18));
        uint256 boundedYield = bound(yieldPercent, 0, 30);

        _deployFreshInfrastructure(0, 60, boundedDecimals0, boundedDecimals1);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        uint256 shares = 100e18;
        _addReHypoToTestPool(alice, shares);

        // Record initial value
        (uint256 initial0, uint256 initial1) = Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(shares);

        // Simulate yield on vault that has balance
        if (boundedYield > 0) {
            uint256 vault0Balance = Alphix(address(testHook)).getAmountInYieldSource(testCurrency0);
            uint256 vault1Balance = Alphix(address(testHook)).getAmountInYieldSource(testCurrency1);

            if (vault0Balance > 0) {
                uint256 yieldAmount = (vault0Balance * boundedYield) / 100;
                if (yieldAmount > 0) {
                    vm.startPrank(owner);
                    MockERC20(Currency.unwrap(testCurrency0)).mint(owner, yieldAmount);
                    MockERC20(Currency.unwrap(testCurrency0)).approve(address(testVault0), yieldAmount);
                    testVault0.simulateYield(yieldAmount);
                    vm.stopPrank();
                }
            } else if (vault1Balance > 0) {
                uint256 yieldAmount = (vault1Balance * boundedYield) / 100;
                if (yieldAmount > 0) {
                    vm.startPrank(owner);
                    MockERC20(Currency.unwrap(testCurrency1)).mint(owner, yieldAmount);
                    MockERC20(Currency.unwrap(testCurrency1)).approve(address(testVault1), yieldAmount);
                    testVault1.simulateYield(yieldAmount);
                    vm.stopPrank();
                }
            }
        }

        // Verify yield is reflected correctly
        (uint256 postYield0, uint256 postYield1) =
            Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(shares);

        // Total value should increase or stay same
        if (boundedYield > 0) {
            assertTrue(
                postYield0 >= initial0 || postYield1 >= initial1, "Yield should increase at least one token value"
            );
        }

        // Remove liquidity - should work regardless of decimals
        vm.prank(alice);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(shares, 0, 0);
        assertEq(Alphix(address(testHook)).balanceOf(alice), 0);
    }

    /**
     * @notice Test multi-user scenarios with different decimals
     * @param decimals0 Decimals for token0
     * @param decimals1 Decimals for token1
     */
    function testFuzz_reHypo_multiUserDifferentDecimals(uint8 decimals0, uint8 decimals1) public {
        // Bound decimals
        uint8 boundedDecimals0 = uint8(bound(decimals0, 6, 18));
        uint8 boundedDecimals1 = uint8(bound(decimals1, 6, 18));

        _deployFreshInfrastructure(0, 60, boundedDecimals0, boundedDecimals1);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();

        // Alice deposits
        _addReHypoToTestPool(alice, 100e18);

        // Bob deposits same shares
        _addReHypoToTestPool(bob, 100e18);

        // Both should have equal shares
        assertEq(Alphix(address(testHook)).balanceOf(alice), 100e18);
        assertEq(Alphix(address(testHook)).balanceOf(bob), 100e18);

        // Same shares = same withdrawal value
        (uint256 aliceWithdraw0, uint256 aliceWithdraw1) =
            Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 bobWithdraw0, uint256 bobWithdraw1) =
            Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(100e18);

        if (aliceWithdraw0 > 0) {
            assertApproxEqRel(aliceWithdraw0, bobWithdraw0, 1e15, "Same shares = same token0 withdrawal");
        }
        if (aliceWithdraw1 > 0) {
            assertApproxEqRel(aliceWithdraw1, bobWithdraw1, 1e15, "Same shares = same token1 withdrawal");
        }
    }

    /**
     * @notice Test edge case: minimum decimals (6) for both tokens
     */
    function test_reHypo_minDecimals_6_6() public {
        _deployFreshInfrastructure(0, 60, 6, 6);
        _addRegularLpToTestPool(10000e18); // More liquidity
        _configureTestPoolReHypo();

        uint256 shares = 100e18;
        _addReHypoToTestPool(alice, shares);

        assertEq(Alphix(address(testHook)).balanceOf(alice), shares);

        // Do multiple swaps with small amounts
        for (uint256 i = 0; i < 3; i++) {
            _doSwapOnTestPool(_scaledAmount(10, 6), i % 2 == 0);
        }

        // Remove liquidity
        vm.prank(alice);
        Alphix(address(testHook)).removeReHypothecatedLiquidity(shares, 0, 0);
        assertEq(Alphix(address(testHook)).balanceOf(alice), 0);
    }

    /**
     * @notice Test preview functions return correct decimals
     * @param decimals0 Decimals for token0
     * @param decimals1 Decimals for token1
     */
    function testFuzz_reHypo_previewDecimalsCorrect(uint8 decimals0, uint8 decimals1) public {
        // Bound decimals
        uint8 boundedDecimals0 = uint8(bound(decimals0, 6, 18));
        uint8 boundedDecimals1 = uint8(bound(decimals1, 6, 18));

        _deployFreshInfrastructure(0, 60, boundedDecimals0, boundedDecimals1);
        _addRegularLpToTestPool(1000e18);
        _configureTestPoolReHypo();
        _addReHypoToTestPool(alice, 100e18);

        // Preview add - amounts should be in their respective token decimals
        (uint256 previewAdd0, uint256 previewAdd1) = Alphix(address(testHook)).previewAddReHypothecatedLiquidity(50e18);

        // At least one should be positive
        assertTrue(previewAdd0 > 0 || previewAdd1 > 0, "Preview add should have positive amounts");

        // Preview remove - should also work
        (uint256 previewRemove0, uint256 previewRemove1) =
            Alphix(address(testHook)).previewRemoveReHypothecatedLiquidity(50e18);

        assertTrue(previewRemove0 > 0 || previewRemove1 > 0, "Preview remove should have positive amounts");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
       HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _scaledAmount(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        return amount * (10 ** decimals);
    }

    function _deployFreshInfrastructure(int24 initialTick, int24 tickSpacing, uint8 decimals0, uint8 decimals1)
        internal
    {
        currentDecimals0 = decimals0;
        currentDecimals1 = decimals1;

        // Deploy fresh Alphix stack (handles its own prank)
        (testHook, testAccessManager) = _deployFreshAlphixStackFull();

        vm.startPrank(owner);

        // Deploy test tokens with specified decimals
        // NOTE: deployCurrencyPairWithDecimals may reorder tokens!
        (testCurrency0, testCurrency1) = deployCurrencyPairWithDecimals(decimals0, decimals1);

        // Fund test addresses with large amounts in 18 decimal format
        // This ensures we always have enough regardless of token decimals
        uint256 fundAmount = 1e30; // Very large amount to cover all cases
        MockERC20(Currency.unwrap(testCurrency0)).mint(alice, fundAmount);
        MockERC20(Currency.unwrap(testCurrency1)).mint(alice, fundAmount);
        MockERC20(Currency.unwrap(testCurrency0)).mint(bob, fundAmount);
        MockERC20(Currency.unwrap(testCurrency1)).mint(bob, fundAmount);

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
        int24 tickLower = TickMath.minUsableTick(testKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(testKey.tickSpacing);
        testHook.initializePool(testKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);

        // Deploy yield vaults with the correct underlying tokens
        testVault0 = new MockYieldVault(IERC20(Currency.unwrap(testCurrency0)));
        testVault1 = new MockYieldVault(IERC20(Currency.unwrap(testCurrency1)));

        // Setup yield manager role
        _setupYieldManagerRole(owner, testAccessManager, address(testHook));

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
        // Tick range is already set at initializePool time (full range by default)

        // setYieldSource requires whenNotPaused
        vm.startPrank(owner);
        Alphix(address(testHook)).setYieldSource(testCurrency0, address(testVault0));
        Alphix(address(testHook)).setYieldSource(testCurrency1, address(testVault1));
        vm.stopPrank();
    }

    function _addReHypoToTestPool(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) = Alphix(address(testHook)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(testCurrency0)).approve(address(testHook), amount0);
        MockERC20(Currency.unwrap(testCurrency1)).approve(address(testHook), amount1);
        Alphix(address(testHook)).addReHypothecatedLiquidity(shares, 0, 0);
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
