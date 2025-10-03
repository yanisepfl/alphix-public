// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixUpgradeabilityFuzzTest
 * @author Alphix
 * @notice Fuzzed UUPS upgradeability tests with state preservation validation
 * @dev Adapts concrete tests from AlphixUpgradeability.t.sol with fuzzed parameters
 */
contract AlphixUpgradeabilityFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;

    uint256 constant MIN_LIQUIDITY = 1e18;
    uint256 constant MAX_LIQUIDITY = 500e18;
    uint256 constant MIN_SWAP_AMOUNT = 1e17;
    uint256 constant MAX_SWAP_AMOUNT = 50e18;
    uint256 constant MIN_RATIO = 0;
    uint256 constant MAX_RATIO = 1e18;

    function setUp() public override {
        super.setUp();

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.startPrank(owner);
        _mintTokensToUser(alice, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        _mintTokensToUser(bob, currency0, currency1, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                         FUZZED BASIC UPGRADE TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Upgrade preserves pool configuration with varying parameters
     * @param liquidityAmount Liquidity to add before upgrade
     * @param ratio Ratio to set before upgrade
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_upgrade_preserves_pool_configurations(uint128 liquidityAmount, uint256 ratio, uint8 poolTypeRaw)
        public
    {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        ratio = bound(ratio, 5e16, MAX_RATIO);

        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        // Setup pool before upgrade
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(testKey, ratio);

        // Record state before upgrade
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig(testPoolId);
        uint24 feeBefore;
        (,,, feeBefore) = poolManager.getSlot0(testPoolId);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify state preserved
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig(testPoolId);
        uint24 feeAfter;
        (,,, feeAfter) = poolManager.getSlot0(testPoolId);

        assertEq(configAfter.initialFee, configBefore.initialFee, "Initial fee preserved");
        assertEq(uint8(configAfter.poolType), uint8(configBefore.poolType), "Pool type preserved");
        assertTrue(configAfter.isConfigured, "Pool remains configured");
        assertEq(feeAfter, feeBefore, "Dynamic fee preserved");
    }

    /**
     * @notice Fuzz: Pool operations work after upgrade with varying amounts
     * @param liquidityBefore Liquidity added before upgrade
     * @param liquidityAfter Liquidity added after upgrade
     * @param swapAmountAfter Swap amount after upgrade
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_pool_operations_work_after_upgrade(
        uint128 liquidityBefore,
        uint128 liquidityAfter,
        uint256 swapAmountAfter,
        uint8 poolTypeRaw
    ) public {
        liquidityBefore = uint128(bound(liquidityBefore, MIN_LIQUIDITY * 10, MAX_LIQUIDITY / 2));
        liquidityAfter = uint128(bound(liquidityAfter, MIN_LIQUIDITY * 5, MAX_LIQUIDITY / 2));
        swapAmountAfter = bound(swapAmountAfter, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);

        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey,) = _createPoolWithType(poolType);

        // Add liquidity before upgrade
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityBefore
        );
        vm.stopPrank();

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Test liquidity operations after upgrade
        vm.startPrank(bob);
        uint256 newTokenId = _addLiquidityForUser(
            bob,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAfter
        );
        vm.stopPrank();

        assertGt(newTokenId, 0, "Should mint new position after upgrade");

        // Test swaps after upgrade
        vm.startPrank(alice);
        uint256 aliceBalanceBefore = MockERC20(Currency.unwrap(testKey.currency1)).balanceOf(alice);
        MockERC20(Currency.unwrap(testKey.currency0)).approve(address(swapRouter), swapAmountAfter);

        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmountAfter,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        uint256 aliceBalanceAfter = MockERC20(Currency.unwrap(testKey.currency1)).balanceOf(alice);
        vm.stopPrank();

        assertGt(aliceBalanceAfter, aliceBalanceBefore, "Should receive tokens from swap after upgrade");
    }

    /**
     * @notice Fuzz: Fee poke works after upgrade with varying ratios
     * @param liquidityAmount Initial liquidity
     * @param ratioBefore Ratio before upgrade
     * @param ratioAfter Ratio after upgrade
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_fee_poke_works_after_upgrade(
        uint128 liquidityAmount,
        uint256 ratioBefore,
        uint256 ratioAfter,
        uint8 poolTypeRaw
    ) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        ratioBefore = bound(ratioBefore, 5e16, MAX_RATIO / 2); // Min 5% to avoid invalid ratio
        ratioAfter = bound(ratioAfter, 5e16, MAX_RATIO); // Min 5%

        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        // Setup
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + params.minPeriod + 1);

        // Poke before upgrade
        vm.prank(owner);
        hook.poke(testKey, ratioBefore);

        uint24 feeBefore;
        (,,, feeBefore) = poolManager.getSlot0(testPoolId);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Poke after upgrade
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratioAfter);

        uint24 feeAfter;
        (,,, feeAfter) = poolManager.getSlot0(testPoolId);

        // Verify fees within bounds
        assertGe(feeBefore, params.minFee, "Fee before >= minFee");
        assertLe(feeBefore, params.maxFee, "Fee before <= maxFee");
        assertGe(feeAfter, params.minFee, "Fee after >= minFee");
        assertLe(feeAfter, params.maxFee, "Fee after <= maxFee");
    }

    /* ========================================================================== */
    /*                      FUZZED MULTIPLE UPGRADE TESTS                         */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Multiple sequential upgrades with operations between
     * @param numUpgrades Number of upgrades to perform (2-5)
     * @param swapAmount Swap amount between upgrades
     * @param ratio Ratio to set between upgrades
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_multiple_sequential_upgrades(
        uint8 numUpgrades,
        uint256 swapAmount,
        uint256 ratio,
        uint8 poolTypeRaw
    ) public {
        numUpgrades = uint8(bound(numUpgrades, 2, 5));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT / 2);
        ratio = bound(ratio, 5e16, MAX_RATIO); // Min 5%

        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        // Initial setup
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            100e18
        );
        vm.stopPrank();

        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);

        // Perform multiple upgrades
        for (uint256 i = 0; i < numUpgrades; i++) {
            // Operation before upgrade
            vm.startPrank(bob);
            MockERC20(Currency.unwrap(testKey.currency0)).approve(address(swapRouter), swapAmount);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: testKey,
                hookData: Constants.ZERO_BYTES,
                receiver: bob,
                deadline: block.timestamp + 100
            });
            vm.stopPrank();

            // Upgrade
            vm.startPrank(owner);
            AlphixLogic newImpl = new AlphixLogic();
            UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newImpl), "");
            vm.stopPrank();

            // Operation after upgrade
            vm.warp(block.timestamp + params.minPeriod + 1);
            vm.prank(owner);
            hook.poke(testKey, ratio);
        }

        // Verify pool still operational
        IAlphixLogic.PoolConfig memory finalConfig = logic.getPoolConfig(testPoolId);
        assertTrue(finalConfig.isConfigured, "Pool should remain configured after multiple upgrades");

        uint24 finalFee;
        (,,, finalFee) = poolManager.getSlot0(testPoolId);
        assertGe(finalFee, params.minFee, "Final fee >= minFee");
        assertLe(finalFee, params.maxFee, "Final fee <= maxFee");
    }

    /**
     * @notice Fuzz: Upgrade with active pool state - varying liquidity and trading
     * @param aliceLiq Alice's liquidity
     * @param bobLiq Bob's liquidity
     * @param swapAmount Swap amount before upgrade
     * @param ratio Ratio before upgrade
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_upgrade_with_active_pool_state(
        uint128 aliceLiq,
        uint128 bobLiq,
        uint256 swapAmount,
        uint256 ratio,
        uint8 poolTypeRaw
    ) public {
        aliceLiq = uint128(bound(aliceLiq, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        bobLiq = uint128(bound(bobLiq, MIN_LIQUIDITY * 5, MAX_LIQUIDITY / 2));
        swapAmount = bound(swapAmount, MIN_SWAP_AMOUNT, MAX_SWAP_AMOUNT);
        ratio = bound(ratio, 5e16, MAX_RATIO); // Min 5%

        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        // Create active pool state
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            aliceLiq
        );
        vm.stopPrank();

        vm.startPrank(bob);
        _addLiquidityForUser(
            bob,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            bobLiq
        );
        vm.stopPrank();

        // Trading activity
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(testKey.currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Set dynamic fee
        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(testKey, ratio);

        // Record state
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig(testPoolId);
        uint24 feeBefore;
        (,,, feeBefore) = poolManager.getSlot0(testPoolId);

        // Upgrade while active
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify state preserved
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig(testPoolId);
        uint24 feeAfter;
        (,,, feeAfter) = poolManager.getSlot0(testPoolId);

        assertEq(configAfter.initialFee, configBefore.initialFee, "Config preserved");
        assertTrue(configAfter.isConfigured, "Pool remains configured");
        assertEq(feeAfter, feeBefore, "Fee preserved");

        // Verify operations still work
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(testKey.currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: testKey,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                    FUZZED POOL TYPE PARAMETER TESTS                        */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Upgrade preserves pool type parameters with custom values
     * @param minFee Custom minimum fee
     * @param maxFee Custom maximum fee
     * @param liquidityAmount Liquidity amount
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_upgrade_preserves_pool_type_parameters(
        uint24 minFee,
        uint24 maxFee,
        uint128 liquidityAmount,
        uint8 poolTypeRaw
    ) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));

        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);
        (PoolKey memory testKey, PoolId testPoolId) = _createPoolWithType(poolType);

        // Get existing params as base
        IAlphixLogic.PoolConfig memory poolConfig = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(poolConfig.poolType);

        // Bound to reasonable values
        minFee = uint24(bound(minFee, 100, 1000)); // 0.01% to 0.1%
        maxFee = uint24(bound(maxFee, minFee + 100, 10000)); // Ensure maxFee > minFee, up to 1%

        // Set custom parameters before upgrade
        params.minFee = minFee;
        params.maxFee = maxFee;

        vm.prank(owner);
        hook.setPoolTypeParams(poolType, params);

        // Add liquidity
        vm.startPrank(alice);
        _addLiquidityForUser(
            alice,
            testKey,
            TickMath.minUsableTick(testKey.tickSpacing),
            TickMath.maxUsableTick(testKey.tickSpacing),
            liquidityAmount
        );
        vm.stopPrank();

        // Record parameters before upgrade
        IAlphixLogic.PoolConfig memory poolCfg = logic.getPoolConfig(testPoolId);
        DynamicFeeLib.PoolTypeParams memory paramsBefore = logic.getPoolTypeParams(poolCfg.poolType);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify parameters preserved
        DynamicFeeLib.PoolTypeParams memory paramsAfter = logic.getPoolTypeParams(poolCfg.poolType);

        assertEq(paramsAfter.minFee, paramsBefore.minFee, "minFee preserved");
        assertEq(paramsAfter.maxFee, paramsBefore.maxFee, "maxFee preserved");
        assertEq(paramsAfter.ratioTolerance, paramsBefore.ratioTolerance, "ratioTolerance preserved");
        assertEq(paramsAfter.lookbackPeriod, paramsBefore.lookbackPeriod, "lookbackPeriod preserved");
    }

    /**
     * @notice Fuzz: New pool initialization after upgrade with varying parameters
     * @param liquidityAmount Liquidity for new pool
     * @param poolTypeRaw Pool type (0=STABLE, 1=STANDARD, 2=VOLATILE)
     */
    function testFuzz_new_pool_initialization_after_upgrade(uint128 liquidityAmount, uint8 poolTypeRaw) public {
        liquidityAmount = uint128(bound(liquidityAmount, MIN_LIQUIDITY * 10, MAX_LIQUIDITY));
        IAlphixLogic.PoolType poolType = _boundPoolType(poolTypeRaw);

        // Upgrade first
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Create new pool after upgrade using different fee tier
        MockERC20 token2 = new MockERC20("Token2", "TK2", 18);
        MockERC20 token3 = new MockERC20("Token3", "TK3", 18);

        Currency currency2 = Currency.wrap(address(token2));
        Currency currency3 = Currency.wrap(address(token3));

        // Mint tokens
        vm.startPrank(owner);
        token2.mint(alice, INITIAL_TOKEN_AMOUNT);
        token3.mint(alice, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        // Create new pool key
        PoolKey memory newKey = PoolKey({
            currency0: currency2 < currency3 ? currency2 : currency3,
            currency1: currency2 < currency3 ? currency3 : currency2,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize new pool
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        PoolId newPoolId = newKey.toId();

        // Configure pool with initializePool using fuzzed pool type
        vm.prank(owner);
        hook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, poolType);

        // Add liquidity to new pool
        vm.startPrank(alice);
        token2.approve(address(permit2), type(uint256).max);
        token3.approve(address(permit2), type(uint256).max);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(address(token2), address(positionManager), type(uint160).max, expiry);
        permit2.approve(address(token3), address(positionManager), type(uint160).max, expiry);

        positionManager.mint(
            newKey,
            TickMath.minUsableTick(newKey.tickSpacing),
            TickMath.maxUsableTick(newKey.tickSpacing),
            liquidityAmount,
            type(uint256).max,
            type(uint256).max,
            alice,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        // Verify new pool is configured
        IAlphixLogic.PoolConfig memory newPoolConfig = logic.getPoolConfig(newPoolId);
        assertTrue(newPoolConfig.isConfigured, "New pool should be configured after upgrade");
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    /**
     * @notice Creates and initializes a new pool with a specific pool type
     * @param poolType The pool type to initialize
     * @return testKey The pool key for the new pool
     * @return testPoolId The pool ID for the new pool
     */
    function _createPoolWithType(IAlphixLogic.PoolType poolType)
        internal
        returns (PoolKey memory testKey, PoolId testPoolId)
    {
        // Create new tokens
        MockERC20 token0 = new MockERC20("Test Token 0", "TEST0", 18);
        MockERC20 token1 = new MockERC20("Test Token 1", "TEST1", 18);

        // Mint tokens to test users
        vm.startPrank(owner);
        token0.mint(alice, INITIAL_TOKEN_AMOUNT);
        token0.mint(bob, INITIAL_TOKEN_AMOUNT);
        token1.mint(alice, INITIAL_TOKEN_AMOUNT);
        token1.mint(bob, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        Currency currency0 = Currency.wrap(address(token0));
        Currency currency1 = Currency.wrap(address(token1));

        // Create pool key
        testKey = PoolKey({
            currency0: currency0 < currency1 ? currency0 : currency1,
            currency1: currency0 < currency1 ? currency1 : currency0,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pool in PoolManager
        poolManager.initialize(testKey, Constants.SQRT_PRICE_1_1);
        testPoolId = testKey.toId();

        // Initialize pool in Alphix with specified pool type
        vm.prank(owner);
        hook.initializePool(testKey, INITIAL_FEE, INITIAL_TARGET_RATIO, poolType);
    }

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

    function _mintTokensToUser(address user, Currency c0, Currency c1, uint256 amount) internal {
        MockERC20(Currency.unwrap(c0)).mint(user, amount);
        MockERC20(Currency.unwrap(c1)).mint(user, amount);
    }
}
