// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../alphix/BaseAlphix.t.sol";
import {Alphix} from "../../../src/Alphix.sol";
import {EasyPosm} from "../../utils/libraries/EasyPosm.sol";

/* AAVE WRAPPER IMPORTS */
import {Alphix4626WrapperAave} from "../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {MockAToken} from "../aave/mocks/MockAToken.sol";
import {MockAavePool} from "../aave/mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "../aave/mocks/MockPoolAddressesProvider.sol";

/**
 * @title AlphixWithAaveWrapperTest
 * @notice Unit tests for Alphix hook integration with Alphix4626WrapperAave as yield source.
 * @dev Tests that the Alphix hook correctly uses the real Aave wrapper for JIT liquidity
 *      rehypothecation rather than a simple mock vault.
 */
contract AlphixWithAaveWrapperTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    /* STATE */

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;

    /// @notice Aave wrapper for currency0
    Alphix4626WrapperAave public aaveWrapper0;
    /// @notice Aave wrapper for currency1
    Alphix4626WrapperAave public aaveWrapper1;

    /// @notice Mock Aave pool
    MockAavePool public aavePool;
    /// @notice Mock aToken for currency0
    MockAToken public aToken0;
    /// @notice Mock aToken for currency1
    MockAToken public aToken1;
    /// @notice Mock pool addresses provider
    MockPoolAddressesProvider public poolAddressesProvider;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    /// @notice Default fee for wrappers: 10% (100_000 hundredths of a bip)
    uint24 internal constant WRAPPER_FEE = 100_000;
    /// @notice Seed liquidity for wrapper deployment
    uint256 internal constant SEED_LIQUIDITY = 1e18;

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

        // Deploy Aave infrastructure
        _deployAaveInfrastructure();

        // Deploy Aave wrappers for both currencies
        _deployAaveWrappers();

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    /**
     * @notice Deploys mock Aave infrastructure (pool, aTokens, provider).
     */
    function _deployAaveInfrastructure() internal {
        // Deploy mock Aave pool
        aavePool = new MockAavePool();

        // Deploy mock aTokens with 18 decimals (matching our test tokens)
        aToken0 = new MockAToken("Aave Token0", "aToken0", 18, Currency.unwrap(currency0), address(aavePool));
        aToken1 = new MockAToken("Aave Token1", "aToken1", 18, Currency.unwrap(currency1), address(aavePool));

        // Initialize reserves in pool
        aavePool.initReserve(Currency.unwrap(currency0), address(aToken0), true, false, false, 0);
        aavePool.initReserve(Currency.unwrap(currency1), address(aToken1), true, false, false, 0);

        // Deploy mock pool addresses provider
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));
    }

    /**
     * @notice Deploys Aave wrappers for currency0 and currency1, adding hook as authorized.
     */
    function _deployAaveWrappers() internal {
        vm.startPrank(owner);

        // Fund owner for seed liquidity
        MockERC20(Currency.unwrap(currency0)).mint(owner, SEED_LIQUIDITY);
        MockERC20(Currency.unwrap(currency1)).mint(owner, SEED_LIQUIDITY);

        // Deploy wrapper0
        uint256 nonce0 = vm.getNonce(owner);
        address expectedWrapper0 = vm.computeCreateAddress(owner, nonce0);
        MockERC20(Currency.unwrap(currency0)).approve(expectedWrapper0, type(uint256).max);

        aaveWrapper0 = new Alphix4626WrapperAave(
            Currency.unwrap(currency0),
            treasury,
            address(poolAddressesProvider),
            "Alphix aToken0 Vault",
            "alphAToken0",
            WRAPPER_FEE,
            SEED_LIQUIDITY
        );

        // Add Alphix hook as authorized hook on wrapper0
        aaveWrapper0.addAlphixHook(address(hook));

        // Deploy wrapper1
        uint256 nonce1 = vm.getNonce(owner);
        address expectedWrapper1 = vm.computeCreateAddress(owner, nonce1);
        MockERC20(Currency.unwrap(currency1)).approve(expectedWrapper1, type(uint256).max);

        aaveWrapper1 = new Alphix4626WrapperAave(
            Currency.unwrap(currency1),
            treasury,
            address(poolAddressesProvider),
            "Alphix aToken1 Vault",
            "alphAToken1",
            WRAPPER_FEE,
            SEED_LIQUIDITY
        );

        // Add Alphix hook as authorized hook on wrapper1
        aaveWrapper1.addAlphixHook(address(hook));

        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        YIELD SOURCE CONFIGURATION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that Aave wrappers can be set as yield sources.
     */
    function test_setYieldSource_aaveWrapper_succeeds() public {
        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(aaveWrapper0));
        Alphix(address(hook)).setYieldSource(currency1, address(aaveWrapper1));
        vm.stopPrank();

        // Verify yield sources are set
        assertEq(
            Alphix(address(hook)).getCurrencyYieldSource(currency0),
            address(aaveWrapper0),
            "Wrapper0 should be yield source"
        );
        assertEq(
            Alphix(address(hook)).getCurrencyYieldSource(currency1),
            address(aaveWrapper1),
            "Wrapper1 should be yield source"
        );
    }

    /**
     * @notice Test that hook is correctly authorized on wrappers.
     */
    function test_hookIsAuthorizedOnWrapper() public view {
        assertTrue(aaveWrapper0.isAlphixHook(address(hook)), "Hook should be authorized on wrapper0");
        assertTrue(aaveWrapper1.isAlphixHook(address(hook)), "Hook should be authorized on wrapper1");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        DEPOSIT/WITHDRAW THROUGH REHYPO TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that addReHypothecatedLiquidity deposits to Aave wrappers.
     */
    function test_addReHypoLiquidity_depositsToAaveWrapper() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = Alphix(address(hook)).previewAddReHypothecatedLiquidity(shares);

        uint256 wrapperShares0Before = aaveWrapper0.balanceOf(address(hook));
        uint256 wrapperShares1Before = aaveWrapper1.balanceOf(address(hook));

        _addReHypoLiquidity(alice, shares);

        uint256 wrapperShares0After = aaveWrapper0.balanceOf(address(hook));
        uint256 wrapperShares1After = aaveWrapper1.balanceOf(address(hook));

        // Hook should have received wrapper shares
        assertGt(wrapperShares0After, wrapperShares0Before, "Hook should have wrapper0 shares");
        assertGt(wrapperShares1After, wrapperShares1Before, "Hook should have wrapper1 shares");

        // Verify assets actually landed in Aave (via aToken balance)
        uint256 aToken0Balance = aToken0.balanceOf(address(aaveWrapper0));
        uint256 aToken1Balance = aToken1.balanceOf(address(aaveWrapper1));

        assertGe(aToken0Balance, amount0, "Wrapper0 should have aTokens");
        assertGe(aToken1Balance, amount1, "Wrapper1 should have aTokens");
    }

    /**
     * @notice Test that removeReHypothecatedLiquidity withdraws from Aave wrappers.
     */
    function test_removeReHypoLiquidity_withdrawsFromAaveWrapper() public {
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
                        YIELD ACCRUAL TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that yield accrual in Aave increases hook's redeemable value.
     */
    function test_yieldAccrual_increasesShareValue() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        (uint256 previewBefore0, uint256 previewBefore1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Simulate 10% yield on both Aave wrappers
        _simulateAaveYield(10);

        (uint256 previewAfter0, uint256 previewAfter1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // After yield, withdrawal preview should show more
        // Note: Wrapper takes a fee on yield, so increase will be less than 10%
        assertGt(previewAfter0, previewBefore0, "Token0 value should increase with yield");
        assertGt(previewAfter1, previewBefore1, "Token1 value should increase with yield");
    }

    /**
     * @notice Test that getAmountInYieldSource reflects current Aave value.
     */
    function test_getAmountInYieldSource_reflectsAaveValue() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 amount0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 amount1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Simulate 10% yield
        _simulateAaveYield(10);

        uint256 amount0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 amount1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Amount should reflect yield (minus wrapper fee)
        assertGt(amount0After, amount0Before, "Amount0 in yield source should increase");
        assertGt(amount1After, amount1Before, "Amount1 in yield source should increase");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        SWAP WITH JIT FROM AAVE WRAPPER TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that swaps use JIT liquidity from Aave wrapper.
     */
    function test_swap_usesJitFromAaveWrapper() public {
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
    function test_swap_reverseDirection_usesJitFromAaveWrapper() public {
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
                        WRAPPER FEE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that wrapper fees are deducted correctly from yield.
     */
    function test_wrapperFees_deductedFromYield() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        uint256 amount0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);

        // Simulate 10% yield
        _simulateAaveYield(10);

        uint256 amount0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldReceived = amount0After - amount0Before;

        // Expected yield without fees would be ~10%
        uint256 grossYield = (amount0Before * 10) / 100;

        // Wrapper takes WRAPPER_FEE (10%) of yield, so net yield = 90% of gross
        // Allow some tolerance for rounding
        assertApproxEqRel(yieldReceived, (grossYield * 90) / 100, 5e16, "Net yield should be 90% of gross");
    }

    /**
     * @notice Test that wrapper fee collection doesn't break hook accounting.
     */
    function test_wrapperFeeCollection_maintainsHookAccounting() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        // Simulate yield
        _simulateAaveYield(10);

        // Record hook's share value before fee collection
        (uint256 previewBefore0, uint256 previewBefore1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Collect fees from wrappers
        vm.startPrank(owner);
        aaveWrapper0.collectFees();
        aaveWrapper1.collectFees();
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
     * @notice Test that user shares correctly track through hook -> wrapper -> Aave.
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
        uint256 hookWrapper0Shares = aaveWrapper0.balanceOf(address(hook));
        uint256 hookWrapper1Shares = aaveWrapper1.balanceOf(address(hook));
        assertGt(hookWrapper0Shares, 0, "Hook should have wrapper0 shares");
        assertGt(hookWrapper1Shares, 0, "Hook should have wrapper1 shares");

        // Layer 3: Wrapper aTokens in Aave
        uint256 wrapper0ATokens = aToken0.balanceOf(address(aaveWrapper0));
        uint256 wrapper1ATokens = aToken1.balanceOf(address(aaveWrapper1));
        assertGt(wrapper0ATokens, 0, "Wrapper0 should have aTokens");
        assertGt(wrapper1ATokens, 0, "Wrapper1 should have aTokens");
    }

    /**
     * @notice Test that total value is conserved across all layers.
     */
    function test_totalValueConserved_acrossLayers() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        uint256 shares = 100e18;
        Alphix(address(hook)).previewAddReHypothecatedLiquidity(shares);

        uint256 totalToken0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(alice)
            + aToken0.balanceOf(address(aaveWrapper0)) + MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook));

        _addReHypoLiquidity(alice, shares);

        uint256 totalToken0After = MockERC20(Currency.unwrap(currency0)).balanceOf(alice)
            + aToken0.balanceOf(address(aaveWrapper0)) + MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook));

        // Total should be conserved (Alice gave tokens, Aave received them)
        assertApproxEqAbs(totalToken0Before, totalToken0After, 2, "Total token0 should be conserved");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        NEGATIVE YIELD (SLASH) TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that negative yield (slash) decreases share value.
     */
    function test_negativeYield_decreasesShareValue() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        (uint256 previewBefore0, uint256 previewBefore1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Simulate 20% slash on both wrappers
        _simulateAaveSlash(20);

        (uint256 previewAfter0, uint256 previewAfter1) =
            Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        // Value should decrease by ~20%
        assertApproxEqRel(previewAfter0, (previewBefore0 * 80) / 100, 2e16, "Token0 should show 20% loss");
        assertApproxEqRel(previewAfter1, (previewBefore1 * 80) / 100, 2e16, "Token1 should show 20% loss");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    function _configureReHypo() internal {
        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(aaveWrapper0));
        Alphix(address(hook)).setYieldSource(currency1, address(aaveWrapper1));
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

    /**
     * @notice Simulates yield accrual in Aave wrappers.
     * @param yieldPercent The yield percentage (e.g., 10 for 10%).
     */
    function _simulateAaveYield(uint256 yieldPercent) internal {
        uint256 currentBalance0 = aToken0.balanceOf(address(aaveWrapper0));
        uint256 currentBalance1 = aToken1.balanceOf(address(aaveWrapper1));

        uint256 yieldAmount0 = (currentBalance0 * yieldPercent) / 100;
        uint256 yieldAmount1 = (currentBalance1 * yieldPercent) / 100;

        aToken0.simulateYield(address(aaveWrapper0), yieldAmount0);
        aToken1.simulateYield(address(aaveWrapper1), yieldAmount1);
    }

    /**
     * @notice Simulates negative yield (slash) in Aave wrappers.
     * @param slashPercent The slash percentage (e.g., 20 for 20%).
     */
    function _simulateAaveSlash(uint256 slashPercent) internal {
        uint256 currentBalance0 = aToken0.balanceOf(address(aaveWrapper0));
        uint256 currentBalance1 = aToken1.balanceOf(address(aaveWrapper1));

        uint256 slashAmount0 = (currentBalance0 * slashPercent) / 100;
        uint256 slashAmount1 = (currentBalance1 * slashPercent) / 100;

        aToken0.simulateSlash(address(aaveWrapper0), slashAmount0);
        aToken1.simulateSlash(address(aaveWrapper1), slashAmount1);
    }

    // Exclude from coverage
    function test() public {}
}
