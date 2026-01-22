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
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {Alphix} from "../../../../src/Alphix.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title JITTickRangeFuzzTest
 * @notice Fuzz tests for JIT liquidity behavior across different tick range configurations
 * @dev Tests verify that:
 *      1. Swaps never revert regardless of JIT tick range configuration
 *      2. JIT participation is correctly determined by tick position
 *      3. Yield sources change only when JIT participates
 */
contract JITTickRangeFuzzTest is BaseAlphixTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public yieldManager;
    address public alice;
    address public bob;

    MockYieldVault public vault0;
    MockYieldVault public vault1;

    int24 public fullRangeLower;
    int24 public fullRangeUpper;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Fund users generously for fuzzing
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 100);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);

        // Add base liquidity for all tests
        _addRegularLp(10000e18);
    }

    /**
     * @notice Fuzz test: JIT behavior with various tick ranges
     * @dev Verifies swaps never revert and JIT participation matches tick position
     * @param jitTickLowerSeed Used to derive JIT tick lower bound
     * @param jitTickUpperSeed Used to derive JIT tick upper bound
     * @param swapAmount Amount to swap (bounded to reasonable range)
     * @param zeroForOne Swap direction
     */
    function testFuzz_jitBehaviorVsTickRange(
        int24 jitTickLowerSeed,
        int24 jitTickUpperSeed,
        uint256 swapAmount,
        bool zeroForOne
    ) public {
        // Bound swap amount to reasonable range (0.01 to 100 tokens)
        swapAmount = bound(swapAmount, 0.01e18, 100e18);

        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        // Derive valid tick range from seeds
        int24 minTick = TickMath.minUsableTick(defaultTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(defaultTickSpacing);

        // Bound the seeds to valid tick range
        int24 rawLower = int24(bound(int256(jitTickLowerSeed), int256(minTick), int256(maxTick - defaultTickSpacing)));
        int24 rawUpper = int24(bound(int256(jitTickUpperSeed), int256(rawLower + defaultTickSpacing), int256(maxTick)));

        // Align to tick spacing
        int24 jitTickLower = (rawLower / defaultTickSpacing) * defaultTickSpacing;
        int24 jitTickUpper = (rawUpper / defaultTickSpacing) * defaultTickSpacing;

        // Ensure valid range
        if (jitTickUpper <= jitTickLower) {
            jitTickUpper = jitTickLower + defaultTickSpacing;
        }

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(jitTickLower, jitTickUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        // Add rehypo liquidity
        _addReHypoLiquidity(alice, 100e18);

        // Record state before
        uint256 yieldSource0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // Determine if current tick is in range BEFORE the swap
        bool wasInRange = currentTick >= jitTickLower && currentTick < jitTickUpper;

        // Execute swap - THIS SHOULD NEVER REVERT
        vm.startPrank(bob);
        if (zeroForOne) {
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
        } else {
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
        }
        vm.stopPrank();

        // Record state after
        uint256 yieldSource0After = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yieldSource1After = Alphix(address(hook)).getAmountInYieldSource(currency1);

        bool yieldSourcesChanged = (yieldSource0After != yieldSource0Before)
            || (yieldSource1After != yieldSource1Before);

        // If we started in range, JIT should have participated (yield sources should change)
        // If we started out of range, JIT should NOT have participated (unless swap moved us into range)
        if (wasInRange) {
            assertTrue(yieldSourcesChanged, "JIT should participate when tick starts in range");
        }
        // Note: We can't assert !yieldSourcesChanged for out-of-range because the swap
        // might move the price INTO the range during execution
    }

    /**
     * @notice Fuzz test: Swaps never revert with extreme tick range configurations
     * @dev Tests edge cases like very narrow ranges, ranges at extremes, etc.
     */
    function testFuzz_swapsNeverRevert_extremeRanges(
        uint256 rangeType,
        uint256 swapAmount,
        bool zeroForOne
    ) public {
        // Bound swap amount
        swapAmount = bound(swapAmount, 0.01e18, 50e18);

        // Get current tick
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 minTick = TickMath.minUsableTick(defaultTickSpacing);
        int24 maxTick = TickMath.maxUsableTick(defaultTickSpacing);

        int24 jitTickLower;
        int24 jitTickUpper;

        // Choose range type based on rangeType seed
        uint256 rangeChoice = rangeType % 6;

        if (rangeChoice == 0) {
            // Full range
            jitTickLower = minTick;
            jitTickUpper = maxTick;
        } else if (rangeChoice == 1) {
            // Single tick spacing (minimum valid range)
            jitTickLower = (currentTick / defaultTickSpacing) * defaultTickSpacing;
            jitTickUpper = jitTickLower + defaultTickSpacing;
        } else if (rangeChoice == 2) {
            // Range far below current tick
            jitTickLower = minTick;
            jitTickUpper = minTick + defaultTickSpacing * 10;
        } else if (rangeChoice == 3) {
            // Range far above current tick
            jitTickLower = maxTick - defaultTickSpacing * 10;
            jitTickUpper = maxTick;
        } else if (rangeChoice == 4) {
            // Range around current tick (likely in range)
            jitTickLower = ((currentTick - 1000) / defaultTickSpacing) * defaultTickSpacing;
            jitTickUpper = ((currentTick + 1000) / defaultTickSpacing) * defaultTickSpacing;
            if (jitTickUpper <= jitTickLower) {
                jitTickUpper = jitTickLower + defaultTickSpacing;
            }
        } else {
            // Asymmetric range
            jitTickLower = ((currentTick - 500) / defaultTickSpacing) * defaultTickSpacing;
            jitTickUpper = ((currentTick + 2000) / defaultTickSpacing) * defaultTickSpacing;
            if (jitTickUpper <= jitTickLower) {
                jitTickUpper = jitTickLower + defaultTickSpacing;
            }
        }

        // Configure JIT (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(jitTickLower, jitTickUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        // Execute swap - THIS SHOULD NEVER REVERT regardless of range configuration
        vm.startPrank(bob);
        if (zeroForOne) {
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
        } else {
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
        }
        vm.stopPrank();

        // If we reach here, swap succeeded (which is the main assertion)
        assertTrue(true, "Swap completed without revert");
    }

    /**
     * @notice Fuzz test: Multiple consecutive swaps with changing tick ranges
     * @dev Simulates dynamic tick range updates during active trading
     */
    function testFuzz_consecutiveSwapsWithRangeChanges(
        uint256 swapCount,
        uint256 seed
    ) public {
        // Bound swap count to 1-10
        swapCount = bound(swapCount, 1, 10);

        // Initial configuration with full range (setTickRange requires whenPaused)
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(fullRangeLower, fullRangeUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        _addReHypoLiquidity(alice, 100e18);

        for (uint256 i = 0; i < swapCount; i++) {
            // Derive swap params from seed
            uint256 swapSeed = uint256(keccak256(abi.encode(seed, i)));
            uint256 swapAmount = bound(swapSeed, 0.1e18, 10e18);
            bool zeroForOne = (swapSeed % 2) == 0;

            // Maybe change tick range (requires pause/unpause)
            if (i > 0 && (swapSeed % 3) == 0) {
                (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
                int24 offset = int24(int256(bound(swapSeed >> 8, 100, 5000)));
                int24 newLower = ((currentTick - offset) / defaultTickSpacing) * defaultTickSpacing;
                int24 newUpper = ((currentTick + offset) / defaultTickSpacing) * defaultTickSpacing;
                if (newUpper <= newLower) {
                    newUpper = newLower + defaultTickSpacing;
                }

                vm.prank(owner);
                Alphix(address(hook)).pause();
                vm.prank(yieldManager);
                Alphix(address(hook)).setTickRange(newLower, newUpper);
                vm.prank(owner);
                Alphix(address(hook)).unpause();
            }

            // Execute swap
            vm.startPrank(bob);
            if (zeroForOne) {
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
            } else {
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
            }
            vm.stopPrank();
        }

        // If we reach here, all swaps succeeded
        assertTrue(true, "All consecutive swaps completed without revert");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════ */

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
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), amount0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), amount1 + 1);
        Alphix(address(hook)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();
    }
}
