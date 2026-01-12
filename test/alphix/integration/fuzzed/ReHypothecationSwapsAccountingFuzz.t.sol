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
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title ReHypothecationSwapsAccountingFuzzTest
 * @notice Fuzz tests for ReHypothecation + Swaps with ERC20-ERC20 pools (non-ETH)
 * @dev Tests value conservation, JIT participation, and accounting invariants
 */
contract ReHypothecationSwapsAccountingFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    // For tracking accounting
    struct AccountingSnapshot {
        uint256 aliceToken0;
        uint256 aliceToken1;
        uint256 bobToken0;
        uint256 bobToken1;
        uint256 vault0Balance;
        uint256 vault1Balance;
        uint256 poolManagerToken0;
        uint256 poolManagerToken1;
        uint256 logicToken0;
        uint256 logicToken1;
        uint256 treasuryToken0;
        uint256 treasuryToken1;
    }

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Fund users with large amounts for fuzzing
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(logic));
        vm.stopPrank();

        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ TESTS - VALUE CONSERVATION
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test: Total value is conserved during swaps with various swap amounts
     */
    function testFuzz_accounting_valueConserved_varyingSwapAmount(uint256 swapAmount) public {
        // Bound swap amount to reasonable range (1e15 to 100e18)
        swapAmount = bound(swapAmount, 1e15, 100e18);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        AccountingSnapshot memory before = _takeSnapshot();
        uint256 totalToken0Before = before.aliceToken0 + before.bobToken0 + before.vault0Balance
            + before.poolManagerToken0 + before.logicToken0 + before.treasuryToken0;
        uint256 totalToken1Before = before.aliceToken1 + before.bobToken1 + before.vault1Balance
            + before.poolManagerToken1 + before.logicToken1 + before.treasuryToken1;

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

        AccountingSnapshot memory after_ = _takeSnapshot();
        uint256 totalToken0After = after_.aliceToken0 + after_.bobToken0 + after_.vault0Balance
            + after_.poolManagerToken0 + after_.logicToken0 + after_.treasuryToken0;
        uint256 totalToken1After = after_.aliceToken1 + after_.bobToken1 + after_.vault1Balance
            + after_.poolManagerToken1 + after_.logicToken1 + after_.treasuryToken1;

        assertEq(totalToken0Before, totalToken0After, "Token0 total should be conserved");
        assertEq(totalToken1Before, totalToken1After, "Token1 total should be conserved");
    }

    /**
     * @notice Fuzz test: Multiple swaps don't leak tokens
     */
    function testFuzz_accounting_multipleSwapsConserved(uint8 swapCount) public {
        // Bound swap count to 1-20
        swapCount = uint8(bound(swapCount, 1, 20));

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        AccountingSnapshot memory before = _takeSnapshot();
        uint256 totalToken0Before = before.aliceToken0 + before.bobToken0 + before.vault0Balance
            + before.poolManagerToken0 + before.logicToken0;

        for (uint256 i = 0; i < swapCount; i++) {
            bool zeroForOne = i % 2 == 0;
            uint256 swapAmount = 1e18;

            vm.startPrank(bob);
            if (zeroForOne) {
                MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
            } else {
                MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount);
            }
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: zeroForOne,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
            vm.stopPrank();
        }

        AccountingSnapshot memory after_ = _takeSnapshot();
        uint256 totalToken0After = after_.aliceToken0 + after_.bobToken0 + after_.vault0Balance
            + after_.poolManagerToken0 + after_.logicToken0;

        assertEq(totalToken0Before, totalToken0After, "Token0 should be conserved after multiple swaps");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ TESTS - REHYPO LIQUIDITY
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test: Varying rehypo liquidity amounts
     */
    function testFuzz_rehypo_varyingLiquidityAmount(uint256 shares) public {
        // Bound shares to reasonable range (1e16 to 1000e18)
        shares = bound(shares, 1e16, 1000e18);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, shares);

        // Verify shares are correctly minted
        assertEq(AlphixLogic(address(logic)).balanceOf(alice), shares, "Shares should match deposited");

        // Do a swap to test JIT works
        uint256 swapAmount = 10e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        uint256 bobToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(bob);
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

        uint256 output = MockERC20(Currency.unwrap(currency1)).balanceOf(bob) - bobToken1Before;
        assertGt(output, 0, "Swap should succeed with rehypo");
    }

    /**
     * @notice Fuzz test: Varying tick ranges for JIT position
     */
    function testFuzz_rehypo_varyingTickRange(int24 tickLower, int24 tickUpper) public {
        // Bound tick range to valid values
        int24 minTick = TickMath.minUsableTick(defaultTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(defaultTickSpacing);

        tickLower = int24(bound(int256(tickLower), int256(minTick), int256(maxTick) - defaultTickSpacing));
        tickUpper = int24(bound(int256(tickUpper), int256(tickLower) + defaultTickSpacing, int256(maxTick)));

        // Ensure tick alignment
        // forge-lint: disable-next-line(divide-before-multiply)
        tickLower = (tickLower / defaultTickSpacing) * defaultTickSpacing;
        // forge-lint: disable-next-line(divide-before-multiply)
        tickUpper = (tickUpper / defaultTickSpacing) * defaultTickSpacing;
        if (tickUpper <= tickLower) tickUpper = tickLower + defaultTickSpacing;

        _addRegularLp(1000e18);

        vm.startPrank(yieldManager);
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setYieldTaxPips(100_000);
        AlphixLogic(address(logic)).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Swap should work regardless of tick range
        uint256 swapAmount = 10e18;
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
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ TESTS - TAX CALCULATIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test: Varying tax rates
     */
    function testFuzz_tax_varyingTaxRate(uint24 taxPips) public {
        // Bound tax rate to valid range (0 to 1_000_000 - max 100%)
        taxPips = uint24(bound(taxPips, 0, 1_000_000));

        _addRegularLp(1000e18);

        vm.startPrank(yieldManager);
        AlphixLogic(address(logic)).setTickRange(fullRangeLower, fullRangeUpper);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setYieldTaxPips(taxPips);
        AlphixLogic(address(logic)).setYieldTreasury(treasury);
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Simulate yield
        uint256 yield0 = 100e18;
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        vault0.simulateYield(yield0);
        vm.stopPrank();

        // Collect tax
        (uint256 collected0,) = AlphixLogic(address(logic)).collectAccumulatedTax();

        // Calculate expected tax
        uint256 expectedTax0 = (yield0 * taxPips) / 1_000_000;

        // Allow 10 wei tolerance for rounding (ERC4626 has internal rounding)
        assertApproxEqAbs(collected0, expectedTax0, 10, "Tax should match expected rate");
    }

    /**
     * @notice Fuzz test: Varying yield amounts
     */
    function testFuzz_tax_varyingYieldAmount(uint256 yieldAmount) public {
        // Bound yield to reasonable range
        yieldAmount = bound(yieldAmount, 1e15, 1000e18);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        uint24 taxPips = AlphixLogic(address(logic)).getReHypothecationConfig().yieldTaxPips;

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yieldAmount);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yieldAmount);
        vault0.simulateYield(yieldAmount);
        vm.stopPrank();

        (uint256 collected0,) = AlphixLogic(address(logic)).collectAccumulatedTax();
        uint256 expectedTax0 = (yieldAmount * taxPips) / 1_000_000;

        // Allow 0.001% relative tolerance for rounding (ERC4626 has internal rounding)
        assertApproxEqRel(collected0, expectedTax0, 1e13, "Tax should be proportional to yield");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ TESTS - JIT PARTICIPATION
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test: JIT participation with varying swap amounts
     */
    function testFuzz_jit_participationVariesWithSwapSize(uint256 swapAmount) public {
        // Bound to reasonable swap size
        swapAmount = bound(swapAmount, 1e17, 50e18);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);

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

        // For zeroForOne swap: JIT gains token0, loses token1
        assertGe(yieldSource0After, yieldSource0Before, "JIT should not lose token0 on zeroForOne");
        assertLe(yieldSource1After, yieldSource1Before, "JIT should provide token1 on zeroForOne");
    }

    /**
     * @notice Fuzz test: Swap direction
     */
    function testFuzz_jit_swapDirection(bool zeroForOne, uint256 swapAmount) public {
        swapAmount = bound(swapAmount, 1e17, 50e18);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);

        vm.startPrank(bob);
        if (zeroForOne) {
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        } else {
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount);
        }
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0After = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);

        if (zeroForOne) {
            // JIT gains token0, provides token1
            assertGe(yieldSource0After, yieldSource0Before, "JIT should gain or maintain token0");
        } else {
            // JIT gains token1, provides token0
            assertGe(yieldSource1After, yieldSource1Before, "JIT should gain or maintain token1");
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FUZZ TESTS - SHARE VALUE
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test: Share value after yield
     */
    function testFuzz_shares_valueAfterYield(uint256 yieldPercent) public {
        // Bound yield to 0-100%
        yieldPercent = bound(yieldPercent, 0, 100);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        (uint256 previewBefore0, uint256 previewBefore1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Calculate yield amount
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 amountInVault1 = AlphixLogic(address(logic)).getAmountInYieldSource(currency1);
        uint256 yield0 = (amountInVault0 * yieldPercent) / 100;
        uint256 yield1 = (amountInVault1 * yieldPercent) / 100;

        // Add yield
        if (yield0 > 0) {
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
            MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
            vault0.simulateYield(yield0);
            vm.stopPrank();
        }
        if (yield1 > 0) {
            vm.startPrank(owner);
            MockERC20(Currency.unwrap(currency1)).mint(owner, yield1);
            MockERC20(Currency.unwrap(currency1)).approve(address(vault1), yield1);
            vault1.simulateYield(yield1);
            vm.stopPrank();
        }

        (uint256 previewAfter0, uint256 previewAfter1) =
            AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Share value should increase with yield (minus tax)
        assertGe(previewAfter0, previewBefore0, "Token0 preview should not decrease with positive yield");
        assertGe(previewAfter1, previewBefore1, "Token1 preview should not decrease with positive yield");
    }

    /**
     * @notice Fuzz test: Share value after loss
     */
    function testFuzz_shares_valueAfterLoss(uint256 lossPercent) public {
        // Bound loss to 0-90%
        lossPercent = bound(lossPercent, 0, 90);

        _addRegularLp(1000e18);
        _configureReHypo();
        _addReHypoLiquidity(alice, 100e18);

        (uint256 previewBefore0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Calculate loss amount
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 loss0 = (amountInVault0 * lossPercent) / 100;

        // Simulate loss
        if (loss0 > 0) {
            vault0.simulateLoss(loss0);
        }

        (uint256 previewAfter0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(100e18);

        // Share value should decrease with loss
        uint256 expectedAfter0 = (previewBefore0 * (100 - lossPercent)) / 100;
        assertApproxEqRel(previewAfter0, expectedAfter0, 2e16, "Share value should reflect loss");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _takeSnapshot() internal view returns (AccountingSnapshot memory snapshot) {
        snapshot.aliceToken0 = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        snapshot.aliceToken1 = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);
        snapshot.bobToken0 = MockERC20(Currency.unwrap(currency0)).balanceOf(bob);
        snapshot.bobToken1 = MockERC20(Currency.unwrap(currency1)).balanceOf(bob);
        snapshot.vault0Balance = MockERC20(Currency.unwrap(currency0)).balanceOf(address(vault0));
        snapshot.vault1Balance = MockERC20(Currency.unwrap(currency1)).balanceOf(address(vault1));
        snapshot.poolManagerToken0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(poolManager));
        snapshot.poolManagerToken1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(poolManager));
        snapshot.logicToken0 = MockERC20(Currency.unwrap(currency0)).balanceOf(address(logic));
        snapshot.logicToken1 = MockERC20(Currency.unwrap(currency1)).balanceOf(address(logic));
        snapshot.treasuryToken0 = MockERC20(Currency.unwrap(currency0)).balanceOf(treasury);
        snapshot.treasuryToken1 = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);
    }

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
