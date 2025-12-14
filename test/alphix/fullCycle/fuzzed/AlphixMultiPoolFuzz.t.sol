// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixMultiPoolFuzzTest
 * @author Alphix
 * @notice Fuzzed tests for multi-pool interactions, cross-pool arbitrage, and simultaneous operations
 * @dev Tests pool isolation, cross-pool behaviors, and system-wide consistency
 */
contract AlphixMultiPoolFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;
    address public arbitrageur;

    uint256 constant MIN_LIQUIDITY = 1e18;
    uint256 constant MAX_LIQUIDITY = 500e18;
    uint256 constant MIN_SWAP_AMOUNT = 1e17;
    uint256 constant MAX_SWAP_AMOUNT = 50e18;
    uint256 constant MAX_RATIO = 1e18;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        arbitrageur = makeAddr("arbitrageur");

        vm.startPrank(owner);
        _mintTokensToUser(alice, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(bob, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(arbitrageur, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                    MULTI-POOL ISOLATION & INDEPENDENCE                     */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Multiple pools with different types operate independently
     * @dev Tests that pool configurations don't interfere with each other
     * @param liquidityStable Liquidity for stable pool
     * @param liquidityStandard Liquidity for standard pool
     * @param liquidityVolatile Liquidity for volatile pool
     * @param swapAmount Swap amount across pools
     */
    function testFuzz_multiPool_differentTypes_operateIndependently(
        uint128 liquidityStable,
        uint128 liquidityStandard,
        uint128 liquidityVolatile,
        uint256 swapAmount
    ) public {
        liquidityStable = uint128(bound(liquidityStable, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        liquidityStandard = uint128(bound(liquidityStandard, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        liquidityVolatile = uint128(bound(liquidityVolatile, MIN_LIQUIDITY * 50, MAX_LIQUIDITY));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT / 2);

        (PoolKey memory stableKey, PoolId stableId) = _createPoolWithType(IAlphixLogic.PoolType.STABLE);
        (PoolKey memory standardKey, PoolId standardId) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);
        (PoolKey memory volatileKey, PoolId volatileId) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            stableKey,
            TickMath.minUsableTick(stableKey.tickSpacing),
            TickMath.maxUsableTick(stableKey.tickSpacing),
            liquidityStable
        );
        _addLiquidityForUser(
            alice,
            standardKey,
            TickMath.minUsableTick(standardKey.tickSpacing),
            TickMath.maxUsableTick(standardKey.tickSpacing),
            liquidityStandard
        );
        _addLiquidityForUser(
            alice,
            volatileKey,
            TickMath.minUsableTick(volatileKey.tickSpacing),
            TickMath.maxUsableTick(volatileKey.tickSpacing),
            liquidityVolatile
        );
        vm.stopPrank();

        DynamicFeeLib.PoolTypeParams memory stablePoolParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STABLE);
        DynamicFeeLib.PoolTypeParams memory standardPoolParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        DynamicFeeLib.PoolTypeParams memory volatilePoolParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.VOLATILE);

        vm.warp(block.timestamp + standardPoolParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(stableKey, 3e17);

        vm.startPrank(bob);
        _performSwap(bob, standardKey, swapAmount, true);
        vm.stopPrank();

        vm.warp(block.timestamp + standardPoolParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(volatileKey, 7e17);

        uint24 stableFee;
        uint24 standardFee;
        uint24 volatileFee;
        (,,, stableFee) = poolManager.getSlot0(stableId);
        (,,, standardFee) = poolManager.getSlot0(standardId);
        (,,, volatileFee) = poolManager.getSlot0(volatileId);

        assertGe(stableFee, stablePoolParams.minFee, "Stable fee bounded");
        assertLe(stableFee, stablePoolParams.maxFee, "Stable fee bounded");
        assertGe(standardFee, standardPoolParams.minFee, "Standard fee bounded");
        assertLe(standardFee, standardPoolParams.maxFee, "Standard fee bounded");
        assertGe(volatileFee, volatilePoolParams.minFee, "Volatile fee bounded");
        assertLe(volatileFee, volatilePoolParams.maxFee, "Volatile fee bounded");

        IAlphixLogic.PoolConfig memory stableConfig = logic.getPoolConfig(stableId);
        IAlphixLogic.PoolConfig memory standardConfig = logic.getPoolConfig(standardId);
        IAlphixLogic.PoolConfig memory volatileConfig = logic.getPoolConfig(volatileId);

        assertTrue(stableConfig.isConfigured, "Stable pool configured");
        assertTrue(standardConfig.isConfigured, "Standard pool configured");
        assertTrue(volatileConfig.isConfigured, "Volatile pool configured");
    }

    /**
     * @notice Fuzz: Simultaneous pokes to multiple pools
     * @dev Tests that concurrent pool operations don't interfere
     * @param numPools Number of pools to create (2-4)
     * @param liquidityPerPool Liquidity for each pool
     * @param ratio1 Ratio for first set of pools
     * @param ratio2 Ratio for second set of pools
     */
    function testFuzz_multiPool_simultaneousPokes_noInterference(
        uint8 numPools,
        uint128 liquidityPerPool,
        uint256 ratio1,
        uint256 ratio2
    ) public {
        numPools = uint8(bound(numPools, 2, 4));
        liquidityPerPool = uint128(bound(liquidityPerPool, MIN_LIQUIDITY * 50, MAX_LIQUIDITY / 2));
        ratio1 = bound(ratio1, 5e16, 5e17);
        ratio2 = bound(ratio2, 5e17, MAX_RATIO);

        PoolKey[] memory pools = new PoolKey[](numPools);
        PoolId[] memory poolIds = new PoolId[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            (pools[i], poolIds[i]) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

            vm.startPrank(alice);
            _addLiquidityForUser(
                alice,
                pools[i],
                TickMath.minUsableTick(pools[i].tickSpacing),
                TickMath.maxUsableTick(pools[i].tickSpacing),
                liquidityPerPool
            );
            vm.stopPrank();
        }

        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params.minPeriod + 1);

        for (uint256 i = 0; i < numPools; i++) {
            uint256 ratio = (i % 2 == 0) ? ratio1 : ratio2;
            // Clamp ratio to protocol bounds to avoid reverts
            if (ratio > params.maxCurrentRatio) ratio = params.maxCurrentRatio;
            if (ratio < 1e15) ratio = 1e15;
            vm.prank(owner);
            hook.poke(pools[i], ratio);
        }

        for (uint256 i = 0; i < numPools; i++) {
            uint24 fee;
            (,,, fee) = poolManager.getSlot0(poolIds[i]);
            assertGe(fee, params.minFee, "Fee bounded for pool");
            assertLe(fee, params.maxFee, "Fee bounded for pool");
        }
    }

    /* ========================================================================== */
    /*                     CROSS-POOL ARBITRAGE SCENARIOS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Arbitrage opportunity between two pools with different fees
     * @dev Tests that arbitrageurs can operate but fees remain bounded
     * @param liquidityPool1 Liquidity for pool 1
     * @param liquidityPool2 Liquidity for pool 2
     * @param arbSwapSize Arbitrageur's swap size
     * @param ratio1 Ratio for pool 1
     * @param ratio2 Ratio for pool 2
     */
    function testFuzz_crossPool_arbitrage_feesRemainBounded(
        uint128 liquidityPool1,
        uint128 liquidityPool2,
        uint256 arbSwapSize,
        uint256 ratio1,
        uint256 ratio2
    ) public {
        liquidityPool1 = uint128(bound(liquidityPool1, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        liquidityPool2 = uint128(bound(liquidityPool2, MIN_LIQUIDITY * 50, MAX_LIQUIDITY / 2));
        arbSwapSize = bound(arbSwapSize, MIN_SWAP_AMOUNT * 2, MAX_SWAP_AMOUNT);
        ratio1 = bound(ratio1, 3e17, 6e17);
        ratio2 = bound(ratio2, 2e17, 8e17);

        (PoolKey memory pool1Key, PoolId pool1Id) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);
        (PoolKey memory pool2Key, PoolId pool2Id) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            pool1Key,
            TickMath.minUsableTick(pool1Key.tickSpacing),
            TickMath.maxUsableTick(pool1Key.tickSpacing),
            liquidityPool1
        );
        _addLiquidityForUser(
            alice,
            pool2Key,
            TickMath.minUsableTick(pool2Key.tickSpacing),
            TickMath.maxUsableTick(pool2Key.tickSpacing),
            liquidityPool2
        );
        vm.stopPrank();

        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(pool1Key, ratio1);

        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(pool2Key, ratio2);

        uint256 arbBalance0Before = MockERC20(Currency.unwrap(pool1Key.currency0)).balanceOf(arbitrageur);
        uint256 arbBalance1Before = MockERC20(Currency.unwrap(pool1Key.currency1)).balanceOf(arbitrageur);

        vm.startPrank(arbitrageur);
        _performSwap(arbitrageur, pool1Key, arbSwapSize, true);
        _performSwap(arbitrageur, pool2Key, arbSwapSize / 2, false);
        vm.stopPrank();

        uint256 arbBalance0After = MockERC20(Currency.unwrap(pool1Key.currency0)).balanceOf(arbitrageur);
        uint256 arbBalance1After = MockERC20(Currency.unwrap(pool1Key.currency1)).balanceOf(arbitrageur);

        uint24 fee1After;
        uint24 fee2After;
        (,,, fee1After) = poolManager.getSlot0(pool1Id);
        (,,, fee2After) = poolManager.getSlot0(pool2Id);

        assertGe(fee1After, params.minFee, "Pool1 fee bounded after arbitrage");
        assertLe(fee1After, params.maxFee, "Pool1 fee bounded after arbitrage");
        assertGe(fee2After, params.minFee, "Pool2 fee bounded after arbitrage");
        assertLe(fee2After, params.maxFee, "Pool2 fee bounded after arbitrage");

        // Verify arbitrage didn't lose funds (at least one token balance should not decrease)
        assertTrue(
            arbBalance0After >= arbBalance0Before || arbBalance1After >= arbBalance1Before,
            "Arbitrage should not lose funds in both tokens"
        );
    }

    /**
     * @notice Fuzz: Liquidity migration between pools
     * @dev Tests LPs moving between pools with different fee structures
     * @param initialLiquidityPool1 Initial liquidity in pool 1
     * @param migrationAmount Amount to migrate
     * @param poolTypePool2Raw Pool type for destination pool
     */
    function testFuzz_crossPool_liquidityMigration_systemStable(
        uint128 initialLiquidityPool1,
        uint128 migrationAmount,
        uint8 poolTypePool2Raw
    ) public {
        IAlphixLogic.PoolType poolTypePool2 = _boundPoolType(poolTypePool2Raw);

        initialLiquidityPool1 = uint128(bound(initialLiquidityPool1, MIN_LIQUIDITY * 100, MAX_LIQUIDITY));
        migrationAmount = uint128(bound(migrationAmount, MIN_LIQUIDITY * 20, initialLiquidityPool1 / 2));

        (PoolKey memory pool1Key, PoolId pool1Id) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);
        (PoolKey memory pool2Key, PoolId pool2Id) = _createPoolWithType(poolTypePool2);

        vm.startPrank(alice);
        uint256 tokenId1 = _addLiquidityForUser(
            alice,
            pool1Key,
            TickMath.minUsableTick(pool1Key.tickSpacing),
            TickMath.maxUsableTick(pool1Key.tickSpacing),
            initialLiquidityPool1
        );
        vm.stopPrank();

        DynamicFeeLib.PoolTypeParams memory params1 = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params1.minPeriod + 1);

        vm.prank(owner);
        hook.poke(pool1Key, 4e17);

        vm.startPrank(alice);
        positionManager.decreaseLiquidity(
            tokenId1, migrationAmount, 0, 0, alice, block.timestamp + 60, Constants.ZERO_BYTES
        );
        _addLiquidityForUser(
            alice,
            pool2Key,
            TickMath.minUsableTick(pool2Key.tickSpacing),
            TickMath.maxUsableTick(pool2Key.tickSpacing),
            migrationAmount
        );
        vm.stopPrank();

        DynamicFeeLib.PoolTypeParams memory params2 = logic.getPoolTypeParams(poolTypePool2);
        vm.warp(block.timestamp + params2.minPeriod + 1);
        vm.prank(owner);
        hook.poke(pool2Key, 5e17);

        uint24 fee1;
        uint24 fee2;
        (,,, fee1) = poolManager.getSlot0(pool1Id);
        (,,, fee2) = poolManager.getSlot0(pool2Id);

        assertGe(fee1, params1.minFee, "Pool1 fee bounded after migration");
        assertLe(fee1, params1.maxFee, "Pool1 fee bounded after migration");
        assertGe(fee2, params2.minFee, "Pool2 fee bounded after migration");
        assertLe(fee2, params2.maxFee, "Pool2 fee bounded after migration");
    }

    /* ========================================================================== */
    /*                    SIMULTANEOUS MULTI-POOL OPERATIONS                      */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Multiple pools receiving swaps simultaneously
     * @dev Tests concurrent trading across multiple pools
     * @param numPools Number of pools (2-5)
     * @param liquidityPerPool Liquidity per pool
     * @param swapsPerPool Number of swaps per pool (1-5)
     * @param swapAmount Swap amount
     */
    function testFuzz_multiPool_simultaneousSwaps_allPoolsOperational(
        uint8 numPools,
        uint128 liquidityPerPool,
        uint8 swapsPerPool,
        uint256 swapAmount
    ) public {
        numPools = uint8(bound(numPools, 2, 5));
        liquidityPerPool = uint128(bound(liquidityPerPool, MIN_LIQUIDITY * 50, MAX_LIQUIDITY / 3));
        swapsPerPool = uint8(bound(swapsPerPool, 1, 5));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT / 2);

        PoolKey[] memory pools = new PoolKey[](numPools);
        PoolId[] memory poolIds = new PoolId[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            IAlphixLogic.PoolType poolType = IAlphixLogic.PoolType(i % 3);
            (pools[i], poolIds[i]) = _createPoolWithType(poolType);

            vm.startPrank(alice);
            _addLiquidityForUser(
                alice,
                pools[i],
                TickMath.minUsableTick(pools[i].tickSpacing),
                TickMath.maxUsableTick(pools[i].tickSpacing),
                liquidityPerPool
            );
            vm.stopPrank();
        }

        for (uint256 i = 0; i < numPools; i++) {
            for (uint256 j = 0; j < swapsPerPool; j++) {
                vm.startPrank(bob);
                _performSwap(bob, pools[i], swapAmount, j % 2 == 0);
                vm.stopPrank();
            }
        }

        for (uint256 i = 0; i < numPools; i++) {
            IAlphixLogic.PoolType poolType = IAlphixLogic.PoolType(i % 3);
            DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

            vm.warp(block.timestamp + params.minPeriod + 1);
            uint256 ratio = 4e17 + (i * 1e17);
            // Clamp ratio to protocol bounds to avoid reverts
            if (ratio > params.maxCurrentRatio) ratio = params.maxCurrentRatio;
            if (ratio < 1e15) ratio = 1e15;

            vm.prank(owner);
            hook.poke(pools[i], ratio);

            uint24 fee;
            (,,, fee) = poolManager.getSlot0(poolIds[i]);
            assertGe(fee, params.minFee, "Fee bounded for pool after swaps");
            assertLe(fee, params.maxFee, "Fee bounded for pool after swaps");
        }
    }

    /**
     * @notice Fuzz: Pool type parameter changes affect all pools of that type
     * @dev Tests that global pool-type parameter updates apply uniformly to all pools of the same type
     * @param numPools Number of pools (2-4)
     * @param newMinFee New min fee for pool type
     * @param newMaxFee New max fee for pool type
     */
    function testFuzz_multiPool_parameterChange_globalEffect(uint8 numPools, uint24 newMinFee, uint24 newMaxFee)
        public
    {
        numPools = uint8(bound(numPools, 2, 4));
        newMinFee = uint24(bound(newMinFee, 100, 1000));
        newMaxFee = uint24(bound(newMaxFee, newMinFee + 100, 10000));

        PoolKey[] memory pools = new PoolKey[](numPools);
        PoolId[] memory poolIds = new PoolId[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            (pools[i], poolIds[i]) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

            vm.startPrank(alice);
            _addLiquidityForUser(
                alice,
                pools[i],
                TickMath.minUsableTick(pools[i].tickSpacing),
                TickMath.maxUsableTick(pools[i].tickSpacing),
                // Casting to uint128 is safe because MIN_LIQUIDITY * 50 is bounded well within uint128 max
                // forge-lint: disable-next-line(unsafe-typecast)
                uint128(MIN_LIQUIDITY * 50)
            );
            vm.stopPrank();
        }

        DynamicFeeLib.PoolTypeParams memory originalParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        DynamicFeeLib.PoolTypeParams memory modifiedParams = originalParams;
        modifiedParams.minFee = newMinFee;
        modifiedParams.maxFee = newMaxFee;

        vm.prank(owner);
        logic.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, modifiedParams);

        DynamicFeeLib.PoolTypeParams memory updatedParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        assertEq(updatedParams.minFee, newMinFee, "Min fee updated");
        assertEq(updatedParams.maxFee, newMaxFee, "Max fee updated");

        for (uint256 i = 0; i < numPools; i++) {
            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolIds[i]);
            assertTrue(config.isConfigured, "All pools remain configured");
        }
    }

    /* ========================================================================== */
    /*                     STRESS TEST: MANY POOLS                                */
    /* ========================================================================== */

    /**
     * @notice Fuzz: System handles many pools simultaneously
     * @dev Stress tests with multiple pools under load
     * @param numPools Number of pools to create (3-8)
     * @param actionsPerPool Number of actions per pool (2-5)
     */
    function testFuzz_multiPool_manyPools_systemResilient(uint8 numPools, uint8 actionsPerPool) public {
        numPools = uint8(bound(numPools, 3, 8));
        actionsPerPool = uint8(bound(actionsPerPool, 2, 5));

        PoolKey[] memory pools = new PoolKey[](numPools);
        PoolId[] memory poolIds = new PoolId[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            IAlphixLogic.PoolType poolType = IAlphixLogic.PoolType(i % 3);
            (pools[i], poolIds[i]) = _createPoolWithType(poolType);

            vm.startPrank(alice);
            _addLiquidityForUser(
                alice,
                pools[i],
                TickMath.minUsableTick(pools[i].tickSpacing),
                TickMath.maxUsableTick(pools[i].tickSpacing),
                // Casting to uint128 is safe because MIN_LIQUIDITY * 30 is bounded well within uint128 max
                // forge-lint: disable-next-line(unsafe-typecast)
                uint128(MIN_LIQUIDITY * 30)
            );
            vm.stopPrank();
        }

        for (uint256 action = 0; action < actionsPerPool; action++) {
            for (uint256 i = 0; i < numPools; i++) {
                IAlphixLogic.PoolType poolType = IAlphixLogic.PoolType(i % 3);
                DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

                vm.startPrank(bob);
                _performSwap(bob, pools[i], MIN_SWAP_AMOUNT, action % 2 == 0);
                vm.stopPrank();

                if (action % 2 == 0) {
                    vm.warp(block.timestamp + params.minPeriod + 1);
                    uint256 ratio = 3e17 + ((i + action) * 1e16);

                    vm.prank(owner);
                    hook.poke(pools[i], ratio);
                }
            }
        }

        for (uint256 i = 0; i < numPools; i++) {
            IAlphixLogic.PoolType poolType = IAlphixLogic.PoolType(i % 3);
            DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolType);

            uint24 fee;
            (,,, fee) = poolManager.getSlot0(poolIds[i]);

            assertGe(fee, params.minFee, "Fee bounded under stress");
            assertLe(fee, params.maxFee, "Fee bounded under stress");

            IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolIds[i]);
            assertTrue(config.isConfigured, "Pool operational under stress");
        }
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    /**
     * @notice Creates a new pool with specified pool type
     * @dev Deploys fresh ERC20 tokens, mints to test users (alice, bob, arbitrageur), and initializes pool
     * @param poolType The type of pool to create (STABLE, STANDARD, or VOLATILE)
     * @return testKey The pool key for the created pool
     * @return testPoolId The pool ID for the created pool
     */
    function _createPoolWithType(IAlphixLogic.PoolType poolType)
        internal
        returns (PoolKey memory testKey, PoolId testPoolId)
    {
        MockERC20 token0 = new MockERC20("Test Token 0", "TEST0", 18);
        MockERC20 token1 = new MockERC20("Test Token 1", "TEST1", 18);

        vm.startPrank(owner);
        token0.mint(alice, INITIAL_TOKEN_AMOUNT);
        token0.mint(bob, INITIAL_TOKEN_AMOUNT);
        token0.mint(arbitrageur, INITIAL_TOKEN_AMOUNT);
        token1.mint(alice, INITIAL_TOKEN_AMOUNT);
        token1.mint(bob, INITIAL_TOKEN_AMOUNT);
        token1.mint(arbitrageur, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        Currency curr0 = Currency.wrap(address(token0));
        Currency curr1 = Currency.wrap(address(token1));

        testKey = PoolKey({
            currency0: curr0 < curr1 ? curr0 : curr1,
            currency1: curr0 < curr1 ? curr1 : curr0,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolManager.initialize(testKey, Constants.SQRT_PRICE_1_1);
        testPoolId = testKey.toId();

        vm.prank(owner);
        hook.initializePool(testKey, INITIAL_FEE, INITIAL_TARGET_RATIO, poolType);
    }

    /**
     * @notice Adds liquidity to a pool for a specific user
     * @dev Handles token approvals and calls position manager to mint liquidity
     * @param user The address that will own the liquidity position
     * @param poolKey The pool to add liquidity to
     * @param lower The lower tick bound for the position
     * @param upper The upper tick bound for the position
     * @param liquidity The amount of liquidity to add
     * @return newTokenId The NFT token ID representing the liquidity position
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
     * @notice Executes a swap for a trader in the specified pool
     * @dev Approves tokens and calls swap router to execute the trade
     * @param trader The address executing the swap
     * @param poolKey The pool to swap in
     * @param amount The input amount for the swap
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
     * @notice Mints test tokens to a user
     * @dev Helper function to mint both currencies to a test user
     * @param user The address to receive the minted tokens
     * @param c0 The first currency to mint
     * @param c1 The second currency to mint
     * @param amount The amount of each token to mint
     */
    function _mintTokensToUser(address user, Currency c0, Currency c1, uint256 amount) internal {
        MockERC20(Currency.unwrap(c0)).mint(user, amount);
        MockERC20(Currency.unwrap(c1)).mint(user, amount);
    }
}
