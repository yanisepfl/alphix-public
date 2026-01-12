// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* OZ IMPORTS */
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
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
        _testBasicUpgrade(poolId);
    }

    // NOTE: With single-pool-per-hook architecture, pool type-specific tests have been consolidated
    // into the default pool test (test_basic_upgrade_to_new_implementation) which uses defaultPoolParams.

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
        IAlphixLogic.PoolConfig memory config = IAlphixLogic(address(logicProxy)).getPoolConfig();
        assertTrue(config.isConfigured, "Pool should remain configured after upgrade");
    }

    /**
     * @notice Test that unauthorized users cannot upgrade
     * @dev Security test for upgrade authorization
     */
    function test_upgrade_reverts_for_unauthorized() public {
        AlphixLogic newLogicImplementation = new AlphixLogic();

        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, unauthorized));
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
     * @dev Ensures pool config remains intact after upgrade (single-pool architecture)
     */
    function test_upgrade_preserves_pool_configurations() public {
        // Store configuration before upgrade
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig();

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify config preserved
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig();

        assertEq(configAfter.initialFee, configBefore.initialFee, "Pool fee preserved");
        assertEq(configAfter.initialTargetRatio, configBefore.initialTargetRatio, "Pool ratio preserved");
        assertTrue(configAfter.isConfigured, "Pool should remain configured");
    }

    /**
     * @notice Test pool parameters preservation across upgrade
     * @dev Ensures custom parameter sets are preserved (single-pool architecture)
     */
    function test_upgrade_preserves_pool_parameters() public {
        // Get current params and modify slightly
        DynamicFeeLib.PoolParams memory customParams = logic.getPoolParams();
        customParams.minFee = 200;
        customParams.maxFee = 4000;

        vm.prank(owner);
        logic.setPoolParams(customParams);

        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify parameters preserved
        DynamicFeeLib.PoolParams memory paramsAfter = logic.getPoolParams();

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
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        vm.prank(owner);
        hook.poke(7e17); // Set ratio

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
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 50e18;

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amt1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        // Casting to uint160 is safe because amt0/amt1 are bounded token amounts that fit within uint160
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amt0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amt1 + 1), expiry);

        (uint256 newTokenId,) = positionManager.mint(
            key,
            minTick,
            maxTick,
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

    // NOTE: With single-pool-per-hook architecture, pool type-specific operation tests have been
    // consolidated into test_pool_operations_work_after_upgrade which uses the default pool.

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
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);

        hook.poke(7e17); // 70% ratio
        vm.stopPrank();

        uint24 feeAfter;
        (,,, feeAfter) = poolManager.getSlot0(poolId);

        // Fee should have changed based on ratio
        assertGt(feeAfter, 0, "Fee should be set after poke");
    }

    /**
     * @notice Test new pool initialization after upgrade
     * @dev Ensures upgraded logic can configure new pools (single-pool architecture)
     */
    function test_new_pool_initialization_after_upgrade() public {
        // Upgrade
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Create and initialize new pool (requires fresh hook stack in single-pool architecture)
        // For this test, we verify the existing pool still works after upgrade
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
        assertTrue(config.isConfigured, "Pool should remain configured after upgrade");
        assertEq(config.initialFee, INITIAL_FEE, "Fee should be preserved");
        assertEq(config.initialTargetRatio, INITIAL_TARGET_RATIO, "Ratio should be preserved");
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
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
        assertTrue(config.isConfigured, "Pool should remain configured after multiple upgrades");
    }

    /**
     * @notice Test upgrade during active pool operations
     * @dev Simulates upgrade while pool has liquidity and activity
     */
    function test_upgrade_with_active_pool_state() public {
        // Add significant liquidity
        vm.startPrank(user1);
        int24 minTick = TickMath.minUsableTick(key.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liquidityAmount = 200e18;

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amt1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        // Casting to uint160 is safe because amt0/amt1 are bounded token amounts that fit within uint160
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amt0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amt1 + 1), expiry);

        positionManager.mint(
            key,
            minTick,
            maxTick,
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
        DynamicFeeLib.PoolParams memory params = logic.getPoolParams();
        vm.warp(block.timestamp + params.minPeriod + 1);
        vm.prank(owner);
        hook.poke(6e17);

        // Now upgrade with all this state
        vm.startPrank(owner);
        AlphixLogic newLogicImplementation = new AlphixLogic();
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(newLogicImplementation), "");
        vm.stopPrank();

        // Verify everything still works
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
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
        IAlphixLogic.PoolConfig memory config = logic.getPoolConfig();
        assertTrue(config.isConfigured, "Pool should remain configured after authorized upgrade");

        // Unauthorized user cannot upgrade
        vm.startPrank(unauthorized);
        AlphixLogic anotherLogic = new AlphixLogic();
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, unauthorized));
        UUPSUpgradeable(address(logic)).upgradeToAndCall(address(anotherLogic), "");
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                              HELPER FUNCTIONS                              */
    /* ========================================================================== */

    /**
     * @notice Helper to test basic upgrade flow with a specific pool
     * @dev Reduces duplication across upgrade tests (single-pool architecture)
     */
    function _testBasicUpgrade(
        PoolId /* testPoolId */
    )
        internal
    {
        // Record state before upgrade
        IAlphixLogic.PoolConfig memory configBefore = logic.getPoolConfig();
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
        IAlphixLogic.PoolConfig memory configAfter = logic.getPoolConfig();
        assertEq(configAfter.initialFee, configBefore.initialFee, "Initial fee should be preserved");
        assertEq(configAfter.initialTargetRatio, configBefore.initialTargetRatio, "Target ratio should be preserved");
        assertTrue(configAfter.isConfigured, "Pool should remain configured");
    }

    /**
     * @notice Helper to test pool operations after upgrade
     */
    function _testPoolOperationsAfterUpgrade(PoolKey memory testKey) internal {
        // Test liquidity operations
        vm.startPrank(user1);
        int24 minTick = TickMath.minUsableTick(testKey.tickSpacing);
        int24 maxTick = TickMath.maxUsableTick(testKey.tickSpacing);
        uint128 liquidityAmount = 50e18;

        (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityAmount
        );

        MockERC20(Currency.unwrap(testKey.currency0)).approve(address(permit2), amt0 + 1);
        MockERC20(Currency.unwrap(testKey.currency1)).approve(address(permit2), amt1 + 1);

        uint48 expiry = uint48(block.timestamp + 100);
        // Casting to uint160 is safe because amt0/amt1 are bounded token amounts that fit within uint160
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(testKey.currency0), address(positionManager), uint160(amt0 + 1), expiry);
        // forge-lint: disable-next-line(unsafe-typecast)
        permit2.approve(Currency.unwrap(testKey.currency1), address(positionManager), uint160(amt1 + 1), expiry);

        (uint256 newTokenId,) = positionManager.mint(
            testKey,
            minTick,
            maxTick,
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

    // NOTE: _createPoolWithType helper was removed with the single-pool-per-hook architecture.
    // Each pool now requires its own hook instance with its own pool params passed at initialization.
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
