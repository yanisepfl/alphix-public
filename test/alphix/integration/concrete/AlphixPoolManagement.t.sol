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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";
import {Registry} from "../../../../src/Registry.sol";
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
        (PoolKey memory k, PoolId id, Alphix freshHook, IAlphixLogic freshLogic,, Registry freshReg) =
            _newUninitializedPoolFreshFull(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolConfigured(id, INITIAL_FEE, INITIAL_TARGET_RATIO);
        freshHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        IAlphixLogic.PoolConfig memory cfg = freshLogic.getPoolConfig();
        assertEq(cfg.initialFee, INITIAL_FEE);
        assertEq(cfg.initialTargetRatio, INITIAL_TARGET_RATIO);
        assertTrue(cfg.isConfigured);

        IRegistry.PoolInfo memory info = freshReg.getPoolInfo(id);
        assertEq(info.initialFee, INITIAL_FEE);
        assertEq(info.initialTargetRatio, INITIAL_TARGET_RATIO);
        assertTrue(info.timestamp > 0);
    }

    /**
     * @notice initializePool should revert when fee is outside pool params bounds.
     */
    function test_initializePool_revertsOnInvalidFee() public {
        (PoolKey memory k,, Alphix freshHook, IAlphixLogic freshLogic,, Registry freshReg) =
            _newUninitializedPoolFreshFull(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // defaultPoolParams bounds: min=1, max=100001 -> pick invalids outside
        uint24 invalidLow = 0;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFee.selector, invalidLow));
        freshHook.initializePool(k, invalidLow, INITIAL_TARGET_RATIO, defaultPoolParams);

        uint24 invalidHigh = 100002;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidFee.selector, invalidHigh));
        freshHook.initializePool(k, invalidHigh, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Valid fee
        uint24 validFee = 500;
        vm.prank(owner);
        freshHook.initializePool(k, validFee, INITIAL_TARGET_RATIO, defaultPoolParams);
        IAlphixLogic.PoolConfig memory cfg = freshLogic.getPoolConfig();
        IRegistry.PoolInfo memory info = freshReg.getPoolInfo(k.toId());
        assertTrue(cfg.isConfigured);
        assertTrue(info.timestamp > 0);
    }

    /**
     * @notice initializePool should revert on zero target ratio.
     */
    function test_initializePool_revertsOnZeroRatio() public {
        (PoolKey memory k,, Alphix freshHook,) =
            _newUninitializedPoolFresh(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidRatio.selector, 0));
        freshHook.initializePool(k, INITIAL_FEE, 0, defaultPoolParams);
    }

    /**
     * @notice initializePool should revert when caller is not owner.
     */
    function test_initializePool_revertsOnNonOwner() public {
        (PoolKey memory k,, Alphix freshHook,) =
            _newUninitializedPoolFresh(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        freshHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice initializePool should revert while the hook is paused.
     */
    function test_initializePool_revertsWhenPaused() public {
        (PoolKey memory k,, Alphix freshHook,) =
            _newUninitializedPoolFresh(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        freshHook.pause();
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
    }

    /**
     * @notice initializePool should revert if logic is not set on the hook.
     */
    function test_initializePool_revertsWithoutLogic() public {
        vm.startPrank(owner);
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        vm.stopPrank();

        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        // forge-lint: disable-next-line(named-struct-fields)
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(testHook));

        // Reverts because the logic has not been set and of the validLogic modifier during initialize
        vm.expectRevert();
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Reverts because the contract is paused (initialize not called)
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        testHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);

        // Manually unpause with owner, but the logic is still not valid (not set).
        testHook.unpause();
        vm.expectRevert(IAlphix.LogicNotSet.selector);
        testHook.initializePool(k, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();
    }

    /**
     * @notice activatePool should succeed from owner after a deactivate.
     */
    function test_activatePool_success() public {
        (, PoolId id, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        freshHook.deactivatePool();
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolActivated(id);
        freshHook.activatePool();
    }

    /**
     * @notice activatePool should revert for non-owner.
     */
    function test_activatePool_revertsOnNonOwner() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        freshHook.activatePool();
    }

    /**
     * @notice activatePool should revert while paused.
     */
    function test_activatePool_revertsWhenPaused() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        freshHook.pause();
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.activatePool();
    }

    /**
     * @notice activatePool should revert when the pool was never configured.
     * @dev Creates a Uniswap pool bound to the hook, but does not call hook.initializePool.
     */
    function test_activatePool_revertsWhenNotConfigured() public {
        (,, Alphix freshHook,) = _newUninitializedPoolFresh(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.PoolNotConfigured.selector);
        freshHook.activatePool();
    }

    /**
     * @notice deactivatePool should emit and succeed from owner.
     */
    function test_deactivatePool_success() public {
        (, PoolId id, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAlphix.PoolDeactivated(id);
        freshHook.deactivatePool();
    }

    /**
     * @notice deactivatePool should revert for non-owner.
     */
    function test_deactivatePool_revertsOnNonOwner() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        freshHook.deactivatePool();
    }

    /**
     * @notice deactivatePool should revert while paused.
     */
    function test_deactivatePool_revertsWhenPaused() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        freshHook.pause();
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.deactivatePool();
    }

    /**
     * @notice setPoolParams should update bounds for the pool.
     */
    function test_setPoolParams_success() public {
        DynamicFeeLib.PoolParams memory newParams = DynamicFeeLib.PoolParams({
            minFee: 1000,
            maxFee: 5000,
            baseMaxFeeDelta: defaultPoolParams.baseMaxFeeDelta,
            lookbackPeriod: defaultPoolParams.lookbackPeriod,
            minPeriod: defaultPoolParams.minPeriod,
            ratioTolerance: defaultPoolParams.ratioTolerance,
            linearSlope: defaultPoolParams.linearSlope,
            maxCurrentRatio: defaultPoolParams.maxCurrentRatio,
            lowerSideFactor: defaultPoolParams.lowerSideFactor,
            upperSideFactor: defaultPoolParams.upperSideFactor
        });
        vm.prank(owner);
        logic.setPoolParams(newParams);
        DynamicFeeLib.PoolParams memory got = logic.getPoolParams();
        assertEq(got.minFee, newParams.minFee);
        assertEq(got.maxFee, newParams.maxFee);
    }

    /**
     * @notice setPoolParams should revert for non-owner.
     */
    function test_setPoolParams_revertsOnNonOwner() public {
        DynamicFeeLib.PoolParams memory newParams = DynamicFeeLib.PoolParams({
            minFee: 1000,
            maxFee: 5000,
            baseMaxFeeDelta: defaultPoolParams.baseMaxFeeDelta,
            lookbackPeriod: defaultPoolParams.lookbackPeriod,
            minPeriod: defaultPoolParams.minPeriod,
            ratioTolerance: defaultPoolParams.ratioTolerance,
            linearSlope: defaultPoolParams.linearSlope,
            maxCurrentRatio: defaultPoolParams.maxCurrentRatio,
            lowerSideFactor: defaultPoolParams.lowerSideFactor,
            upperSideFactor: defaultPoolParams.upperSideFactor
        });
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        logic.setPoolParams(newParams);
    }

    /**
     * @notice getPoolParams should match the configured bounds.
     */
    function test_getPoolParams() public {
        // Use a fresh pool with fresh logic
        (,,, IAlphixLogic freshLogic) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        DynamicFeeLib.PoolParams memory setParams = freshLogic.getPoolParams();
        assertEq(setParams.minFee, defaultPoolParams.minFee);
        assertEq(setParams.maxFee, defaultPoolParams.maxFee);
    }

    /**
     * @notice getPoolParams returns the current bounds for the pool.
     */
    function test_getPoolParams_view() public view {
        DynamicFeeLib.PoolParams memory current = logic.getPoolParams();
        assertEq(current.minFee, defaultPoolParams.minFee);
        assertEq(current.maxFee, defaultPoolParams.maxFee);
    }

    /**
     * @notice poke should update LP fee when called by owner and emit FeeUpdated; state is verified via StateLibrary.getSlot0.
     */
    function test_poke_success() public {
        (, PoolId id, Alphix freshHook, IAlphixLogic freshLogic) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // Cooldown enforcement requires minPeriod elapsed (Base uses 1 day)
        vm.warp(block.timestamp + 1 days);

        (,,, uint24 preLpFee) = poolManager.getSlot0(id);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        // Only check the indexed topic (poolId); data unchecked due to algorithmic computation
        emit IAlphix.FeeUpdated(id, 0, 0, 0, 0, 0);
        freshHook.poke(INITIAL_TARGET_RATIO);

        (,,, uint24 postLpFee) = poolManager.getSlot0(id);

        // Verify within bounds
        DynamicFeeLib.PoolParams memory pp = freshLogic.getPoolParams();
        assertTrue(postLpFee >= pp.minFee && postLpFee <= pp.maxFee);

        // Either updated or remained the same depending on algorithm and inputs; both acceptable within bounds
        preLpFee = preLpFee;
    }

    /**
     * @notice poke should revert when called by non-poker-role.
     */
    function test_poke_revertsOnNonOwner() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        freshHook.poke(INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke can be called by any address with FEE_POKER_ROLE.
     */
    function test_poke_success_withPokerRole() public {
        (,, Alphix freshHook,, AccessManager freshAm,) =
            _initPoolFreshFull(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // user1 doesn't have FEE_POKER_ROLE, should fail
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        freshHook.poke(INITIAL_TARGET_RATIO);

        // Grant FEE_POKER_ROLE to user1
        vm.prank(owner);
        freshAm.grantRole(FEE_POKER_ROLE, user1, 0);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // Now user1 can call poke
        vm.prank(user1);
        freshHook.poke(INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke should fail after FEE_POKER_ROLE is revoked.
     */
    function test_poke_revertsAfterPokerRoleRevoked() public {
        (,, Alphix freshHook,, AccessManager freshAm,) =
            _initPoolFreshFull(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // Grant FEE_POKER_ROLE to user1
        vm.prank(owner);
        freshAm.grantRole(FEE_POKER_ROLE, user1, 0);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        // user1 can call poke
        vm.prank(user1);
        freshHook.poke(INITIAL_TARGET_RATIO);

        // Revoke FEE_POKER_ROLE from user1
        vm.prank(owner);
        freshAm.revokeRole(FEE_POKER_ROLE, user1);

        // Wait for cooldown again
        vm.warp(block.timestamp + 1 days + 1);

        // Now user1 cannot call poke
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        freshHook.poke(INITIAL_TARGET_RATIO);
    }

    /**
     * @notice poke should revert while paused.
     */
    function test_poke_revertsWhenPaused() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(owner);
        freshHook.pause();

        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        freshHook.poke(INITIAL_TARGET_RATIO);
    }

    // Note: test_poke_revertsOnInvalidHooks_onlyValidPools removed - single pool architecture stores pool key,
    // so poke no longer takes a key parameter. Pool validation happens at initializePool instead.

    /**
     * @notice poke should not be re-entrant (nonReentrant).
     * @dev Deploys a MockReenteringLogic as the hook owner, advances past cooldown,
     *      then calls poke via the hook. The mock's getFee will attempt to re-enter poke,
     *      triggering ReentrancyGuard's reentrant call revert.
     */
    function test_poke_reentrancyGuard_blocksReentry() public {
        // Initialize a pool and allow initial fee update cooldown to expire
        (,, Alphix freshHook,, AccessManager freshAm,) =
            _initPoolFreshFull(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.warp(block.timestamp + 1 days + 1);

        // Deploy the re-entering logic and set it as the hook owner
        MockReenteringLogic reenterLogic = new MockReenteringLogic(address(freshHook));

        // Grant FEE_POKER_ROLE to reenterLogic so it can call poke
        vm.prank(owner);
        freshAm.grantRole(FEE_POKER_ROLE, address(reenterLogic), 0);

        vm.prank(owner);
        // Transfer hook ownership so getFee->poke happens as owner
        freshHook.transferOwnership(address(reenterLogic));

        // Mock accepts ownership (complete the 2-step Ownable transfer)
        vm.prank(address(reenterLogic));
        freshHook.acceptOwnership();

        // Set hook logic to reentering one (LogicUpdated event removed for bytecode savings)
        vm.startPrank(address(reenterLogic));
        freshHook.setLogic(address(reenterLogic));
        vm.stopPrank();

        // Expect reentrancy guard to block the nested call
        vm.prank(address(reenterLogic));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        freshHook.poke(INITIAL_TARGET_RATIO);
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
        // forge-lint: disable-next-line(named-struct-fields)
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(testHook));

        // initialize reverts due to validLogic in beforeInitialize
        // PoolManager wraps the LogicNotSet error in a WrappedError
        vm.expectRevert();
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Paused by default; unpause to hit LogicNotSet in getFee path
        vm.startPrank(owner);
        testHook.unpause();
        vm.expectRevert(IAlphix.LogicNotSet.selector);
        testHook.poke(INITIAL_TARGET_RATIO);
        vm.stopPrank();

        // Any non-poker-role caller reverts with AccessManaged
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user1));
        testHook.poke(INITIAL_TARGET_RATIO);
    }

    /**
     * @notice Poke should revert if currentRatio is zero.
     */
    function test_poke_revertsOnZeroRatio() public {
        (,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // Advance time past cooldown period
        vm.warp(block.timestamp + 2 days);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphixLogic.InvalidRatio.selector, 0));
        freshHook.poke(0);
    }

    /**
     * @notice Poke should revert if cooldown not elapsed since last fee update.
     */
    function test_poke_revertsOnCooldownNotElapsed() public {
        uint256 currentTimestamp = block.timestamp;
        (PoolKey memory k,, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // Immediately poking should hit logic cooldown check
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphixLogic.CooldownNotElapsed.selector, k.toId(), currentTimestamp + 1 days, 1 days
            )
        );
        freshHook.poke(INITIAL_TARGET_RATIO);
    }

    /**
     * @notice setGlobalMaxAdjRate should update the global max adjustment rate.
     */
    function test_setGlobalMaxAdjRate_success() public {
        uint256 newRate = 2e18; // within allowed bounds per logic
        vm.prank(owner);
        logic.setGlobalMaxAdjRate(newRate);
        assertEq(logic.getGlobalMaxAdjRate(), newRate);
    }

    /**
     * @notice Test setGlobalMaxAdjRate reverts when rate is zero
     */
    function test_setGlobalMaxAdjRate_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setGlobalMaxAdjRate(0);
    }

    /**
     * @notice Test setGlobalMaxAdjRate reverts when rate exceeds maximum
     */
    function test_setGlobalMaxAdjRate_revertsOnTooHigh() public {
        uint256 tooHigh = AlphixGlobalConstants.MAX_ADJUSTMENT_RATE + 1;
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidParameter.selector);
        logic.setGlobalMaxAdjRate(tooHigh);
    }

    /**
     * @notice getFee should return the fee stored in PoolManager slot0.
     */
    function test_getFee_view() public {
        (, PoolId id, Alphix freshHook,) =
            _initPoolFresh(INITIAL_FEE, INITIAL_TARGET_RATIO, 18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        (,,, uint24 feeFromSlot) = poolManager.getSlot0(id);
        uint24 feeFromView = freshHook.getFee();
        assertEq(feeFromView, feeFromSlot);
    }

    /* HELPERS */

    /**
     * @notice Create a fresh Uniswap pool bound to a fresh hook without configuring Alphix.
     * @dev Creates a new hook+logic pair to support single-pool-per-hook architecture.
     * @return k The pool key
     * @return id The pool ID
     * @return freshHook The fresh hook instance
     * @return freshLogic The fresh logic instance
     */
    function _newUninitializedPoolFresh(uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice)
        internal
        returns (PoolKey memory k, PoolId id, Alphix freshHook, IAlphixLogic freshLogic)
    {
        (freshHook, freshLogic) = _deployFreshAlphixStack();
        (k, id) = _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, freshHook);
    }

    /**
     * @notice Create a fresh Uniswap pool bound to a fresh hook without configuring Alphix, with full returns.
     * @dev Creates a new hook+logic pair to support single-pool-per-hook architecture.
     * @return k The pool key
     * @return id The pool ID
     * @return freshHook The fresh hook instance
     * @return freshLogic The fresh logic instance
     * @return freshAm The fresh AccessManager instance
     * @return freshReg The fresh Registry instance
     */
    function _newUninitializedPoolFreshFull(uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice)
        internal
        returns (
            PoolKey memory k,
            PoolId id,
            Alphix freshHook,
            IAlphixLogic freshLogic,
            AccessManager freshAm,
            Registry freshReg
        )
    {
        (freshHook, freshLogic, freshAm, freshReg) = _deployFreshAlphixStackFull();
        (k, id) = _newUninitializedPoolWithHook(d0, d1, spacing, initialPrice, freshHook);
    }

    /**
     * @notice Create and initialize a pool in Alphix with given params using a fresh hook.
     * @dev Creates a new hook+logic pair to support single-pool-per-hook architecture.
     * @return k The pool key
     * @return id The pool ID
     * @return freshHook The fresh hook instance
     * @return freshLogic The fresh logic instance
     */
    function _initPoolFresh(uint24 fee, uint256 ratio, uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice)
        internal
        returns (PoolKey memory k, PoolId id, Alphix freshHook, IAlphixLogic freshLogic)
    {
        (freshHook, freshLogic) = _deployFreshAlphixStack();
        (k, id) = _initPoolWithHook(fee, ratio, d0, d1, spacing, initialPrice, freshHook);
    }

    /**
     * @notice Create and initialize a pool in Alphix with given params using a fresh hook, returning AccessManager.
     * @dev Creates a new hook+logic pair to support single-pool-per-hook architecture.
     * @return k The pool key
     * @return id The pool ID
     * @return freshHook The fresh hook instance
     * @return freshLogic The fresh logic instance
     * @return freshAm The fresh AccessManager instance
     * @return freshReg The fresh Registry instance
     */
    function _initPoolFreshFull(uint24 fee, uint256 ratio, uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice)
        internal
        returns (
            PoolKey memory k,
            PoolId id,
            Alphix freshHook,
            IAlphixLogic freshLogic,
            AccessManager freshAm,
            Registry freshReg
        )
    {
        (freshHook, freshLogic, freshAm, freshReg) = _deployFreshAlphixStackFull();
        (k, id) = _initPoolWithHook(fee, ratio, d0, d1, spacing, initialPrice, freshHook);
    }
}
