// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* OZ IMPORTS */
import {Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/* LOCAL IMPORTS */
import "../../BaseAlphix.t.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IRegistry} from "../../../../src/interfaces/IRegistry.sol";
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
        uint24 invalidFee = 10001; // 1.0001%
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAlphix.InvalidFeeForPoolType.selector, IAlphixLogic.PoolType.STANDARD, invalidFee)
        );
        hook.initializePool(k, invalidFee, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        invalidFee = 499; // 0.0499%
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAlphix.InvalidFeeForPoolType.selector, IAlphixLogic.PoolType.STANDARD, invalidFee)
        );
        hook.initializePool(k, invalidFee, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        uint24 validFee = 500; // 0.05%
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
        vm.expectRevert(IAlphix.NullArgument.selector);
        hook.initializePool(k, INITIAL_FEE, 0, IAlphixLogic.PoolType.STANDARD);
    }

    /**
     * @notice initializePool should revert when caller is not owner.
     */
    function test_initializePool_revertsOnNonOwner() public {
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);
        vm.prank(unauthorized);
        // Expect revert from Ownable when calling initializePool
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
        // Expect revert because the contract is paused
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
        vm.expectRevert(); // Reverts because the logic has not been set and of the validLogic modifier
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Reverts because the logic has not been set (initialize not called) and the contract is still paused.
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
        // Expect revert from Ownable when calling activatePool
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

        // Reverts because the contract is paused.
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.activatePool(k);
    }

    /**
     * @notice activatePool should revert when the pool was never configured.
     * @dev Creates a Uniswap pool bound to the hook, but does not call hook.initializePool.
     */
    function test_activatePool_revertsWhenNotConfigured() public {
        // Creates an unconfigured pool for the default hook
        (PoolKey memory k,) = _newUninitializedPool(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1);

        // Revert because the pool has not been configured yet
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
        // Expect revert from Ownable when calling activatePool
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

        // Reverts because the contract is paused.
        vm.startPrank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.deactivatePool(k);
    }

    /**
     * @notice setPoolTypeBounds should update bounds for the given pool type.
     */
    function test_setPoolTypeBounds_success() public {
        IAlphixLogic.PoolTypeBounds memory newBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: 5000});
        vm.prank(owner);
        hook.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, newBounds);

        IAlphixLogic.PoolTypeBounds memory got = hook.getPoolTypeBounds(IAlphixLogic.PoolType.STANDARD);
        assertEq(got.minFee, newBounds.minFee);
        assertEq(got.maxFee, newBounds.maxFee);
    }

    /**
     * @notice setPoolTypeBounds should revert for non-owner.
     */
    function test_setPoolTypeBounds_revertsOnNonOwner() public {
        IAlphixLogic.PoolTypeBounds memory newBounds = IAlphixLogic.PoolTypeBounds({minFee: 1000, maxFee: 5000});
        vm.prank(unauthorized);
        // Expect revert from Ownable when calling setPoolTypeBounds
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        hook.setPoolTypeBounds(IAlphixLogic.PoolType.STANDARD, newBounds);
    }

    /**
     * @notice getPoolBounds should match the configured type bounds.
     */
    function test_getPoolBounds() public {
        (, PoolId id) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );
        IAlphixLogic.PoolTypeBounds memory setBounds = hook.getPoolBounds(id);
        assertEq(setBounds.minFee, standardBounds.minFee);
        assertEq(setBounds.maxFee, standardBounds.maxFee);
    }

    /**
     * @notice getPoolTypeBounds returns the current bounds for a pool type.
     */
    function test_getPoolTypeBounds() public view {
        IAlphixLogic.PoolTypeBounds memory currentBounds = hook.getPoolTypeBounds(IAlphixLogic.PoolType.STABLE);
        assertEq(currentBounds.minFee, stableBounds.minFee);
        assertEq(currentBounds.maxFee, stableBounds.maxFee);
    }

    /**
     * @notice poke should update LP fee when called by logic and emit FeeUpdated; state is verified via StateLibrary.getSlot0.
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

        (,,, uint24 preLpFee) = poolManager.getSlot0(id);

        vm.prank(address(logic));
        vm.expectEmit(true, false, false, true);
        emit IAlphix.FeeUpdated(id, preLpFee, 3000);
        hook.poke(k);

        (,,, uint24 postLpFee) = poolManager.getSlot0(id);
        assertEq(postLpFee, 3000, "lpFee not updated as expected");
    }

    /**
     * @notice poke should revert when called by non-logic.
     */
    function test_poke_revertsOnNonLogic() public {
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
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        hook.poke(k);

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        hook.poke(k);
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

        vm.prank(address(logic));
        // Reverts because the contract is paused.
        vm.expectRevert(Pausable.EnforcedPause.selector);
        hook.poke(k);
    }

    /**
     * @notice Poke should revert for invalid PoolKey.hooks (onlyValidPools).
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
        vm.prank(address(logic));
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.poke(k);
    }

    /**
     * @notice Poke should not be re-entrant (nonReentrant).
     * @dev A malicious logic tries to re-enter poke during getFee
     */
    function test_poke_reentrancyGuard_blocksReentry() public {
        // Init pool with default hook
        (PoolKey memory k,) = _initPool(
            IAlphixLogic.PoolType.STANDARD,
            INITIAL_FEE,
            INITIAL_TARGET_RATIO,
            18,
            18,
            defaultTickSpacing,
            Constants.SQRT_PRICE_1_1
        );

        // Swap in a re-entrancy attempting logic
        vm.startPrank(owner);
        MockReenteringLogic reenter = new MockReenteringLogic(address(hook));
        // Force-set logic (owner only)
        vm.expectEmit(true, true, false, true);
        emit IAlphix.LogicUpdated(hook.getLogic(), address(reenter));
        hook.setLogic(address(reenter));
        vm.stopPrank();

        // Reentrant call to poke reverts
        vm.prank(address(reenter));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        hook.poke(k);
    }

    /**
     * @notice Poke should revert when logic is unset.
     * @dev Deploy a fresh hook with no initialize() so logic==address(0). Build a pool bound to that hook.
     *      Any caller attempting hook.poke will fail the onlyLogic check.
     */
    function test_poke_revertsWhenLogicUnset_invalidCaller() public {
        // Fresh hook, not initialized => logic == address(0)
        vm.startPrank(owner);
        Alphix testHook = _deployAlphixHook(poolManager, owner, accessManager, registry);
        vm.stopPrank();

        // Create a Uniswap pool bound to testHook
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(18, 18);
        PoolKey memory k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20, IHooks(testHook));
        vm.expectRevert();
        poolManager.initialize(k, Constants.SQRT_PRICE_1_1);

        // Any caller fails onlyLogic (msg.sender != logic(0x0))
        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        testHook.poke(k);

        // logic not set
        vm.prank(address(0));
        vm.expectRevert(IAlphix.LogicNotSet.selector);
        testHook.poke(k);
    }

    /* HELPERS */

    /**
     * @notice Create a fresh Uniswap pool bound to the current hook without configuring Alphix.
     */
    function _newUninitializedPool(uint8 d0, uint8 d1, int24 spacing, uint160 initialPrice)
        internal
        returns (PoolKey memory k, PoolId id)
    {
        (Currency c0, Currency c1) = deployCurrencyPairWithDecimals(d0, d1);
        k = PoolKey(c0, c1, LPFeeLibrary.DYNAMIC_FEE_FLAG, spacing, IHooks(hook));
        id = k.toId();
        poolManager.initialize(k, initialPrice);
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
        (k, id) = _newUninitializedPool(d0, d1, spacing, initialPrice);
        vm.prank(owner);
        hook.initializePool(k, fee, ratio, ptype);
    }
}
