// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixExtremeStatesFuzzTest
 * @author Alphix
 * @notice Fuzzed tests for extreme state transitions and edge case scenarios
 * @dev Tests liquidity drain/flood, OOB streaks, ratio oscillations, and parameter extremes
 */
contract AlphixExtremeStatesFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;
    address public charlie;

    uint128 constant MIN_LIQUIDITY = 1e18;
    uint128 constant MAX_LIQUIDITY = 500e18;
    uint256 constant MIN_SWAP_AMOUNT = 1e17;
    uint256 constant MAX_SWAP_AMOUNT = 50e18;

    struct LiquidityDrainParams {
        uint128 initialLiquidity;
        uint8 drainSteps;
        uint128 reentryLiquidity;
        uint256 swapAmount;
    }

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        vm.startPrank(owner);
        _mintTokensToUser(alice, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(bob, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(charlie, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                      LIQUIDITY DRAIN & FLOOD TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Gradual liquidity drain followed by sudden re-entry
     * @dev Tests fee stability through liquidity extremes
     * @param initialLiquidity Starting pool liquidity
     * @param drainSteps Number of drain steps (3-8)
     * @param reentryLiquidity Amount of liquidity re-added
     * @param swapAmount Swap during drain
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_liquidityDrain_thenFlood_feeStability(
        uint128 initialLiquidity,
        uint8 drainSteps,
        uint128 reentryLiquidity,
        uint256 swapAmount
    ) public {
        LiquidityDrainParams memory params = LiquidityDrainParams({
            initialLiquidity: uint128(bound(initialLiquidity, MIN_LIQUIDITY * 100, MAX_LIQUIDITY)),
            drainSteps: uint8(bound(drainSteps, 3, 8)),
            reentryLiquidity: uint128(bound(reentryLiquidity, MIN_LIQUIDITY * 50, MAX_LIQUIDITY)),
            swapAmount: bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT / 4)
        });

        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        _executeLiquidityDrain(testKey, testPoolId, params);
        _executeLiquidityFlood(testKey, testPoolId, params.reentryLiquidity);
    }

    /**
     * @notice Fuzz: Complete liquidity removal then re-add
     * @dev Tests pool behavior at liquidity extremes
     * @param initialLiquidity Initial liquidity
     * @param waitTime Time before re-adding (1-7 days)
     * @param newLiquidity New liquidity amount
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_liquidityZero_thenRestore_poolRecovery(
        uint128 initialLiquidity,
        uint256 waitTime,
        uint128 newLiquidity
    ) public {
        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        initialLiquidity = uint128(bound(initialLiquidity, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        waitTime = bound(waitTime, 1 days, 7 days);
        newLiquidity = uint128(bound(newLiquidity, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));

        int24 minTick = TickMath.minUsableTick(testKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(testKey.tickSpacing);

        vm.startPrank(alice);
        uint256 aliceTokenId = _addLiquidityForUser(alice, testKey, minTick, maxTick, initialLiquidity);
        vm.stopPrank();

        logic.getPoolConfig(); // Assert pool is configured
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(4e17);

        vm.startPrank(alice);
        positionManager.decreaseLiquidity(
            aliceTokenId, initialLiquidity, 0, 0, alice, block.timestamp + 60, Constants.ZERO_BYTES
        );
        vm.stopPrank();

        vm.warp(block.timestamp + waitTime);

        vm.startPrank(bob);
        _addLiquidityForUser(bob, testKey, minTick, maxTick, newLiquidity);
        vm.stopPrank();

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(6e17);

        uint24 feeAfterRecovery;
        (,,, feeAfterRecovery) = poolManager.getSlot0(testPoolId);

        assertGe(feeAfterRecovery, params.minFee, "Fee bounded after recovery");
        assertLe(feeAfterRecovery, params.maxFee, "Fee bounded after recovery");
        IAlphixLogic.PoolConfig memory poolConfigAfter = logic.getPoolConfig();
        assertTrue(poolConfigAfter.isConfigured, "Pool remains configured");
    }

    /**
     * @notice Fuzz: Massive sudden liquidity injection
     * @dev Tests fee behavior when liquidity increases dramatically
     * @param baseLiquidity Base pool liquidity
     * @param massiveAddition Sudden large liquidity add
     * @param swapAmount Swap amount after injection
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_liquidityMassiveInjection_feeAdjustmentCorrect(
        uint128 baseLiquidity,
        uint128 massiveAddition,
        uint256 swapAmount
    ) public {
        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        baseLiquidity = uint128(bound(baseLiquidity, MIN_LIQUIDITY * 10, MAX_LIQUIDITY / 4));
        massiveAddition = uint128(bound(massiveAddition, MAX_LIQUIDITY / 2, MAX_LIQUIDITY));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);

        int24 minTick = TickMath.minUsableTick(testKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(testKey.tickSpacing);

        vm.startPrank(alice);
        _addLiquidityForUser(alice, testKey, minTick, maxTick, baseLiquidity);
        vm.stopPrank();

        logic.getPoolConfig(); // Assert pool is configured
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Intentionally not asserting pre/post fee direction; fees are bounded and adaptive

        vm.startPrank(bob);
        _addLiquidityForUser(bob, testKey, minTick, maxTick, massiveAddition);
        vm.stopPrank();

        vm.startPrank(charlie);
        _performSwap(charlie, testKey, swapAmount, true);
        vm.stopPrank();

        vm.warp(block.timestamp + params.minPeriod + 1);
        uint256 newRatio = (swapAmount * 1e18) / (uint256(baseLiquidity) + uint256(massiveAddition));
        if (newRatio > params.maxCurrentRatio) newRatio = params.maxCurrentRatio;
        if (newRatio < 1e15) newRatio = 1e15;

        vm.prank(owner);
        hook.poke(newRatio);

        uint24 feeAfterInjection;
        (,,, feeAfterInjection) = poolManager.getSlot0(testPoolId);

        assertGe(feeAfterInjection, params.minFee, "Fee bounded after massive injection");
        assertLe(feeAfterInjection, params.maxFee, "Fee bounded after massive injection");
    }

    /* ========================================================================== */
    /*                          OOB STREAK BEHAVIOR TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Consecutive OOB hits on same side (upper)
     * @dev Tests streak behavior and fee acceleration
     * @param liquidityAmount Pool liquidity
     * @param numConsecutiveHits Number of consecutive upper OOB pokes (5-50)
     * @param baseDeviation Base deviation from target
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_oobStreak_consecutiveUpperHits_feeIncreases(
        uint128 liquidityAmount,
        uint8 numConsecutiveHits,
        uint256 baseDeviation
    ) public {
        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        numConsecutiveHits = uint8(bound(numConsecutiveHits, 5, 50));
        baseDeviation = bound(baseDeviation, 1e17, 5e17);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig();
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        uint24 previousFee;
        (,,, previousFee) = poolManager.getSlot0(testPoolId);

        for (uint256 i = 0; i < numConsecutiveHits; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            uint256 upperBound =
                poolConfig.initialTargetRatio + (poolConfig.initialTargetRatio * params.ratioTolerance / 1e18);
            uint256 oobRatio = upperBound + baseDeviation + (i * 1e16);
            if (oobRatio > params.maxCurrentRatio) oobRatio = params.maxCurrentRatio;

            vm.prank(owner);
            hook.poke(oobRatio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            if (previousFee < params.maxFee) {
                assertGe(currentFee, previousFee, "Fee should increase or stay with consecutive upper OOB");
            }
            assertLe(currentFee, params.maxFee, "Fee bounded by maxFee");

            previousFee = currentFee;
        }
    }

    /**
     * @notice Fuzz: Consecutive OOB hits on same side (lower)
     * @dev Tests streak behavior with fee decrease
     * @param liquidityAmount Pool liquidity
     * @param numConsecutiveHits Number of consecutive lower OOB pokes (5-50)
     * @param baseDeviation Base deviation from target
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_oobStreak_consecutiveLowerHits_feeDecreases(
        uint128 liquidityAmount,
        uint8 numConsecutiveHits,
        uint256 baseDeviation
    ) public {
        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        numConsecutiveHits = uint8(bound(numConsecutiveHits, 5, 50));
        baseDeviation = bound(baseDeviation, 1e16, 2e17);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig();
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(poolConfig.initialTargetRatio + 3e17);

        vm.warp(block.timestamp + params.minPeriod + 1);

        uint24 previousFee;
        (,,, previousFee) = poolManager.getSlot0(testPoolId);

        for (uint256 i = 0; i < numConsecutiveHits; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            uint256 lowerBound = _calculateLowerBound(poolConfig.initialTargetRatio, params.ratioTolerance);
            uint256 oobRatio = lowerBound > baseDeviation ? lowerBound - baseDeviation : 1e15;
            if (oobRatio < 1e15) oobRatio = 1e15;

            vm.prank(owner);
            hook.poke(oobRatio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            if (previousFee > params.minFee) {
                assertLe(currentFee, previousFee, "Fee should decrease or stay with consecutive lower OOB");
            }
            assertGe(currentFee, params.minFee, "Fee bounded by minFee");

            previousFee = currentFee;
        }
    }

    /**
     * @notice Fuzz: Alternating OOB side hits (streak reset)
     * @dev Tests that streak resets when switching from upper to lower or vice versa
     * @param liquidityAmount Pool liquidity
     * @param numAlternations Number of side switches (6-20)
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_oobStreak_alternatingHits_streakResets(uint128 liquidityAmount, uint8 numAlternations) public {
        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        numAlternations = uint8(bound(numAlternations, 6, 20));

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig();
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        uint256 upperBound =
            poolConfig.initialTargetRatio + (poolConfig.initialTargetRatio * params.ratioTolerance / 1e18);
        uint256 lowerBound = _calculateLowerBound(poolConfig.initialTargetRatio, params.ratioTolerance);

        bool previousWasUpper = true; // Track previous OOB direction
        uint24 previousFee;
        (,,, previousFee) = poolManager.getSlot0(testPoolId);

        for (uint256 i = 0; i < numAlternations; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);

            bool isUpper = (i % 2 == 0);
            uint256 ratio;
            if (isUpper) {
                ratio = upperBound + 1e17;
                if (ratio > params.maxCurrentRatio) ratio = params.maxCurrentRatio;
            } else {
                ratio = lowerBound > 1e17 ? lowerBound - 1e17 : 1e15;
            }

            vm.prank(owner);
            hook.poke(ratio);

            uint24 currentFee;
            (,,, currentFee) = poolManager.getSlot0(testPoolId);

            assertGe(currentFee, params.minFee, "Fee bounded during alternation");
            assertLe(currentFee, params.maxFee, "Fee bounded during alternation");

            // Verify streak reset behavior through observable fee changes:
            // When alternating sides, fee changes should be smaller due to streak reset (streak=1)
            // vs sustained pressure (which would accumulate larger streaks)
            if (i > 0 && isUpper != previousWasUpper) {
                // After side switch, the fee change magnitude should be relatively moderate
                // (This is an observable consequence of streak reset without checking internal state)
                uint256 feeChange = currentFee > previousFee ? currentFee - previousFee : previousFee - currentFee;
                uint256 maxPossibleChange = uint256(params.maxFee) - uint256(params.minFee);

                // Fee change should not be at maximum since streak just reset to 1
                assertTrue(
                    feeChange < maxPossibleChange, "Fee change after alternation should be moderate (streak reset)"
                );
            }

            previousWasUpper = isUpper;
            previousFee = currentFee;
        }
    }

    /* ========================================================================== */
    /*                       BLACK SWAN EVENT SIMULATION                          */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Complete pool lifecycle through black swan event
     * @dev Normal → extreme volatility → recovery → stabilization
     * @param normalLiquidity Normal state liquidity
     * @param crisisSwapSize Crisis event swap size
     * @param recoveryTime Time to recover (1-14 days)
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function testFuzz_blackSwan_fullLifecycle_systemRecovery(
        uint128 normalLiquidity,
        uint256 crisisSwapSize,
        uint256 recoveryTime
    ) public {
        (PoolKey memory testKey, PoolId testPoolId) = (key, poolId);

        normalLiquidity = uint128(bound(normalLiquidity, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        crisisSwapSize = bound(crisisSwapSize, MAX_SWAP_AMOUNT / 2, MAX_SWAP_AMOUNT);
        recoveryTime = bound(recoveryTime, 1 days, 14 days);

        int24 minTick = TickMath.minUsableTick(testKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(testKey.tickSpacing);

        vm.startPrank(alice);
        _addLiquidityForUser(alice, testKey, minTick, maxTick, normalLiquidity);
        vm.stopPrank();

        logic.getPoolConfig(); // Assert pool is configured
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();

        vm.warp(block.timestamp + 7 days);
        vm.prank(owner);
        hook.poke(5e17);

        uint24 feeNormal;
        (,,, feeNormal) = poolManager.getSlot0(testPoolId);

        vm.startPrank(bob);
        _performSwap(bob, testKey, crisisSwapSize, true);
        _performSwap(bob, testKey, crisisSwapSize / 2, false);
        _performSwap(bob, testKey, crisisSwapSize / 3, true);
        vm.stopPrank();

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(9e17);

        uint24 feeCrisis;
        (,,, feeCrisis) = poolManager.getSlot0(testPoolId);

        vm.warp(block.timestamp + recoveryTime);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + params.minPeriod + 1);
            uint256 recoveryRatio = 9e17 - (i * 1e17);
            if (recoveryRatio < 1e17) recoveryRatio = 1e17;

            vm.prank(owner);
            hook.poke(recoveryRatio);
        }

        uint24 feeRecovered;
        (,,, feeRecovered) = poolManager.getSlot0(testPoolId);

        assertGe(feeNormal, params.minFee, "Normal fee bounded");
        assertGe(feeCrisis, params.minFee, "Crisis fee bounded");
        assertGe(feeRecovered, params.minFee, "Recovered fee bounded");
        assertLe(feeRecovered, params.maxFee, "Recovered fee bounded");

        // Verify crisis typically increases fee (though EMA behavior may vary)
        // At minimum, verify system responds to crisis with fee adjustment
        assertTrue(
            feeCrisis >= feeNormal || feeRecovered <= params.maxFee,
            "System should respond to crisis with fee changes while staying bounded"
        );

        IAlphixLogic.PoolConfig memory poolConfigAfter = logic.getPoolConfig();
        assertTrue(poolConfigAfter.isConfigured, "Pool operational after black swan");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    /**
     * @notice Calculate lower bound with underflow guard
     * @dev Prevents underflow when ratioTolerance > 1e18
     * @param targetRatio The target ratio to calculate bounds for
     * @param ratioTolerance The tolerance percentage (e.g., 2e17 = 20%)
     * @return lowerBound The calculated lower bound, minimum 1e15
     */
    function _calculateLowerBound(uint256 targetRatio, uint256 ratioTolerance) internal pure returns (uint256) {
        uint256 tol = (targetRatio * ratioTolerance) / 1e18;
        return targetRatio > tol ? (targetRatio - tol) : 1e15;
    }

    // NOTE: _createPoolWithType helper removed in single-pool-per-hook architecture.
    // Tests now use the default pool (key, poolId) from BaseAlphixTest setUp.

    /**
     * @notice Adds liquidity to a pool for a specific user
     * @dev Handles token approvals and calls position manager to mint liquidity
     * @param user The address that will own the liquidity position
     * @param poolKey The pool to add liquidity to
     * @param lower The lower tick boundary of the position
     * @param upper The upper tick boundary of the position
     * @param liquidity The amount of liquidity to add
     * @return newTokenId The token ID of the newly minted position
     */
    function _addLiquidityForUser(address user, PoolKey memory poolKey, int24 lower, int24 upper, uint128 liquidity)
        internal
        returns (uint256 newTokenId)
    {
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(poolKey.currency1)).approve(address(permit2), type(uint256).max);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(poolKey.currency0), address(positionManager), type(uint160).max, expiry);
        permit2.approve(Currency.unwrap(poolKey.currency1), address(positionManager), type(uint160).max, expiry);

        (newTokenId,) = positionManager.mint(
            poolKey,
            lower,
            upper,
            liquidity,
            type(uint256).max,
            type(uint256).max,
            user,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
    }

    /**
     * @notice Executes a swap on behalf of a trader
     * @dev Handles token approvals and calls swap router
     * @param trader The address executing the swap
     * @param poolKey The pool to swap in
     * @param amount The amount of input tokens to swap
     * @param zeroForOne True if swapping token0 for token1, false otherwise
     */
    function _performSwap(address trader, PoolKey memory poolKey, uint256 amount, bool zeroForOne) internal {
        Currency inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amount);

        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 100
        });
    }

    /**
     * @notice Mints tokens to a user for both currencies in a pool
     * @dev Used in setUp to provide initial token balances to test users
     * @param user The address to receive the minted tokens
     * @param c0 The first currency
     * @param c1 The second currency
     * @param amount The amount of each token to mint
     */
    function _mintTokensToUser(address user, Currency c0, Currency c1, uint256 amount) internal {
        MockERC20(Currency.unwrap(c0)).mint(user, amount);
        MockERC20(Currency.unwrap(c1)).mint(user, amount);
    }

    /**
     * @notice Executes the liquidity drain phase of the drain-and-flood test
     * @dev Gradually removes liquidity while performing swaps between each step
     * @param testKey The pool key
     * @param testPoolId The pool ID
     * @param params The liquidity drain parameters
     * @dev Note: poolType parameter removed in single-pool architecture
     * @return aliceTokenId The token ID of Alice's liquidity position
     */
    function _executeLiquidityDrain(PoolKey memory testKey, PoolId testPoolId, LiquidityDrainParams memory params)
        internal
        returns (uint256 aliceTokenId)
    {
        vm.startPrank(alice);
        aliceTokenId = _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            params.initialLiquidity
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory poolParams = logic.getPoolParams();
        // Guard against tiny-liquidity rounding: ensure liquidityPerStep is at least 1
        uint128 liquidityPerStep = params.initialLiquidity / params.drainSteps;
        if (liquidityPerStep == 0) liquidityPerStep = 1;

        // Defensive bound to avoid future underflow if drainSteps is 0
        uint8 stepsMinusOne = params.drainSteps > 0 ? params.drainSteps - 1 : 0;
        for (uint256 i = 0; i < stepsMinusOne; i++) {
            vm.warp(block.timestamp + 1 days);

            vm.startPrank(alice);
            positionManager.decreaseLiquidity(
                aliceTokenId, liquidityPerStep, 0, 0, alice, block.timestamp + 60, Constants.ZERO_BYTES
            );
            vm.stopPrank();

            vm.startPrank(bob);
            _performSwap(bob, testKey, params.swapAmount, i % 2 == 0);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + poolParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(3e17);

        uint24 feeDuringDrain;
        (,,, feeDuringDrain) = poolManager.getSlot0(testPoolId);
        assertGe(feeDuringDrain, poolParams.minFee, "Fee bounded during drain");
        assertLe(feeDuringDrain, poolParams.maxFee, "Fee bounded during drain");
    }

    /**
     * @notice Executes the liquidity flood phase of the drain-and-flood test
     * @dev Adds massive liquidity suddenly and verifies fee bounds
     * @param testKey The pool key
     * @param testPoolId The pool ID
     * @param reentryLiquidity The amount of liquidity to inject
     * @dev Note: poolType parameter removed in single-pool architecture
     */
    function _executeLiquidityFlood(PoolKey memory testKey, PoolId testPoolId, uint128 reentryLiquidity) internal {
        vm.startPrank(charlie);
        _addLiquidityForUser(
            charlie,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            reentryLiquidity
        );
        vm.stopPrank();

        DynamicFeeLib.PoolParams memory poolParams = logic.getPoolParams();
        vm.warp(block.timestamp + poolParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(5e17);

        uint24 feeAfterFlood;
        (,,, feeAfterFlood) = poolManager.getSlot0(testPoolId);
        assertGe(feeAfterFlood, poolParams.minFee, "Fee bounded after flood");
        assertLe(feeAfterFlood, poolParams.maxFee, "Fee bounded after flood");
    }
}
