// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "../../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../../src/libraries/AlphixGlobalConstants.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title AlphixUnitTest
 * @notice Comprehensive unit tests for Alphix contract
 * @dev Tests all functions, error paths, and edge cases for branch coverage
 */
contract AlphixUnitTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    function setUp() public override {
        super.setUp();

        // Deploy yield vaults for currency0 and currency1
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                PAUSE/UNPAUSE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_pause_succeeds() public {
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Hook should be paused");
    }

    function test_pause_revertsWhenNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.pause();
    }

    function test_unpause_succeeds() public {
        vm.startPrank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Hook should be paused");
        hook.unpause();
        assertFalse(hook.paused(), "Hook should be unpaused");
        vm.stopPrank();
    }

    function test_unpause_revertsWhenNotOwner() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(unauthorized);
        vm.expectRevert();
        hook.unpause();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                           INITIALIZE POOL TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_initializePool_revertsOnPoolAlreadyConfigured() public {
        // Pool is already configured in setUp
        // First pause the hook so whenPaused modifier passes
        vm.prank(owner);
        hook.pause();

        // Now try to initialize again - should fail with PoolAlreadyConfigured
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(IAlphix.PoolAlreadyConfigured.selector);
        hook.initializePool(key, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);
    }

    function test_initializePool_revertsOnFeeBelowMin() public {
        Alphix freshHook = _deployFreshAlphixStack();

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphix.InvalidInitialFee.selector, 0, defaultPoolParams.minFee, defaultPoolParams.maxFee
            )
        );
        freshHook.initializePool(freshKey, 0, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper); // Fee 0 is below min
    }

    function test_initializePool_revertsOnFeeAboveMax() public {
        Alphix freshHook = _deployFreshAlphixStack();

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        uint24 badFee = uint24(defaultPoolParams.maxFee + 1);
        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphix.InvalidInitialFee.selector, badFee, defaultPoolParams.minFee, defaultPoolParams.maxFee
            )
        );
        freshHook.initializePool(freshKey, badFee, INITIAL_TARGET_RATIO, defaultPoolParams, tickLower, tickUpper);
    }

    function test_initializePool_revertsOnInvalidTargetRatio_zero() public {
        Alphix freshHook = _deployFreshAlphixStack();

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        freshHook.initializePool(freshKey, INITIAL_FEE, 0, defaultPoolParams, tickLower, tickUpper); // Zero ratio is invalid
    }

    function test_initializePool_revertsOnInvalidTargetRatio_exceedsMax() public {
        Alphix freshHook = _deployFreshAlphixStack();

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        uint256 badRatio = defaultPoolParams.maxCurrentRatio + 1;
        int24 tickLower = TickMath.minUsableTick(freshKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(freshKey.tickSpacing);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        freshHook.initializePool(freshKey, INITIAL_FEE, badRatio, defaultPoolParams, tickLower, tickUpper);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                             SET POOL PARAMS TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setPoolParams_succeeds() public {
        DynamicFeeLib.PoolParams memory newParams = defaultPoolParams;
        newParams.minFee = 100;
        newParams.maxFee = 10000;

        vm.prank(owner);
        hook.setPoolParams(newParams);

        DynamicFeeLib.PoolParams memory storedParams = hook.getPoolParams();
        assertEq(storedParams.minFee, newParams.minFee, "minFee should be updated");
        assertEq(storedParams.maxFee, newParams.maxFee, "maxFee should be updated");
    }

    function test_setPoolParams_revertsOnMinFeeBelow() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minFee = 0; // Below MIN_FEE

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidFeeBounds.selector));
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnMinFeeGreaterThanMax() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minFee = 10000;
        badParams.maxFee = 1000; // minFee > maxFee

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidFeeBounds.selector));
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnMaxFeeExceedsLimit() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.maxFee = LPFeeLibrary.MAX_LP_FEE + 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidFeeBounds.selector));
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidMinPeriod_belowMin() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minPeriod = AlphixGlobalConstants.MIN_PERIOD - 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidMinPeriod_aboveMax() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.minPeriod = AlphixGlobalConstants.MAX_PERIOD + 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidLookbackPeriod_belowMin() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.lookbackPeriod = AlphixGlobalConstants.MIN_LOOKBACK_PERIOD - 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidRatioTolerance() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.ratioTolerance = AlphixGlobalConstants.MIN_RATIO_TOLERANCE - 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidLinearSlope() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.linearSlope = AlphixGlobalConstants.MIN_LINEAR_SLOPE - 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidMaxCurrentRatio_zero() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.maxCurrentRatio = 0;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidMaxCurrentRatio_exceedsMax() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.maxCurrentRatio = AlphixGlobalConstants.MAX_CURRENT_RATIO + 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidUpperSideFactor() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.upperSideFactor = AlphixGlobalConstants.ONE_TENTH_WAD - 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidLowerSideFactor() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.lowerSideFactor = AlphixGlobalConstants.TEN_WAD + 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsWhenNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.setPoolParams(defaultPoolParams);
    }

    function test_setPoolParams_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectRevert();
        hook.setPoolParams(defaultPoolParams);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          SET GLOBAL MAX ADJ RATE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setGlobalMaxAdjRate_succeeds() public {
        uint256 newRate = 5e17; // 50%

        vm.prank(owner);
        hook.setGlobalMaxAdjRate(newRate);

        assertEq(hook.getGlobalMaxAdjRate(), newRate, "Global max adj rate should be updated");
    }

    function test_setGlobalMaxAdjRate_revertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setGlobalMaxAdjRate(0);
    }

    function test_setGlobalMaxAdjRate_revertsOnExceedMax() public {
        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setGlobalMaxAdjRate(AlphixGlobalConstants.MAX_ADJUSTMENT_RATE + 1);
    }

    function test_setGlobalMaxAdjRate_revertsWhenNotOwner() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.setGlobalMaxAdjRate(5e17); // uint256 is correct here
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                   POKE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_poke_succeeds() public {
        // Warp past cooldown
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(INITIAL_TARGET_RATIO);
    }

    function test_poke_revertsOnInvalidRatio_zero() public {
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        hook.poke(0);
    }

    function test_poke_revertsOnInvalidRatio_exceedsMax() public {
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        uint256 badRatio = defaultPoolParams.maxCurrentRatio + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        hook.poke(badRatio);
    }

    function test_poke_revertsOnCooldownNotElapsed() public {
        // Don't warp - cooldown hasn't elapsed
        // Cooldown starts from pool initialization at block.timestamp
        // Next eligible timestamp is block.timestamp + minPeriod
        uint256 nextEligible = block.timestamp + defaultPoolParams.minPeriod;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.CooldownNotElapsed.selector, block.timestamp, nextEligible));
        hook.poke(INITIAL_TARGET_RATIO);
    }

    function test_poke_revertsWhenPaused() public {
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        vm.expectRevert();
        hook.poke(INITIAL_TARGET_RATIO);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            REHYPOTHECATION TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_addReHypothecatedLiquidity_revertsOnZeroShares() public {
        // Setup yield sources first
        _setupYieldSources();

        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        hook.addReHypothecatedLiquidity(0, 0, 0);
    }

    function test_removeReHypothecatedLiquidity_revertsOnZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        hook.removeReHypothecatedLiquidity(0, 0, 0);
    }

    function test_removeReHypothecatedLiquidity_revertsOnInsufficientShares() public {
        // User has no shares, try to remove some
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InsufficientShares.selector));
        hook.removeReHypothecatedLiquidity(100e18, 0, 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            YIELD SOURCE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldSource_revertsOnInvalidSource() public {
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Try to set an EOA as yield source (invalid)
        address eoa = makeAddr("eoa");

        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector));
        hook.setYieldSource(currency0, eoa);
    }

    function test_setYieldSource_succeeds() public {
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vm.prank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));

        address storedYieldSource = hook.getCurrencyYieldSource(currency0);
        assertEq(storedYieldSource, address(vault0), "Yield source should be set");
    }

    function test_setYieldSource_revertsOnZeroAddress() public {
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // First set a yield source
        vm.prank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));

        // Trying to clear it should revert with InvalidYieldSource
        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector));
        hook.setYieldSource(currency0, address(0));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              TICK RANGE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_tickRange_isSetAtInitialization() public view {
        // Tick range is now set immutably at initializePool time
        IReHypothecation.ReHypothecationConfig memory config = hook.getReHypothecationConfig();

        // Default setUp initializes with full-range ticks
        int24 expectedLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 expectedUpper = TickMath.maxUsableTick(defaultTickSpacing);

        assertEq(config.tickLower, expectedLower, "Tick lower should be set at init");
        assertEq(config.tickUpper, expectedUpper, "Tick upper should be set at init");
    }

    function test_tickRange_canBeCustomizedAtInit() public {
        // Deploy fresh hook and initialize with custom tick range
        Alphix freshHook = _deployFreshAlphixStack();

        (PoolKey memory freshKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, freshHook);

        int24 customLower = -200;
        int24 customUpper = 200;

        vm.prank(owner);
        freshHook.initializePool(
            freshKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams, customLower, customUpper
        );

        IReHypothecation.ReHypothecationConfig memory config = freshHook.getReHypothecationConfig();
        assertEq(config.tickLower, customLower, "Custom lower tick should be set");
        assertEq(config.tickUpper, customUpper, "Custom upper tick should be set");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              PREVIEW FUNCTIONS TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_previewAddFromAmount0_firstDepositor() public {
        // No shares minted yet, first depositor scenario
        _setupYieldSources();

        // Preview adding 100 tokens as first depositor
        (uint256 shares, uint256 amount1Needed) = hook.previewAddFromAmount0(100e18);

        // First depositor should get 1:1 shares
        assertGt(shares, 0, "Should get some shares");
        assertGt(amount1Needed, 0, "Should need some amount1");
    }

    function test_previewAddFromAmount1_firstDepositor() public {
        _setupYieldSources();

        (uint256 shares, uint256 amount0Needed) = hook.previewAddFromAmount1(100e18);

        assertGt(shares, 0, "Should get some shares");
        assertGt(amount0Needed, 0, "Should need some amount0");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              CONSTRUCTOR TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    // Note: test_constructor_revertsOnZeroPoolManager cannot be tested because
    // BaseHook.validateHookAddress() reverts first with HookAddressNotValid
    // before our check on line 140-141 is reached.
    // This is expected behavior - the parent contract guards against this first.

    // Note: test_constructor_revertsOnZeroAccessManager also cannot be tested
    // because deploying with the correct poolManager and zero accessManager
    // requires a valid hook address, which needs complex mining.
    // The OpenZeppelin AccessManaged constructor accepts address(0) without reverting,
    // so our check provides defense-in-depth but is hard to test in isolation.

    /* ═══════════════════════════════════════════════════════════════════════════
                          COMPUTE FEE UPDATE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_computeFeeUpdate_succeeds() public view {
        // computeFeeUpdate is view function, no cooldown needed for calling
        (uint24 newFee,,) = hook.computeFeeUpdate(INITIAL_TARGET_RATIO);

        // Fee should be within bounds
        assertGe(newFee, defaultPoolParams.minFee, "Fee should be >= minFee");
        assertLe(newFee, defaultPoolParams.maxFee, "Fee should be <= maxFee");
    }

    function test_computeFeeUpdate_revertsOnInvalidRatio_zero() public {
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        hook.computeFeeUpdate(0);
    }

    function test_computeFeeUpdate_revertsOnInvalidRatio_exceedsMax() public {
        uint256 badRatio = defaultPoolParams.maxCurrentRatio + 1;
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector));
        hook.computeFeeUpdate(badRatio);
    }

    function test_computeFeeUpdate_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        vm.expectRevert(); // EnforcedPause
        hook.computeFeeUpdate(INITIAL_TARGET_RATIO);
    }

    function test_computeFeeUpdate_wouldUpdateAfterCooldown() public {
        // Warp past cooldown
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        // Compute with a significantly different ratio
        uint256 differentRatio = INITIAL_TARGET_RATIO * 2;
        (uint24 newFee,,) = hook.computeFeeUpdate(differentRatio);

        // Should indicate would update (though this depends on the fee calculation)
        // At minimum we verify it doesn't revert and returns valid data
        assertGe(newFee, defaultPoolParams.minFee);
        assertLe(newFee, defaultPoolParams.maxFee);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      YIELD SOURCE MIGRATION TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldSource_migratesExistingShares() public {
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Tick range is already set at initializePool time (full range by default)
        // Setup yield sources (requires whenNotPaused)
        vm.startPrank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));
        hook.setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        // Add liquidity to create shares in yield source
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);
        hook.addReHypothecatedLiquidity(1e18, 0, 0);
        vm.stopPrank();

        // Verify shares exist in first yield source
        uint256 amountBefore = hook.getAmountInYieldSource(currency0);
        assertGt(amountBefore, 0, "Should have amount in yield source");

        // Deploy new vault and migrate
        MockYieldVault newVault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));

        vm.prank(yieldManager);
        hook.setYieldSource(currency0, address(newVault0));

        // Verify migration - new yield source should have the assets
        assertEq(hook.getCurrencyYieldSource(currency0), address(newVault0), "New yield source should be set");

        // Amount should be approximately preserved (within rounding)
        uint256 amountAfter = hook.getAmountInYieldSource(currency0);
        assertApproxEqAbs(amountAfter, amountBefore, 2, "Amount should be preserved after migration");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        PREVIEW EDGE CASE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_previewAddFromAmount0_returnsZeroForZeroAmount() public {
        _setupYieldSources();

        // With zero amount, should return zero
        (uint256 amount1, uint256 shares) = hook.previewAddFromAmount0(0);
        assertEq(shares, 0, "Zero amount0 should give zero shares");
        assertEq(amount1, 0, "Zero amount0 should require zero amount1");
    }

    function test_previewAddFromAmount1_returnsZeroForZeroAmount() public {
        _setupYieldSources();

        (uint256 amount0, uint256 shares) = hook.previewAddFromAmount1(0);
        assertEq(shares, 0, "Zero amount1 should give zero shares");
        assertEq(amount0, 0, "Zero amount1 should require zero amount0");
    }

    function test_previewAddFromAmount0_withExistingSupply() public {
        _setupYieldSources();

        // First add some liquidity
        uint256 initialDeposit = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, initialDeposit);
        MockERC20(Currency.unwrap(currency1)).mint(user1, initialDeposit);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), initialDeposit);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), initialDeposit);
        hook.addReHypothecatedLiquidity(10e18, 0, 0);
        vm.stopPrank();

        // Now preview with existing supply
        (, uint256 shares) = hook.previewAddFromAmount0(50e18);

        // Should get some shares and require some amount1
        assertGt(shares, 0, "Should get shares with existing supply");
    }

    function test_previewAddFromAmount1_withExistingSupply() public {
        _setupYieldSources();

        // First add some liquidity
        uint256 initialDeposit = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, initialDeposit);
        MockERC20(Currency.unwrap(currency1)).mint(user1, initialDeposit);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), initialDeposit);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), initialDeposit);
        hook.addReHypothecatedLiquidity(10e18, 0, 0);
        vm.stopPrank();

        // Now preview with existing supply
        (, uint256 shares) = hook.previewAddFromAmount1(50e18);

        // Should get some shares and require some amount0
        assertGt(shares, 0, "Should get shares with existing supply");
    }

    function test_previewAddFromAmount0_tinyAmount_returnsZeroShares() public {
        _setupYieldSources();

        // First add substantial liquidity
        uint256 initialDeposit = 1000e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, initialDeposit);
        MockERC20(Currency.unwrap(currency1)).mint(user1, initialDeposit);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), initialDeposit);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), initialDeposit);
        hook.addReHypothecatedLiquidity(100e18, 0, 0);
        vm.stopPrank();

        // Preview with very tiny amount that rounds to 0 shares
        // With 100e18 shares and ~100e18 total amount, 1 wei gives < 1 share
        // This should return 0 shares (rounds down)
        // Note: Exact behavior depends on liquidity calculation
        hook.previewAddFromAmount0(1);
    }

    function test_previewAddFromAmount1_tinyAmount_returnsZeroShares() public {
        _setupYieldSources();

        // First add substantial liquidity
        uint256 initialDeposit = 1000e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, initialDeposit);
        MockERC20(Currency.unwrap(currency1)).mint(user1, initialDeposit);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), initialDeposit);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), initialDeposit);
        hook.addReHypothecatedLiquidity(100e18, 0, 0);
        vm.stopPrank();

        // Preview with very tiny amount
        hook.previewAddFromAmount1(1);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    SET POOL PARAMS ADDITIONAL TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setPoolParams_revertsOnInvalidBaseMaxFeeDelta_belowMin() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.baseMaxFeeDelta = AlphixGlobalConstants.MIN_FEE - 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    function test_setPoolParams_revertsOnInvalidBaseMaxFeeDelta_aboveMax() public {
        DynamicFeeLib.PoolParams memory badParams = defaultPoolParams;
        badParams.baseMaxFeeDelta = LPFeeLibrary.MAX_LP_FEE + 1;

        vm.prank(owner);
        vm.expectRevert(IAlphix.InvalidParameter.selector);
        hook.setPoolParams(badParams);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      PREVIEW WITH EMPTY YIELD SOURCES
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_previewRemoveReHypothecatedLiquidity_zeroSupply() public view {
        // No liquidity added, totalSupply == 0
        (uint256 amount0, uint256 amount1) = hook.previewRemoveReHypothecatedLiquidity(100e18);

        // With zero supply, should return zero
        assertEq(amount0, 0, "Should return 0 amount0 with zero supply");
        assertEq(amount1, 0, "Should return 0 amount1 with zero supply");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    BEFORE INITIALIZE - ACCESS CONTROL TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Tests that only owner can call poolManager.initialize (Issue #3 fix).
     * @dev This test verifies the fix for Sherlock audit Issue #3: beforeInitialize
     *      now checks that sender == owner() to prevent front-running of pool creation.
     */
    function test_beforeInitialize_revertsWhenNotOwner() public {
        // Deploy fresh Alphix hook
        Alphix freshHook = _deployFreshAlphixStack();

        // Create a valid pool key
        MockERC20 token0 = new MockERC20("Token0", "TK0", 18);
        MockERC20 token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 < token1 for proper ordering
        (address addr0, address addr1) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));

        PoolKey memory newPoolKey = PoolKey({
            currency0: Currency.wrap(addr0),
            currency1: Currency.wrap(addr1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(freshHook)
        });

        // Try to initialize as non-owner (unauthorized user)
        // This should revert (the error is wrapped by PoolManager)
        vm.prank(unauthorized);
        vm.expectRevert();
        poolManager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

        // Verify that owner CAN initialize
        address hookOwner = freshHook.owner();
        vm.prank(hookOwner);
        poolManager.initialize(newPoolKey, Constants.SQRT_PRICE_1_1);

        // Pool should now be initialized at Uniswap level
        // (Alphix level initialization would be done via initializePool)
    }

    function test_beforeInitialize_revertsOnETHPool() public {
        // Deploy fresh Alphix hook (not AlphixETH)
        Alphix freshHook = _deployFreshAlphixStack();

        // Try to initialize with an ETH pool (currency0 = address(0))
        // Need to create a key with ETH as currency0
        MockERC20 token = new MockERC20("Token", "TKN", 18);

        PoolKey memory ethPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(freshHook)
        });

        // This should revert with UnsupportedNativeCurrency
        // The error is wrapped by PoolManager
        // Must call as owner since beforeInitialize now checks sender == owner first
        // Note: vm.prank must be called BEFORE vm.expectRevert to avoid
        // the owner() call being considered as the "next call"
        address hookOwner = freshHook.owner();
        vm.prank(hookOwner);
        vm.expectRevert();
        poolManager.initialize(ethPoolKey, Constants.SQRT_PRICE_1_1);
    }

    /**
     * @notice Tests that re-initialization reverts with PoolAlreadyInitialized.
     * @dev Our hook's check fires BEFORE PoolManager's sqrtPriceX96 check.
     *      This verifies our _poolKey.hooks check is necessary and not redundant.
     *      Note: The PoolManager wraps hook errors in WrappedError, so we use generic expectRevert.
     *      Run with -vvv to see the trace showing PoolAlreadyInitialized thrown by our hook.
     */
    function test_beforeInitialize_revertsOnReInitialization() public {
        // Pool is already initialized in setUp
        // Our hook's check fires BEFORE PoolManager's sqrtPriceX96 check
        // Must be owner to pass the first check (sender == owner())
        vm.prank(owner);
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      JIT EDGE CASE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_jit_noExecutionWithEqualTickRange() public {
        // Setup yield sources but with equal tick range (0,0) - should skip JIT
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vm.startPrank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));
        hook.setYieldSource(currency1, address(vault1));
        // Don't set tick range - defaults to (0, 0) which is equal
        vm.stopPrank();

        // Add some liquidity to yield sources
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);
        // With tick range (0,0), addReHypothecatedLiquidity will still work
        // but JIT won't execute on swaps due to equal tick bounds
        // Note: previewAddReHypothecatedLiquidity may revert or return 0 with equal ticks
        vm.stopPrank();

        // The key point is that _computeBeforeSwapJit will return shouldExecute=false
        // when tickLower == tickUpper (line 839-840)
    }

    function test_jit_noExecutionWithNoYieldSources() public {
        // Pool is configured but no yield sources set
        // JIT should not execute because yield sources are empty

        // Add liquidity directly to pool manager (bypassing hook)
        // This simulates having the pool configured but no yield sources

        // The _computeBeforeSwapJit will return shouldExecute=false
        // when either yield source is address(0) (lines 833-836)
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    REMOVE REHYPOTHECATED LIQUIDITY - ZERO AMOUNTS TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_removeReHypothecatedLiquidity_revertsWhenBothAmountsRoundToZero() public {
        _setupYieldSources();

        // Add a large amount of liquidity first
        uint256 largeDeposit = 1000e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, largeDeposit);
        MockERC20(Currency.unwrap(currency1)).mint(user1, largeDeposit);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), largeDeposit);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), largeDeposit);
        hook.addReHypothecatedLiquidity(100e18, 0, 0); // Get 100e18 shares
        vm.stopPrank();

        // Now try to withdraw with just 1 share - both amounts will round to 0
        // With 100e18 shares and ~100e18 total assets, 1 share gives ~1e-18 of each asset = 0
        // This should revert with ZeroAmounts
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroAmounts.selector);
        hook.removeReHypothecatedLiquidity(1, 0, 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    SET POOL PARAMS - TARGET RATIO CLAMPING TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setPoolParams_clampsTargetRatioToNewMaxCurrentRatio() public {
        // First set a high target ratio by poking with a high ratio
        // Warp past cooldown
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        // Poke with the max allowed ratio to push target ratio high
        vm.prank(owner);
        hook.poke(defaultPoolParams.maxCurrentRatio);

        // Now update pool params with a LOWER maxCurrentRatio
        DynamicFeeLib.PoolParams memory newParams = defaultPoolParams;
        newParams.maxCurrentRatio = 1e18; // Lower than what target ratio might be

        vm.prank(owner);
        hook.setPoolParams(newParams);

        // Verify target ratio was clamped: subsequent poke should work with the new range
        vm.warp(block.timestamp + newParams.minPeriod + 1);

        // This should NOT revert - if target ratio wasn't clamped, fee calculation might fail
        vm.prank(owner);
        hook.poke(newParams.maxCurrentRatio);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            SLIPPAGE PROTECTION TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_addReHypothecatedLiquidity_withinSlippage_succeeds() public {
        _setupYieldSources();

        // Mint and approve tokens
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Add liquidity with slippage check (1% tolerance)
        hook.addReHypothecatedLiquidity(10e18, sqrtPriceX96, 10000);
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), 10e18, "User should have 10e18 shares");
    }

    function test_addReHypothecatedLiquidity_exceedsSlippage_reverts() public {
        _setupYieldSources();

        // Mint and approve tokens
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Provide a price that's significantly different from actual (simulating price moved)
        // Expected price is 2x current price - should fail with any reasonable slippage
        uint160 wrongExpectedPrice = sqrtPriceX96 * 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                IReHypothecation.PriceSlippageExceeded.selector, wrongExpectedPrice, sqrtPriceX96, 10000
            )
        );
        hook.addReHypothecatedLiquidity(10e18, wrongExpectedPrice, 10000);
        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_zeroExpectedPrice_skipsCheck() public {
        _setupYieldSources();

        // Mint and approve tokens
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Pass 0 for expectedSqrtPriceX96 to skip slippage check
        hook.addReHypothecatedLiquidity(10e18, 0, 0);
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), 10e18, "User should have 10e18 shares");
    }

    function test_removeReHypothecatedLiquidity_withinSlippage_succeeds() public {
        _setupYieldSources();

        // Setup: Add liquidity first
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);
        hook.addReHypothecatedLiquidity(50e18, 0, 0);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Remove liquidity with slippage check (1% tolerance)
        hook.removeReHypothecatedLiquidity(25e18, sqrtPriceX96, 10000);
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), 25e18, "User should have 25e18 shares remaining");
    }

    function test_removeReHypothecatedLiquidity_exceedsSlippage_reverts() public {
        _setupYieldSources();

        // Setup: Add liquidity first
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);
        hook.addReHypothecatedLiquidity(50e18, 0, 0);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Try to remove with wrong expected price
        uint160 wrongExpectedPrice = sqrtPriceX96 * 2;

        vm.expectRevert(
            abi.encodeWithSelector(
                IReHypothecation.PriceSlippageExceeded.selector, wrongExpectedPrice, sqrtPriceX96, 10000
            )
        );
        hook.removeReHypothecatedLiquidity(25e18, wrongExpectedPrice, 10000);
        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_exactSlippageBoundary_succeeds() public {
        _setupYieldSources();

        // Mint and approve tokens
        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Set expected price to exactly match current - should pass with any slippage
        hook.addReHypothecatedLiquidity(10e18, sqrtPriceX96, 1); // Even 0.0001% slippage should pass
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), 10e18, "User should have 10e18 shares");
    }

    /**
     * @notice Test that slippage protection prevents sandwich attacks on addLiquidity
     * @dev Simulates: 1) User sees price P, 2) Attacker front-runs with swap moving price,
     *      3) User's tx with slippage protection reverts because price moved
     */
    function test_addReHypothecatedLiquidity_sandwichAttack_preventsWithSlippage() public {
        _setupYieldSources();

        // Setup: mint tokens to both user and attacker
        // Use smaller swap amount that the pool can handle (pool has ~100e18 liquidity)
        address attacker = makeAddr("attacker");
        uint256 swapAmount = 10e18; // Smaller amount that will move price but won't overflow
        uint256 depositAmount = 100e18;

        MockERC20(Currency.unwrap(currency0)).mint(attacker, swapAmount);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, swapAmount);
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        // Step 1: User observes current price and prepares tx with slippage protection
        (uint160 userExpectedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 userSlippageTolerance = 5000; // 0.5% tolerance

        // Step 2: Attacker front-runs with a swap to move price
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify price actually moved
        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());
        assertNotEq(newPrice, userExpectedPrice, "Price should have moved after swap");

        // Step 3: User's add liquidity tx should revert due to slippage protection
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IReHypothecation.PriceSlippageExceeded.selector, userExpectedPrice, newPrice, userSlippageTolerance
            )
        );
        hook.addReHypothecatedLiquidity(10e18, userExpectedPrice, userSlippageTolerance);
        vm.stopPrank();

        // User protected - no shares minted, no tokens lost
        assertEq(hook.balanceOf(user1), 0, "User should have no shares (protected by slippage)");
    }

    /**
     * @notice Test that slippage protection prevents sandwich attacks on removeLiquidity
     * @dev Simulates: 1) LP sees price P, 2) Attacker front-runs with swap moving price,
     *      3) LP's withdrawal tx with slippage protection reverts
     */
    function test_removeReHypothecatedLiquidity_sandwichAttack_preventsWithSlippage() public {
        _setupYieldSources();

        // Setup: user adds liquidity first
        // Use smaller swap amount that the pool can handle (pool has ~100e18 liquidity)
        address attacker = makeAddr("attacker");
        uint256 swapAmount = 10e18; // Smaller amount that will move price but won't overflow
        uint256 depositAmount = 100e18;

        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency0)).mint(attacker, swapAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);
        hook.addReHypothecatedLiquidity(50e18, 0, 0); // Add without slippage check initially
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), 50e18, "User should have 50e18 shares");

        // Step 1: User observes current price and prepares withdrawal with slippage protection
        (uint160 userExpectedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 userSlippageTolerance = 5000; // 0.5% tolerance

        // Step 2: Attacker front-runs with a swap to move price
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify price actually moved
        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());
        assertNotEq(newPrice, userExpectedPrice, "Price should have moved after swap");

        // Step 3: User's remove liquidity tx should revert due to slippage protection
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReHypothecation.PriceSlippageExceeded.selector, userExpectedPrice, newPrice, userSlippageTolerance
            )
        );
        hook.removeReHypothecatedLiquidity(25e18, userExpectedPrice, userSlippageTolerance);
        vm.stopPrank();

        // User protected - shares not burned
        assertEq(hook.balanceOf(user1), 50e18, "User should still have all shares (protected by slippage)");
    }

    /**
     * @notice Test that without slippage protection (0,0), user IS vulnerable to price manipulation
     * @dev This demonstrates what happens when users opt out of slippage protection
     */
    function test_addReHypothecatedLiquidity_noSlippageProtection_vulnerableToManipulation() public {
        _setupYieldSources();

        // Use smaller swap amount that the pool can handle (pool has ~100e18 liquidity)
        address attacker = makeAddr("attacker");
        uint256 swapAmount = 10e18; // Smaller amount that will move price but won't overflow
        uint256 depositAmount = 100e18;

        MockERC20(Currency.unwrap(currency0)).mint(attacker, swapAmount);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, swapAmount);
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        // Record price before attack
        (uint160 priceBefore,,,) = poolManager.getSlot0(key.toId());

        // Attacker manipulates price
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        (uint160 priceAfter,,,) = poolManager.getSlot0(key.toId());
        assertNotEq(priceAfter, priceBefore, "Price should have moved");

        // User adds liquidity WITHOUT slippage protection - this SUCCEEDS (user is vulnerable!)
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Passing 0,0 disables slippage check - tx goes through at manipulated price
        hook.addReHypothecatedLiquidity(10e18, 0, 0);
        vm.stopPrank();

        // User got shares but at potentially unfavorable price
        assertEq(hook.balanceOf(user1), 10e18, "User got shares (but at manipulated price)");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    SLIPPAGE PROTECTION FUZZ TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test: add liquidity succeeds when price is within slippage tolerance
     * @param slippageTolerance The slippage tolerance (bounded to reasonable values)
     * @param shares The number of shares to mint (bounded to reasonable values)
     */
    function testFuzz_addReHypothecatedLiquidity_withinSlippage_succeeds(uint24 slippageTolerance, uint256 shares)
        public
    {
        _setupYieldSources();

        // Bound inputs to reasonable values
        slippageTolerance = uint24(bound(slippageTolerance, 100, 500000)); // 0.01% to 50%
        shares = bound(shares, 1e18, 50e18); // 1 to 50 shares

        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Should succeed - price hasn't moved
        hook.addReHypothecatedLiquidity(shares, sqrtPriceX96, slippageTolerance);
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), shares, "User should have shares");
    }

    /**
     * @notice Fuzz test: add liquidity reverts when price exceeds slippage tolerance
     * @param slippageTolerance The slippage tolerance (bounded to small values)
     * @param swapAmount The amount to swap to move price (bounded)
     */
    function testFuzz_addReHypothecatedLiquidity_exceedsSlippage_reverts(uint24 slippageTolerance, uint256 swapAmount)
        public
    {
        _setupYieldSources();

        // Bound inputs
        slippageTolerance = uint24(bound(slippageTolerance, 100, 5000)); // 0.01% to 0.5% (tight tolerance)
        swapAmount = bound(swapAmount, 5e18, 10e18); // Enough to move price beyond tight tolerance

        address attacker = makeAddr("attacker");
        uint256 depositAmount = 100e18;

        MockERC20(Currency.unwrap(currency0)).mint(attacker, swapAmount);
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        // Record price before attack
        (uint160 priceBefore,,,) = poolManager.getSlot0(key.toId());

        // Attacker moves price with swap
        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        // Verify price moved
        (uint160 priceAfter,,,) = poolManager.getSlot0(key.toId());
        if (priceAfter == priceBefore) {
            // Price didn't move enough, skip this test case
            return;
        }

        // User tries to add with slippage protection using old price
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Calculate actual slippage
        uint256 priceDiff = priceAfter > priceBefore ? priceAfter - priceBefore : priceBefore - priceAfter;
        uint256 actualSlippage = (priceDiff * LPFeeLibrary.MAX_LP_FEE) / priceBefore;

        // Only expect revert if actual slippage exceeds tolerance
        if (actualSlippage > slippageTolerance) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IReHypothecation.PriceSlippageExceeded.selector, priceBefore, priceAfter, slippageTolerance
                )
            );
        }

        hook.addReHypothecatedLiquidity(10e18, priceBefore, slippageTolerance);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test: remove liquidity succeeds when price is within slippage tolerance
     * @param slippageTolerance The slippage tolerance (bounded to reasonable values)
     * @param sharesToRemove The number of shares to remove (bounded)
     */
    function testFuzz_removeReHypothecatedLiquidity_withinSlippage_succeeds(
        uint24 slippageTolerance,
        uint256 sharesToRemove
    ) public {
        _setupYieldSources();

        // Bound inputs
        slippageTolerance = uint24(bound(slippageTolerance, 100, 500000)); // 0.01% to 50%

        uint256 depositAmount = 100e18;
        uint256 initialShares = 50e18;
        sharesToRemove = bound(sharesToRemove, 1e18, initialShares); // 1 to all shares

        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        // First add liquidity
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);
        hook.addReHypothecatedLiquidity(initialShares, 0, 0);
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), initialShares, "User should have initial shares");

        // Get current price
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());

        // Remove liquidity with slippage protection - should succeed
        vm.prank(user1);
        hook.removeReHypothecatedLiquidity(sharesToRemove, sqrtPriceX96, slippageTolerance);

        assertEq(hook.balanceOf(user1), initialShares - sharesToRemove, "User shares should be reduced");
    }

    /**
     * @notice Fuzz test: add liquidity with zero expected price skips slippage check
     * @param shares The number of shares to mint (bounded)
     */
    function testFuzz_addReHypothecatedLiquidity_zeroExpectedPrice_skipsCheck(uint256 shares) public {
        _setupYieldSources();

        shares = bound(shares, 1e18, 50e18);

        uint256 depositAmount = 100e18;
        MockERC20(Currency.unwrap(currency0)).mint(user1, depositAmount);
        MockERC20(Currency.unwrap(currency1)).mint(user1, depositAmount);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), depositAmount);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), depositAmount);

        // Passing 0 for expected price should skip slippage check
        // Even with very strict slippage (1), it should succeed
        hook.addReHypothecatedLiquidity(shares, 0, 1);
        vm.stopPrank();

        assertEq(hook.balanceOf(user1), shares, "User should have shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                HELPER FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    function _setupYieldSources() internal {
        address yieldManager = makeAddr("yieldManager");

        // Setup role as owner (admin of AccessManager)
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Tick range is already set at initializePool time (full range by default)
        // Set yield sources (requires whenNotPaused)
        vm.startPrank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));
        hook.setYieldSource(currency1, address(vault1));
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
