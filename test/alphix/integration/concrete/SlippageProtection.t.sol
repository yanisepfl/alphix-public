// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";

/**
 * @title SlippageProtectionIntegrationTest
 * @notice Integration tests for slippage protection in rehypothecation operations
 * @dev Tests realistic sandwich attack scenarios and slippage protection behavior
 *      in an end-to-end integration context
 */
contract SlippageProtectionIntegrationTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    address public alice;
    address public bob;
    address public attacker;

    function setUp() public override {
        super.setUp();

        // Deploy yield vaults
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        attacker = makeAddr("attacker");

        // Setup yield sources
        _configureReHypothecation();

        // Mint tokens to test users
        MockERC20(Currency.unwrap(currency0)).mint(alice, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 1000e18);
        MockERC20(Currency.unwrap(currency0)).mint(bob, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(bob, 1000e18);
        MockERC20(Currency.unwrap(currency0)).mint(attacker, 1000e18);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 1000e18);

        // Approve hook for transfers
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      SANDWICH ATTACK PREVENTION - ADD LIQUIDITY
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test full sandwich attack scenario where slippage protection saves user
     * @dev 1. Alice observes price and prepares add liquidity tx
     *      2. Attacker front-runs with swap to move price
     *      3. Alice's tx reverts due to slippage protection
     *      4. Attacker's back-run becomes unprofitable
     */
    function test_integration_addLiquidity_sandwichAttackPrevented() public {
        // Alice observes current price
        (uint160 aliceObservedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 slippageTolerance = 5000; // 0.5%

        // Attacker front-runs Alice's tx with a swap
        uint256 attackSwapAmount = 10e18;
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: attackSwapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Price has moved
        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());
        assertTrue(newPrice != aliceObservedPrice, "Price should have moved");

        // Alice's add liquidity tx should revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReHypothecation.PriceSlippageExceeded.selector, aliceObservedPrice, newPrice, slippageTolerance
            )
        );
        hook.addReHypothecatedLiquidity(10e18, aliceObservedPrice, slippageTolerance);

        // Alice is protected - no shares minted
        assertEq(hook.balanceOf(alice), 0, "Alice should have no shares");
    }

    /**
     * @notice Test that slippage protection allows transactions within tolerance
     * @dev Small price movements that stay within tolerance should succeed
     */
    function test_integration_addLiquidity_smallPriceMove_withinTolerance() public {
        // Alice observes current price
        (uint160 aliceObservedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 slippageTolerance = 50000; // 5% - generous tolerance

        // Small swap that moves price slightly
        uint256 smallSwapAmount = 1e18;
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: smallSwapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Alice's add liquidity tx should succeed with generous tolerance
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(10e18, aliceObservedPrice, slippageTolerance);

        // Alice gets her shares
        assertEq(hook.balanceOf(alice), 10e18, "Alice should have shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                   SANDWICH ATTACK PREVENTION - REMOVE LIQUIDITY
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test full sandwich attack scenario on remove liquidity
     * @dev 1. Alice has LP shares and observes price
     *      2. Attacker front-runs with swap to move price
     *      3. Alice's remove tx reverts due to slippage protection
     */
    function test_integration_removeLiquidity_sandwichAttackPrevented() public {
        // Alice adds liquidity first (no slippage protection needed for setup)
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(50e18, 0, 0);
        assertEq(hook.balanceOf(alice), 50e18, "Alice should have shares");

        // Alice observes price and prepares withdrawal
        (uint160 aliceObservedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 slippageTolerance = 5000; // 0.5%

        // Attacker front-runs with swap
        uint256 attackSwapAmount = 10e18;
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: attackSwapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Price has moved
        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());
        assertTrue(newPrice != aliceObservedPrice, "Price should have moved");

        // Alice's remove liquidity tx should revert
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IReHypothecation.PriceSlippageExceeded.selector, aliceObservedPrice, newPrice, slippageTolerance
            )
        );
        hook.removeReHypothecatedLiquidity(25e18, aliceObservedPrice, slippageTolerance);

        // Alice protected - shares not burned
        assertEq(hook.balanceOf(alice), 50e18, "Alice should still have all shares");
    }

    /**
     * @notice Test successful removal when price is stable
     */
    function test_integration_removeLiquidity_stablePrice_succeeds() public {
        // Alice adds liquidity
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(50e18, 0, 0);

        // Get current price
        (uint160 currentPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 slippageTolerance = 1000; // 0.1% - strict tolerance

        // Remove liquidity immediately (no price change)
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(25e18, currentPrice, slippageTolerance);

        // Alice has remaining shares
        assertEq(hook.balanceOf(alice), 25e18, "Alice should have 25e18 shares left");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            SLIPPAGE OPT-OUT SCENARIOS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that passing 0 for expected price skips slippage check
     * @dev Users can opt-out of slippage protection if they choose
     */
    function test_integration_addLiquidity_zeroExpectedPrice_skipsSlippageCheck() public {
        // Move price with a swap
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Alice adds with no slippage protection (0 expected price)
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(10e18, 0, 0);

        // Tx succeeds - user opted out of protection
        assertEq(hook.balanceOf(alice), 10e18, "Alice should have shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            MULTI-USER SCENARIOS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that slippage protection works correctly with multiple LPs
     * @dev Multiple users should be independently protected
     */
    function test_integration_multipleUsers_independentSlippageProtection() public {
        // Both Alice and Bob observe the same price
        (uint160 observedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 aliceSlippage = 2000; // 0.2% - tight
        uint24 bobSlippage = 20000; // 2% - loose

        // Attacker moves price
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: 5e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());

        // Calculate actual slippage
        uint256 priceDiff = newPrice > observedPrice ? newPrice - observedPrice : observedPrice - newPrice;
        uint256 actualSlippage = (priceDiff * LPFeeLibrary.MAX_LP_FEE) / observedPrice;

        // Alice should be protected (if her slippage is exceeded)
        if (actualSlippage > aliceSlippage) {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IReHypothecation.PriceSlippageExceeded.selector, observedPrice, newPrice, aliceSlippage
                )
            );
            hook.addReHypothecatedLiquidity(10e18, observedPrice, aliceSlippage);
        }

        // Bob with looser tolerance should succeed
        if (actualSlippage <= bobSlippage) {
            vm.prank(bob);
            hook.addReHypothecatedLiquidity(10e18, observedPrice, bobSlippage);
            assertEq(hook.balanceOf(bob), 10e18, "Bob should have shares");
        }
    }

    /**
     * @notice Test slippage protection with yield accrual between observation and execution
     * @dev Yield changes shouldn't affect price-based slippage check
     */
    function test_integration_slippageProtection_withYieldAccrual() public {
        // Alice adds initial liquidity
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(50e18, 0, 0);

        // Observe price for withdrawal
        (uint160 observedPrice,,,) = poolManager.getSlot0(key.toId());
        uint24 slippageTolerance = 10000; // 1%

        // Simulate yield accrual (shouldn't affect pool price)
        uint256 yield0 = 5e18;
        uint256 yield1 = 5e18;

        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        vault0.simulateYield(yield0);

        MockERC20(Currency.unwrap(currency1)).mint(owner, yield1);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault1), yield1);
        vault1.simulateYield(yield1);
        vm.stopPrank();

        // Alice removes liquidity - should succeed since pool price unchanged
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(25e18, observedPrice, slippageTolerance);

        assertEq(hook.balanceOf(alice), 25e18, "Alice should have 25e18 shares remaining");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            EDGE CASES
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test exact boundary of slippage tolerance
     * @dev Price at exactly the boundary should pass
     */
    function test_integration_slippage_exactBoundary() public {
        // Get current price
        (uint160 currentPrice,,,) = poolManager.getSlot0(key.toId());

        // Add liquidity with current price and minimal slippage tolerance
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(10e18, currentPrice, 1); // 0.0001% tolerance

        // Should succeed since price hasn't changed
        assertEq(hook.balanceOf(alice), 10e18, "Alice should have shares");
    }

    /**
     * @notice Test slippage protection with max tolerance (100%)
     * @dev Maximum tolerance should always pass
     */
    function test_integration_slippage_maxTolerance_alwaysPasses() public {
        // Move price significantly
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: 10e18,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Record old price (before swap started)
        uint160 oldPrice = Constants.SQRT_PRICE_1_1;

        // Add with maximum tolerance
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(10e18, oldPrice, uint24(LPFeeLibrary.MAX_LP_FEE)); // 100% tolerance

        // Should succeed despite large price movement
        assertEq(hook.balanceOf(alice), 10e18, "Alice should have shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                HELPER FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    function _configureReHypothecation() internal {
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vm.startPrank(yieldManager);
        hook.setYieldSource(currency0, address(vault0));
        hook.setYieldSource(currency1, address(vault1));
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
