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

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* SOLMATE IMPORTS */

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixLogicETH} from "../../../../src/AlphixLogicETH.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title ReHypothecationETHSwapsTest
 * @notice Comprehensive tests for ReHypothecation + Swaps in ETH pools
 * @dev Tests JIT liquidity provisioning from yield sources during swaps
 */
contract ReHypothecationETHSwapsTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;

    MockYieldVault public wethVault;
    MockYieldVault public tokenVault;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        token.mint(alice, INITIAL_TOKEN_AMOUNT);
        token.mint(bob, INITIAL_TOKEN_AMOUNT);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, payable(address(logic)));
        vm.stopPrank();

        wethVault = new MockYieldVault(IERC20(address(weth)));
        tokenVault = new MockYieldVault(IERC20(address(token)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        BASIC SWAP WITH REHYPOTHECATION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test ETH->Token swap with full rehypo setup
     * @dev This was the failing test case before the fix
     */
    function test_swap_ethToToken_withReHypo() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        uint256 aliceTokenBefore = token.balanceOf(alice);
        uint256 ethInYieldBefore =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYieldBefore =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        // Swap 1 ETH -> Token
        vm.startPrank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify swap succeeded
        assertGt(token.balanceOf(alice), aliceTokenBefore, "Alice should have received tokens");

        // Verify yield sources are still operational
        uint256 ethInYieldAfter =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYieldAfter =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        // After zeroForOne swap, ETH in yield should increase, token should decrease
        assertGt(ethInYieldAfter, ethInYieldBefore, "ETH in yield should increase after ETH->Token swap");
        assertLt(tokenInYieldAfter, tokenInYieldBefore, "Token in yield should decrease after ETH->Token swap");
    }

    /**
     * @notice Test Token->ETH swap with full rehypo setup
     */
    function test_swap_tokenToEth_withReHypo() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        uint256 aliceEthBefore = alice.balance;
        uint256 ethInYieldBefore =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYieldBefore =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        // Swap 1 Token -> ETH
        vm.startPrank(alice);
        token.approve(address(swapRouter), 1e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify swap succeeded
        assertGt(alice.balance, aliceEthBefore, "Alice should have received ETH");

        // Verify yield sources are still operational
        uint256 ethInYieldAfter =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYieldAfter =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        // After oneForZero swap, ETH in yield should decrease, token should increase
        assertLt(ethInYieldAfter, ethInYieldBefore, "ETH in yield should decrease after Token->ETH swap");
        assertGt(tokenInYieldAfter, tokenInYieldBefore, "Token in yield should increase after Token->ETH swap");
    }

    /**
     * @notice Test swap without rehypo configured (should work normally)
     */
    function test_swap_ethToToken_withoutReHypo() public {
        _addRegularLp(100 ether);

        uint256 aliceTokenBefore = token.balanceOf(alice);

        // Swap 1 ETH -> Token
        vm.startPrank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertGt(token.balanceOf(alice), aliceTokenBefore, "Swap without rehypo should work");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            MULTIPLE SWAPS TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test multiple consecutive swaps in same direction
     */
    function test_multipleSwaps_sameDirection() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        uint256 initialTokenInYield =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        // Perform 5 consecutive ETH->Token swaps
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(alice);
            swapRouter.swapExactTokensForTokens{value: 0.5 ether}({
                amountIn: 0.5 ether,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: alice,
                deadline: block.timestamp + 100
            });
        }

        uint256 finalTokenInYield =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        // Token in yield should have decreased significantly
        assertLt(finalTokenInYield, initialTokenInYield, "Token in yield should decrease after multiple swaps");
    }

    /**
     * @notice Test alternating swap directions
     */
    function test_multipleSwaps_alternatingDirections() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Perform alternating swaps
        for (uint256 i = 0; i < 6; i++) {
            if (i % 2 == 0) {
                // ETH -> Token
                vm.prank(alice);
                swapRouter.swapExactTokensForTokens{value: 0.5 ether}({
                    amountIn: 0.5 ether,
                    amountOutMin: 0,
                    zeroForOne: true,
                    poolKey: key,
                    hookData: Constants.ZERO_BYTES,
                    receiver: alice,
                    deadline: block.timestamp + 100
                });
            } else {
                // Token -> ETH
                vm.startPrank(alice);
                token.approve(address(swapRouter), 0.5e18);
                swapRouter.swapExactTokensForTokens({
                    amountIn: 0.5e18,
                    amountOutMin: 0,
                    zeroForOne: false,
                    poolKey: key,
                    hookData: Constants.ZERO_BYTES,
                    receiver: alice,
                    deadline: block.timestamp + 100
                });
                vm.stopPrank();
            }
        }

        // All swaps should have completed successfully
        // Yield sources should still have positive balances
        uint256 ethInYield = AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYield =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        assertGt(ethInYield, 0, "ETH in yield should be positive");
        assertGt(tokenInYield, 0, "Token in yield should be positive");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            DIFFERENT POOL PRICES TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test swap at skewed price (more ETH in pool)
     */
    function test_swap_atSkewedPrice_moreEth() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Skew the price by doing a large swap first
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: 20 ether}({
            amountIn: 20 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });

        // Now test swap at new price
        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        assertGt(token.balanceOf(alice), aliceTokenBefore, "Swap at skewed price should work");
    }

    /**
     * @notice Test swap at skewed price (more Token in pool)
     */
    function test_swap_atSkewedPrice_moreToken() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Skew the price by doing a large swap first
        vm.startPrank(bob);
        token.approve(address(swapRouter), 20e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 20e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Now test swap at new price
        vm.startPrank(alice);
        token.approve(address(swapRouter), 1e18);
        uint256 aliceEthBefore = alice.balance;
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertGt(alice.balance, aliceEthBefore, "Swap at skewed price should work");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        DIFFERENT TICK RANGES TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test with narrow rehypo tick range
     */
    function test_swap_narrowReHypoRange() public {
        _addRegularLp(100 ether);

        // Configure narrow tick range (around current price)
        int24 narrowLower = -100 * defaultTickSpacing;
        int24 narrowUpper = 100 * defaultTickSpacing;

        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(narrowLower, narrowUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 10e18);

        // Test swap
        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Test with asymmetric rehypo tick range
     */
    function test_swap_asymmetricReHypoRange() public {
        _addRegularLp(100 ether);

        // Configure asymmetric tick range
        int24 asymLower = -200 * defaultTickSpacing;
        int24 asymUpper = 50 * defaultTickSpacing;

        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(asymLower, asymUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 10e18);

        // Test swap in both directions
        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        vm.startPrank(alice);
        token.approve(address(swapRouter), 1e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 1e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        YIELD SCENARIOS TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test swap after positive yield
     */
    function test_swap_afterPositiveYield() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate positive yield
        uint256 yield0 = 1 ether;
        uint256 yield1 = 1e18;
        vm.startPrank(owner);
        weth.deposit{value: yield0}();
        weth.approve(address(wethVault), yield0);
        wethVault.simulateYield(yield0);
        token.mint(owner, yield1);
        token.approve(address(tokenVault), yield1);
        tokenVault.simulateYield(yield1);
        vm.stopPrank();

        // Swap should work with yield
        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Test swap after negative yield (loss)
     */
    function test_swap_afterNegativeYield() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate 10% loss
        uint256 ethInYield = AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYield =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));
        wethVault.simulateLoss(ethInYield / 10);
        tokenVault.simulateLoss(tokenInYield / 10);

        // Swap should still work after loss
        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 0.5 ether}({
            amountIn: 0.5 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Test swap triggers tax accumulation
     */
    function test_swap_accumulatesTaxFromYield() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate positive yield
        uint256 yield1 = 10e18;
        vm.startPrank(owner);
        token.mint(owner, yield1);
        token.approve(address(tokenVault), yield1);
        tokenVault.simulateYield(yield1);
        vm.stopPrank();

        // Do a swap that triggers JIT
        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        // Collect tax
        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();
        uint256 treasuryTokenAfter = token.balanceOf(treasury);

        // Treasury should have received some tax
        assertGt(treasuryTokenAfter, treasuryTokenBefore, "Treasury should receive tax from yield");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        TAX COLLECTION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test tax collection with different tax rates
     */
    function test_taxCollection_differentRates() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate yield
        uint256 yield1 = 100e18;
        vm.startPrank(owner);
        token.mint(owner, yield1);
        token.approve(address(tokenVault), yield1);
        tokenVault.simulateYield(yield1);
        vm.stopPrank();

        // Collect tax at 10% rate
        (, uint256 collected1) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();

        // Tax should be approximately 10% of yield
        assertApproxEqAbs(collected1, yield1 / 10, 2, "Tax should be ~10% of yield");
    }

    /**
     * @notice Test tax collection goes to treasury
     * @dev Note: For ETH pools, currency0 tax is sent as native ETH, not WETH
     */
    function test_taxCollection_goesToTreasury() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate yield on both currencies
        uint256 yield0 = 1 ether;
        uint256 yield1 = 100e18;

        vm.startPrank(owner);
        weth.deposit{value: yield0}();
        weth.approve(address(wethVault), yield0);
        wethVault.simulateYield(yield0);

        token.mint(owner, yield1);
        token.approve(address(tokenVault), yield1);
        tokenVault.simulateYield(yield1);
        vm.stopPrank();

        // For ETH pools, treasury receives native ETH for currency0
        uint256 treasuryEthBefore = treasury.balance;
        uint256 treasuryTokenBefore = token.balanceOf(treasury);

        // Collect tax
        (uint256 collectedEth, uint256 collectedToken) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();

        uint256 treasuryEthAfter = treasury.balance;
        uint256 treasuryTokenAfter = token.balanceOf(treasury);

        // Treasury should receive the tax
        assertEq(treasuryEthAfter - treasuryEthBefore, collectedEth, "Treasury should receive ETH tax");
        assertEq(treasuryTokenAfter - treasuryTokenBefore, collectedToken, "Treasury should receive token tax");
    }

    /**
     * @notice Test tax collection with zero tax rate
     */
    function test_taxCollection_zeroTaxRate() public {
        _addRegularLp(100 ether);

        // Configure with 0% tax
        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(0); // 0% tax
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 10e18);

        // Simulate yield
        uint256 yield1 = 100e18;
        vm.startPrank(owner);
        token.mint(owner, yield1);
        token.approve(address(tokenVault), yield1);
        tokenVault.simulateYield(yield1);
        vm.stopPrank();

        // Collect tax - should be 0
        (, uint256 collected1) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();
        assertEq(collected1, 0, "No tax should be collected with 0% rate");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        EDGE CASES
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test swap with only regular LP (no rehypo)
     */
    function test_swap_onlyRegularLP() public {
        _addRegularLp(100 ether);

        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Test swap with significant rehypo LP contribution
     * @dev JIT provides substantial liquidity alongside regular LP
     */
    function test_swap_significantReHypoLP() public {
        // Add standard regular LP
        _addRegularLp(100 ether);
        _configureReHypo();
        // Add significant rehypo position (same size as regular LP)
        _addReHypoLiquidity(alice, 100e18);

        uint256 ethInYieldBefore =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));

        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        // Verify swap worked and rehypo was used
        uint256 ethInYieldAfter =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        assertGt(ethInYieldAfter, ethInYieldBefore, "ETH in yield should increase after ETH->Token swap");
    }

    /**
     * @notice Test small swap (dust amounts)
     */
    function test_swap_smallAmount() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Very small swap
        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: 0.001 ether}({
            amountIn: 0.001 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Test large swap relative to rehypo liquidity
     */
    function test_swap_largeRelativeToReHypo() public {
        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Large swap that exceeds rehypo liquidity
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: 50 ether}({
            amountIn: 50 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _addRegularLp(uint256 ethAmount) internal {
        vm.startPrank(owner);

        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        positionManager.mint(
            key,
            fullRangeLower,
            fullRangeUpper,
            100e18,
            ethAmount,
            1000e18,
            owner,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _configureReHypo() internal {
        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000); // 10%
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();
    }

    function _addReHypoLiquidity(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
