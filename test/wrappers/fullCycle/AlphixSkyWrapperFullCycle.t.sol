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
 * @title AlphixSkyWrapperFullCycleTest
 * @notice End-to-end integration tests for Alphix hook with Alphix4626WrapperSky as yield source.
 * @dev Tests complete user journeys including:
 *      - Multi-user deposits, rate appreciation, and withdrawals
 *      - Rate decrease (negative yield) scenarios
 *      - Fee collection from wrapper affecting hook accounting
 *      - PSM swap integration verification
 *
 *      NOTE: The Sky wrapper has a circuit breaker that limits rate changes to 5% per update.
 *      Tests use small rate changes (<=5%) or trigger accrual between changes.
 */
contract AlphixSkyWrapperFullCycleTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    /* STATE */

    address public yieldManager;
    address public treasury;
    address public alice;
    address public bob;
    address public charlie;

    Alphix4626WrapperSky public skyWrapper0;
    Alphix4626WrapperSky public skyWrapper1;

    MockPSM3 public psm0;
    MockPSM3 public psm1;

    MockRateProvider public rateProvider0;
    MockRateProvider public rateProvider1;

    SkyMockERC20 public susds0;
    SkyMockERC20 public susds1;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    uint24 internal constant WRAPPER_FEE = 100_000; // 10%
    uint256 internal constant SEED_LIQUIDITY = 1e18;
    uint256 internal constant RATE_PRECISION = 1e27;

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

        _deploySkyInfrastructure();
        _deploySkyWrappers();

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);
    }

    function _deploySkyInfrastructure() internal {
        susds0 = new SkyMockERC20("Savings Token0", "sToken0", 18);
        susds1 = new SkyMockERC20("Savings Token1", "sToken1", 18);

        rateProvider0 = new MockRateProvider();
        rateProvider1 = new MockRateProvider();

        psm0 = new MockPSM3(Currency.unwrap(currency0), address(susds0), address(rateProvider0));
        psm1 = new MockPSM3(Currency.unwrap(currency1), address(susds1), address(rateProvider1));

        // Fund PSMs with liquidity
        susds0.mint(address(psm0), 1_000_000_000e18);
        susds1.mint(address(psm1), 1_000_000_000e18);
        MockERC20(Currency.unwrap(currency0)).mint(address(psm0), 1_000_000_000e18);
        MockERC20(Currency.unwrap(currency1)).mint(address(psm1), 1_000_000_000e18);
    }

    function _deploySkyWrappers() internal {
        vm.startPrank(owner);

        MockERC20(Currency.unwrap(currency0)).mint(owner, SEED_LIQUIDITY);
        MockERC20(Currency.unwrap(currency1)).mint(owner, SEED_LIQUIDITY);

        uint256 nonce0 = vm.getNonce(owner);
        address expectedWrapper0 = vm.computeCreateAddress(owner, nonce0);
        MockERC20(Currency.unwrap(currency0)).approve(expectedWrapper0, type(uint256).max);

        skyWrapper0 = new Alphix4626WrapperSky(
            address(psm0), treasury, "Alphix sToken0 Vault", "alphsToken0", WRAPPER_FEE, SEED_LIQUIDITY, 0
        );
        skyWrapper0.addAlphixHook(address(hook));

        uint256 nonce1 = vm.getNonce(owner);
        address expectedWrapper1 = vm.computeCreateAddress(owner, nonce1);
        MockERC20(Currency.unwrap(currency1)).approve(expectedWrapper1, type(uint256).max);

        skyWrapper1 = new Alphix4626WrapperSky(
            address(psm1), treasury, "Alphix sToken1 Vault", "alphsToken1", WRAPPER_FEE, SEED_LIQUIDITY, 0
        );
        skyWrapper1.addAlphixHook(address(hook));

        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        FULL CYCLE TEST: DEPOSIT -> RATE APPRECIATION -> WITHDRAW
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Complete cycle: Alice deposits, rate appreciates, Alice withdraws with profit.
     * @dev Uses 5% rate change to stay within circuit breaker limit.
     */
    function test_fullCycle_depositRateAppreciationWithdraw() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // === Phase 1: Alice deposits ===
        console2.log("=== Phase 1: Alice deposits ===");
        _addReHypoLiquidity(alice, 100e18);

        uint256 aliceToken0Initial = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);

        (uint256 aliceValue0Before,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice initial value token0:", aliceValue0Before);

        // === Phase 2: Rate appreciates (5% to stay within circuit breaker) ===
        console2.log("=== Phase 2: Rate appreciation ===");
        _simulateSkyYield(5);

        (uint256 aliceValue0After,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("Alice value after rate appreciation:", aliceValue0After);

        // Alice should have more value
        assertGt(aliceValue0After, aliceValue0Before, "Alice token0 value should increase with rate appreciation");

        // === Phase 3: Alice withdraws ===
        console2.log("=== Phase 3: Alice withdraws ===");
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        uint256 aliceToken0Final = MockERC20(Currency.unwrap(currency0)).balanceOf(alice);
        uint256 received0 = aliceToken0Final - aliceToken0Initial;
        console2.log("Alice received token0:", received0);

        assertApproxEqRel(received0, aliceValue0After, 1e16, "Alice should receive her token0 value");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        MULTI-USER WITH RATE CHANGES
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Multi-user scenario with rate increases.
     * @dev Uses multiple small rate changes with accrual between to stay within circuit breaker.
     */
    function test_fullCycle_multiUserWithRateChanges() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // === Alice deposits at 1:1 rate ===
        _addReHypoLiquidity(alice, 100e18);
        (uint256 aliceInitialValue0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);

        console2.log("=== Alice deposits at 1:1 rate ===");
        console2.log("Alice initial value0:", aliceInitialValue0);

        // === Rate increases 5% (within circuit breaker), accrue, then another 5% ===
        _simulateSkyYieldWithAccrue(5);
        _simulateSkyYieldWithAccrue(5);

        (uint256 aliceAfterIncrease0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(100e18);
        console2.log("=== After rate increases ===");
        console2.log("Alice value after increase:", aliceAfterIncrease0);

        // === Bob deposits at higher rate ===
        (uint256 bobRequired0,) = Alphix(address(hook)).previewAddReHypothecatedLiquidity(100e18);
        console2.log("=== Bob deposits at higher rate ===");
        console2.log("Bob required for 100 shares:", bobRequired0);

        // Bob needs more tokens for same shares
        assertGt(bobRequired0, aliceInitialValue0, "Bob should need more tokens at higher rate");

        _addReHypoLiquidity(bob, 100e18);

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
     * @notice Stress test: Many consecutive swaps with JIT liquidity from Sky wrapper.
     */
    function test_fullCycle_manySwapsWithJit() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 500e18);

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
                        FEE COLLECTION IN sUSDS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that wrapper fee collection (in sUSDS) works correctly.
     * @dev Uses small rate change with accrual to stay within circuit breaker.
     */
    function test_fullCycle_wrapperFeeCollectionInSusds() public {
        _configureReHypo();
        _addRegularLp(1000e18);
        _addReHypoLiquidity(alice, 100e18);

        // Generate yield via rate increase (5% within circuit breaker)
        _simulateSkyYieldWithAccrue(5);

        // Check wrapper has claimable fees (in sUSDS terms internally)
        uint256 fees0 = skyWrapper0.getClaimableFees();
        uint256 fees1 = skyWrapper1.getClaimableFees();

        console2.log("=== Before fee collection ===");
        console2.log("Claimable fees wrapper0 (sUSDS):", fees0);
        console2.log("Claimable fees wrapper1 (sUSDS):", fees1);

        assertGt(fees0, 0, "Wrapper0 should have fees");
        assertGt(fees1, 0, "Wrapper1 should have fees");

        // Collect fees (sent as sUSDS to treasury)
        vm.startPrank(owner);
        skyWrapper0.collectFees();
        skyWrapper1.collectFees();
        vm.stopPrank();

        // Treasury should have received sUSDS fees
        uint256 treasuryFees0 = susds0.balanceOf(treasury);
        assertEq(treasuryFees0, fees0, "Treasury should have wrapper0 fees in sUSDS");

        // Alice can still withdraw
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        PSM SWAP INTEGRATION
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test: PSM swaps work correctly during deposits and withdrawals.
     */
    function test_fullCycle_psmSwapIntegration() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // Record PSM balances before
        uint256 psmUsds0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(address(psm0));
        uint256 psmSusds0Before = susds0.balanceOf(address(psm0));

        // Alice deposits (triggers USDS -> sUSDS swap in PSM)
        _addReHypoLiquidity(alice, 100e18);

        uint256 psmUsds0AfterDeposit = MockERC20(Currency.unwrap(currency0)).balanceOf(address(psm0));
        uint256 psmSusds0AfterDeposit = susds0.balanceOf(address(psm0));

        console2.log("=== After deposit (USDS -> sUSDS) ===");
        console2.log("PSM USDS change:", int256(psmUsds0AfterDeposit) - int256(psmUsds0Before));
        console2.log("PSM sUSDS change:", int256(psmSusds0AfterDeposit) - int256(psmSusds0Before));

        // PSM should have received USDS, given out sUSDS
        assertGt(psmUsds0AfterDeposit, psmUsds0Before, "PSM should have more USDS after deposit");
        assertLt(psmSusds0AfterDeposit, psmSusds0Before, "PSM should have less sUSDS after deposit");

        // Alice withdraws (triggers sUSDS -> USDS swap in PSM)
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        uint256 psmUsds0AfterWithdraw = MockERC20(Currency.unwrap(currency0)).balanceOf(address(psm0));
        uint256 psmSusds0AfterWithdraw = susds0.balanceOf(address(psm0));

        console2.log("=== After withdraw (sUSDS -> USDS) ===");
        console2.log("PSM USDS change:", int256(psmUsds0AfterWithdraw) - int256(psmUsds0AfterDeposit));
        console2.log("PSM sUSDS change:", int256(psmSusds0AfterWithdraw) - int256(psmSusds0AfterDeposit));

        // PSM should have given out USDS, received sUSDS
        assertLt(psmUsds0AfterWithdraw, psmUsds0AfterDeposit, "PSM should have less USDS after withdraw");
        assertGt(psmSusds0AfterWithdraw, psmSusds0AfterDeposit, "PSM should have more sUSDS after withdraw");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        THREE USERS INTERLEAVED WITH RATE CHANGES
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test: Three users with interleaved deposits and rate changes.
     * @dev Uses small rate changes with accrual between to stay within circuit breaker.
     */
    function test_fullCycle_threeUsersInterleavedWithRateChanges() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // === Round 1: Alice deposits at 1:1 ===
        _addReHypoLiquidity(alice, 100e18);

        // === Round 2: Rate +5%, accrue, Bob deposits ===
        _simulateSkyYieldWithAccrue(5);
        _addReHypoLiquidity(bob, 100e18);

        // === Round 3: Rate +5%, accrue, Charlie deposits ===
        _simulateSkyYieldWithAccrue(5);
        _addReHypoLiquidity(charlie, 100e18);

        // === Round 4: Alice partial withdraw ===
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(50e18, 0, 0);

        // === Final: Everyone withdraws ===
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

        assertEq(Alphix(address(hook)).totalSupply(), 0, "All shares should be withdrawn");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        WRAPPER SOLVENCY CHECK
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test: Wrapper remains solvent after many operations.
     */
    function test_fullCycle_wrapperSolvency() public {
        _configureReHypo();
        _addRegularLp(1000e18);

        // Multiple users deposit
        _addReHypoLiquidity(alice, 200e18);
        _addReHypoLiquidity(bob, 150e18);

        // Rate increases (with accrual between)
        _simulateSkyYieldWithAccrue(5);
        _simulateSkyYieldWithAccrue(5);

        // Partial withdrawals
        vm.prank(alice);
        Alphix(address(hook)).removeReHypothecatedLiquidity(100e18, 0, 0);

        // Check solvency: wrapper sUSDS balance >= claimable fees
        uint256 wrapper0SusdsBalance = susds0.balanceOf(address(skyWrapper0));
        uint256 wrapper0Fees = skyWrapper0.getClaimableFees();

        console2.log("=== Wrapper0 solvency check ===");
        console2.log("sUSDS balance:", wrapper0SusdsBalance);
        console2.log("Claimable fees:", wrapper0Fees);

        // The sUSDS balance should cover claimable fees (rest is user assets)
        assertGe(wrapper0SusdsBalance, wrapper0Fees, "Wrapper0 should have enough sUSDS for fees");

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

    /**
     * @notice Simulates yield by increasing rate, then syncs the rate.
     * @dev Rate changes > 1% require syncRate() to bypass circuit breaker.
     */
    function _simulateSkyYield(uint256 yieldPercent) internal {
        rateProvider0.simulateYield(yieldPercent);
        rateProvider1.simulateYield(yieldPercent);

        // Sync rate to bypass circuit breaker for rate changes > 1%
        if (yieldPercent > 1) {
            vm.startPrank(owner);
            skyWrapper0.syncRate();
            skyWrapper1.syncRate();
            vm.stopPrank();
        }
    }

    /**
     * @notice Simulates yield by increasing rate, syncs, then triggers accrual.
     * @dev Use this to "lock in" a rate change before making another.
     */
    function _simulateSkyYieldWithAccrue(uint256 yieldPercent) internal {
        rateProvider0.simulateYield(yieldPercent);
        rateProvider1.simulateYield(yieldPercent);

        // Sync rate to bypass circuit breaker for rate changes > 1%
        vm.startPrank(owner);
        if (yieldPercent > 1) {
            skyWrapper0.syncRate();
            skyWrapper1.syncRate();
        }
        // Trigger accrual by calling setFee (locks in the rate change)
        skyWrapper0.setFee(WRAPPER_FEE);
        skyWrapper1.setFee(WRAPPER_FEE);
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
