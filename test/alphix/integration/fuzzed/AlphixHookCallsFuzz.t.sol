// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */

/* UNISWAP V4 IMPORTS */
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixHookCallsFuzzTest
 * @author Alphix
 * @notice Fuzz tests for hook integration with position manager and swap router
 * @dev Tests liquidity operations and swaps with fuzzed parameters
 */
contract AlphixHookCallsFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    /* FUZZING CONSTRAINTS */

    // Liquidity amounts (reasonable ranges for testing)
    uint128 constant MIN_LIQUIDITY_FUZZ = 1e15; // 0.001 tokens
    uint128 constant MAX_LIQUIDITY_FUZZ = 1000e18; // 1000 tokens

    // Swap amounts
    uint256 constant MIN_SWAP_AMOUNT_FUZZ = 1e15; // 0.001 tokens
    uint256 constant MAX_SWAP_AMOUNT_FUZZ = 100e18; // 100 tokens

    // Fee amounts for initial pool setup
    uint24 constant MIN_INITIAL_FEE_FUZZ = 100;
    uint24 constant MAX_INITIAL_FEE_FUZZ = 5000;

    // Target ratio for initial pool setup
    uint256 constant MIN_TARGET_RATIO_FUZZ = 5e17; // 50%
    uint256 constant MAX_TARGET_RATIO_FUZZ = 15e17; // 150%

    /* ========================================================================== */
    /*                          POOL INITIALIZATION TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that owner can initialize pools with various parameters
     * @dev Tests pool initialization across different fees and target ratios
     * @param initialFee Initial fee for the pool
     * @param targetRatio Initial target ratio
     * @dev Removed: poolType parameter (single-pool architecture)
     */
    function testFuzz_owner_can_initialize_pool_with_various_params(uint24 initialFee, uint256 targetRatio) public {
        // Single-pool-per-hook architecture - deploy fresh stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Use defaultPoolParams for bounds (before pool is configured)
        // Bound parameters to valid range
        initialFee = uint24(bound(initialFee, defaultPoolParams.minFee, defaultPoolParams.maxFee));
        targetRatio = bound(targetRatio, MIN_TARGET_RATIO_FUZZ, defaultPoolParams.maxCurrentRatio);

        // Create fresh pool
        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        // Initialize pool
        vm.prank(owner);
        freshHook.initializePool(freshKey, initialFee, targetRatio, defaultPoolParams);

        // Verify configuration
        IAlphix.PoolConfig memory cfg = freshHook.getPoolConfig();
        assertEq(cfg.initialFee, initialFee, "initial fee mismatch");
        assertEq(cfg.initialTargetRatio, targetRatio, "initial target ratio mismatch");
        assertTrue(cfg.isConfigured, "pool should be configured");
    }

    /* ========================================================================== */
    /*                        LIQUIDITY OPERATION TESTS                          */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that users can add liquidity with various amounts
     * @dev Tests liquidity provision across different liquidity amounts
     * @param liquidityAmount Amount of liquidity to add
     */
    function testFuzz_user_can_add_liquidity_with_various_amounts(uint128 liquidityAmount) public {
        // Bound liquidity to reasonable range
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY_FUZZ, MAX_LIQUIDITY_FUZZ));

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create configured pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        // Full-range position
        int24 tl = TickMath.minUsableTick(kFresh.tickSpacing);
        int24 tu = TickMath.maxUsableTick(kFresh.tickSpacing);

        // Calculate required token amounts
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityAmount
        );

        vm.startPrank(user1);

        // Approve tokens
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(permit2), amt1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(kFresh.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        // Mint position
        (uint256 newTokenId,) = positionManager.mint(
            kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, user1, block.timestamp, Constants.ZERO_BYTES
        );

        assertTrue(newTokenId != 0, "position should be minted");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that users can remove liquidity with various amounts
     * @dev Tests liquidity removal across different amounts
     * @param initialLiquidity Initial liquidity to provide
     * @param removePercentage Percentage of liquidity to remove (0-100)
     */
    function testFuzz_user_can_remove_liquidity(uint128 initialLiquidity, uint8 removePercentage) public {
        // Bound parameters
        initialLiquidity = uint128(bound(initialLiquidity, MIN_LIQUIDITY_FUZZ, MAX_LIQUIDITY_FUZZ));
        removePercentage = uint8(bound(removePercentage, 1, 100));

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create pool and add liquidity
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.startPrank(owner);

        // Seed liquidity
        uint256 posId = seedLiquidity(kFresh, owner, true, UNIT, 10_000e18, 10_000e18);
        assertTrue(posId != 0, "failed to mint position");

        // Calculate amount to remove
        uint256 liqToRemove = (uint256(initialLiquidity) * removePercentage) / 100;
        if (liqToRemove == 0) liqToRemove = 1; // Ensure at least 1

        // Remove liquidity
        positionManager.decreaseLiquidity(
            posId,
            // Casting to uint128 is safe because liqToRemove is a percentage of uint128 initialLiquidity
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128(liqToRemove),
            0,
            0,
            owner,
            block.timestamp,
            Constants.ZERO_BYTES
        );

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                              SWAP TESTS                                   */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that swaps work with various amounts
     * @dev Tests swap execution across different swap sizes
     * @param swapAmount Amount to swap
     * @param zeroForOne Swap direction
     */
    function testFuzz_user_can_swap_with_various_amounts(uint256 swapAmount, bool zeroForOne) public {
        // Bound swap amount
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT_FUZZ, MAX_SWAP_AMOUNT_FUZZ);

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create pool with liquidity
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.startPrank(owner);

        // Add liquidity
        seedLiquidity(kFresh, owner, true, UNIT, 10_000e18, 10_000e18);

        // Approve swap input
        if (zeroForOne) {
            MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(swapRouter), swapAmount);
        } else {
            MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(swapRouter), swapAmount);
        }

        // Execute swap
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: kFresh,
            hookData: Constants.ZERO_BYTES,
            receiver: owner,
            deadline: block.timestamp + 1
        });

        // Verify swap executed
        if (zeroForOne) {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(int256(swapDelta.amount0()), -int256(swapAmount), "amount0 spent mismatch");
            assertTrue(int256(swapDelta.amount1()) > 0, "amount1 received should be positive");
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(int256(swapDelta.amount1()), -int256(swapAmount), "amount1 spent mismatch");
            assertTrue(int256(swapDelta.amount0()) > 0, "amount0 received should be positive");
        }

        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that swaps respect pool pause state
     * @dev Verifies swaps revert when pool is paused
     * @param swapAmount Amount to swap
     */
    function testFuzz_swap_reverts_when_paused(uint256 swapAmount) public {
        // Bound swap amount
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT_FUZZ, MAX_SWAP_AMOUNT_FUZZ);

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create pool with liquidity
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.startPrank(owner);

        // Add liquidity
        seedLiquidity(kFresh, owner, true, UNIT, 10_000e18, 10_000e18);

        // Pause hook
        freshHook.pause();

        // Approve swap input
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(swapRouter), swapAmount);

        // Expect revert when trying to swap
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: kFresh,
            hookData: Constants.ZERO_BYTES,
            receiver: owner,
            deadline: block.timestamp + 1
        });

        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that liquidity operations respect pool deactivation
     * @dev Verifies operations revert when pool is deactivated
     * @param liquidityAmount Amount of liquidity
     */
    function testFuzz_liquidity_reverts_when_deactivated(uint128 liquidityAmount) public {
        // Bound liquidity
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY_FUZZ, MAX_LIQUIDITY_FUZZ));

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook
        );

        vm.startPrank(owner);

        // Pause pool
        freshHook.pause();

        // Calculate amounts
        int24 tl = TickMath.minUsableTick(kFresh.tickSpacing);
        int24 tu = TickMath.maxUsableTick(kFresh.tickSpacing);
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityAmount
        );

        // Approve tokens
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(permit2), amt1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(kFresh.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        // Expect revert when trying to add liquidity
        _expectRevertOnModifyLiquiditiesMint(kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, owner);

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                        TOKEN DECIMALS TESTS                               */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that operations work with different token decimals
     * @dev Tests pool operations across various token decimal combinations
     * @param decimals0 Decimals for token0 (6-18)
     * @param decimals1 Decimals for token1 (6-18)
     * @param liquidityAmount Amount of liquidity to add
     */
    function testFuzz_operations_work_with_different_decimals(uint8 decimals0, uint8 decimals1, uint128 liquidityAmount)
        public
    {
        // Bound decimals to realistic range (6-18)
        decimals0 = uint8(bound(decimals0, 6, 18));
        decimals1 = uint8(bound(decimals1, 6, 18));
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY_FUZZ, MAX_LIQUIDITY_FUZZ));

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create pool with specific decimals
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            decimals0,
            decimals1,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook
        );

        // Full-range position
        int24 tl = TickMath.minUsableTick(kFresh.tickSpacing);
        int24 tu = TickMath.maxUsableTick(kFresh.tickSpacing);

        // Calculate required token amounts
        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tl), TickMath.getSqrtPriceAtTick(tu), liquidityAmount
        );

        vm.startPrank(user1);

        // Approve tokens
        MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(permit2), amt1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(kFresh.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        // Mint position - should work regardless of decimals
        (uint256 newTokenId,) = positionManager.mint(
            kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, user1, block.timestamp, Constants.ZERO_BYTES
        );

        assertTrue(newTokenId != 0, "position should be minted with any decimals");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that swaps work with different token decimals
     * @dev Tests swap execution across various decimal combinations
     * @param decimals0 Decimals for token0 (6-18)
     * @param decimals1 Decimals for token1 (6-18)
     * @param swapAmount Amount to swap (scaled)
     * @param zeroForOne Swap direction
     */
    function testFuzz_swaps_work_with_different_decimals(
        uint8 decimals0,
        uint8 decimals1,
        uint256 swapAmount,
        bool zeroForOne
    ) public {
        // Bound decimals to realistic range
        decimals0 = uint8(bound(decimals0, 6, 18));
        decimals1 = uint8(bound(decimals1, 6, 18));

        // Scale swap amount to appropriate decimal
        uint8 swapDecimals = zeroForOne ? decimals0 : decimals1;
        swapAmount = bound(swapAmount, 10 ** swapDecimals / 1000, 10 ** swapDecimals * 100); // 0.001 to 100 tokens

        // Deploy fresh hook stack
        Alphix freshHook = _deployFreshAlphixStack();

        // Create pool with specific decimals
        (PoolKey memory kFresh,) = _initPoolWithHook(
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            decimals0,
            decimals1,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            freshHook
        );

        vm.startPrank(owner);

        // Add liquidity (scaled to decimals)
        uint256 liq0 = 10_000 * 10 ** decimals0;
        uint256 liq1 = 10_000 * 10 ** decimals1;
        seedLiquidity(kFresh, owner, true, UNIT, liq0, liq1);

        // Approve swap input
        if (zeroForOne) {
            MockERC20(Currency.unwrap(kFresh.currency0)).approve(address(swapRouter), swapAmount);
        } else {
            MockERC20(Currency.unwrap(kFresh.currency1)).approve(address(swapRouter), swapAmount);
        }

        // Execute swap
        BalanceDelta swapDelta = swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: kFresh,
            hookData: Constants.ZERO_BYTES,
            receiver: owner,
            deadline: block.timestamp + 1
        });

        // Verify swap executed correctly
        if (zeroForOne) {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(int256(swapDelta.amount0()), -int256(swapAmount), "amount0 spent mismatch");
            assertTrue(int256(swapDelta.amount1()) > 0, "amount1 received should be positive");
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(int256(swapDelta.amount1()), -int256(swapAmount), "amount1 spent mismatch");
            assertTrue(int256(swapDelta.amount0()) > 0, "amount0 received should be positive");
        }

        vm.stopPrank();
    }
}
