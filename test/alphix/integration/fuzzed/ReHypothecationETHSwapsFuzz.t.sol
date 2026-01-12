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

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixLogicETH} from "../../../../src/AlphixLogicETH.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title ReHypothecationETHSwapsFuzzTest
 * @notice Fuzz tests for ReHypothecation + Swaps in ETH pools
 * @dev Tests JIT liquidity provisioning with fuzzed parameters
 */
contract ReHypothecationETHSwapsFuzzTest is BaseAlphixETHTest {
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

    // Bounds for fuzz testing
    uint256 constant MIN_SWAP_AMOUNT = 0.001 ether;
    uint256 constant MAX_SWAP_AMOUNT = 50 ether;
    uint256 constant MIN_REHYPO_SHARES = 1e18;
    uint256 constant MAX_REHYPO_SHARES = 100e18;
    uint256 constant MIN_YIELD = 0.001 ether;
    uint256 constant MAX_YIELD = 10 ether;
    uint24 constant MAX_TAX_PIPS = 500_000; // 50% max for tests

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.deal(alice, 10000 ether);
        vm.deal(bob, 10000 ether);
        token.mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        token.mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, payable(address(logic)));
        vm.stopPrank();

        wethVault = new MockYieldVault(IERC20(address(weth)));
        tokenVault = new MockYieldVault(IERC20(address(token)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: SWAP AMOUNTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test ETH->Token swap amounts with rehypo
     */
    function testFuzz_swap_ethToToken_varyingAmounts(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);

        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 50e18);

        uint256 aliceTokenBefore = token.balanceOf(alice);

        vm.prank(alice);
        swapRouter.swapExactTokensForTokens{value: swapAmount}({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        assertGt(token.balanceOf(alice), aliceTokenBefore, "Swap should succeed");
    }

    /**
     * @notice Fuzz test Token->ETH swap amounts with rehypo
     */
    function testFuzz_swap_tokenToEth_varyingAmounts(uint256 swapAmount) public {
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);

        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 50e18);

        uint256 aliceEthBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertGt(alice.balance, aliceEthBefore, "Swap should succeed");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: REHYPO SHARES
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test varying rehypo share amounts
     */
    function testFuzz_swap_varyingReHypoShares(uint256 shares) public {
        shares = bound(shares, MIN_REHYPO_SHARES, MAX_REHYPO_SHARES);

        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, shares);

        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });

        // Yield source should still be functional
        uint256 ethInYieldAfter =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        assertGt(ethInYieldAfter, 0, "ETH in yield should be positive");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: TICK RANGES
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test varying rehypo tick ranges
     */
    function testFuzz_swap_varyingTickRanges(int24 lowerMultiple, int24 upperMultiple) public {
        // Bound tick multiples to reasonable ranges
        lowerMultiple = int24(bound(int256(lowerMultiple), -500, -10));
        upperMultiple = int24(bound(int256(upperMultiple), 10, 500));

        int24 tickLower = lowerMultiple * defaultTickSpacing;
        int24 tickUpper = upperMultiple * defaultTickSpacing;

        // Ensure range includes current tick (0)
        if (tickLower > 0) tickLower = -10 * defaultTickSpacing;
        if (tickUpper < 0) tickUpper = 10 * defaultTickSpacing;

        _addRegularLp(100 ether);

        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 10e18);

        // Swap should work regardless of tick range
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: YIELD SCENARIOS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test swaps with varying positive yield
     */
    function testFuzz_swap_afterPositiveYield(uint256 yieldAmount) public {
        yieldAmount = bound(yieldAmount, MIN_YIELD, MAX_YIELD);

        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate positive yield
        vm.startPrank(owner);
        weth.deposit{value: yieldAmount}();
        weth.approve(address(wethVault), yieldAmount);
        wethVault.simulateYield(yieldAmount);
        vm.stopPrank();

        // Swap should work with yield
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Fuzz test swaps with varying negative yield (loss)
     */
    function testFuzz_swap_afterNegativeYield(uint8 lossPercent) public {
        // Bound loss to 1-50%
        lossPercent = uint8(bound(lossPercent, 1, 50));

        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 10e18);

        // Simulate loss
        uint256 ethInYield = AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 loss = (ethInYield * lossPercent) / 100;
        if (loss > 0 && loss < ethInYield) {
            wethVault.simulateLoss(loss);
        }

        // Swap should still work after loss (smaller swap to avoid liquidity issues)
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: 0.1 ether}({
            amountIn: 0.1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: TAX RATES
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test tax collection with varying tax rates
     */
    function testFuzz_taxCollection_varyingRates(uint24 taxPips) public {
        taxPips = uint24(bound(taxPips, 0, MAX_TAX_PIPS));

        _addRegularLp(100 ether);

        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(taxPips);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 10e18);

        // Simulate yield
        uint256 yield1 = 10e18;
        vm.startPrank(owner);
        token.mint(owner, yield1);
        token.approve(address(tokenVault), yield1);
        tokenVault.simulateYield(yield1);
        vm.stopPrank();

        uint256 treasuryTokenBefore = token.balanceOf(treasury);

        // Collect tax
        (, uint256 collected1) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();

        uint256 treasuryTokenAfter = token.balanceOf(treasury);

        // Calculate expected tax (with tolerance for rounding)
        uint256 expectedTax = (yield1 * taxPips) / 1_000_000;

        if (taxPips == 0) {
            assertEq(collected1, 0, "Zero tax rate should collect nothing");
        } else {
            assertApproxEqAbs(collected1, expectedTax, 10, "Tax should be proportional to rate");
            assertEq(treasuryTokenAfter - treasuryTokenBefore, collected1, "Treasury should receive tax");
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: MULTIPLE SWAPS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test multiple consecutive swaps
     */
    function testFuzz_multipleSwaps(uint8 numSwaps, uint256 swapAmount) public {
        numSwaps = uint8(bound(numSwaps, 1, 10));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, 5 ether);

        _addRegularLp(100 ether);
        _configureReHypo();
        _addReHypoLiquidity(alice, 50e18);

        for (uint8 i = 0; i < numSwaps; i++) {
            if (i % 2 == 0) {
                // ETH -> Token
                vm.prank(bob);
                swapRouter.swapExactTokensForTokens{value: swapAmount}({
                    amountIn: swapAmount,
                    amountOutMin: 0,
                    zeroForOne: true,
                    poolKey: key,
                    hookData: Constants.ZERO_BYTES,
                    receiver: bob,
                    deadline: block.timestamp + 100
                });
            } else {
                // Token -> ETH
                vm.startPrank(bob);
                token.approve(address(swapRouter), swapAmount);
                swapRouter.swapExactTokensForTokens({
                    amountIn: swapAmount,
                    amountOutMin: 0,
                    zeroForOne: false,
                    poolKey: key,
                    hookData: Constants.ZERO_BYTES,
                    receiver: bob,
                    deadline: block.timestamp + 100
                });
                vm.stopPrank();
            }
        }

        // Verify yield sources are still operational
        uint256 ethInYield = AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(0)));
        uint256 tokenInYield =
            AlphixLogicETH(payable(address(logic))).getAmountInYieldSource(Currency.wrap(address(token)));

        assertGt(ethInYield, 0, "ETH in yield should be positive");
        assertGt(tokenInYield, 0, "Token in yield should be positive");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ: COMBINED SCENARIOS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test complete scenario: add rehypo, yield, swap, collect tax
     */
    function testFuzz_fullScenario(uint256 shares, uint256 swapAmount, uint256 yieldAmount, uint24 taxPips) public {
        shares = bound(shares, MIN_REHYPO_SHARES, MAX_REHYPO_SHARES);
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, 10 ether);
        yieldAmount = bound(yieldAmount, MIN_YIELD, MAX_YIELD);
        taxPips = uint24(bound(taxPips, 10_000, MAX_TAX_PIPS)); // At least 1% tax

        _addRegularLp(100 ether);

        // Configure with fuzzed tax rate
        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(token)), address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(taxPips);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        // Add rehypo liquidity
        _addReHypoLiquidity(alice, shares);

        // Simulate yield
        vm.startPrank(owner);
        token.mint(owner, yieldAmount);
        token.approve(address(tokenVault), yieldAmount);
        tokenVault.simulateYield(yieldAmount);
        vm.stopPrank();

        // Perform swap
        vm.prank(bob);
        swapRouter.swapExactTokensForTokens{value: swapAmount}({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });

        // Collect tax
        uint256 treasuryTokenBefore = token.balanceOf(treasury);
        (, uint256 collected1) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();
        uint256 treasuryTokenAfter = token.balanceOf(treasury);

        // Verify tax went to treasury
        assertEq(treasuryTokenAfter - treasuryTokenBefore, collected1, "Treasury should receive collected tax");
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
