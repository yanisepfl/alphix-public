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
 * @title SlippageProtectionFuzzTest
 * @notice Fuzz integration tests for slippage protection in rehypothecation operations
 * @dev Tests various combinations of slippage tolerances, swap amounts, and share amounts
 *      to ensure robust slippage protection behavior
 */
contract SlippageProtectionFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    address public alice;
    address public attacker;

    function setUp() public override {
        super.setUp();

        // Deploy yield vaults
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        alice = makeAddr("alice");
        attacker = makeAddr("attacker");

        // Setup yield sources
        _configureReHypothecation();

        // Mint tokens
        MockERC20(Currency.unwrap(currency0)).mint(alice, 10000e18);
        MockERC20(Currency.unwrap(currency1)).mint(alice, 10000e18);
        MockERC20(Currency.unwrap(currency0)).mint(attacker, 10000e18);
        MockERC20(Currency.unwrap(currency1)).mint(attacker, 10000e18);

        // Approve
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    FUZZ TESTS - ADD LIQUIDITY SLIPPAGE PROTECTION
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz: Add liquidity succeeds when no price manipulation occurs
     * @param shares Shares to mint (bounded)
     * @param slippageTolerance Slippage tolerance (bounded)
     */
    function testFuzz_integration_addLiquidity_noPriceMove_succeeds(uint256 shares, uint24 slippageTolerance) public {
        // Bound inputs
        shares = bound(shares, 1e18, 100e18);
        slippageTolerance = uint24(bound(slippageTolerance, 1, LPFeeLibrary.MAX_LP_FEE));

        (uint160 currentPrice,,,) = poolManager.getSlot0(key.toId());

        vm.prank(alice);
        hook.addReHypothecatedLiquidity(shares, currentPrice, slippageTolerance);

        assertEq(hook.balanceOf(alice), shares, "Alice should have correct shares");
    }

    /**
     * @notice Fuzz: Add liquidity behavior after price manipulation
     * @dev Either succeeds (within tolerance) or reverts (exceeds tolerance)
     * @param swapAmount Amount to swap for price manipulation (bounded)
     * @param shares Shares to mint (bounded)
     * @param slippageTolerance Slippage tolerance (bounded)
     */
    function testFuzz_integration_addLiquidity_afterPriceMove(
        uint256 swapAmount,
        uint256 shares,
        uint24 slippageTolerance
    ) public {
        // Bound inputs
        swapAmount = bound(swapAmount, 1e17, 10e18); // 0.1 to 10 tokens
        shares = bound(shares, 1e18, 50e18);
        slippageTolerance = uint24(bound(slippageTolerance, 100, 100000)); // 0.01% to 10%

        // Alice observes price before attack
        (uint160 observedPrice,,,) = poolManager.getSlot0(key.toId());

        // Attacker moves price
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Get new price
        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());

        // Calculate slippage using the same formula as the contract
        // Contract uses: priceDiff * MAX_LP_FEE > expectedPrice * maxSlippage
        uint256 priceDiff = newPrice > observedPrice ? newPrice - observedPrice : observedPrice - newPrice;
        bool exceedsSlippage = priceDiff * LPFeeLibrary.MAX_LP_FEE > uint256(observedPrice) * slippageTolerance;

        // Either succeeds or reverts based on slippage
        if (exceedsSlippage) {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IReHypothecation.PriceSlippageExceeded.selector, observedPrice, newPrice, slippageTolerance
                )
            );
            hook.addReHypothecatedLiquidity(shares, observedPrice, slippageTolerance);
            assertEq(hook.balanceOf(alice), 0, "Alice should have no shares (protected)");
        } else {
            vm.prank(alice);
            hook.addReHypothecatedLiquidity(shares, observedPrice, slippageTolerance);
            assertEq(hook.balanceOf(alice), shares, "Alice should have shares (within tolerance)");
        }
    }

    /**
     * @notice Fuzz: Zero expected price always skips slippage check
     * @param swapAmount Amount to swap for price manipulation (bounded)
     * @param shares Shares to mint (bounded)
     */
    function testFuzz_integration_addLiquidity_zeroExpectedPrice_alwaysSucceeds(uint256 swapAmount, uint256 shares)
        public
    {
        // Bound inputs
        swapAmount = bound(swapAmount, 1e17, 10e18);
        shares = bound(shares, 1e18, 50e18);

        // Move price (doesn't matter how much)
        if (swapAmount > 0) {
            vm.prank(attacker);
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: attacker,
                deadline: block.timestamp + 100
            });
        }

        // Add with 0 expected price - should always succeed
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(shares, 0, 0);

        assertEq(hook.balanceOf(alice), shares, "Alice should have shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                  FUZZ TESTS - REMOVE LIQUIDITY SLIPPAGE PROTECTION
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz: Remove liquidity succeeds when no price manipulation occurs
     * @param shares Shares to add/remove (bounded)
     * @param slippageTolerance Slippage tolerance (bounded)
     */
    function testFuzz_integration_removeLiquidity_noPriceMove_succeeds(uint256 shares, uint24 slippageTolerance)
        public
    {
        // Bound inputs
        shares = bound(shares, 1e18, 100e18);
        slippageTolerance = uint24(bound(slippageTolerance, 1, LPFeeLibrary.MAX_LP_FEE));

        // Add liquidity first
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(shares, 0, 0);

        (uint160 currentPrice,,,) = poolManager.getSlot0(key.toId());

        // Remove with slippage protection
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(shares, currentPrice, slippageTolerance);

        assertEq(hook.balanceOf(alice), 0, "Alice should have no shares after removal");
    }

    /**
     * @notice Fuzz: Remove liquidity behavior after price manipulation
     * @param swapAmount Amount to swap for price manipulation (bounded)
     * @param addShares Shares to add initially (bounded)
     * @param removeShares Shares to remove (bounded)
     * @param slippageTolerance Slippage tolerance (bounded)
     */
    function testFuzz_integration_removeLiquidity_afterPriceMove(
        uint256 swapAmount,
        uint256 addShares,
        uint256 removeShares,
        uint24 slippageTolerance
    ) public {
        // Bound inputs
        swapAmount = bound(swapAmount, 1e17, 10e18);
        addShares = bound(addShares, 10e18, 100e18);
        removeShares = bound(removeShares, 1e18, addShares);
        slippageTolerance = uint24(bound(slippageTolerance, 100, 100000)); // 0.01% to 10%

        // Add liquidity first
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(addShares, 0, 0);

        // Alice observes price before attack
        (uint160 observedPrice,,,) = poolManager.getSlot0(key.toId());

        // Attacker moves price
        vm.prank(attacker);
        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: attacker,
            deadline: block.timestamp + 100
        });

        // Get new price
        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());

        // Calculate slippage using the same formula as the contract
        // Contract uses: priceDiff * MAX_LP_FEE > expectedPrice * maxSlippage
        uint256 priceDiff = newPrice > observedPrice ? newPrice - observedPrice : observedPrice - newPrice;
        bool exceedsSlippage = priceDiff * LPFeeLibrary.MAX_LP_FEE > uint256(observedPrice) * slippageTolerance;

        // Either succeeds or reverts based on slippage
        if (exceedsSlippage) {
            vm.prank(alice);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IReHypothecation.PriceSlippageExceeded.selector, observedPrice, newPrice, slippageTolerance
                )
            );
            hook.removeReHypothecatedLiquidity(removeShares, observedPrice, slippageTolerance);
            assertEq(hook.balanceOf(alice), addShares, "Alice should still have all shares (protected)");
        } else {
            vm.prank(alice);
            hook.removeReHypothecatedLiquidity(removeShares, observedPrice, slippageTolerance);
            assertEq(hook.balanceOf(alice), addShares - removeShares, "Alice should have remaining shares");
        }
    }

    /**
     * @notice Fuzz: Partial removal with varying shares and tolerance
     * @param totalShares Total shares to add (bounded)
     * @param removePercentage Percentage to remove (bounded 1-100)
     * @param slippageTolerance Slippage tolerance (bounded)
     */
    function testFuzz_integration_partialRemoval_varyingShares(
        uint256 totalShares,
        uint8 removePercentage,
        uint24 slippageTolerance
    ) public {
        // Bound inputs
        totalShares = bound(totalShares, 10e18, 500e18);
        removePercentage = uint8(bound(removePercentage, 1, 100));
        slippageTolerance = uint24(bound(slippageTolerance, 1000, LPFeeLibrary.MAX_LP_FEE));

        uint256 sharesToRemove = (totalShares * removePercentage) / 100;
        if (sharesToRemove == 0) sharesToRemove = 1e18;

        // Add liquidity
        vm.prank(alice);
        hook.addReHypothecatedLiquidity(totalShares, 0, 0);

        (uint160 currentPrice,,,) = poolManager.getSlot0(key.toId());

        // Remove partial with slippage protection
        vm.prank(alice);
        hook.removeReHypothecatedLiquidity(sharesToRemove, currentPrice, slippageTolerance);

        uint256 expectedRemaining = totalShares - sharesToRemove;
        assertEq(hook.balanceOf(alice), expectedRemaining, "Alice should have correct remaining shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      FUZZ TESTS - BIDIRECTIONAL PRICE MOVEMENT
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz: Test slippage with both swap directions
     * @param swapAmount Amount to swap (bounded)
     * @param shares Shares to add (bounded)
     * @param slippageTolerance Slippage tolerance (bounded)
     * @param zeroForOne Swap direction
     */
    function testFuzz_integration_bidirectionalPriceMovement(
        uint256 swapAmount,
        uint256 shares,
        uint24 slippageTolerance,
        bool zeroForOne
    ) public {
        // Bound inputs
        swapAmount = bound(swapAmount, 1e17, 5e18);
        shares = bound(shares, 1e18, 50e18);
        slippageTolerance = uint24(bound(slippageTolerance, 100, 50000));

        // Alice observes price
        (uint160 observedPrice,,,) = poolManager.getSlot0(key.toId());

        // Attacker moves price in chosen direction
        vm.prank(attacker);
        if (zeroForOne) {
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: attacker,
                deadline: block.timestamp + 100
            });
        } else {
            swapRouter.swapExactTokensForTokens({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: false,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: attacker,
                deadline: block.timestamp + 100
            });
        }

        (uint160 newPrice,,,) = poolManager.getSlot0(key.toId());

        // Calculate slippage using the same formula as the contract
        // Contract uses: priceDiff * MAX_LP_FEE > expectedPrice * maxSlippage
        uint256 priceDiff = newPrice > observedPrice ? newPrice - observedPrice : observedPrice - newPrice;
        bool exceedsSlippage = priceDiff * LPFeeLibrary.MAX_LP_FEE > uint256(observedPrice) * slippageTolerance;

        // Verify behavior matches expectation
        if (exceedsSlippage) {
            vm.prank(alice);
            vm.expectRevert();
            hook.addReHypothecatedLiquidity(shares, observedPrice, slippageTolerance);
        } else {
            vm.prank(alice);
            hook.addReHypothecatedLiquidity(shares, observedPrice, slippageTolerance);
            assertEq(hook.balanceOf(alice), shares);
        }
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
