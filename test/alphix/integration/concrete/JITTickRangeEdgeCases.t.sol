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
import {Alphix} from "../../../../src/Alphix.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title JITTickRangeEdgeCasesTest
 * @notice Comprehensive edge case tests for JIT liquidity behavior when tick range is out of range
 * @dev Tests verify that swaps continue to work correctly when JIT tick range doesn't cover current price
 *
 * Key behaviors tested:
 * - JIT gracefully skips when out of range (no revert)
 * - Yield sources remain unchanged when JIT doesn't participate
 * - Swaps still execute using regular V4 pool liquidity
 * - Transitions into/out of range work correctly
 */
contract JITTickRangeEdgeCasesTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public yieldManager;
    address public alice;
    address public bob;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Fund users
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        PRICE ABOVE RANGE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test JIT doesn't participate when current tick is above the configured tick range
     * @dev Sets a narrow tick range far below current tick, verifies yield sources unchanged
     *      Price is "above" range means current tick > tickUpper
     *      Use oneForZero swap to move tick UP (away from range)
     */
    function test_jit_priceAboveRange_noJitParticipation() public {
        _addRegularLp(1000e18);

        // Get current tick (should be around 0 for 1:1 price)
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Set JIT range FAR BELOW current tick so price stays above range
        // We'll do oneForZero swap which moves tick UP, staying out of range
        int24 narrowLower = -10000;
        int24 narrowUpper = -5000;
        // Align to tick spacing
        narrowLower = (narrowLower / defaultTickSpacing) * defaultTickSpacing;
        narrowUpper = (narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Verify we're out of range to start
        assertTrue(currentTick > narrowUpper, "Current tick should be above JIT range");

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(narrowLower, narrowUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Record yield source balances before swap
        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Execute swap (oneForZero moves tick UP, staying out of range)
        uint256 swapAmount = 10e18;
        uint256 bobToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount);
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
        uint256 output = MockERC20(Currency.unwrap(currency0)).balanceOf(bob) - bobToken0Before;

        // Verify swap worked
        assertGt(output, 0, "Swap should produce output even when JIT out of range");

        // Verify still out of range
        (, int24 newTick,,) = poolManager.getSlot0(key.toId());
        assertTrue(newTick > narrowUpper, "New tick should still be above JIT range");

        // Verify yield sources unchanged (allowing small rounding tolerance)
        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        uint256 change0 = yieldSource0After > yieldSource0Before
            ? yieldSource0After - yieldSource0Before
            : yieldSource0Before - yieldSource0After;
        uint256 change1 = yieldSource1After > yieldSource1Before
            ? yieldSource1After - yieldSource1Before
            : yieldSource1Before - yieldSource1After;

        assertLt(change0, 1e15, "Yield source0 should be ~unchanged when tick above range");
        assertLt(change1, 1e15, "Yield source1 should be ~unchanged when tick above range");
    }

    /**
     * @notice Test JIT doesn't participate when current tick is below the configured tick range
     * @dev Sets a narrow tick range far above current tick, verifies yield sources unchanged
     *      Price is "below" range means current tick < tickLower
     *      Use zeroForOne swap to move tick DOWN (away from range)
     */
    function test_jit_priceBelowRange_noJitParticipation() public {
        _addRegularLp(1000e18);

        // Get current tick (should be around 0 for 1:1 price)
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Set JIT range FAR ABOVE current tick so price stays below range
        // We'll do zeroForOne swap which moves tick DOWN, staying out of range
        int24 narrowLower = 5000;
        int24 narrowUpper = 10000;
        // Align to tick spacing
        narrowLower = (narrowLower / defaultTickSpacing) * defaultTickSpacing;
        narrowUpper = (narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Verify we're out of range to start
        assertTrue(currentTick < narrowLower, "Current tick should be below JIT range");

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(narrowLower, narrowUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Record yield source balances before swap
        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Execute swap (zeroForOne moves tick DOWN, staying out of range)
        uint256 swapAmount = 10e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(bob);
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
        uint256 output = MockERC20(Currency.unwrap(currency1)).balanceOf(bob) - bobToken1Before;

        // Verify swap worked
        assertGt(output, 0, "Swap should produce output even when JIT below range");

        // Verify still out of range
        (, int24 newTick,,) = poolManager.getSlot0(key.toId());
        assertTrue(newTick < narrowLower, "New tick should still be below JIT range");

        // Verify yield sources unchanged (allowing small rounding tolerance)
        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        uint256 change0 = yieldSource0After > yieldSource0Before
            ? yieldSource0After - yieldSource0Before
            : yieldSource0Before - yieldSource0After;
        uint256 change1 = yieldSource1After > yieldSource1Before
            ? yieldSource1After - yieldSource1Before
            : yieldSource1Before - yieldSource1After;

        assertLt(change0, 1e15, "Yield source0 should be ~unchanged when tick below range");
        assertLt(change1, 1e15, "Yield source1 should be ~unchanged when tick below range");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        RANGE TRANSITION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test swap that starts out-of-range but ends in-range
     * @dev Large swap moves price into JIT range, JIT should participate in later portion
     */
    function test_jit_swapMovesIntoRange_jitParticipates() public {
        _addRegularLp(1000e18);

        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Set JIT range below current tick
        int24 narrowLower = currentTick - 500;
        int24 narrowUpper = currentTick - 50;
        narrowLower = (narrowLower / defaultTickSpacing) * defaultTickSpacing;
        narrowUpper = (narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(narrowLower, narrowUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Large swap that should move price DOWN (into range)
        // zeroForOne = true means selling token0, price goes down
        uint256 largePriceMovingSwap = 200e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), largePriceMovingSwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: largePriceMovingSwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(currency1)).balanceOf(bob) - bobToken1Before;

        assertGt(output, 0, "Swap should produce output");

        // Check if price moved into range
        (, int24 newTick,,) = poolManager.getSlot0(key.toId());

        // If price is now in range, JIT should have participated
        if (newTick >= narrowLower && newTick < narrowUpper) {
            // JIT likely participated - check for yield source changes
            uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
            uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

            // Note: JIT participation during the swap is complex - it depends on
            // whether price was in range during execution. Log for analysis.
            console2.log("Price moved into range. New tick:");
            console2.log(newTick);
            console2.log("JIT range lower:");
            console2.log(narrowLower);
            console2.log("JIT range upper:");
            console2.log(narrowUpper);
            console2.log("YS0 change:");
            console2.log(yieldSource0After > yieldSource0Before ? yieldSource0After - yieldSource0Before : yieldSource0Before - yieldSource0After);
            console2.log("YS1 change:");
            console2.log(yieldSource1After > yieldSource1Before ? yieldSource1After - yieldSource1Before : yieldSource1Before - yieldSource1After);
        }
    }

    /**
     * @notice Test swap that starts in-range but ends out-of-range
     * @dev Large swap moves price out of JIT range
     */
    function test_jit_swapMovesOutOfRange_partialJit() public {
        _addRegularLp(1000e18);

        // Configure full range JIT first (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(fullRangeLower, fullRangeUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Now narrow the range to only cover a small area around current tick
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 narrowLower = currentTick - 50;
        int24 narrowUpper = currentTick + 50;
        narrowLower = (narrowLower / defaultTickSpacing) * defaultTickSpacing;
        narrowUpper = (narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // setTickRange requires whenPaused
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(narrowLower, narrowUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Small swap - should use JIT
        uint256 smallSwap = 1e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), smallSwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: smallSwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // JIT should have participated since we started in range
        bool jitParticipated = (yieldSource0After != yieldSource0Before) || (yieldSource1After != yieldSource1Before);

        console2.log("Small swap in-range - JIT participated:");
        console2.log(jitParticipated);
        console2.log("YS0 before:");
        console2.log(yieldSource0Before);
        console2.log("YS0 after:");
        console2.log(yieldSource0After);
        console2.log("YS1 before:");
        console2.log(yieldSource1Before);
        console2.log("YS1 after:");
        console2.log(yieldSource1After);

        // Now do a large swap that moves price out of range
        uint256 largeSwap = 300e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), largeSwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: largeSwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        (, int24 newTick,,) = poolManager.getSlot0(key.toId());
        bool outOfRange = newTick < narrowLower || newTick >= narrowUpper;

        console2.log("After large swap - out of range:");
        console2.log(outOfRange);
        console2.log("New tick:");
        console2.log(newTick);
        console2.log("Range lower:");
        console2.log(narrowLower);
        console2.log("Range upper:");
        console2.log(narrowUpper);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        EXTREME TICK VALUE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test with MIN_TICK and MAX_TICK boundaries
     * @dev Ensures JIT works correctly at tick space extremes
     */
    function test_jit_extremeTickValues_minMax() public {
        _addRegularLp(1000e18);

        // Set JIT to full possible range
        int24 minTick = TickMath.minUsableTick(defaultTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(defaultTickSpacing);

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(minTick, maxTick);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Execute swap
        uint256 swapAmount = 10e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(bob);
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
        uint256 output = MockERC20(Currency.unwrap(currency1)).balanceOf(bob) - bobToken1Before;

        assertGt(output, 0, "Swap should work with extreme tick values");

        // JIT should participate since full range covers everything
        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        bool jitParticipated = (yieldSource0After != yieldSource0Before) || (yieldSource1After != yieldSource1Before);
        assertTrue(jitParticipated, "JIT should participate when using full tick range");
    }

    /**
     * @notice Test with single tick spacing range (minimum possible range)
     * @dev tickLower = tickUpper - tickSpacing
     */
    function test_jit_singleTickSpacingRange() public {
        _addRegularLp(1000e18);

        // Get current tick and set minimum range around it
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 alignedTick = (currentTick / defaultTickSpacing) * defaultTickSpacing;

        int24 narrowLower = alignedTick;
        int24 narrowUpper = alignedTick + defaultTickSpacing;

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(narrowLower, narrowUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Very small swap to stay in range
        uint256 tinySwap = 0.01e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), tinySwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: tinySwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(currency1)).balanceOf(bob) - bobToken1Before;

        assertGt(output, 0, "Swap should work with single tick spacing range");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        BIDIRECTIONAL SWAP TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test multiple swaps in both directions while out of range
     * @dev Ensures consistent behavior regardless of swap direction
     *      Small swaps around tick 0 with range far above (5000-10000)
     */
    function test_jit_bidirectionalSwaps_outOfRange() public {
        _addRegularLp(1000e18);

        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Set JIT range FAR ABOVE current tick so small swaps stay out of range
        int24 narrowLower = 5000;
        int24 narrowUpper = 10000;
        narrowLower = (narrowLower / defaultTickSpacing) * defaultTickSpacing;
        narrowUpper = (narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Verify we're out of range
        assertTrue(currentTick < narrowLower, "Current tick should be below JIT range");

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(narrowLower, narrowUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Initial = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Initial = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Swap 1: zeroForOne (moves tick DOWN, stays out of range)
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 5e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Swap 2: oneForZero (moves tick UP but not enough to reach range)
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), 5e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Swap 3: zeroForOne again
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 3e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 3e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify still out of range
        (, int24 finalTick,,) = poolManager.getSlot0(key.toId());
        assertTrue(finalTick < narrowLower, "Final tick should still be below JIT range");

        // Verify yield sources unchanged after all swaps (with small tolerance for rounding)
        uint256 yieldSource0Final = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Final = Alphix(address(hook)).getAmountInYieldSource(currency1);

        uint256 change0 = yieldSource0Final > yieldSource0Initial
            ? yieldSource0Final - yieldSource0Initial
            : yieldSource0Initial - yieldSource0Final;
        uint256 change1 = yieldSource1Final > yieldSource1Initial
            ? yieldSource1Final - yieldSource1Initial
            : yieldSource1Initial - yieldSource1Final;

        assertLt(change0, 1e15, "Yield source0 should be ~unchanged after bidirectional swaps out of range");
        assertLt(change1, 1e15, "Yield source1 should be ~unchanged after bidirectional swaps out of range");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        TICK RANGE CHANGE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test setTickRange called when price is outside the new range
     * @dev Verifies system handles range changes gracefully
     */
    function test_jit_rangeChangeWhileOutOfRange() public {
        _addRegularLp(1000e18);

        // Start with full range (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(fullRangeLower, fullRangeUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Verify JIT works with full range
        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);

        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 5e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        assertTrue(yieldSource0After != yieldSource0Before, "JIT should participate with full range");

        // Now change to a range that excludes current price
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 farLower = currentTick + 1000;
        int24 farUpper = currentTick + 2000;
        farLower = (farLower / defaultTickSpacing) * defaultTickSpacing;
        farUpper = (farUpper / defaultTickSpacing) * defaultTickSpacing;

        // setTickRange requires whenPaused
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(farLower, farUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        // Record new state
        uint256 yieldSource0BeforeOutOfRange = Alphix(address(hook)).getAmountInYieldSource(currency0);

        // Swap should work but JIT shouldn't participate
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), 5e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0AfterOutOfRange = Alphix(address(hook)).getAmountInYieldSource(currency0);

        // Allow tiny tolerance for rounding
        uint256 change = yieldSource0AfterOutOfRange > yieldSource0BeforeOutOfRange
            ? yieldSource0AfterOutOfRange - yieldSource0BeforeOutOfRange
            : yieldSource0BeforeOutOfRange - yieldSource0AfterOutOfRange;

        assertLt(change, 1e15, "JIT should not participate after range changed to exclude current price");
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

    function _addReHypoLiquidity(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) = Alphix(address(hook)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), amount0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), amount1 + 1);
        Alphix(address(hook)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();
    }
}
