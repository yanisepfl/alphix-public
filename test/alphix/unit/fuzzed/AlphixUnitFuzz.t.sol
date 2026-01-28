// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title AlphixUnitFuzzTest
 * @notice Fuzz tests for Alphix contract
 * @dev Tests functions with random inputs to find edge cases
 */
contract AlphixUnitFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    function setUp() public override {
        super.setUp();

        // Deploy yield vaults for currency0 and currency1
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              SET POOL PARAMS FUZZ
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test that valid pool params are accepted
     */
    function testFuzz_setPoolParams_validParams(
        uint24 minFee,
        uint24 maxFee,
        uint24 baseMaxFeeDelta,
        uint24 lookbackPeriod,
        uint256 minPeriod,
        uint256 ratioTolerance,
        uint256 linearSlope,
        uint256 maxCurrentRatio,
        uint256 upperSideFactor,
        uint256 lowerSideFactor
    ) public {
        // Bound to valid ranges (AlphixGlobalConstants)
        minFee = uint24(bound(minFee, AlphixGlobalConstants.MIN_FEE, LPFeeLibrary.MAX_LP_FEE - 1));
        maxFee = uint24(bound(maxFee, minFee + 1, LPFeeLibrary.MAX_LP_FEE));
        baseMaxFeeDelta = uint24(bound(baseMaxFeeDelta, 1, LPFeeLibrary.MAX_LP_FEE));
        lookbackPeriod = uint24(
            bound(lookbackPeriod, AlphixGlobalConstants.MIN_LOOKBACK_PERIOD, AlphixGlobalConstants.MAX_LOOKBACK_PERIOD)
        );
        minPeriod = bound(minPeriod, AlphixGlobalConstants.MIN_PERIOD, AlphixGlobalConstants.MAX_PERIOD);
        ratioTolerance = bound(ratioTolerance, AlphixGlobalConstants.MIN_RATIO_TOLERANCE, AlphixGlobalConstants.TEN_WAD);
        linearSlope = bound(linearSlope, AlphixGlobalConstants.MIN_LINEAR_SLOPE, AlphixGlobalConstants.TEN_WAD);
        maxCurrentRatio = bound(maxCurrentRatio, 1, AlphixGlobalConstants.MAX_CURRENT_RATIO);
        upperSideFactor = bound(upperSideFactor, AlphixGlobalConstants.ONE_TENTH_WAD, AlphixGlobalConstants.TEN_WAD);
        lowerSideFactor = bound(lowerSideFactor, AlphixGlobalConstants.ONE_TENTH_WAD, AlphixGlobalConstants.TEN_WAD);

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: minFee,
            maxFee: maxFee,
            baseMaxFeeDelta: baseMaxFeeDelta,
            lookbackPeriod: lookbackPeriod,
            minPeriod: minPeriod,
            ratioTolerance: ratioTolerance,
            linearSlope: linearSlope,
            maxCurrentRatio: maxCurrentRatio,
            upperSideFactor: upperSideFactor,
            lowerSideFactor: lowerSideFactor
        });

        vm.prank(owner);
        hook.setPoolParams(params);

        DynamicFeeLib.PoolParams memory storedParams = hook.getPoolParams();
        assertEq(storedParams.minFee, minFee, "minFee mismatch");
        assertEq(storedParams.maxFee, maxFee, "maxFee mismatch");
        assertEq(storedParams.lookbackPeriod, lookbackPeriod, "lookbackPeriod mismatch");
        assertEq(storedParams.minPeriod, minPeriod, "minPeriod mismatch");
    }

    /**
     * @notice Fuzz test that minFee below MIN_FEE reverts
     */
    function testFuzz_setPoolParams_invalidMinFee_belowMin(uint24 minFee) public {
        // minFee below MIN_FEE (which is 1)
        vm.assume(minFee < AlphixGlobalConstants.MIN_FEE);

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minFee = minFee;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidFeeBounds.selector));
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that minFee > maxFee reverts
     */
    function testFuzz_setPoolParams_invalidMinFee_greaterThanMax(uint24 minFee, uint24 maxFee) public {
        // Ensure minFee > maxFee and both are valid
        minFee = uint24(bound(minFee, 2, LPFeeLibrary.MAX_LP_FEE));
        maxFee = uint24(bound(maxFee, 1, minFee - 1));

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minFee = minFee;
        badParams.maxFee = maxFee;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidFeeBounds.selector));
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that maxFee above MAX_LP_FEE reverts
     */
    function testFuzz_setPoolParams_invalidMaxFee_exceedsMax(uint24 maxFee) public {
        // maxFee above MAX_LP_FEE
        vm.assume(maxFee > LPFeeLibrary.MAX_LP_FEE);

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.maxFee = maxFee;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidFeeBounds.selector));
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that minPeriod below MIN_PERIOD reverts
     */
    function testFuzz_setPoolParams_invalidMinPeriod_belowMin(uint256 minPeriod) public {
        // minPeriod below MIN_PERIOD
        vm.assume(minPeriod < AlphixGlobalConstants.MIN_PERIOD);

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minPeriod = minPeriod;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that minPeriod above MAX_PERIOD reverts
     */
    function testFuzz_setPoolParams_invalidMinPeriod_aboveMax(uint256 minPeriod) public {
        // minPeriod above MAX_PERIOD
        vm.assume(minPeriod > AlphixGlobalConstants.MAX_PERIOD);

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minPeriod = minPeriod;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that lookbackPeriod outside bounds reverts
     */
    function testFuzz_setPoolParams_invalidLookbackPeriod(uint24 lookbackPeriod) public {
        // lookbackPeriod outside valid range
        vm.assume(
            lookbackPeriod < AlphixGlobalConstants.MIN_LOOKBACK_PERIOD
                || lookbackPeriod > AlphixGlobalConstants.MAX_LOOKBACK_PERIOD
        );

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.lookbackPeriod = lookbackPeriod;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that ratioTolerance outside bounds reverts
     */
    function testFuzz_setPoolParams_invalidRatioTolerance(uint256 ratioTolerance) public {
        // ratioTolerance outside valid range
        vm.assume(
            ratioTolerance < AlphixGlobalConstants.MIN_RATIO_TOLERANCE || ratioTolerance > AlphixGlobalConstants.TEN_WAD
        );

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.ratioTolerance = ratioTolerance;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that linearSlope outside bounds reverts
     */
    function testFuzz_setPoolParams_invalidLinearSlope(uint256 linearSlope) public {
        // linearSlope outside valid range
        vm.assume(linearSlope < AlphixGlobalConstants.MIN_LINEAR_SLOPE || linearSlope > AlphixGlobalConstants.TEN_WAD);

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.linearSlope = linearSlope;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that maxCurrentRatio outside bounds reverts
     */
    function testFuzz_setPoolParams_invalidMaxCurrentRatio(uint256 maxCurrentRatio) public {
        // maxCurrentRatio is 0 or above max
        vm.assume(maxCurrentRatio == 0 || maxCurrentRatio > AlphixGlobalConstants.MAX_CURRENT_RATIO);

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.maxCurrentRatio = maxCurrentRatio;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that upperSideFactor outside bounds reverts
     */
    function testFuzz_setPoolParams_invalidUpperSideFactor(uint256 upperSideFactor) public {
        // upperSideFactor outside valid range
        vm.assume(
            upperSideFactor < AlphixGlobalConstants.ONE_TENTH_WAD || upperSideFactor > AlphixGlobalConstants.TEN_WAD
        );

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.upperSideFactor = upperSideFactor;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /**
     * @notice Fuzz test that lowerSideFactor outside bounds reverts
     */
    function testFuzz_setPoolParams_invalidLowerSideFactor(uint256 lowerSideFactor) public {
        // lowerSideFactor outside valid range
        vm.assume(
            lowerSideFactor < AlphixGlobalConstants.ONE_TENTH_WAD || lowerSideFactor > AlphixGlobalConstants.TEN_WAD
        );

        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.lowerSideFactor = lowerSideFactor;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          SET GLOBAL MAX ADJ RATE FUZZ
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test valid global max adj rate values
     */
    function testFuzz_setGlobalMaxAdjRate_validRange(uint256 newRate) public {
        // Bound to valid range
        newRate = bound(newRate, 1, AlphixGlobalConstants.MAX_ADJUSTMENT_RATE);

        vm.prank(owner);
        hook.setGlobalMaxAdjRate(newRate);

        assertEq(hook.getGlobalMaxAdjRate(), newRate, "Rate should be updated");
    }

    /**
     * @notice Fuzz test that rates above max revert
     */
    function testFuzz_setGlobalMaxAdjRate_exceedsMax(uint256 newRate) public {
        // Above max
        vm.assume(newRate > AlphixGlobalConstants.MAX_ADJUSTMENT_RATE);

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setGlobalMaxAdjRate(newRate);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                POKE FUZZ
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test poke with various valid ratios
     */
    function testFuzz_poke_withValidRatio(uint256 ratio) public {
        // Bound ratio to valid range
        ratio = bound(ratio, 1, defaultPoolParams.maxCurrentRatio);

        // Warp past cooldown
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(ratio);

        // Fee should be within bounds
        uint24 fee = hook.getFee();
        assertGe(fee, defaultPoolParams.minFee, "Fee should be >= minFee");
        assertLe(fee, defaultPoolParams.maxFee, "Fee should be <= maxFee");
    }

    /**
     * @notice Fuzz test poke with invalid ratio (zero)
     */
    function testFuzz_poke_invalidRatio_zero() public {
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        hook.poke(0);
    }

    /**
     * @notice Fuzz test poke with invalid ratio (exceeds max)
     */
    function testFuzz_poke_invalidRatio_exceedsMax(uint256 ratio) public {
        // Above maxCurrentRatio
        vm.assume(ratio > defaultPoolParams.maxCurrentRatio);

        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        hook.poke(ratio);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          INITIALIZE POOL FUZZ
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test initializePool with valid fee
     */
    function testFuzz_initializePool_withValidFee(uint24 fee) public {
        // Deploy fresh hook
        Alphix freshHook = _deployFreshAlphixStack();

        // Bound fee within pool params bounds
        fee = uint24(bound(fee, defaultPoolParams.minFee, defaultPoolParams.maxFee));

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(freshKey, fee, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);

        assertEq(freshHook.getFee(), fee, "Fee should match");
    }

    /**
     * @notice Fuzz test initializePool with valid target ratio
     */
    function testFuzz_initializePool_withValidTargetRatio(uint256 ratio) public {
        // Deploy fresh hook
        Alphix freshHook = _deployFreshAlphixStack();

        // Bound ratio within valid range
        ratio = bound(ratio, 1, defaultPoolParams.maxCurrentRatio);

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        freshHook.initializePool(freshKey, INITIAL_FEE, ratio, defaultPoolParams, tickLower, tickUpper);

        // Pool should be initialized
        assertTrue(PoolId.unwrap(freshHook.getPoolId()) != bytes32(0), "Pool should be initialized");
    }

    /**
     * @notice Fuzz test initializePool with invalid fee (below min)
     */
    function testFuzz_initializePool_invalidFee_belowMin(uint24 fee) public {
        // Deploy fresh hook
        Alphix freshHook = _deployFreshAlphixStack();

        // Fee below minFee
        vm.assume(fee < defaultPoolParams.minFee);

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphix.InvalidInitialFee.selector, fee, defaultPoolParams.minFee, defaultPoolParams.maxFee
            )
        );
        freshHook.initializePool(freshKey, fee, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);
    }

    /**
     * @notice Fuzz test initializePool with invalid fee (above max)
     */
    function testFuzz_initializePool_invalidFee_aboveMax(uint24 fee) public {
        // Deploy fresh hook
        Alphix freshHook = _deployFreshAlphixStack();

        // Fee above maxFee
        vm.assume(fee > defaultPoolParams.maxFee);

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphix.InvalidInitialFee.selector, fee, defaultPoolParams.minFee, defaultPoolParams.maxFee
            )
        );
        freshHook.initializePool(freshKey, fee, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);
    }

    /**
     * @notice Fuzz test initializePool with invalid target ratio (zero or exceeds max)
     */
    function testFuzz_initializePool_invalidTargetRatio(uint256 ratio) public {
        // Deploy fresh hook
        Alphix freshHook = _deployFreshAlphixStack();

        // Ratio is 0 or above maxCurrentRatio
        vm.assume(ratio == 0 || ratio > defaultPoolParams.maxCurrentRatio);

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        freshHook.initializePool(freshKey, INITIAL_FEE, ratio, defaultPoolParams, tickLower, tickUpper);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                           TICK RANGE FUZZ
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test initializePool with valid tick ranges
     * @dev Tick range is now set immutably at initializePool time
     */
    function testFuzz_initializePool_withTickRange_valid(int24 tickLowerRaw, int24 tickUpperRaw) public {
        Alphix freshHook = _deployFreshAlphixStack();

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        // Get usable tick bounds for this spacing
        int24 tickSpacing = defaultTickSpacing;
        int24 minUsable = TickMath.minUsableTick(tickSpacing);
        int24 maxUsable = TickMath.maxUsableTick(tickSpacing);

        // Bound ticks to usable range
        int24 tickLower = int24(bound(int256(tickLowerRaw), int256(minUsable), int256(maxUsable - tickSpacing)));
        int24 tickUpper = int24(bound(int256(tickUpperRaw), int256(tickLower + tickSpacing), int256(maxUsable)));

        // Align to spacing
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        // Ensure proper ordering after alignment
        if (tickLower >= tickUpper) {
            tickUpper = tickLower + tickSpacing;
        }

        // Skip if still invalid
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            return;
        }

        vm.prank(owner);
        freshHook.initializePool(freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);

        IReHypothecation.ReHypothecationConfig memory config = freshHook.getReHypothecationConfig();
        assertEq(config.tickLower, tickLower, "Lower tick mismatch");
        assertEq(config.tickUpper, tickUpper, "Upper tick mismatch");
    }

    // Exclude from coverage
    function test() public {}
}
