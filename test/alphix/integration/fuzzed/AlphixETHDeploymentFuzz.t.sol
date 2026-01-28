// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* OZ IMPORTS */

/* SOLMATE IMPORTS */

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixETH} from "../../../../src/AlphixETH.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";

/**
 * @title AlphixETHDeploymentFuzzTest
 * @notice Fuzz tests for AlphixETH deployment and initialization
 */
contract AlphixETHDeploymentFuzzTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    /* ========================================================================== */
    /*                           POOL INITIALIZATION FUZZ                         */
    /* ========================================================================== */

    function testFuzz_initializePool_withValidFee(uint24 fee) public {
        // Bound fee within valid range (use global bounds from contracts)
        fee = uint24(bound(fee, 1, LPFeeLibrary.MAX_LP_FEE));

        AlphixETH freshHook = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        vm.prank(freshHook.owner());
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Use pool params that accept this fee
        DynamicFeeLib.PoolParams memory params = defaultPoolParams;
        params.minFee = 1;
        params.maxFee = LPFeeLibrary.MAX_LP_FEE;

        int24 tickLower = TickMath.minUsableTick(newKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(newKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(newKey, fee, INITIAL_TARGET_RATIO, params, tickLower, tickUpper);

        assertEq(freshHook.getFee(), fee);
    }

    function testFuzz_initializePool_withValidTargetRatio(uint256 ratio) public {
        // Bound ratio within valid range (1 wei to maxCurrentRatio)
        ratio = bound(ratio, 1, defaultPoolParams.maxCurrentRatio);

        AlphixETH freshHook = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        vm.prank(freshHook.owner());
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(newKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(newKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, ratio, defaultPoolParams, tickLower, tickUpper);

        // Pool should be initialized - verify by checking pool ID is set
        assertTrue(PoolId.unwrap(freshHook.getPoolId()) != bytes32(0));
    }

    function testFuzz_initializePool_withVariousTokenDecimals(uint8 decimals) public {
        // Bound decimals to reasonable range
        decimals = uint8(bound(decimals, 6, 18));

        AlphixETH freshHook = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(decimals);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        vm.prank(freshHook.owner());
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(newKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(newKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);

        // Verify initialization succeeded
        PoolKey memory cachedKey = freshHook.getPoolKey();
        assertEq(Currency.unwrap(cachedKey.currency0), address(0));
        assertEq(Currency.unwrap(cachedKey.currency1), Currency.unwrap(newToken));
    }

    function testFuzz_initializePool_withVariousTickSpacing(int24 tickSpacing) public {
        // Bound tick spacing to valid range (must be positive and reasonable)
        tickSpacing = int24(bound(int256(tickSpacing), 1, 200));

        AlphixETH freshHook = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: newToken,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: tickSpacing,
            hooks: IHooks(freshHook)
        });

        vm.prank(freshHook.owner());
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(newKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(newKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);

        PoolKey memory cachedKey = freshHook.getPoolKey();
        assertEq(cachedKey.tickSpacing, tickSpacing);
    }

    /* ========================================================================== */
    /*                           ETH RECEIVE FUZZ                                 */
    /* ========================================================================== */

    /**
     * @notice Fuzz test that receive() rejects ETH from unauthorized senders.
     * @dev Only PoolManager and ETH yield source are allowed to send ETH.
     */
    function testFuzz_receive_rejectsUnauthorizedSenders(address sender) public {
        vm.assume(sender != address(0));
        vm.assume(sender != address(poolManager));
        // Exclude precompiles and system addresses that might have special behavior
        vm.assume(uint160(sender) > 100);

        vm.deal(sender, 1 ether);
        vm.prank(sender);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertFalse(success, "Should reject ETH from unauthorized senders");
    }

    function testFuzz_receive_acceptsETHFromPoolManager(uint256 amount) public {
        amount = bound(amount, 1, 100 ether);

        vm.deal(address(poolManager), amount);
        vm.prank(address(poolManager));
        (bool success,) = address(hook).call{value: amount}("");
        assertTrue(success, "Should accept ETH from PoolManager");
        assertEq(address(hook).balance, amount);
    }

    /* ========================================================================== */
    /*                           POKE FUZZ                                        */
    /* ========================================================================== */

    function testFuzz_poke_withVariousRatios(uint256 ratio) public {
        // Bound ratio within valid range (1 wei to maxCurrentRatio)
        ratio = bound(ratio, 1, defaultPoolParams.maxCurrentRatio);

        // Wait for cooldown
        vm.warp(block.timestamp + 1 days + 1);

        vm.prank(owner);
        hook.poke(ratio);

        // Fee should be updated (may or may not have changed depending on ratio)
        assertTrue(hook.getFee() > 0);
    }

    function testFuzz_poke_respectsCooldownWithVariousDelays(uint256 delay) public {
        // First poke
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(owner);
        hook.poke(5e17);

        // Second poke with variable delay
        delay = bound(delay, 0, 2 days);
        vm.warp(block.timestamp + delay);

        if (delay < defaultPoolParams.minPeriod) {
            vm.prank(owner);
            vm.expectRevert();
            hook.poke(6e17);
        } else {
            vm.prank(owner);
            hook.poke(6e17);
            // Should succeed
        }
    }

    /* ========================================================================== */
    /*                           POOL PARAMS FUZZ                                 */
    /* ========================================================================== */

    function testFuzz_initializePool_withValidPoolParams(
        uint24 minFee,
        uint24 maxFee,
        uint24 baseMaxFeeDelta,
        uint24 lookbackPeriod
    ) public {
        // Bound parameters within valid global ranges (from AlphixGlobalConstants)
        // MIN_LOOKBACK_PERIOD = 7, MAX_LOOKBACK_PERIOD = 365
        // MIN_FEE = 1, MAX_LP_FEE = 1000000 (100%)
        minFee = uint24(bound(minFee, 1, 100000));
        maxFee = uint24(bound(maxFee, minFee + 1, LPFeeLibrary.MAX_LP_FEE));
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, 1, LPFeeLibrary.MAX_LP_FEE));
        lookbackPeriod = uint24(bound(lookbackPeriod, 7, 365)); // Within AlphixGlobalConstants bounds

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: minFee,
            maxFee: maxFee,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: lookbackPeriod,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: 1e18,
            lowerSideFactor: 2e18
        });

        AlphixETH freshHook = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        vm.prank(freshHook.owner());
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        // Use a fee within the provided range
        uint24 initialFee = uint24(bound(uint256(minFee), minFee, maxFee));

        int24 tickLower = TickMath.minUsableTick(newKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(newKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(newKey, initialFee, INITIAL_TARGET_RATIO, params, tickLower, tickUpper);

        // Verify initialization
        assertEq(freshHook.getFee(), initialFee);
    }

    function testFuzz_initializePool_withVariousSideFactors(uint256 upperSideFactor, uint256 lowerSideFactor) public {
        // Bound side factors within valid range
        upperSideFactor = bound(upperSideFactor, 1e17, 10e18);
        lowerSideFactor = bound(lowerSideFactor, 1e17, 10e18);

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: 100001,
            baseMaxFeeDelta: 50,
            lookbackPeriod: 30,
            minPeriod: 1 days,
            ratioTolerance: 5e15,
            linearSlope: 1e18,
            maxCurrentRatio: 1e21,
            upperSideFactor: upperSideFactor,
            lowerSideFactor: lowerSideFactor
        });

        AlphixETH freshHook = _deployFreshAlphixEthStack();

        Currency newToken = deployEthPoolToken(18);
        PoolKey memory newKey = createEthPoolKey(newToken, 20, freshHook);

        vm.prank(freshHook.owner());
        poolManager.initialize(newKey, Constants.SQRT_PRICE_1_1);

        int24 tickLower = TickMath.minUsableTick(newKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(newKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(newKey, INITIAL_FEE, INITIAL_TARGET_RATIO, params, tickLower, tickUpper);

        // Verify initialization
        assertEq(freshHook.getFee(), INITIAL_FEE);
    }
}
