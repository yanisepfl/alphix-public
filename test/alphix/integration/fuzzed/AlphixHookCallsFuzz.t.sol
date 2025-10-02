// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../../src/BaseDynamicFee.sol";
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
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
     * @param poolTypeIndex Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_owner_can_initialize_pool_with_various_params(
        uint24 initialFee,
        uint256 targetRatio,
        uint8 poolTypeIndex
    ) public {
        // Bound pool type
        poolTypeIndex = uint8(bound(poolTypeIndex, 0, 2));

        // Map to pool type
        IAlphixLogic.PoolType poolType;
        if (poolTypeIndex == 0) poolType = IAlphixLogic.PoolType.STABLE;
        else if (poolTypeIndex == 1) poolType = IAlphixLogic.PoolType.STANDARD;
        else poolType = IAlphixLogic.PoolType.VOLATILE;

        // Get pool type parameters to bound fee correctly
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

        // Bound parameters to valid range for this pool type
        initialFee = uint24(bound(initialFee, params.minFee, params.maxFee));
        targetRatio = bound(targetRatio, MIN_TARGET_RATIO_FUZZ, params.maxCurrentRatio);

        // Create fresh pool
        (PoolKey memory freshKey, PoolId freshId) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        // Initialize pool
        vm.prank(owner);
        hook.initializePool(freshKey, initialFee, targetRatio, poolType);

        // Verify configuration
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(freshId);
        assertEq(cfg.initialFee, initialFee, "initial fee mismatch");
        assertEq(cfg.initialTargetRatio, targetRatio, "initial target ratio mismatch");
        assertEq(uint8(cfg.poolType), uint8(poolType), "pool type mismatch");
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

        // Create configured pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
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
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
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

        // Create pool and add liquidity
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
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
            posId, uint128(liqToRemove), 0, 0, owner, block.timestamp, Constants.ZERO_BYTES
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

        // Create pool with liquidity
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
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
            assertEq(int256(swapDelta.amount0()), -int256(swapAmount), "amount0 spent mismatch");
            assertTrue(int256(swapDelta.amount1()) > 0, "amount1 received should be positive");
        } else {
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

        // Create pool with liquidity
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
        );

        vm.startPrank(owner);

        // Add liquidity
        seedLiquidity(kFresh, owner, true, UNIT, 10_000e18, 10_000e18);

        // Pause logic
        AlphixLogic(address(logicProxy)).pause();

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

        // Create pool
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
        );

        vm.startPrank(owner);

        // Deactivate pool
        hook.deactivatePool(kFresh);

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
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        permit2.approve(Currency.unwrap(kFresh.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        // Expect revert when trying to add liquidity
        _expectRevertOnModifyLiquiditiesMint(kFresh, tl, tu, liquidityAmount, amt0 + 1, amt1 + 1, owner);

        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that afterInitialize requires dynamic fee
     * @dev Verifies static fee pools are rejected
     * @param staticFee Static fee value
     */
    function testFuzz_afterInitialize_requires_dynamic_fee(uint24 staticFee) public {
        // Bound to valid static fee range (exclude dynamic fee flag)
        staticFee = uint24(bound(staticFee, 1, LPFeeLibrary.MAX_LP_FEE));
        vm.assume(!LPFeeLibrary.isDynamicFee(staticFee));

        // Create static fee key
        PoolKey memory staticKey = PoolKey(currency0, currency1, staticFee, defaultTickSpacing, IHooks(hook));

        // Expect revert
        vm.prank(address(hook));
        vm.expectRevert(BaseDynamicFee.NotDynamicFee.selector);
        logic.afterInitialize(user1, staticKey, Constants.SQRT_PRICE_1_1, 0);
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

        // Create pool with specific decimals
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            decimals0,
            decimals1,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
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
        permit2.approve(Currency.unwrap(kFresh.currency0), address(positionManager), uint160(amt0 + 1), expiry);
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

        // Create pool with specific decimals
        (PoolKey memory kFresh,) = _initPoolWithHook(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            decimals0,
            decimals1,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1,
            hook
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
            assertEq(int256(swapDelta.amount0()), -int256(swapAmount), "amount0 spent mismatch");
            assertTrue(int256(swapDelta.amount1()) > 0, "amount1 received should be positive");
        } else {
            assertEq(int256(swapDelta.amount1()), -int256(swapAmount), "amount1 spent mismatch");
            assertTrue(int256(swapDelta.amount0()) > 0, "amount0 received should be positive");
        }

        vm.stopPrank();
    }
}
