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
 * @title SafeTickRangeChangeTest
 * @notice Tests proving safe tick range changes don't break JIT
 * @dev Safe conditions for setTickRange:
 *      - Price BELOW new range + token0 > 0 → Safe (newLower > currentTick)
 *      - Price ABOVE new range + token1 > 0 → Safe (newUpper ≤ currentTick)
 *
 *      When price is OUT of range, JIT can add liquidity with only one token.
 *      When price crosses the range, the other token is naturally acquired via swaps.
 */
contract SafeTickRangeChangeTest is BaseAlphixTest {
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

        // Fund users
        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 1000);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 1000);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 1000);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 1000);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);

        // Add regular LP so swaps can execute
        _addRegularLp(10000e18);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                     SAFE RANGE CHANGE TESTS - CONCRETE
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test: Safe range change when price is BELOW the new range with token0 > 0
     * @dev Steps:
     *      1. Configure initial JIT range with price IN range
     *      2. Add rehypo liquidity
     *      3. Execute swaps to push price BELOW range and drain token1
     *      4. Change range (while paused) to a range where price is BELOW
     *      5. Unpause and verify JIT works with swaps
     */
    function test_setTickRange_safeWhenPriceBelowRangeWithToken0() public {
        // Initial narrow range around tick 0
        int24 initialLower = -1000;
        int24 initialUpper = 1000;
        initialLower = (initialLower / defaultTickSpacing) * defaultTickSpacing;
        initialUpper = (initialUpper / defaultTickSpacing) * defaultTickSpacing;

        // Configure initial JIT
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(initialLower, initialUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();
        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        // Add rehypo liquidity
        _addReHypoLiquidity(alice, 500e18);

        uint256 yield0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yield1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);
        console2.log("Initial yield0:", yield0Before);
        console2.log("Initial yield1:", yield1Before);

        // Push price BELOW the initial range via zeroForOne swaps (sell token0, buy token1)
        // This drains token1 from yield source
        for (uint256 i = 0; i < 20; i++) {
            _executeSwap(bob, 200e18, true); // zeroForOne
        }

        (, int24 tickAfterDrain,,) = poolManager.getSlot0(key.toId());
        uint256 yield0AfterDrain = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yield1AfterDrain = Alphix(address(hook)).getAmountInYieldSource(currency1);
        console2.log("Tick after drain:", int256(tickAfterDrain));
        console2.log("Yield0 after drain:", yield0AfterDrain);
        console2.log("Yield1 after drain:", yield1AfterDrain);

        // Verify price is BELOW initial range
        assertTrue(tickAfterDrain < initialLower, "Price should be below initial range");
        // Yield sources should be one-sided: token0 > 0, token1 = 0
        assertGt(yield0AfterDrain, 0, "Should have token0");
        assertEq(yield1AfterDrain, 0, "Should have no token1");

        // Now safely change range to one where current price is BELOW
        // New range: [currentTick + 100, currentTick + 2000]
        int24 newLower = ((tickAfterDrain + 100) / defaultTickSpacing) * defaultTickSpacing;
        int24 newUpper = ((tickAfterDrain + 2000) / defaultTickSpacing) * defaultTickSpacing;

        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(newLower, newUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        console2.log("New range lower:", int256(newLower));
        console2.log("New range upper:", int256(newUpper));

        // Verify JIT works: execute swaps in recovery direction (oneForZero)
        // This should cross the new range and restore token1
        for (uint256 i = 0; i < 30; i++) {
            _executeSwap(bob, 200e18, false); // oneForZero
        }

        uint256 yield0Final = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yield1Final = Alphix(address(hook)).getAmountInYieldSource(currency1);
        (, int24 tickFinal,,) = poolManager.getSlot0(key.toId());
        console2.log("Final tick:", int256(tickFinal));
        console2.log("Final yield0:", yield0Final);
        console2.log("Final yield1:", yield1Final);

        // The key assertion: JIT self-healed after safe range change
        assertGt(yield1Final, 0, "JIT should have self-healed: token1 recovered after range crossing");
    }

    /**
     * @notice Test: Safe range change when price is ABOVE the new range with token1 > 0
     * @dev Steps:
     *      1. Configure initial JIT range with price IN range
     *      2. Add rehypo liquidity
     *      3. Execute swaps to push price ABOVE range and drain token0
     *      4. Change range (while paused) to a range where price is ABOVE
     *      5. Unpause and verify JIT works with swaps
     */
    function test_setTickRange_safeWhenPriceAboveRangeWithToken1() public {
        // Initial narrow range around tick 0
        int24 initialLower = -1000;
        int24 initialUpper = 1000;
        initialLower = (initialLower / defaultTickSpacing) * defaultTickSpacing;
        initialUpper = (initialUpper / defaultTickSpacing) * defaultTickSpacing;

        // Configure initial JIT
        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(initialLower, initialUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();
        vm.startPrank(yieldManager);
        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        // Add rehypo liquidity
        _addReHypoLiquidity(alice, 500e18);

        uint256 yield0Before = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yield1Before = Alphix(address(hook)).getAmountInYieldSource(currency1);
        console2.log("Initial yield0:", yield0Before);
        console2.log("Initial yield1:", yield1Before);

        // Push price ABOVE the initial range via oneForZero swaps (sell token1, buy token0)
        // This drains token0 from yield source
        for (uint256 i = 0; i < 20; i++) {
            _executeSwap(bob, 200e18, false); // oneForZero
        }

        (, int24 tickAfterDrain,,) = poolManager.getSlot0(key.toId());
        uint256 yield0AfterDrain = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yield1AfterDrain = Alphix(address(hook)).getAmountInYieldSource(currency1);
        console2.log("Tick after drain:", int256(tickAfterDrain));
        console2.log("Yield0 after drain:", yield0AfterDrain);
        console2.log("Yield1 after drain:", yield1AfterDrain);

        // Verify price is ABOVE initial range
        assertTrue(tickAfterDrain >= initialUpper, "Price should be above initial range");
        // Yield sources should be one-sided: token0 = 0, token1 > 0
        assertEq(yield0AfterDrain, 0, "Should have no token0");
        assertGt(yield1AfterDrain, 0, "Should have token1");

        // Now safely change range to one where current price is ABOVE
        // New range: [currentTick - 2000, currentTick - 100]
        int24 newLower = ((tickAfterDrain - 2000) / defaultTickSpacing) * defaultTickSpacing;
        int24 newUpper = ((tickAfterDrain - 100) / defaultTickSpacing) * defaultTickSpacing;

        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(newLower, newUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();

        console2.log("New range lower:", int256(newLower));
        console2.log("New range upper:", int256(newUpper));

        // Verify JIT works: execute swaps in recovery direction (zeroForOne)
        // This should cross the new range and restore token0
        for (uint256 i = 0; i < 30; i++) {
            _executeSwap(bob, 200e18, true); // zeroForOne
        }

        uint256 yield0Final = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 yield1Final = Alphix(address(hook)).getAmountInYieldSource(currency1);
        (, int24 tickFinal,,) = poolManager.getSlot0(key.toId());
        console2.log("Final tick:", int256(tickFinal));
        console2.log("Final yield0:", yield0Final);
        console2.log("Final yield1:", yield1Final);

        // The key assertion: JIT self-healed after safe range change
        assertGt(yield0Final, 0, "JIT should have self-healed: token0 recovered after range crossing");
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

    function _executeSwap(address swapper, uint256 amount, bool zeroForOne) internal {
        vm.startPrank(swapper);
        if (zeroForOne) {
            MockERC20(Currency.unwrap(currency0)).approve(address(swapRouter), amount);
            swapRouter.swapExactTokensForTokens({
                amountIn: amount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: swapper,
                deadline: block.timestamp + 100
            });
        } else {
            MockERC20(Currency.unwrap(currency1)).approve(address(swapRouter), amount);
            swapRouter.swapExactTokensForTokens({
                amountIn: amount,
                amountOutMin: 0,
                zeroForOne: false,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: swapper,
                deadline: block.timestamp + 100
            });
        }
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
