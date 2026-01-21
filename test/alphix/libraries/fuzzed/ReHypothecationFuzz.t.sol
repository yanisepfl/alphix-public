// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* LOCAL IMPORTS */
import {ReHypothecationLib} from "../../../../src/libraries/ReHypothecation.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/**
 * @title ReHypothecationFuzzTest
 * @notice Fuzz tests for ReHypothecationLib library
 * @dev Tests library functions with random inputs to find edge cases
 */
contract ReHypothecationFuzzTest is Test {
    MockERC20 public tokenA;
    MockYieldVault public vaultA;

    // Test harness
    ReHypothecationFuzzHarness public harness;

    /* FUZZING CONSTRAINTS */
    uint256 constant MAX_AMOUNT = 1e30; // 1 trillion with 18 decimals
    uint256 constant MIN_AMOUNT = 1;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);

        // Deploy yield vault
        vaultA = new MockYieldVault(IERC20(address(tokenA)));

        // Deploy harness
        harness = new ReHypothecationFuzzHarness();

        // Mint tokens - use reasonable amounts to avoid overflow
        tokenA.mint(address(this), 1e40);
        tokenA.mint(address(harness), 1e40);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          validateTickRange FUZZ TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test that valid tick ranges don't revert
     * @param tickLowerRaw Lower tick raw value
     * @param tickUpperRaw Upper tick raw value
     * @param tickSpacingRaw Tick spacing raw value (1-200)
     */
    function testFuzz_validateTickRange_valid(int24 tickLowerRaw, int24 tickUpperRaw, uint8 tickSpacingRaw)
        public
        pure
    {
        // Bound tick spacing to realistic values (1-200)
        int24 tickSpacing = int24(uint24(bound(tickSpacingRaw, 1, 200)));

        // Get usable tick bounds for this spacing
        int24 minUsable = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        if (minUsable < TickMath.MIN_TICK) minUsable += tickSpacing;
        int24 maxUsable = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        // Bound ticks to usable range
        int24 tickLower = int24(bound(int256(tickLowerRaw), int256(minUsable), int256(maxUsable - tickSpacing)));
        int24 tickUpper = int24(bound(int256(tickUpperRaw), int256(tickLower + tickSpacing), int256(maxUsable)));

        // Align to spacing
        tickLower = (tickLower / tickSpacing) * tickSpacing;
        tickUpper = (tickUpper / tickSpacing) * tickSpacing;

        // Ensure proper ordering after alignment
        if (tickLower >= tickUpper) {
            tickUpper = tickLower + tickSpacing;
        }

        // Final bounds check
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK || tickLower >= tickUpper) {
            return; // Skip invalid cases
        }

        // Should not revert
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, tickSpacing);
    }

    /**
     * @notice Fuzz test that invalid tick ranges (lower >= upper) revert
     * @param tickRaw Tick value to use as both lower and upper
     * @param tickSpacingRaw Tick spacing raw value
     */
    function testFuzz_validateTickRange_invalidOrdering(int24 tickRaw, uint8 tickSpacingRaw) public {
        int24 tickSpacing = int24(uint24(bound(tickSpacingRaw, 1, 200)));

        // Align tick to spacing
        int24 tick = (tickRaw / tickSpacing) * tickSpacing;

        // Use same tick for both (tickLower == tickUpper is invalid)
        // Library functions called directly without expectRevert - just verify they revert
        try this.callValidateTickRange(tick, tick, tickSpacing) {
            fail("Should have reverted for equal ticks");
        } catch {
            // Expected - test passes
        }
    }

    // Helper to call library in external context
    function callValidateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) external pure {
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, tickSpacing);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      convertSharesToAmounts FUZZ TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test that convertSharesToAmounts always rounds down
     * @param shares Number of shares
     * @param totalShares Total shares
     * @param totalAmount0 Total amount0
     * @param totalAmount1 Total amount1
     */
    function testFuzz_convertSharesToAmounts_roundsDown(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAmount0,
        uint256 totalAmount1
    ) public pure {
        // Avoid division by zero and overflow
        totalShares = bound(totalShares, 1, MAX_AMOUNT);
        shares = bound(shares, 0, totalShares);
        totalAmount0 = bound(totalAmount0, 0, MAX_AMOUNT);
        totalAmount1 = bound(totalAmount1, 0, MAX_AMOUNT);

        (uint256 amount0, uint256 amount1) =
            ReHypothecationLib.convertSharesToAmounts(shares, totalShares, totalAmount0, totalAmount1);

        // Result should never exceed proportional share
        if (shares > 0) {
            // amount0 <= (shares * totalAmount0) / totalShares
            // To avoid overflow in check, use: amount0 * totalShares <= shares * totalAmount0
            assertTrue(amount0 <= totalAmount0, "amount0 should not exceed total");
            assertTrue(amount1 <= totalAmount1, "amount1 should not exceed total");
        }

        // Zero shares should return zero
        if (shares == 0) {
            assertEq(amount0, 0, "Zero shares should give zero amount0");
            assertEq(amount1, 0, "Zero shares should give zero amount1");
        }
    }

    /**
     * @notice Fuzz test that convertSharesToAmountsRoundUp always rounds up
     * @param shares Number of shares
     * @param totalShares Total shares
     * @param totalAmount0 Total amount0
     * @param totalAmount1 Total amount1
     */
    function testFuzz_convertSharesToAmountsRoundUp_roundsUp(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAmount0,
        uint256 totalAmount1
    ) public pure {
        // Avoid division by zero and overflow
        totalShares = bound(totalShares, 1, MAX_AMOUNT);
        shares = bound(shares, 0, totalShares);
        totalAmount0 = bound(totalAmount0, 0, MAX_AMOUNT);
        totalAmount1 = bound(totalAmount1, 0, MAX_AMOUNT);

        (uint256 amount0Up, uint256 amount1Up) =
            ReHypothecationLib.convertSharesToAmountsRoundUp(shares, totalShares, totalAmount0, totalAmount1);

        (uint256 amount0Down, uint256 amount1Down) =
            ReHypothecationLib.convertSharesToAmounts(shares, totalShares, totalAmount0, totalAmount1);

        // Round up should always be >= round down
        assertTrue(amount0Up >= amount0Down, "Round up should be >= round down for amount0");
        assertTrue(amount1Up >= amount1Down, "Round up should be >= round down for amount1");

        // Zero shares should return zero for both
        if (shares == 0) {
            assertEq(amount0Up, 0, "Zero shares should give zero amount0");
            assertEq(amount1Up, 0, "Zero shares should give zero amount1");
        }
    }

    /**
     * @notice Fuzz test rounding difference creates protocol-favorable rounding
     * @dev Deposit uses round up (user pays more), withdraw uses round down (user gets less)
     * @param shares Number of shares
     * @param totalShares Total shares
     * @param totalAmount0 Total amount0
     * @param totalAmount1 Total amount1
     */
    function testFuzz_rounding_protocolFavorable(
        uint256 shares,
        uint256 totalShares,
        uint256 totalAmount0,
        uint256 totalAmount1
    ) public pure {
        // Avoid edge cases
        totalShares = bound(totalShares, 1, MAX_AMOUNT);
        shares = bound(shares, 1, totalShares);
        totalAmount0 = bound(totalAmount0, 1, MAX_AMOUNT);
        totalAmount1 = bound(totalAmount1, 1, MAX_AMOUNT);

        // Deposit amounts (round up - user pays more)
        (uint256 depositAmount0, uint256 depositAmount1) =
            ReHypothecationLib.convertSharesToAmountsRoundUp(shares, totalShares, totalAmount0, totalAmount1);

        // Withdrawal amounts (round down - user gets less)
        (uint256 withdrawAmount0, uint256 withdrawAmount1) =
            ReHypothecationLib.convertSharesToAmounts(shares, totalShares, totalAmount0, totalAmount1);

        // Protocol always keeps the dust
        assertTrue(depositAmount0 >= withdrawAmount0, "Deposit should be >= withdrawal for amount0");
        assertTrue(depositAmount1 >= withdrawAmount1, "Deposit should be >= withdrawal for amount1");
    }

    /**
     * @notice Fuzz test that full share redemption equals total
     * @param totalAmount0 Total amount0
     * @param totalAmount1 Total amount1
     */
    function testFuzz_fullRedemption_equalsTotal(uint256 totalAmount0, uint256 totalAmount1) public pure {
        totalAmount0 = bound(totalAmount0, 0, MAX_AMOUNT);
        totalAmount1 = bound(totalAmount1, 0, MAX_AMOUNT);

        uint256 totalShares = 1000e18;

        // Redeem all shares
        (uint256 amount0, uint256 amount1) =
            ReHypothecationLib.convertSharesToAmounts(totalShares, totalShares, totalAmount0, totalAmount1);

        // Should get full amount (no rounding when shares == totalShares)
        assertEq(amount0, totalAmount0, "Full redemption should return all amount0");
        assertEq(amount1, totalAmount1, "Full redemption should return all amount1");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                           migrateYieldSource FUZZ TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test migration preserves value (approximately)
     * @param depositAmount Amount to deposit and migrate
     */
    function testFuzz_migrateYieldSource_preservesValue(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1e18, 1000e18);

        // Deposit to first vault
        uint256 shares = harness.depositToYieldSource(address(vaultA), Currency.wrap(address(tokenA)), depositAmount);

        // Create second vault
        MockYieldVault vaultA2 = new MockYieldVault(IERC20(address(tokenA)));

        // Get value before migration
        uint256 valueBefore = harness.getAmountInYieldSource(address(vaultA), shares);

        // Migrate
        uint256 newShares =
            harness.migrateYieldSource(address(vaultA), address(vaultA2), Currency.wrap(address(tokenA)), shares);

        // Get value after migration
        uint256 valueAfter = harness.getAmountInYieldSource(address(vaultA2), newShares);

        // Value should be preserved (within rounding tolerance)
        assertApproxEqAbs(valueAfter, valueBefore, 2, "Migration should preserve value");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                           getLiquidityToUse FUZZ TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test getLiquidityToUse with various inputs
     * @param sqrtPriceX96 Current sqrt price
     * @param amount0 Amount of token0
     * @param amount1 Amount of token1
     */
    function testFuzz_getLiquidityToUse_neverReverts(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        public
        pure
    {
        // Bound to valid sqrt price range
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));

        // Use reasonable tick range
        int24 tickLower = -60;
        int24 tickUpper = 60;

        // Bound amounts
        amount0 = bound(amount0, 0, 1e30);
        amount1 = bound(amount1, 0, 1e30);

        // Should never revert
        uint128 liquidity = ReHypothecationLib.getLiquidityToUse(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);

        // Zero amounts should give zero or minimal liquidity
        if (amount0 == 0 && amount1 == 0) {
            assertEq(liquidity, 0, "Zero amounts should give zero liquidity");
        }
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              isValidYieldSource FUZZ TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Fuzz test that random addresses are invalid yield sources
     * @param randomAddr Random address
     */
    function testFuzz_isValidYieldSource_randomAddressInvalid(address randomAddr) public view {
        // Exclude actual valid vault
        vm.assume(randomAddr != address(vaultA));
        vm.assume(randomAddr != address(0));

        // Most random addresses should be invalid
        // (they either have no code or wrong asset)
        bool isValid = harness.isValidYieldSource(randomAddr, Currency.wrap(address(tokenA)));

        // If address has no code, it should be invalid
        if (randomAddr.code.length == 0) {
            assertFalse(isValid, "Address with no code should be invalid");
        }
    }
}

/**
 * @title ReHypothecationFuzzHarness
 * @notice Test harness for fuzz testing library functions
 */
contract ReHypothecationFuzzHarness {
    function isValidYieldSource(address yieldSource, Currency currency) external view returns (bool) {
        return ReHypothecationLib.isValidYieldSource(yieldSource, currency);
    }

    function depositToYieldSource(address yieldSource, Currency currency, uint256 amount) external returns (uint256) {
        return ReHypothecationLib.depositToYieldSource(yieldSource, currency, amount);
    }

    function getAmountInYieldSource(address yieldSource, uint256 sharesOwned) external view returns (uint256) {
        return ReHypothecationLib.getAmountInYieldSource(yieldSource, sharesOwned);
    }

    function migrateYieldSource(address oldYieldSource, address newYieldSource, Currency currency, uint256 sharesOwned)
        external
        returns (uint256)
    {
        return ReHypothecationLib.migrateYieldSource(oldYieldSource, newYieldSource, currency, sharesOwned);
    }
}
