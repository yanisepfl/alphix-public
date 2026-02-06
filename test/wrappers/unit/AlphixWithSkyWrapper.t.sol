// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {console2} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../alphix/BaseAlphix.t.sol";
import {Alphix} from "../../../src/Alphix.sol";
import {EasyPosm} from "../../utils/libraries/EasyPosm.sol";

/* SKY WRAPPER IMPORTS */
import {Alphix4626WrapperSky} from "../../../src/wrappers/sky/Alphix4626WrapperSky.sol";
import {MockPSM3} from "../sky/mocks/MockPSM3.sol";
import {MockRateProvider} from "../sky/mocks/MockRateProvider.sol";
import {MockERC20 as SkyMockERC20} from "../sky/mocks/MockERC20.sol";

/**
 * @title AlphixWithSkyWrapperTest
 * @notice Unit tests for Alphix hook integration with Alphix4626WrapperSky as yield source.
 * @dev Tests that the Alphix hook correctly uses the real Sky wrapper for JIT liquidity
 *      rehypothecation rather than a simple mock vault.
 *
 *      Key differences from Aave wrapper tests:
 *      - Uses PSM for swaps (USDS -> sUSDS)
 *      - Rate provider tracks sUSDS/USDS rate (27 decimals)
 *      - Yield comes from rate appreciation, not rebasing
 *      - Fees collected in sUSDS, not the underlying asset
 */
contract AlphixWithSkyWrapperTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    /* STATE */

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;

    /// @notice Sky wrapper for currency0
    Alphix4626WrapperSky public skyWrapper0;
    /// @notice Sky wrapper for currency1
    Alphix4626WrapperSky public skyWrapper1;

    /// @notice Mock PSM3 for currency0
    MockPSM3 public psm0;
    /// @notice Mock PSM3 for currency1
    MockPSM3 public psm1;

    /// @notice Mock rate providers
    MockRateProvider public rateProvider0;
    MockRateProvider public rateProvider1;

    /// @notice Mock sUSDS tokens (savings tokens)
    SkyMockERC20 public susds0;
    SkyMockERC20 public susds1;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    /// @notice Default fee for wrappers: 10% (100_000 hundredths of a bip)
    uint24 internal constant WRAPPER_FEE = 100_000;
    /// @notice Seed liquidity for wrapper deployment
    uint256 internal constant SEED_LIQUIDITY = 1e18;
    /// @notice Rate precision (27 decimals)
    uint256 internal constant RATE_PRECISION = 1e27;

    /* SETUP */

    function setUp() public override {
        super.setUp();

        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Fund users with tokens
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);

        // Setup yield manager role
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Deploy Sky infrastructure
        _deploySkyInfrastructure();

        // Deploy Sky wrappers for both currencies
        _deploySkyWrappers();

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /**
     * @notice Deploys mock Sky infrastructure (PSM3, rate providers, sUSDS tokens).
     */
    function _deploySkyInfrastructure() internal {
        // Deploy mock sUSDS tokens (18 decimals)
        susds0 = new SkyMockERC20("Savings Token0", "sToken0", 18);
        susds1 = new SkyMockERC20("Savings Token1", "sToken1", 18);

        // Deploy mock rate providers (starting at 1:1)
        rateProvider0 = new MockRateProvider();
        rateProvider1 = new MockRateProvider();

        // Deploy mock PSM3s
        // Note: PSM3 requires underlying token (USDS-like) and savings token (sUSDS-like)
        psm0 = new MockPSM3(Currency.unwrap(currency0), address(susds0), address(rateProvider0));
        psm1 = new MockPSM3(Currency.unwrap(currency1), address(susds1), address(rateProvider1));

        // Fund PSMs with liquidity for swaps (both directions)
        susds0.mint(address(psm0), 1_000_000_000e18);
        susds1.mint(address(psm1), 1_000_000_000e18);
        MockERC20(Currency.unwrap(currency0)).mint(address(psm0), 1_000_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(psm1), 1_000_000_000e18);
    }

    /**
     * @notice Deploys Sky wrappers for currency0 and currency1, adding hook as authorized.
     */
    function _deploySkyWrappers() internal {
        vm.startPrank(owner);

        // Fund owner for seed liquidity
        MockERC20(Currency.unwrap(currency0)).mint(owner, SEED_LIQUIDITY);
        MockERC20(Currency.unwrap(currency1)).mint(owner, SEED_LIQUIDITY);

        // Deploy wrapper0
        uint256 nonce0 = vm.getNonce(owner);
        address expectedWrapper0 = vm.computeCreateAddress(owner, nonce0);
        MockERC20(Currency.unwrap(currency0)).approve(expectedWrapper0, type(uint256).max);

        skyWrapper0 = new Alphix4626WrapperSky(
            address(psm0), treasury, "Alphix sToken0 Vault", "alphsToken0", WRAPPER_FEE, SEED_LIQUIDITY, 0
        );

        // Add Alphix hook as authorized hook on wrapper0
        skyWrapper0.addAlphixHook(address(hook));

        // Deploy wrapper1
        uint256 nonce1 = vm.getNonce(owner);
        address expectedWrapper1 = vm.computeCreateAddress(owner, nonce1);
        MockERC20(Currency.unwrap(currency1)).approve(expectedWrapper1, type(uint256).max);

        skyWrapper1 = new Alphix4626WrapperSky(
            address(psm1), treasury, "Alphix sToken1 Vault", "alphsToken1", WRAPPER_FEE, SEED_LIQUIDITY, 0
        );

        // Add Alphix hook as authorized hook on wrapper1
        skyWrapper1.addAlphixHook(address(hook));

        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        YIELD SOURCE CONFIGURATION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that Sky wrappers can be set as yield sources.
     */
    function test_setYieldSource_skyWrapper_succeeds() public {
        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(skyWrapper0));
        Alphix(address(hook)).setYieldSource(currency1, address(skyWrapper1));
        vm.stopPrank();

        // Verify yield sources are set
        assertEq(
            Alphix(address(hook)).getCurrencyYieldSource(currency0),
            address(skyWrapper0),
            "Wrapper0 should be yield source"
        );
        assertEq(
            Alphix(address(hook)).getCurrencyYieldSource(currency1),
            address(skyWrapper1),
            "Wrapper1 should be yield source"
        );
    }

    /**
     * @notice Test that hook is correctly authorized on wrappers.
     */
    function test_hookIsAuthorizedOnWrapper() public view {
        assertTrue(skyWrapper0.isAlphixHook(address(hook)), "Hook should be authorized on wrapper0");
        assertTrue(skyWrapper1.isAlphixHook(address(hook)), "Hook should be authorized on wrapper1");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        DEPOSIT/WITHDRAW THROUGH REHYPO TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that addReHypothecatedLiquidity deposits to Sky wrappers.
     */
    function test_addReHypoLiquidity_depositsToSkyWrapper() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        uint256 shares = 100e18;
        Alphix(address(hook)).previewAddReHypothecatedLiquidity(shares);

        uint256 wrapperShares0Before = skyWrapper0.balanceOf(address(hook));
        uint256 wrapperShares1Before = skyWrapper1.balanceOf(address(hook));

        _addReHypoLiquidity(alice, shares);

        uint256 wrapperShares0After = skyWrapper0.balanceOf(address(hook));
        uint256 wrapperShares1After = skyWrapper1.balanceOf(address(hook));

        // Hook should have received wrapper shares
        assertGt(wrapperShares0After, wrapperShares0Before, "Hook should have wrapper0 shares");
        assertGt(wrapperShares1After, wrapperShares1Before, "Hook should have wrapper1 shares");

        // Verify assets actually landed in sUSDS (via wrapper's sUSDS balance)
        uint256 susds0Balance = susds0.balanceOf(address(skyWrapper0));
        uint256 susds1Balance = susds1.balanceOf(address(skyWrapper1));

        assertGt(susds0Balance, 0, "Wrapper0 should have sUSDS");
        assertGt(susds1Balance, 0, "Wrapper1 should have sUSDS");
    }

    /**
     * @notice Test that removeReHypothecatedLiquidity withdraws from Sky wrappers.
     */
    function test_removeReHypoLiquidity_withdrawsFromSkyWrapper() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 aliceToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceToken1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        (uint256 previewAmount0, uint256 previewAmount1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        uint256 aliceToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 aliceToken1After = MockERC20(Currency.unwrap(currency1)).balanceOf(alice);

        // Alice should receive tokens back
        assertApproxEqRel(aliceToken0After - aliceToken0Before, previewAmount0, 1e16, "Alice should get token0 back");
        assertApproxEqRel(aliceToken1After - aliceToken1Before, previewAmount1, 1e16, "Alice should get token1 back");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        RATE-BASED YIELD TRACKING TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that rate appreciation increases hook's redeemable value.
     */
    function test_rateAppreciation_increasesShareValue() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        (uint256 previewBefore0, uint256 previewBefore1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Simulate 10% rate appreciation on both wrappers
        rateProvider0.simulateYield(10);
        rateProvider1.simulateYield(10);

        // Sync rate to bypass circuit breaker (> 1% rate change)
        vm.startPrank(owner);
        skyWrapper0.syncRate();
        skyWrapper1.syncRate();
        vm.stopPrank();

        (uint256 previewAfter0, uint256 previewAfter1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // After rate appreciation, withdrawal preview should show more
        // Note: Wrapper takes a fee on yield, so increase will be less than 10%
        assertGt(previewAfter0, previewBefore0, "Token0 value should increase with rate appreciation");
        assertGt(previewAfter1, previewBefore1, "Token1 value should increase with rate appreciation");
    }

    /**
     * @notice Test that getAmountInYieldSource reflects current rate value.
     */
    function test_getAmountInYieldSource_reflectsRateValue() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 amount0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 amount1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Simulate 10% rate appreciation
        rateProvider0.simulateYield(10);
        rateProvider1.simulateYield(10);

        // Sync rate to bypass circuit breaker (> 1% rate change)
        vm.startPrank(owner);
        skyWrapper0.syncRate();
        skyWrapper1.syncRate();
        vm.stopPrank();

        uint256 amount0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 amount1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Amount should reflect rate appreciation (minus wrapper fee)
        assertGt(amount0After, amount0Before, "Amount0 in yield source should increase");
        assertGt(amount1After, amount1Before, "Amount1 in yield source should increase");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        SWAP WITH JIT FROM SKY WRAPPER TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that swaps use JIT liquidity from Sky wrapper.
     */
    function test_swap_usesJitFromSkyWrapper() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Bob swaps token0 -> token1
        uint256 swapAmount = 10e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // JIT participation: for zeroForOne swap, yield source gains token0, loses token1
        assertGt(yieldSource0After, yieldSource0Before, "Yield source should gain token0 from swap");
        assertLt(yieldSource1After, yieldSource1Before, "Yield source should lose token1 from swap");
    }

    /**
     * @notice Test swap in opposite direction.
     */
    function test_swap_reverseDirection_usesJitFromSkyWrapper() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Bob swaps token1 -> token0
        uint256 swapAmount = 10e18;
        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), swapAmount);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: bob,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();

        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // JIT participation: for oneForZero swap, yield source gains token1, loses token0
        assertLt(yieldSource0After, yieldSource0Before, "Yield source should lose token0 from swap");
        assertGt(yieldSource1After, yieldSource1Before, "Yield source should gain token1 from swap");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        WRAPPER FEE TESTS (IN sUSDS)
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that wrapper fees are deducted in sUSDS from yield.
     */
    function test_wrapperFees_deductedFromYieldInSusds() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 amount0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);

        // Simulate 10% rate appreciation
        rateProvider0.simulateYield(10);

        // Sync rate to bypass circuit breaker (> 1% rate change)
        vm.prank(owner);
        skyWrapper0.syncRate();

        uint256 amount0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldReceived = amount0After - amount0Before;

        // Expected yield without fees would be ~10%
        uint256 grossYield = (amount0Before * 10) / 100;

        // Wrapper takes WRAPPER_FEE (10%) of yield, so net yield = 90% of gross
        // Allow some tolerance for PSM swap rounding
        assertApproxEqRel(yieldReceived, (grossYield * 90) / 100, 5e16, "Net yield should be ~90% of gross");
    }

    /**
     * @notice Test that wrapper fee collection doesn't break hook accounting.
     * @dev Uses 5% yield changes which requires syncRate() to bypass circuit breaker (threshold is 1%).
     */
    function test_wrapperFeeCollection_maintainsHookAccounting() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        // Simulate yield (5% exceeds the 1% circuit breaker threshold)
        rateProvider0.simulateYield(5);
        rateProvider1.simulateYield(5);

        // Sync rate to bypass circuit breaker, then trigger accrual by calling setFee
        vm.startPrank(owner);
        skyWrapper0.syncRate();
        skyWrapper1.syncRate();
        skyWrapper0.setFee(WRAPPER_FEE);
        skyWrapper1.setFee(WRAPPER_FEE);
        vm.stopPrank();

        // Record hook's share value before fee collection
        (uint256 previewBefore0, uint256 previewBefore1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Collect fees from wrappers (fees collected in sUSDS)
        vm.startPrank(owner);
        skyWrapper0.collectFees();
        skyWrapper1.collectFees();
        vm.stopPrank();

        // Record hook's share value after fee collection
        (uint256 previewAfter0, uint256 previewAfter1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Hook's redeemable value should remain the same (fees were already deducted from totalAssets)
        assertApproxEqRel(previewAfter0, previewBefore0, 1e15, "Token0 value should be unchanged after fee collection");
        assertApproxEqRel(previewAfter1, previewBefore1, 1e15, "Token1 value should be unchanged after fee collection");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        SHARE ACCOUNTING TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that user shares correctly track through hook -> wrapper -> sUSDS.
     */
    function test_shareAccounting_throughAllLayers() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        uint256 shares = 100e18;
        _addReHypoLiquidity(alice, shares);

        // Layer 1: User shares in hook
        uint256 aliceHookShares = Alphix(address(hook)).balanceOf(alice);
        assertEq(aliceHookShares, shares, "Alice should have hook shares");

        // Layer 2: Hook shares in wrappers
        uint256 hookWrapper0Shares = skyWrapper0.balanceOf(address(hook));
        uint256 hookWrapper1Shares = skyWrapper1.balanceOf(address(hook));
        assertGt(hookWrapper0Shares, 0, "Hook should have wrapper0 shares");
        assertGt(hookWrapper1Shares, 0, "Hook should have wrapper1 shares");

        // Layer 3: Wrapper sUSDS holdings
        uint256 wrapper0Susds = susds0.balanceOf(address(skyWrapper0));
        uint256 wrapper1Susds = susds1.balanceOf(address(skyWrapper1));
        assertGt(wrapper0Susds, 0, "Wrapper0 should have sUSDS");
        assertGt(wrapper1Susds, 0, "Wrapper1 should have sUSDS");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        NEGATIVE YIELD (RATE DECREASE) TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that rate decrease (negative yield) decreases share value.
     */
    function test_rateDecrease_decreasesShareValue() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        (uint256 previewBefore0, uint256 previewBefore1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Simulate 20% rate decrease (slash) on both wrappers
        rateProvider0.simulateSlash(20);
        rateProvider1.simulateSlash(20);

        // Sync rate to bypass circuit breaker (> 1% rate change)
        vm.startPrank(owner);
        skyWrapper0.syncRate();
        skyWrapper1.syncRate();
        vm.stopPrank();

        (uint256 previewAfter0, uint256 previewAfter1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Value should decrease by ~20%
        assertApproxEqRel(previewAfter0, (previewBefore0 * 80) / 100, 2e16, "Token0 should show ~20% loss");
        assertApproxEqRel(previewAfter1, (previewBefore1 * 80) / 100, 2e16, "Token1 should show ~20% loss");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        PSM SWAP VERIFICATION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that deposits go through PSM correctly.
     */
    function test_deposit_goesThruPsm() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        uint256 psm0SusdsBefore = susds0.balanceOf(address(skyWrapper0));

        _addReHypoLiquidity(alice, 100e18);

        uint256 psm0SusdsAfter = susds0.balanceOf(address(skyWrapper0));

        // Wrapper should have gained sUSDS via PSM swap
        assertGt(psm0SusdsAfter, psm0SusdsBefore, "Wrapper should have more sUSDS after deposit");
    }

    /**
     * @notice Test that withdrawals go through PSM correctly.
     */
    function test_withdraw_goesThruPsm() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 wrapper0SusdsBefore = susds0.balanceOf(address(skyWrapper0));

        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(50e18, 0, 0);

        uint256 wrapper0SusdsAfter = susds0.balanceOf(address(skyWrapper0));

        // Wrapper should have less sUSDS (swapped back to underlying via PSM)
        assertLt(wrapper0SusdsAfter, wrapper0SusdsBefore, "Wrapper should have less sUSDS after withdrawal");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _configureReHypo() internal {
        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(skyWrapper0));
        Alphix(address(hook)).setYieldSource(currency1, address(skyWrapper1));
        vm.stopPrank();
    }

    function _addRegularLp(uint256 amount) internal {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(
            Currency.unwrap(currency0), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );
        permit2.approve(
            Currency.unwrap(currency1), address(positionManager), type(uint160).max, uint48(block.timestamp + 100)
        );

        positionManager.mint(
            key,
            fullRangeLower,
            fullRangeUpper,
            amount,
            amount,
            amount * 2,
            owner,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );
        vm.stopPrank();
    }

    function _addReHypoLiquidity(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) = Alphix(address(hook)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), amount1);
        Alphix(address(hook)).addReHypothecatedLiquidity(shares, 0, 0);
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
