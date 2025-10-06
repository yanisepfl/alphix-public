// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* OZ IMPORTS */
import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {MockReenteringLogic} from "../../../utils/mocks/MockReenteringLogic.sol";

contract AlphixPoolManagementTest is BaseAlphixTest {
    using StateLibrary for IPoolManager;

    /* TESTS */

    /**
     * @notice initializePool should configure pool and register it.
     */
    function test_initializePool_success() public {
        (PoolKey memory k, PoolId id) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolConfigured(id, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
        hook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(id);
        assertEq(cfg.initialFee, INITIAL_FEE);
        assertEq(cfg.initialTargetRatio, INITIAL_TARGET_RATIO);
        assertEq(uint8(cfg.poolType), uint8(IAlphixLogic.PoolType.STANDARD));
        assertTrue(cfg.isConfigured);

        IRegistry.PoolInfo memory info = registry.getPoolInfo(id);
        assertEq(info.initialFee, INITIAL_FEE);
        assertEq(info.initialTargetRatio, INITIAL_TARGET_RATIO);
        assertTrue(info.timestamp > 0);
    }

    /**
     * @notice initializePool should revert when fee is outside pool-type bounds.
     */
    function test_initializePool_revertsOnInvalidFee() public {
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // STANDARD bounds from Base: min=99, max=10001 -> pick invalids outside
        uint24 invalidLow = 98;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.InvalidFeeForPoolType.selector, IAlphixLogic.PoolType.STANDARD, invalidLow
            )
        );
        hook.initializePool(k, invalidLow, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        uint24 invalidHigh = 10002;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.InvalidFeeForPoolType.selector, IAlphixLogic.PoolType.STANDARD, invalidHigh
            )
        );
        hook.initializePool(k, invalidHigh, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Valid fee
        uint24 validFee = 500;
        vm.prank(owner);
        hook.initializePool(k, validFee, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
        IAlphixLogic.PoolConfig memory cfg = logic.getPoolConfig(k.toId());
        IRegistry.PoolInfo memory info = registry.getPoolInfo(k.toId());
        assertTrue(cfg.isConfigured);
        assertTrue(info.timestamp > 0);
    }

    /**
     * @notice initializePool should revert on zero target ratio.
     */
    function test_initializePool_revertsOnZeroRatio() public {
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, IAlphixLogic.PoolType.STANDARD, 0)
        );
        hook.initializePool(k, INITIAL_FEE, 0, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice initializePool should revert when caller is not owner.
     */
    function test_initializePool_revertsOnNonOwner() public {
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice initializePool should revert while the hook is paused.
     */
    function test_initializePool_revertsWhenPaused() public {
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        hook.pause();
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice initializePool should revert if logic is not set on the hook.
     */
    function test_initializePool_revertsWithoutLogic() public {
        vm.startPrank(owner);
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        vm.stopPrank();

        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(testHook));

        // Reverts because the logic has not been set and of the validLogic modifier during initialize
        vm.expectRevert();
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Reverts because the contract is paused (initialize not called)
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        testHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Manually unpause with owner, but the logic is still not valid (not set).
        testHook.unpause();
        vm.expectRevert(IAlphix.LogicNotSet.selector);
        testHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
        vm.stopPrank();
    }

    /**
     * @notice activatePool should succeed from owner after a deactivate.
     */
    function test_activatePool_success() public {
        (PoolKey memory k, PoolId id) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(owner);
        hook.deactivatePool(k);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolActivated(id);
        hook.activatePool(k);
    }

    /**
     * @notice activatePool should revert for non-owner.
     */
    function test_activatePool_revertsOnNonOwner() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.activatePool(k);
    }

    /**
     * @notice activatePool should revert while paused.
     */
    function test_activatePool_revertsWhenPaused() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(owner);
        hook.pause();
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.activatePool(k);
    }

    /**
     * @notice activatePool should revert when the pool was never configured.
     * @dev Creates a Uniswap pool bound to the hook, but does not call hook.initializePool.
     */
    function test_activatePool_revertsWhenNotConfigured() public {
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.PoolNotConfigured.selector);
        hook.activatePool(k);
    }

    /**
     * @notice deactivatePool should emit and succeed from owner.
     */
    function test_deactivatePool_success() public {
        (PoolKey memory k, PoolId id) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolDeactivated(id);
        hook.deactivatePool(k);
    }

    /**
     * @notice deactivatePool should revert for non-owner.
     */
    function test_deactivatePool_revertsOnNonOwner() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.deactivatePool(k);
    }

    /**
     * @notice deactivatePool should revert while paused.
     */
    function test_deactivatePool_revertsWhenPaused() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(owner);
        hook.pause();
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.deactivatePool(k);
    }

    /**
     * @notice setPoolTypeBounds should update bounds for the given pool type.
     */
    function test_setPoolTypeBounds_success() public {
        // Adapted to PoolTypeParams
        DynamicFeeLib.PoolTypeParams memory newParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1000,
            maxFee: 5000,
            baseMaxFeeDelta: standardParams.baseMaxFeeDelta,
            lookbackPeriod: standardParams.lookbackPeriod,
            minPeriod: standardParams.minPeriod,
            ratioTolerance: standardParams.ratioTolerance,
            linearSlope: standardParams.linearSlope,
            maxCurrentRatio: standardParams.maxCurrentRatio,
            lowerSideFactor: standardParams.lowerSideFactor,
            upperSideFactor: standardParams.upperSideFactor
        });
        vm.prank(owner);
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newParams);
        DynamicFeeLib.PoolTypeParams memory got = hook.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minFee, newParams.minFee);
        assertEq(got.maxFee, newParams.maxFee);
    }

    /**
     * @notice setPoolTypeBounds should revert for non-owner.
     */
    function test_setPoolTypeBounds_revertsOnNonOwner() public {
        DynamicFeeLib.PoolTypeParams memory newParams = DynamicFeeLib.PoolTypeParams({
            minFee: 1000,
            maxFee: 5000,
            baseMaxFeeDelta: standardParams.baseMaxFeeDelta,
            lookbackPeriod: standardParams.lookbackPeriod,
            minPeriod: standardParams.minPeriod,
            ratioTolerance: standardParams.ratioTolerance,
            linearSlope: standardParams.linearSlope,
            maxCurrentRatio: standardParams.maxCurrentRatio,
            lowerSideFactor: standardParams.lowerSideFactor,
            upperSideFactor: standardParams.upperSideFactor
        });
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.setPoolTypeParams(IAlphixLogic.PoolType.STANDARD, newParams);
    }

    /**
     * @notice getPoolBounds should match the configured type bounds.
     */
    function test_getPoolBounds() public {
        (PoolKey memory k, PoolId id) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        DynamicFeeLib.PoolTypeParams memory setParams = hook.getPoolParams(id);
        assertEq(setParams.minFee, standardParams.minFee);
        assertEq(setParams.maxFee, standardParams.maxFee);
        // silence k
        k.fee = k.fee;
    }

    /**
     * @notice getPoolTypeBounds returns the current bounds for a pool type.
     */
    function test_getPoolTypeBounds() public view {
        DynamicFeeLib.PoolTypeParams memory current = hook.getPoolTypeParams(IAlphixLogic.PoolType.STABLE);
        assertEq(current.minFee, stableParams.minFee);
        assertEq(current.maxFee, stableParams.maxFee);
    }

    /**
     * @notice poke should update LP fee when called by owner and emit FeeUpdated; state is verified via StateLibrary.getSlot0.
     */
    function test_poke_success() public {
        (PoolKey memory k, PoolId id) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        // Cooldown enforcement requires minPeriod elapsed (Base uses 1 day)
        vm.warp(block.timestamp + 1 days);

        (,,, uint24 preLpFee) = poolManager.getSlot0(id);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        // Only check the indexed topic (poolId); data unchecked due to algorithmic computation
        emit IAlphix.FeeUpdated(id, 0, 0, 0, 0, 0);
        hook.poke(k, INITIAL_TARGET_RATIO);

        (,,, uint24 postLpFee) = poolManager.getSlot0(id);

        // Verify within STANDARD bounds
        DynamicFeeLib.PoolTypeParams memory pp = hook.getPoolTypeParams(IAlphixLogic.PoolType.STANDARD);
        assertTrue(postLpFee >= pp.minFee && postLpFee <= pp.maxFee);

        // Either updated or remained the same depending on algorithm and inputs; both acceptable within bounds
        preLpFee = preLpFee;
    }

    /**
     * @notice poke should revert when called by non-poker-role.
     */
    function test_poke_revertsOnNonOwner() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        hook.poke(k, INITIAL_TARGET_RATIO);

        vm.prank(address(logic));
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(logic)));
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke can be called by any address with FEE_POKER_ROLE.
     */
    function test_poke_success_withPokerRole() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        // user1 doesn't have FEE_POKER_ROLE, should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        hook.poke(k, INITIAL_TARGET_RATIO);

        // Grant FEE_POKER_ROLE to user1
        vm.prank(owner);
        accessManager.grantRole(FEE_POKER_ROLE, user1, 0);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // Now user1 can call poke
        vm.prank(user1);
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke should fail after FEE_POKER_ROLE is revoked.
     */
    function test_poke_revertsAfterPokerRoleRevoked() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        // Grant FEE_POKER_ROLE to user1
        vm.prank(owner);
        accessManager.grantRole(FEE_POKER_ROLE, user1, 0);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // user1 can call poke
        vm.prank(user1);
        hook.poke(k, INITIAL_TARGET_RATIO);

        // Revoke FEE_POKER_ROLE from user1
        vm.prank(owner);
        accessManager.revokeRole(FEE_POKER_ROLE, user1);

        // Wait for cooldown again
        vm.warp(block.timestamp + 1 days + 1);

        // Now user1 cannot call poke
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke should revert while paused.
     */
    function test_poke_revertsWhenPaused() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke should revert for invalid PoolKey.hooks (onlyValidPools).
     * @dev Uses a PoolKey whose hooks field points to a different hook contract.
     */
    function test_poke_revertsOnInvalidHooks_onlyValidPools() public {
        vm.startPrank(owner);
        Alphix otherHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        (,, IAlphixLogic otherLogic) = _deployAlphixLogic(owner, address(otherHook));
        otherHook.initialize(address(otherLogic));
        vm.stopPrank();

        // Create a pool bound to the otherHook (not the default hook)
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, defaultTickSpacing, IHooks(otherHook));
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Call poke on the default hook with the key attached to another hook
        vm.prank(owner);
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke should not be re-entrant (nonReentrant).
     * @dev Deploys a MockReenteringLogic as the hook owner, advances past cooldown,
     *      then calls poke via the hook. The mock’s getFee will attempt to re-enter poke,
     *      triggering ReentrancyGuard’s reentrant call revert.
     */
    function test_poke_reentrancyGuard_blocksReentry() public {
        // Initialize a pool and allow initial fee update cooldown to expire
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        vm.warp(block.timestamp + 1 days + 1);

        // Deploy the re-entering logic and set it as the hook owner
        MockReenteringLogic reenterLogic = new MockReenteringLogic(address(hook));

        // Grant FEE_POKER_ROLE to reenterLogic so it can call poke
        vm.prank(owner);
        accessManager.grantRole(FEE_POKER_ROLE, address(reenterLogic), 0);

        vm.prank(owner);
        // Transfer hook ownership so getFee->poke happens as owner
        hook.transferOwnership(address(reenterLogic));

        // Mock accepts ownership (complete the 2-step Ownable transfer)
        vm.prank(address(reenterLogic));
        hook.acceptOwnership();

        // Set hook logic to reentering one
        vm.startPrank(address(reenterLogic));
        vm.expectEmit(true, true, false, true);
        emit IAlphix.LogicUpdated(hook.getLogic(), address(reenterLogic));
        hook.setLogic(address(reenterLogic));
        vm.stopPrank();

        // Expect reentrancy guard to block the nested call
        vm.prank(address(reenterLogic));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice Poke should revert when logic is unset.
     * @dev Deploy a fresh hook with no initialize(); Any owner caller attempting hook.poke will fail validLogic in getFee.
     */
    function test_poke_revertsWhenLogicUnset_invalidCaller() public {
        vm.startPrank(owner);
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        vm.stopPrank();

        // Create a Uniswap pool bound to testHook
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(testHook));

        // initialize reverts due to validLogic in beforeInitialize
        vm.expectRevert();
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Paused by default; unpause to hit LogicNotSet in getFee path
        vm.startPrank(owner);
        testHook.unpause();
        vm.expectRevert(IAlphix.LogicNotSet.selector);
        testHook.poke(k, INITIAL_TARGET_RATIO);
        vm.stopPrank();

        // Any non-poker-role caller reverts with AccessManaged
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        testHook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice Poke should revert if currentRatio is zero.
     */
    function test_poke_revertsOnZeroRatio() public {
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        // Advance time past cooldown period
        vm.warp(block.timestamp + 2 days);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAlphixLogic.InvalidRatioForPoolType.selector, IAlphixLogic.PoolType.STANDARD, 0)
        );
        hook.poke(k, 0);
    }

    /**
     * @notice Poke should revert if cooldown not elapsed since last fee update.
     */
    function test_poke_revertsOnCooldownNotElapsed() public {
        uint256 currentTimestamp = block.timestamp;
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        // Immediately poking should hit logic cooldown check
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.CooldownNotElapsed.selector, k.toId(), currentTimestamp + 1 days, 1 days
            )
        );
        hook.poke(k, INITIAL_TARGET_RATIO);
    }

    /**
     * @notice setGlobalMaxAdjRate should update the global max adjustment rate.
     */
    function test_setGlobalMaxAdjRate_success() public {
        uint256 newRate = 2e18; // within allowed bounds per logic
        vm.prank(owner);
        hook.setGlobalMaxAdjRate(newRate);
        assertEq(logic.getGlobalMaxAdjRate(), newRate);
    }

    /**
     * @notice Test setGlobalMaxAdjRate reverts when rate is zero
     */
    function test_setGlobalMaxAdjRate_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        hook.setGlobalMaxAdjRate(0);
    }

    /**
     * @notice Test setGlobalMaxAdjRate reverts when rate exceeds maximum
     */
    function test_setGlobalMaxAdjRate_revertsOnTooHigh() public {
        uint256 tooHigh = AlphixGlobalConstants.MAX_ADJUSTMENT_RATE + 1;
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        hook.setGlobalMaxAdjRate(tooHigh);
    }

    /**
     * @notice getFee should return the fee stored in PoolManager slot0.
     */
    function test_getFee_view() public {
        (PoolKey memory k, PoolId id) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        (,,, uint24 feeFromSlot) = poolManager.getSlot0(id);
        uint24 feeFromView = hook.getFee(k);
        assertEq(feeFromView, feeFromSlot);
    }

    /* HELPERS */

    /**
     * @notice Create a fresh Uniswap pool bound to the current hook without configuring Alphix.
     */
    function _newUninitializedPool(uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        return _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, hook);
    }

    /**
     * @notice Create and initialize a pool in Alphix with given params.
     */
    function _initPool(
        IAlphixLogic.PoolType ptype,
        uint24 fee,
        uint256 ratio,
        uint8 d0,
        uint8 d1,
        int24 spacing,
        uint160 initialPrice
    ) internal returns (PoolKey memory k, PoolId id) {
        return _initPoolWithHook(ptype, fee, ratio, d0, d1, spacing, initialPrice, hook);
    }
}
