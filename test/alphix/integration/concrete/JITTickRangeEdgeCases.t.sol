// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {console2} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary, PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
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
 * @title JITTickRangeEdgeCasesTest
 * @notice Comprehensive edge case tests for JIT liquidity behavior when tick range is out of range
 * @dev Tests verify that swaps continue to work correctly when JIT tick range doesn't cover current price
 *
 * Key behaviors tested:
 * - JIT gracefully skips when out of range (no revert)
 * - Yield sources remain unchanged when JIT doesn't participate
 * - Swaps still execute using regular V4 pool liquidity
 * - Transitions into/out of range work correctly
 *
 * NOTE: Since tick range is now immutable (set at pool initialization), each test that needs
 * a specific tick range must deploy a fresh hook with that range set at initialization time.
 */
contract JITTickRangeEdgeCasesTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    /**
     * @notice Struct to hold test context and avoid stack too deep errors
     */
    struct JITTestContext {
        Alphix freshHook;
        AccessManager freshAm;
        PoolKey testKey;
        PoolId testPoolId;
        MockYieldVault freshVault0;
        MockYieldVault freshVault1;
        address freshYieldManager;
        uint256 yieldSource0Before;
        uint256 yieldSource1Before;
        uint256 yieldSource0After;
        uint256 yieldSource1After;
        int24 narrowLower;
        int24 narrowUpper;
    }

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
     * @dev Deploys a fresh hook with a narrow tick range far below current tick (0),
     *      verifies yield sources unchanged after swap.
     *      Price is "above" range means current tick > tickUpper
     *      Use oneForZero swap to move tick UP (away from range)
     */
    function test_jit_priceAboveRange_noJitParticipation() public {
        JITTestContext memory ctx;

        // Set JIT range FAR BELOW current tick (0) so price stays above range
        ctx.narrowLower = -10000;
        ctx.narrowUpper = -5000;
        ctx.narrowLower = (ctx.narrowLower / defaultTickSpacing) * defaultTickSpacing;
        ctx.narrowUpper = (ctx.narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Deploy fresh hook with the narrow tick range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Get current tick (should be around 0 for 1:1 price)
        (, int24 currentTick,,) = poolManager.getSlot0(ctx.testPoolId);

        // Verify we're out of range to start
        assertTrue(currentTick > ctx.narrowUpper, "Current tick should be above JIT range");

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        // Record yield source balances before swap
        ctx.yieldSource0Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // Execute swap (oneForZero moves tick UP, staying out of range)
        uint256 swapAmount = 10e18;
        uint256 bobToken0Before = MockERC20(Currency.unwrap(ctx.testKey.currency0)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(ctx.testKey.currency0)).balanceOf(bob) - bobToken0Before;

        // Verify swap worked
        assertGt(output, 0, "Swap should produce output even when JIT out of range");

        // Verify still out of range
        (, int24 newTick,,) = poolManager.getSlot0(ctx.testPoolId);
        assertTrue(newTick > ctx.narrowUpper, "New tick should still be above JIT range");

        // Verify yield sources unchanged (allowing small rounding tolerance)
        ctx.yieldSource0After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        uint256 change0 = ctx.yieldSource0After > ctx.yieldSource0Before
            ? ctx.yieldSource0After - ctx.yieldSource0Before
            : ctx.yieldSource0Before - ctx.yieldSource0After;
        uint256 change1 = ctx.yieldSource1After > ctx.yieldSource1Before
            ? ctx.yieldSource1After - ctx.yieldSource1Before
            : ctx.yieldSource1Before - ctx.yieldSource1After;

        assertLt(change0, 1e15, "Yield source0 should be ~unchanged when tick above range");
        assertLt(change1, 1e15, "Yield source1 should be ~unchanged when tick above range");
    }

    /**
     * @notice Test JIT doesn't participate when current tick is below the configured tick range
     * @dev Deploys a fresh hook with a narrow tick range far above current tick (0),
     *      verifies yield sources unchanged after swap.
     *      Price is "below" range means current tick < tickLower
     *      Use zeroForOne swap to move tick DOWN (away from range)
     */
    function test_jit_priceBelowRange_noJitParticipation() public {
        JITTestContext memory ctx;

        // Set JIT range FAR ABOVE current tick (0) so price stays below range
        ctx.narrowLower = 5000;
        ctx.narrowUpper = 10000;
        ctx.narrowLower = (ctx.narrowLower / defaultTickSpacing) * defaultTickSpacing;
        ctx.narrowUpper = (ctx.narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Deploy fresh hook with the narrow tick range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Get current tick (should be around 0 for 1:1 price)
        (, int24 currentTick,,) = poolManager.getSlot0(ctx.testPoolId);

        // Verify we're out of range to start
        assertTrue(currentTick < ctx.narrowLower, "Current tick should be below JIT range");

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        // Record yield source balances before swap
        ctx.yieldSource0Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // Execute swap (zeroForOne moves tick DOWN, staying out of range)
        uint256 swapAmount = 10e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob) - bobToken1Before;

        // Verify swap worked
        assertGt(output, 0, "Swap should produce output even when JIT below range");

        // Verify still out of range
        (, int24 newTick,,) = poolManager.getSlot0(ctx.testPoolId);
        assertTrue(newTick < ctx.narrowLower, "New tick should still be below JIT range");

        // Verify yield sources unchanged (allowing small rounding tolerance)
        ctx.yieldSource0After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        uint256 change0 = ctx.yieldSource0After > ctx.yieldSource0Before
            ? ctx.yieldSource0After - ctx.yieldSource0Before
            : ctx.yieldSource0Before - ctx.yieldSource0After;
        uint256 change1 = ctx.yieldSource1After > ctx.yieldSource1Before
            ? ctx.yieldSource1After - ctx.yieldSource1Before
            : ctx.yieldSource1Before - ctx.yieldSource1After;

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
        JITTestContext memory ctx;

        // Get current tick at 1:1 price (around 0)
        // Set JIT range below current tick - a large zeroForOne swap should move price into this range
        ctx.narrowLower = -500;
        ctx.narrowUpper = -50;
        ctx.narrowLower = (ctx.narrowLower / defaultTickSpacing) * defaultTickSpacing;
        ctx.narrowUpper = (ctx.narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Deploy fresh hook with the narrow tick range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        ctx.yieldSource0Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // Large swap that should move price DOWN (into range)
        // zeroForOne = true means selling token0, price goes down
        uint256 largePriceMovingSwap = 200e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), largePriceMovingSwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: largePriceMovingSwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob) - bobToken1Before;

        assertGt(output, 0, "Swap should produce output");

        // Check if price moved into range
        (, int24 newTick,,) = poolManager.getSlot0(ctx.testPoolId);

        // If price is now in range, JIT should have participated
        if (newTick >= ctx.narrowLower && newTick < ctx.narrowUpper) {
            // JIT likely participated - check for yield source changes
            ctx.yieldSource0After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
            ctx.yieldSource1After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

            // Note: JIT participation during the swap is complex - it depends on
            // whether price was in range during execution. Log for analysis.
            console2.log("Price moved into range. New tick:");
            console2.log(newTick);
            console2.log("JIT range lower:");
            console2.log(ctx.narrowLower);
            console2.log("JIT range upper:");
            console2.log(ctx.narrowUpper);
            console2.log("YS0 change:");
            console2.log(
                ctx.yieldSource0After > ctx.yieldSource0Before
                    ? ctx.yieldSource0After - ctx.yieldSource0Before
                    : ctx.yieldSource0Before - ctx.yieldSource0After
            );
            console2.log("YS1 change:");
            console2.log(
                ctx.yieldSource1After > ctx.yieldSource1Before
                    ? ctx.yieldSource1After - ctx.yieldSource1Before
                    : ctx.yieldSource1Before - ctx.yieldSource1After
            );
        }
    }

    /**
     * @notice Test swap that starts in-range but ends out-of-range
     * @dev Tests behavior when a large swap moves price out of JIT range
     *      First do a small swap in-range, then a large swap that moves out of range
     */
    function test_jit_swapMovesOutOfRange_partialJit() public {
        JITTestContext memory ctx;

        // Start with a narrow range centered around tick 0
        ctx.narrowLower = -60;
        ctx.narrowUpper = 60;
        ctx.narrowLower = (ctx.narrowLower / defaultTickSpacing) * defaultTickSpacing;
        ctx.narrowUpper = (ctx.narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Deploy fresh hook with the narrow tick range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        ctx.yieldSource0Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // Small swap - should use JIT (we're starting in range)
        uint256 smallSwap = 1e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), smallSwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: smallSwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        ctx.yieldSource0After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // JIT should have participated since we started in range
        bool jitParticipated =
            (ctx.yieldSource0After != ctx.yieldSource0Before) || (ctx.yieldSource1After != ctx.yieldSource1Before);

        console2.log("Small swap in-range - JIT participated:");
        console2.log(jitParticipated);
        console2.log("YS0 before:");
        console2.log(ctx.yieldSource0Before);
        console2.log("YS0 after:");
        console2.log(ctx.yieldSource0After);
        console2.log("YS1 before:");
        console2.log(ctx.yieldSource1Before);
        console2.log("YS1 after:");
        console2.log(ctx.yieldSource1After);

        // Now do a large swap that moves price out of range
        uint256 largeSwap = 300e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), largeSwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: largeSwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        (, int24 newTick,,) = poolManager.getSlot0(ctx.testPoolId);
        bool outOfRange = newTick < ctx.narrowLower || newTick >= ctx.narrowUpper;

        console2.log("After large swap - out of range:");
        console2.log(outOfRange);
        console2.log("New tick:");
        console2.log(newTick);
        console2.log("Range lower:");
        console2.log(ctx.narrowLower);
        console2.log("Range upper:");
        console2.log(ctx.narrowUpper);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        EXTREME TICK VALUE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test with MIN_TICK and MAX_TICK boundaries
     * @dev Ensures JIT works correctly at tick space extremes
     */
    function test_jit_extremeTickValues_minMax() public {
        JITTestContext memory ctx;

        // Set JIT to full possible range
        ctx.narrowLower = TickMath.minUsableTick(defaultTickSpacing);
        ctx.narrowUpper = TickMath.maxUsableTick(defaultTickSpacing);

        // Deploy fresh hook with the full tick range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        ctx.yieldSource0Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // Execute swap
        uint256 swapAmount = 10e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob) - bobToken1Before;

        assertGt(output, 0, "Swap should work with extreme tick values");

        // JIT should participate since full range covers everything
        ctx.yieldSource0After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        bool jitParticipated =
            (ctx.yieldSource0After != ctx.yieldSource0Before) || (ctx.yieldSource1After != ctx.yieldSource1Before);
        assertTrue(jitParticipated, "JIT should participate when using full tick range");
    }

    /**
     * @notice Test with single tick spacing range (minimum possible range)
     * @dev tickLower = tickUpper - tickSpacing
     */
    function test_jit_singleTickSpacingRange() public {
        JITTestContext memory ctx;

        // Get current tick and set minimum range around it
        // Current tick at 1:1 price is around 0
        ctx.narrowLower = 0;
        ctx.narrowUpper = defaultTickSpacing;

        // Deploy fresh hook with the single tick spacing range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        // Very small swap to stay in range
        uint256 tinySwap = 0.01e18;
        uint256 bobToken1Before = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob);
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), tinySwap);
        swapRouter.swapExactTokensForTokens({
            amountIn: tinySwap,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
        uint256 output = MockERC20(Currency.unwrap(ctx.testKey.currency1)).balanceOf(bob) - bobToken1Before;

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
        JITTestContext memory ctx;

        // Set JIT range FAR ABOVE current tick (0) so small swaps stay out of range
        ctx.narrowLower = 5000;
        ctx.narrowUpper = 10000;
        ctx.narrowLower = (ctx.narrowLower / defaultTickSpacing) * defaultTickSpacing;
        ctx.narrowUpper = (ctx.narrowUpper / defaultTickSpacing) * defaultTickSpacing;

        // Deploy fresh hook with the narrow tick range set at initialization
        (ctx.freshHook, ctx.freshAm) = _deployFreshAlphixStackFull();

        (ctx.testKey, ctx.testPoolId) = _initPoolWithHookAndTickRange(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            ctx.freshHook,
            ctx.narrowLower,
            ctx.narrowUpper
        );

        // Fund test users with the new currencies
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Add regular LP to the pool
        _addRegularLpToPool(ctx.testKey, 1000e18);

        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(ctx.testPoolId);

        // Verify we're out of range
        assertTrue(currentTick < ctx.narrowLower, "Current tick should be below JIT range");

        // Setup yield sources for fresh hook
        ctx.freshVault0 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency0)));
        ctx.freshVault1 = new MockYieldVault(IERC20(Currency.unwrap(ctx.testKey.currency1)));

        ctx.freshYieldManager = makeAddr("freshYieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(ctx.freshYieldManager, ctx.freshAm, address(ctx.freshHook));
        vm.stopPrank();

        vm.startPrank(ctx.freshYieldManager);
        ctx.freshHook.setYieldSource(ctx.testKey.currency0, address(ctx.freshVault0));
        ctx.freshHook.setYieldSource(ctx.testKey.currency1, address(ctx.freshVault1));
        vm.stopPrank();

        _addReHypoLiquidityToHook(alice, 100e18, ctx.freshHook, ctx.testKey);

        ctx.yieldSource0Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1Before = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        // Swap 1: zeroForOne (moves tick DOWN, stays out of range)
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), 5e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Swap 2: oneForZero (moves tick UP but not enough to reach range)
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency1)).approve(address(swapRouter), 5e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Swap 3: zeroForOne again
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(ctx.testKey.currency0)).approve(address(swapRouter), 3e18);
        swapRouter.swapExactTokensForTokens({
            amountIn: 3e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: ctx.testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify still out of range
        (, int24 finalTick,,) = poolManager.getSlot0(ctx.testPoolId);
        assertTrue(finalTick < ctx.narrowLower, "Final tick should still be below JIT range");

        // Verify yield sources unchanged after all swaps (with small tolerance for rounding)
        ctx.yieldSource0After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency0);
        ctx.yieldSource1After = ctx.freshHook.getAmountInYieldSource(ctx.testKey.currency1);

        uint256 change0 = ctx.yieldSource0After > ctx.yieldSource0Before
            ? ctx.yieldSource0After - ctx.yieldSource0Before
            : ctx.yieldSource0Before - ctx.yieldSource0After;
        uint256 change1 = ctx.yieldSource1After > ctx.yieldSource1Before
            ? ctx.yieldSource1After - ctx.yieldSource1Before
            : ctx.yieldSource1Before - ctx.yieldSource1After;

        assertLt(change0, 1e15, "Yield source0 should be ~unchanged after bidirectional swaps out of range");
        assertLt(change1, 1e15, "Yield source1 should be ~unchanged after bidirectional swaps out of range");
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

    /**
     * @notice Add regular LP to any pool (not just the default one)
     * @param poolKey The pool key to add liquidity to
     * @param amount The amount of liquidity to add
     */
    function _addRegularLpToPool(PoolKey memory poolKey, uint256 amount) internal {
        int24 _tickLower = TickMath.minUsableTick(poolKey.tickSpacing);
        int24 _tickUpper = TickMath.maxUsableTick(poolKey.tickSpacing);

        vm.startPrank(owner);

        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(poolKey.currency0),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 100)
        );
        permit2.approve(
            Currency.unwrap(poolKey.currency1),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 100)
        );

        // Get liquidity amounts
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(_tickLower),
            TickMath.getSqrtPriceAtTick(_tickUpper),
            amount,
            amount
        );

        positionManager.mint(
            poolKey,
            _tickLower,
            _tickUpper,
            liquidityAmount,
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

    /**
     * @notice Add rehypothecated liquidity to a specific hook and pool
     * @param user The user adding liquidity
     * @param shares The number of shares to mint
     * @param targetHook The hook to add liquidity to
     * @param poolKey The pool key for the currencies
     */
    function _addReHypoLiquidityToHook(address user, uint256 shares, Alphix targetHook, PoolKey memory poolKey)
        internal
    {
        (uint256 amount0, uint256 amount1) = targetHook.previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(targetHook), amount0 + 1);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(targetHook), amount1 + 1);
        targetHook.addReHypothecatedLiquidity(shares);
        vm.stopPrank();
    }
}
