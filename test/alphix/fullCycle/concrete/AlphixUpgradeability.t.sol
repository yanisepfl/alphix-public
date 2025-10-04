// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test, console} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";
import {MockAlphixLogic} from "../../../utils/mocks/MockAlphixLogic.sol";

/**
 * @title AlphixUpgradeabilityTest
 * @author Alphix
 * @notice Comprehensive upgradeability tests for the Alphix protocol
 * @dev Tests UUPS upgrade patterns, state preservation, and upgrade scenarios
 */
contract AlphixUpgradeabilityTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    // Events to test
    event Upgraded(address indexed implementation);

    /* ========================================================================== */
    /*                           BASIC UPGRADE SCENARIOS                          */
    /* ========================================================================== */

    /**
     * @notice Test basic upgrade flow: deploy new implementation and upgrade (STABLE pool)
     * @dev Verifies proxy upgrade mechanism works correctly
     */
    function test_basic_upgrade_to_new_implementation() public {
        // Record state before upgrade
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig(poolId);
        address logicAddressBefore = hook.getLogic();

        // Deploy new implementation
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();

        // Upgrade through proxy
        bytes memory emptyData = "";
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), emptyData);
        vm.stopPrank();

        // Verify upgrade
        address logicAddressAfter = hook.getLogic();
        assertEq(logicAddressBefore, logicAddressAfter, "Hook should still point to same proxy");

        // Verify state preserved
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig(poolId);
        assertEq(configAfter.initialFee, configBefore.initialFee, "Initial fee should be preserved");
        assertEq(configAfter.initialTargetRatio, configBefore.initialTargetRatio, "Target ratio should be preserved");
        assertEq(uint8(configAfter.poolType), uint8(configBefore.poolType), "Pool type should be preserved");
        assertTrue(configAfter.isConfigured, "Pool should remain configured");
    }

    /**
     * @notice Test basic upgrade flow: deploy new implementation and upgrade (STANDARD pool)
     * @dev Verifies proxy upgrade mechanism works correctly
     */
    function test_basic_upgrade_to_new_implementation_standard() public {
        (, PoolId testPoolId) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        // Record state before upgrade
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig(testPoolId);
        address logicAddressBefore = hook.getLogic();

        // Deploy new implementation
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();

        // Upgrade through proxy
        bytes memory emptyData = "";
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), emptyData);
        vm.stopPrank();

        // Verify upgrade
        address logicAddressAfter = hook.getLogic();
        assertEq(logicAddressBefore, logicAddressAfter, "Hook should still point to same proxy");

        // Verify state preserved
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig(testPoolId);
        assertEq(configAfter.initialFee, configBefore.initialFee, "Initial fee should be preserved");
        assertEq(configAfter.initialTargetRatio, configBefore.initialTargetRatio, "Target ratio should be preserved");
        assertEq(uint8(configAfter.poolType), uint8(configBefore.poolType), "Pool type should be preserved");
        assertTrue(configAfter.isConfigured, "Pool should remain configured");
    }

    /**
     * @notice Test basic upgrade flow: deploy new implementation and upgrade (VOLATILE pool)
     * @dev Verifies proxy upgrade mechanism works correctly
     */
    function test_basic_upgrade_to_new_implementation_volatile() public {
        (, PoolId testPoolId) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        // Record state before upgrade
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig(testPoolId);
        address logicAddressBefore = hook.getLogic();

        // Deploy new implementation
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();

        // Upgrade through proxy
        bytes memory emptyData = "";
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), emptyData);
        vm.stopPrank();

        // Verify upgrade
        address logicAddressAfter = hook.getLogic();
        assertEq(logicAddressBefore, logicAddressAfter, "Hook should still point to same proxy");

        // Verify state preserved
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig(testPoolId);
        assertEq(configAfter.initialFee, configBefore.initialFee, "Initial fee should be preserved");
        assertEq(configAfter.initialTargetRatio, configBefore.initialTargetRatio, "Target ratio should be preserved");
        assertEq(uint8(configAfter.poolType), uint8(configBefore.poolType), "Pool type should be preserved");
        assertTrue(configAfter.isConfigured, "Pool should remain configured");
    }

    /**
     * @notice Test upgrade with initialization data
     * @dev Verifies upgradeToAndCall with initialization logic using MockAlphixLogic
     */
    function test_upgrade_with_initialization_data() public {
        // Deploy new mock implementation with a reinitializer
        MockAlphixLogic mockImplementation = new MockAlphixLogic();

        // Prepare initialization data for initializeV2(uint24 _mockFee)
        uint24 mockFeeValue = 1234; // Arbitrary fee value for testing
        bytes memory initData = abi.encodeWithSignature("initializeV2(uint24)", mockFeeValue);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false, address(logicProxy));
        emit Upgraded(address(mockImplementation));
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(mockImplementation), initData);

        // Verify upgrade successful - if initData was processed without reverting, initialization worked
        // (MockAlphixLogic.mockFee is private, so we verify through successful execution)

        // Verify original pool config was preserved
        IAlphixLogic.PoolConfig memory config = IAlphixLogic(address(logicProxy)).getPoolConfig(poolId);
        assertTrue(config.isConfigured, "Pool should remain configured after upgrade");
    }

    /**
     * @notice Test that unauthorized users cannot upgrade
     * @dev Security test for upgrade authorization
     */
    function test_upgrade_reverts_for_unauthorized() public {
        AlphixLogic newLogicImplementation = new AlphixLogic();

        vm.prank(unauthorized);
        vm.expectRevert();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
    }

    /**
     * @notice Test upgrade rejects invalid implementation (missing interface)
     * @dev Verifies _authorizeUpgrade validation
     */
    function test_upgrade_rejects_invalid_implementation() public {
        // Deploy a contract that doesn't implement IAlphixLogic
        InvalidLogicImplementation invalidImpl = new InvalidLogicImplementation();

        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidLogicContract.selector);
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(invalidImpl), "");
    }

    /* ========================================================================== */
    /*                      STATE PRESERVATION SCENARIOS                          */
    /* ========================================================================== */

    /**
     * @notice Test pool configuration preservation across upgrade
     * @dev Ensures all pool configs remain intact after upgrade
     */
    function test_upgrade_preserves_pool_configurations() public {
        // Create multiple pools with different configurations
        (PoolKey memory pool1,) =
            _initPoolWithHook(IAlphixLogic.PoolType.STABLE, 300, 4e17, 18, 18, 10, Constants.SQRT_PRICE_1_1, hook);

        (PoolKey memory pool2,) =
            _initPoolWithHook(IAlphixLogic.PoolType.VOLATILE, 3000, 8e17, 6, 6, 60, Constants.SQRT_PRICE_1_1, hook);

        // Store configurations
        PoolId pool1Id = pool1.toId();
        PoolId pool2Id = pool2.toId();

        IAlphixLogic.PoolConfig memory config1Before = logic.getPoolConfig(pool1Id);
        IAlphixLogic.PoolConfig memory config2Before = logic.getPoolConfig(pool2Id);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify all configs preserved
        IAlphixLogic.PoolConfig memory config1After = logic.getPoolConfig(pool1Id);
        IAlphixLogic.PoolConfig memory config2After = logic.getPoolConfig(pool2Id);

        assertEq(config1After.initialFee, config1Before.initialFee, "Pool1 fee preserved");
        assertEq(config1After.initialTargetRatio, config1Before.initialTargetRatio, "Pool1 ratio preserved");
        assertEq(uint8(config1After.poolType), uint8(config1Before.poolType), "Pool1 type preserved");

        assertEq(config2After.initialFee, config2Before.initialFee, "Pool2 fee preserved");
        assertEq(config2After.initialTargetRatio, config2Before.initialTargetRatio, "Pool2 ratio preserved");
        assertEq(uint8(config2After.poolType), uint8(config2Before.poolType), "Pool2 type preserved");
    }

    /**
     * @notice Test pool type parameters preservation across upgrade
     * @dev Ensures custom parameter sets are preserved
     */
    function test_upgrade_preserves_pool_type_parameters() public {
        // Get current params and modify slightly
        DynamicFeeLib.PoolTypeParams memory customParams = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        customParams.minFee = 200;
        customParams.maxFee = 4000;

        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, customParams);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify parameters preserved
        DynamicFeeLib.PoolTypeParams memory paramsAfter = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);

        assertEq(paramsAfter.minFee, customParams.minFee, "minFee preserved");
        assertEq(paramsAfter.maxFee, customParams.maxFee, "maxFee preserved");
        assertEq(paramsAfter.baseMaxFeeDelta, customParams.baseMaxFeeDelta, "baseMaxFeeDelta preserved");
        assertEq(paramsAfter.lookbackPeriod, customParams.lookbackPeriod, "lookbackPeriod preserved");
        assertEq(paramsAfter.minPeriod, customParams.minPeriod, "minPeriod preserved");
        assertEq(paramsAfter.ratioTolerance, customParams.ratioTolerance, "ratioTolerance preserved");
        assertEq(paramsAfter.linearSlope, customParams.linearSlope, "linearSlope preserved");
        assertEq(paramsAfter.maxCurrentRatio, customParams.maxCurrentRatio, "maxCurrentRatio preserved");
        assertEq(paramsAfter.lowerSideFactor, customParams.lowerSideFactor, "lowerSideFactor preserved");
        assertEq(paramsAfter.upperSideFactor, customParams.upperSideFactor, "upperSideFactor preserved");
    }

    /**
     * @notice Test that fee state is maintained through upgrade
     * @dev Verifies dynamic fee calculation continues after upgrade
     */
    function test_upgrade_maintains_fee_state() public {
        // Trigger fee update before upgrade
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(key, 7e17); // Set ratio

        uint24 feeBefore;
        (,,, feeBefore) = poolManager.getSlot0(poolId);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify fee preserved
        uint24 feeAfter;
        (,,, feeAfter) = poolManager.getSlot0(poolId);
        assertEq(feeAfter, feeBefore, "Fee should be preserved through upgrade");
    }

    /* ========================================================================== */
    /*                     FUNCTIONAL TESTING POST-UPGRADE                        */
    /* ========================================================================== */

    /**
     * @notice Test pool operations work correctly after upgrade (STABLE pool)
     * @dev Ensures upgraded logic handles hook callbacks properly
     */
    function test_pool_operations_work_after_upgrade() public {
        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Test liquidity operations
        vm.startPrank(user1);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 50e18;

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amt1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amt0 + 1), expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amt1 + 1), expiry);

        (uint256 newTokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amt0 + 1,
            amt1 + 1,
            user1,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        assertGt(newTokenId, 0, "Liquidity should be added successfully after upgrade");

        // Test swap operations
        vm.startPrank(user2);
        uint256 swapAmount = 10e18;
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);

        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: user2,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertNotEq(delta.amount0(), 0, "Swap should work after upgrade");
    }

    /**
     * @notice Test pool operations work correctly after upgrade (STANDARD pool)
     * @dev Ensures upgraded logic handles hook callbacks properly
     */
    function test_pool_operations_work_after_upgrade_standard() public {
        (PoolKey memory testKey,) = _createPoolWithType(IAlphixLogic.PoolType.STANDARD);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        _testPoolOperationsAfterUpgrade(testKey);
    }

    /**
     * @notice Test pool operations work correctly after upgrade (VOLATILE pool)
     * @dev Ensures upgraded logic handles hook callbacks properly
     */
    function test_pool_operations_work_after_upgrade_volatile() public {
        (PoolKey memory testKey,) = _createPoolWithType(IAlphixLogic.PoolType.VOLATILE);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        _testPoolOperationsAfterUpgrade(testKey);
    }

    /**
     * @notice Test fee poke functionality after upgrade
     * @dev Ensures dynamic fee adjustment continues to work
     */
    function test_fee_poke_works_after_upgrade() public {
        // Get initial fee
        uint24 feeBefore;
        (,,, feeBefore) = poolManager.getSlot0(poolId);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");

        // Poke with new ratio
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params.minPeriod + 1);

        hook.poke(key, 7e17); // 70% ratio
        vm.stopPrank();

        uint24 feeAfter;
        (,,, feeAfter) = poolManager.getSlot0(poolId);

        // Fee should have changed based on ratio
        assertGt(feeAfter, 0, "Fee should be set after poke");
    }

    /**
     * @notice Test new pool initialization after upgrade
     * @dev Ensures upgraded logic can configure new pools
     */
    function test_new_pool_initialization_after_upgrade() public {
        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Create and initialize new pool
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory newKey = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        PoolId newPoolId = newKey.toId();

        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        vm.prank(owner);
        hook.initializePool(newKey, 1000, 5e17, IAlphixLogic.PoolType.VOLATILE);

        // Verify pool configured
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(newPoolId);
        assertTrue(config.isConfigured, "New pool should be configured after upgrade");
        assertEq(config.initialFee, 1000, "Fee should be set correctly");
        assertEq(config.initialTargetRatio, 5e17, "Ratio should be set correctly");
        assertEq(uint8(config.poolType), uint8(IAlphixLogic.PoolType.VOLATILE), "Pool type should be set correctly");
    }

    /* ========================================================================== */
    /*                        UPGRADE EDGE CASES                                  */
    /* ========================================================================== */

    /**
     * @notice Test multiple sequential upgrades
     * @dev Ensures protocol can be upgraded multiple times
     */
    function test_multiple_sequential_upgrades() public {
        // First upgrade
        vm.startPrank(owner);
        AlphixLogic newLogic1 = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogic1), "");

        // Second upgrade
        AlphixLogic newLogic2 = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogic2), "");

        // Third upgrade
        AlphixLogic newLogic3 = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogic3), "");
        vm.stopPrank();

        // Verify state still preserved
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        assertTrue(config.isConfigured, "Pool should remain configured after multiple upgrades");
    }

    /**
     * @notice Test upgrade during active pool operations
     * @dev Simulates upgrade while pool has liquidity and activity
     */
    function test_upgrade_with_active_pool_state() public {
        // Add significant liquidity
        vm.startPrank(user1);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 200e18;

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amt1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amt0 + 1), expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amt1 + 1), expiry);

        positionManager.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amt0 + 1,
            amt1 + 1,
            user1,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        // Perform some swaps
        vm.startPrank(user2);
        uint256 swapAmount = 50e18;
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: user2,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Update fee
        DynamicFeeLib.PoolTypeParams memory params = logic.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(key, 6e17);

        // Now upgrade with all this state
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify everything still works
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        assertTrue(config.isConfigured, "Pool should remain configured");

        // Can still perform operations
        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount);
        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: user2,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertNotEq(delta.amount1(), 0, "Operations should work after upgrade with active state");
    }

    /**
     * @notice Test that upgrades respect access control
     * @dev Ensures only authorized addresses can perform upgrades
     */
    function test_upgrade_access_control_enforced() public {
        // Authorized owner can upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify upgrade succeeded
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig(poolId);
        assertTrue(config.isConfigured, "Pool should remain configured after authorized upgrade");

        // Unauthorized user cannot upgrade
        vm.startPrank(unauthorized);
        AlphixLogic anotherLogic = new AlphixLogic();
        vm.expectRevert();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(anotherLogic), "");
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    /**
     * @notice Helper to test pool operations after upgrade
     */
    function _testPoolOperationsAfterUpgrade(PoolKey memory testKey) internal {
        // Test liquidity operations
        vm.startPrank(user1);
        int24 tickLower = TickMath.minUsableTick(testKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(testKey.tickSpacing);
        uint128 liquidityAmount = 50e18;

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(testKey.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(testKey.currency1)).approve(address(permit2), amt1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(testKey.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        permit2.approve(Currency.unwrap(testKey.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        (uint256 newTokenId,) = positionManager.mint(
            testKey,
            tickLower,
            tickUpper,
            liquidityAmount,
            amt0 + 1,
            amt1 + 1,
            user1,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();

        assertGt(newTokenId, 0, "Liquidity should be added successfully after upgrade");

        // Test swap operations
        _performSimpleSwap(user2, testKey, 10e18);
    }

    /**
     * @notice Helper to perform a simple swap test
     */
    function _performSimpleSwap(address trader, PoolKey memory poolKey, uint256 swapAmount) internal {
        vm.startPrank(trader);
        MockERC20(Currency.unwrap(poolKey.currency0)).approve(address(swapRouter), swapAmount);

        BalanceDelta delta = swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: trader,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        assertNotEq(delta.amount0(), 0, "Swap should work after upgrade");
    }

    /**
     * @notice Helper to create a pool with a specific pool type
     * @param poolType The pool type to create
     * @return testKey The pool key
     * @return testPoolId The pool ID
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
        token0.mint(user1, INITIAL_TOKEN_AMOUNT);
        token0.mint(user2, INITIAL_TOKEN_AMOUNT);
        token1.mint(user1, INITIAL_TOKEN_AMOUNT);
        token1.mint(user2, INITIAL_TOKEN_AMOUNT);
        vm.stopPrank();

        Currency testCurrency0 = Currency.wrap(address(token0));
        Currency testCurrency1 = Currency.wrap(address(token1));

        // Create pool key
        testKey = PoolKey({
            currency0: testCurrency0 < testCurrency1 ? testCurrency0 : testCurrency1,
            currency1: testCurrency0 < testCurrency1 ? testCurrency1 : testCurrency0,
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
}

/**
 * @title InvalidLogicImplementation
 * @notice Mock contract for testing invalid upgrade
 * @dev Does not implement IAlphixLogic interface
 */
contract InvalidLogicImplementation is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}

    function supportsInterface(bytes4) public pure returns (bool) {
        return false;
    }
}
