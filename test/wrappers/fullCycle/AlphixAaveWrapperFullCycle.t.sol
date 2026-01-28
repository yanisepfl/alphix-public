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

/* AAVE WRAPPER IMPORTS */
import {Alphix4626WrapperAave} from "../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {MockAToken} from "../aave/mocks/MockAToken.sol";
import {MockAavePool} from "../aave/mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "../aave/mocks/MockPoolAddressesProvider.sol";

/**
 * @title AlphixAaveWrapperFullCycleTest
 * @notice End-to-end integration tests for Alphix hook with Alphix4626WrapperAave as yield source.
 * @dev Tests complete user journeys including:
 *      - Multi-user deposits, yield accrual, and withdrawals
 *      - Negative yield (slash) scenarios
 *      - Fee collection from wrapper affecting hook accounting
 *      - Multiple swap cycles with JIT liquidity
 */
contract AlphixAaveWrapperFullCycleTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    /* STATE */

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;
    address public charlie;

    Alphix4626WrapperAave public aaveWrapper0;
    Alphix4626WrapperAave public aaveWrapper1;

    MockAavePool public aavePool;
    MockAToken public aToken0;
    MockAToken public aToken1;
    MockPoolAddressesProvider public poolAddressesProvider;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    uint24 internal constant WRAPPER_FEE = 100_000; // 10%
    uint256 internal constant SEED_LIQUIDITY = 1e18;

    /* SETUP */

    function setUp() public override {
        super.setUp();

        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Fund users
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency0)).mint(charlie, INITIAL_TOKEN_AMOUNT * 10);
        MockERC20(Currency.unwrap(currency1)).mint(charlie, INITIAL_TOKEN_AMOUNT * 10);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        _deployAaveInfrastructure();
        _deployAaveWrappers();

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    function _deployAaveInfrastructure() internal {
        aavePool = new MockAavePool();
        aToken0 = new MockAToken("Aave Token0", "aToken0", 18, Currency.unwrap(currency0), address(aavePool));
        aToken1 = new MockAToken("Aave Token1", "aToken1", 18, Currency.unwrap(currency1), address(aavePool));
        aavePool.initReserve(Currency.unwrap(currency0), address(aToken0), true, false, false, 0);
        aavePool.initReserve(Currency.unwrap(currency1), address(aToken1), true, false, false, 0);
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));

        // Fund aTokens with underlying liquidity for withdrawals
        // This simulates Aave pool having underlying assets available
        MockERC20(Currency.unwrap(currency0)).mint(address(aToken0), 1_000_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(aToken1), 1_000_000_000e18);
    }

    function _deployAaveWrappers() internal {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currency0)).mint(owner, SEED_LIQUIDITY);
        MockERC20(Currency.unwrap(currency1)).mint(owner, SEED_LIQUIDITY);

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
        aaveWrapper0.addAlphixHook(address(hook));

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
        aaveWrapper1.addAlphixHook(address(hook));

        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FULL CYCLE TEST: DEPOSIT -> YIELD -> WITHDRAW
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Complete cycle: Alice deposits, Aave generates yield, Alice withdraws with profit.
     * @dev No swaps to keep the test simple and focus on yield accounting.
     */
    function test_fullCycle_depositYieldWithdraw() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // === Phase 1: Alice deposits ===
        console2.log("=== Phase 1: Alice deposits ===");
        _addReHypoLiquidity(alice, 100e18);

        uint256 aliceToken0Initial = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);

        (uint256 aliceValue0Before,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice initial value token0:", aliceValue0Before);

        // === Phase 2: Aave generates yield ===
        console2.log("=== Phase 2: Yield accrual ===");
        _simulateAaveYield(10); // 10% yield

        (uint256 aliceValue0After,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice value after yield token0:", aliceValue0After);

        // Alice should have more value (yield)
        assertGt(aliceValue0After, aliceValue0Before, "Alice token0 value should increase");

        // === Phase 3: Alice withdraws ===
        console2.log("=== Phase 3: Alice withdraws ===");
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        uint256 aliceToken0Final = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 received0 = aliceToken0Final - aliceToken0Initial;
        console2.log("Alice received token0:", received0);

        // Allow tolerance for rounding
        assertApproxEqRel(received0, aliceValue0After, 1e16, "Alice should receive her token0 value");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        MULTI-USER WITH YIELD AND SLASH
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Multi-user scenario: Alice deposits, yield accrues, Bob deposits at higher price, slash occurs.
     */
    function test_fullCycle_multiUserWithYieldAndSlash() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // === Alice deposits before yield ===
        _addReHypoLiquidity(alice, 100e18);
        (uint256 aliceInitialValue0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        console2.log("=== Alice deposits ===");
        console2.log("Alice initial value0:", aliceInitialValue0);

        // === Yield accrues ===
        _simulateAaveYield(20); // 20% yield

        (uint256 aliceAfterYield0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("=== After 20% yield ===");
        console2.log("Alice value after yield:", aliceAfterYield0);

        // === Bob deposits at higher share price ===
        (uint256 bobRequired0,) = Alphix(address(hook)).previewAddReHypothecatedLiquidity(100e18);
        console2.log("=== Bob deposits ===");
        console2.log("Bob required for 100 shares:", bobRequired0);

        // Bob needs to deposit more because share price increased
        assertGt(bobRequired0, aliceInitialValue0, "Bob should need more tokens at higher share price");

        _addReHypoLiquidity(bob, 100e18);

        // === Slash occurs (50%) ===
        _simulateAaveSlash(50);

        console2.log("=== After 50% slash ===");

        (uint256 aliceAfterSlash0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        (uint256 bobAfterSlash0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        console2.log("Alice value after slash:", aliceAfterSlash0);
        console2.log("Bob value after slash:", bobAfterSlash0);

        // Both have same shares, so both get same withdrawal value
        assertApproxEqRel(aliceAfterSlash0, bobAfterSlash0, 1e15, "Same shares = same withdrawal value");

        // === Both withdraw ===
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        vm.prank(bob);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        assertEq(Alphix(address(hook)).balanceOf(alice), 0, "Alice should have 0 shares");
        assertEq(Alphix(address(hook)).balanceOf(bob), 0, "Bob should have 0 shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        MANY SWAPS WITH JIT
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Stress test: Many consecutive swaps with JIT liquidity.
     */
    function test_fullCycle_manySwapsWithJit() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 500e18); // Large rehypo position

        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        console2.log("=== Initial yield source balances ===");
        console2.log("YS0:", yieldSource0Before);
        console2.log("YS1:", yieldSource1Before);

        // 50 swaps in alternating directions
        for (uint256 i = 0; i < 50; i++) {
            bool zeroForOne = (i % 2 == 0);
            _swapExactIn(bob, zeroForOne, 1e18);
        }

        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        console2.log("=== After 50 swaps ===");
        console2.log("YS0:", yieldSource0After);
        console2.log("YS1:", yieldSource1After);

        uint256 totalValueBefore = yieldSource0Before + yieldSource1Before;
        uint256 totalValueAfter = yieldSource0After + yieldSource1After;

        // Total value should be roughly conserved
        assertApproxEqRel(totalValueAfter, totalValueBefore, 5e16, "Total value should be roughly conserved");

        // Alice should still be able to withdraw
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(500e18, 0, 0);

        assertEq(Alphix(address(hook)).balanceOf(alice), 0, "Alice should have withdrawn all");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        WRAPPER FEE COLLECTION
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that wrapper fee collection works and treasury receives fees.
     * @dev Note: Aave wrapper collects fees in aTokens, not underlying.
     */
    function test_fullCycle_wrapperFeeCollection() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        // Generate yield
        _simulateAaveYield(20);

        // Check wrapper has claimable fees
        uint256 fees0 = aaveWrapper0.getClaimableFees();
        uint256 fees1 = aaveWrapper1.getClaimableFees();

        console2.log("=== Before fee collection ===");
        console2.log("Claimable fees wrapper0:", fees0);
        console2.log("Claimable fees wrapper1:", fees1);

        assertGt(fees0, 0, "Wrapper0 should have fees");
        assertGt(fees1, 0, "Wrapper1 should have fees");

        // Collect fees
        vm.startPrank(owner);
        aaveWrapper0.collectFees();
        aaveWrapper1.collectFees();
        vm.stopPrank();

        // Treasury should have received fees (in aTokens for Aave wrapper)
        uint256 treasuryAToken0 = aToken0.balanceOf(treasury);
        uint256 treasuryAToken1 = aToken1.balanceOf(treasury);
        assertEq(treasuryAToken0, fees0, "Treasury should have wrapper0 fees in aTokens");
        assertEq(treasuryAToken1, fees1, "Treasury should have wrapper1 fees in aTokens");

        // Alice can still withdraw
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        THREE USERS INTERLEAVED OPERATIONS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test: Three users with interleaved deposits and withdrawals (no swaps to keep simple).
     */
    function test_fullCycle_threeUsersInterleaved() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // === Round 1: Alice deposits ===
        _addReHypoLiquidity(alice, 100e18);

        // === Round 2: Some yield, then Bob deposits ===
        _simulateAaveYield(5);
        _addReHypoLiquidity(bob, 100e18);

        // === Round 3: More yield, Charlie deposits ===
        _simulateAaveYield(5);
        _addReHypoLiquidity(charlie, 100e18);

        // === Round 4: More yield ===
        _simulateAaveYield(10);

        // === Round 5: Alice partial withdraw ===
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(50e18, 0, 0);

        // === Round 6: Slash ===
        _simulateAaveSlash(10);

        // === Final: Everyone withdraws remaining ===
        uint256 aliceShares = Alphix(address(hook)).balanceOf(alice);
        uint256 bobShares = Alphix(address(hook)).balanceOf(bob);
        uint256 charlieShares = Alphix(address(hook)).balanceOf(charlie);

        console2.log("=== Final shares ===");
        console2.log("Alice:", aliceShares);
        console2.log("Bob:", bobShares);
        console2.log("Charlie:", charlieShares);

        if (aliceShares > 0) {
            vm.prank(alice);
            Alphix(address(hook)).removeReHypothecatedLiquidity(aliceShares, 0, 0);
        }

        vm.prank(bob);
        Alphix(address(hook)).removeReHypothecatedLiquidity(bobShares, 0, 0);

        vm.prank(charlie);
        Alphix(address(hook)).removeReHypothecatedLiquidity(charlieShares, 0, 0);

        // Verify all shares are gone
        assertEq(Alphix(address(hook)).totalSupply(), 0, "All shares should be withdrawn");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        YIELD SOURCE SOLVENCY
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test: After many operations, yield source remains solvent.
     */
    function test_fullCycle_yieldSourceSolvency() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // Multiple users deposit
        _addReHypoLiquidity(alice, 200e18);
        _addReHypoLiquidity(bob, 150e18);

        // Yield
        _simulateAaveYield(15);

        // More yield
        _simulateAaveYield(10);

        // Partial withdrawals
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        // Slash
        _simulateAaveSlash(5);

        // Check solvency: wrapper aToken balance >= totalAssets + claimable fees
        uint256 wrapper0ATokens = aToken0.balanceOf(address(aaveWrapper0));
        uint256 wrapper0TotalAssets = aaveWrapper0.totalAssets();
        uint256 wrapper0Fees = aaveWrapper0.getClaimableFees();

        console2.log("=== Wrapper0 solvency check ===");
        console2.log("aToken balance:", wrapper0ATokens);
        console2.log("totalAssets:", wrapper0TotalAssets);
        console2.log("claimable fees:", wrapper0Fees);

        assertGe(wrapper0ATokens, wrapper0TotalAssets + wrapper0Fees, "Wrapper0 should be solvent");

        // Full withdrawal
        uint256 aliceRemaining = Alphix(address(hook)).balanceOf(alice);
        uint256 bobRemaining = Alphix(address(hook)).balanceOf(bob);

        if (aliceRemaining > 0) {
            vm.prank(alice);
            Alphix(address(hook)).removeReHypothecatedLiquidity(aliceRemaining, 0, 0);
        }

        vm.prank(bob);
        Alphix(address(hook)).removeReHypothecatedLiquidity(bobRemaining, 0, 0);

        assertEq(Alphix(address(hook)).totalSupply(), 0, "All shares should be withdrawn");
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

    function _swapExactIn(address user, bool zeroForOne, uint256 amount) internal {
        Currency inputCurrency = zeroForOne ? currency0 : currency1;
        vm.startPrank(user);
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amount);
        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: user,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    function _simulateAaveYield(uint256 yieldPercent) internal {
        uint256 currentBalance0 = aToken0.balanceOf(address(aaveWrapper0));
        uint256 currentBalance1 = aToken1.balanceOf(address(aaveWrapper1));
        aToken0.simulateYield(address(aaveWrapper0), (currentBalance0 * yieldPercent) / 100);
        aToken1.simulateYield(address(aaveWrapper1), (currentBalance1 * yieldPercent) / 100);
    }

    function _simulateAaveSlash(uint256 slashPercent) internal {
        uint256 currentBalance0 = aToken0.balanceOf(address(aaveWrapper0));
        uint256 currentBalance1 = aToken1.balanceOf(address(aaveWrapper1));
        aToken0.simulateSlash(address(aaveWrapper0), (currentBalance0 * slashPercent) / 100);
        aToken1.simulateSlash(address(aaveWrapper1), (currentBalance1 * slashPercent) / 100);
    }

    // Exclude from coverage
    function test() public {}
}
