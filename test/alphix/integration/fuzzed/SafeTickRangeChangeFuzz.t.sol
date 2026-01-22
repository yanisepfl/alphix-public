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
 * @title SafeTickRangeChangeFuzzTest
 * @notice Fuzz tests proving safe tick range changes never cause JIT to get stuck
 * @dev Safe conditions for setTickRange (documented in IReHypothecation):
 *      - Price BELOW new range + token0 > 0 → Safe
 *      - Price ABOVE new range + token1 > 0 → Safe
 */
contract SafeTickRangeChangeFuzzTest is BaseAlphixTest {
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

    // Storage variables for fuzz test to avoid stack-too-deep
    int24 internal _newLower;
    int24 internal _newUpper;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        MockERC20(Currency.unwrap(currency0)).mint(alice, INITIAL_TOKEN_AMOUNT * 10000);
        MockERC20(Currency.unwrap(currency1)).mint(alice, INITIAL_TOKEN_AMOUNT * 10000);
        MockERC20(Currency.unwrap(currency0)).mint(bob, INITIAL_TOKEN_AMOUNT * 10000);
        MockERC20(Currency.unwrap(currency1)).mint(bob, INITIAL_TOKEN_AMOUNT * 10000);

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        fullRangeLower = TickMath.minUsableTick(defaultTickSpacing);
        fullRangeUpper = TickMath.maxUsableTick(defaultTickSpacing);

        _addRegularLp(50000e18);
    }

    /**
     * @notice Fuzz test: After a safe range change, JIT never gets permanently stuck
     * @param swapCount Number of random swaps to execute after range change
     * @param seed Random seed for swap directions and sizes
     * @param rangeOffset How far the new range is from current tick
     * @param drainDirection true = drain token1 first, false = drain token0 first
     */
    function testFuzz_safeRangeChange_neverGetsStuck(
        uint256 swapCount,
        uint256 seed,
        uint256 rangeOffset,
        bool drainDirection
    ) public {
        swapCount = bound(swapCount, 10, 50);
        rangeOffset = bound(rangeOffset, 500, 5000);

        _setupInitialJIT();
        _addReHypoLiquidity(alice, 1000e18);
        _drainOneSide(drainDirection);
        _performSafeRangeChange(rangeOffset, drainDirection);

        uint256 maxConsecutiveStuck = _executeSwapsAndTrack(swapCount, seed);
        _verifyRecovery(maxConsecutiveStuck, swapCount);
    }

    function _setupInitialJIT() internal {
        int24 initialLower = -2000;
        int24 initialUpper = 2000;
        initialLower = (initialLower / defaultTickSpacing) * defaultTickSpacing;
        initialUpper = (initialUpper / defaultTickSpacing) * defaultTickSpacing;

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
    }

    function _drainOneSide(bool drainDirection) internal {
        Currency drainedCurrency = drainDirection ? currency1 : currency0;

        for (uint256 i = 0; i < 50; i++) {
            if (Alphix(address(hook)).getAmountInYieldSource(drainedCurrency) == 0) break;
            _executeSwap(bob, 500e18, drainDirection);
        }
    }

    function _performSafeRangeChange(uint256 rangeOffset, bool drainDirection) internal {
        (, int24 tickAfterDrain,,) = poolManager.getSlot0(key.toId());

        if (drainDirection) {
            _newLower = tickAfterDrain + int24(int256(rangeOffset));
            _newUpper = tickAfterDrain + int24(int256(rangeOffset)) + 2000;
        } else {
            _newLower = tickAfterDrain - int24(int256(rangeOffset)) - 2000;
            _newUpper = tickAfterDrain - int24(int256(rangeOffset));
        }

        _newLower = (_newLower / defaultTickSpacing) * defaultTickSpacing;
        _newUpper = (_newUpper / defaultTickSpacing) * defaultTickSpacing;

        if (_newLower < TickMath.MIN_TICK) _newLower = TickMath.minUsableTick(defaultTickSpacing);
        if (_newUpper > TickMath.MAX_TICK) _newUpper = TickMath.maxUsableTick(defaultTickSpacing);
        if (_newLower >= _newUpper) _newUpper = _newLower + defaultTickSpacing * 10;

        vm.prank(owner);
        Alphix(address(hook)).pause();
        vm.prank(yieldManager);
        Alphix(address(hook)).setTickRange(_newLower, _newUpper);
        vm.prank(owner);
        Alphix(address(hook)).unpause();
    }

    function _executeSwapsAndTrack(uint256 swapCount, uint256 seed) internal returns (uint256 maxConsecutiveStuck) {
        uint256 consecutiveStuckCount = 0;

        for (uint256 i = 0; i < swapCount; i++) {
            uint256 swapSeed = uint256(keccak256(abi.encode(seed, i)));
            _executeSwap(bob, bound(swapSeed, 10e18, 200e18), (swapSeed % 2) == 0);

            uint256 yield0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
            uint256 yield1 = Alphix(address(hook)).getAmountInYieldSource(currency1);
            (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

            bool inRange = currentTick >= _newLower && currentTick < _newUpper;
            bool oneSided = (yield0 == 0) || (yield1 == 0);

            if (inRange && oneSided) {
                consecutiveStuckCount++;
                if (consecutiveStuckCount > maxConsecutiveStuck) maxConsecutiveStuck = consecutiveStuckCount;
            } else {
                consecutiveStuckCount = 0;
            }
        }
    }

    function _verifyRecovery(uint256 maxConsecutiveStuck, uint256 swapCount) internal {
        uint256 finalYield0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 finalYield1 = Alphix(address(hook)).getAmountInYieldSource(currency1);
        (, int24 finalTick,,) = poolManager.getSlot0(key.toId());

        bool finalInRange = finalTick >= _newLower && finalTick < _newUpper;
        bool finalOneSided = (finalYield0 == 0) || (finalYield1 == 0);

        if (finalInRange && finalOneSided) {
            bool recoveryDirection = (finalYield0 == 0);
            for (uint256 i = 0; i < 20; i++) {
                _executeSwap(bob, 200e18, recoveryDirection);
                finalYield0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
                finalYield1 = Alphix(address(hook)).getAmountInYieldSource(currency1);
                if (finalYield0 > 0 && finalYield1 > 0) break;
            }
        }

        console2.log("Max consecutive stuck swaps:", maxConsecutiveStuck);
        console2.log("Final yield0:", finalYield0);
        console2.log("Final yield1:", finalYield1);

        assertTrue(maxConsecutiveStuck < swapCount, "JIT should self-heal: not stuck for entire swap sequence");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        HELPER FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    function _addRegularLp(uint256 amount) internal {
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));
        permit2.approve(Currency.unwrap(currency1), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        positionManager.mint(key, fullRangeLower, fullRangeUpper, amount, amount, amount * 2, owner, block.timestamp + 60, Constants.ZERO_BYTES);
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

    function test() public {}
}
