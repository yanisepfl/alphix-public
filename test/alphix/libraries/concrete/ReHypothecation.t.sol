// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {ReHypothecationLib} from "../../../../src/libraries/ReHypothecation.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title ReHypothecationLibTest
 * @notice Tests for ReHypothecationLib library functions
 * @dev Targets uncovered branches in the library for 100% coverage
 */
contract ReHypothecationLibTest is Test {
    MockERC20 public token0;
    MockERC20 public token1;
    MockYieldVault public vault0;
    MockYieldVault public vault1;
    ReHypothecationLibWrapper public wrapper;

    Currency public currency0;
    Currency public currency1;

    int24 public constant TICK_SPACING = 60;

    function setUp() public {
        // Deploy test tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);

        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));

        // Deploy yield vaults
        vault0 = new MockYieldVault(IERC20(address(token0)));
        vault1 = new MockYieldVault(IERC20(address(token1)));

        // Deploy wrapper for library tests
        wrapper = new ReHypothecationLibWrapper();

        // Mint tokens for testing
        token0.mint(address(this), 1000e18);
        token1.mint(address(this), 1000e18);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            isValidYieldSource TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test isValidYieldSource returns true for valid vault
     */
    function test_isValidYieldSource_validVault() public view {
        bool isValid = ReHypothecationLib.isValidYieldSource(address(vault0), currency0);
        assertTrue(isValid, "Should be valid for matching vault");
    }

    /**
     * @notice Test isValidYieldSource returns false for zero address
     */
    function test_isValidYieldSource_zeroAddress() public view {
        bool isValid = ReHypothecationLib.isValidYieldSource(address(0), currency0);
        assertFalse(isValid, "Should be invalid for zero address");
    }

    /**
     * @notice Test isValidYieldSource returns false for EOA (no code)
     */
    function test_isValidYieldSource_eoa() public {
        address eoa = makeAddr("eoa");
        bool isValid = ReHypothecationLib.isValidYieldSource(eoa, currency0);
        assertFalse(isValid, "Should be invalid for EOA");
    }

    /**
     * @notice Test isValidYieldSource returns false for native currency (address(0))
     */
    function test_isValidYieldSource_nativeCurrency() public view {
        Currency native = Currency.wrap(address(0));
        bool isValid = ReHypothecationLib.isValidYieldSource(address(vault0), native);
        assertFalse(isValid, "Should be invalid for native currency");
    }

    /**
     * @notice Test isValidYieldSource returns false when asset doesn't match currency
     */
    function test_isValidYieldSource_assetMismatch() public view {
        // vault0's asset is token0, but we're checking with currency1
        bool isValid = ReHypothecationLib.isValidYieldSource(address(vault0), currency1);
        assertFalse(isValid, "Should be invalid when asset doesn't match");
    }

    /**
     * @notice Test isValidYieldSource returns false when asset() call reverts
     * @dev This hits the catch block at line 68-69 in ReHypothecation.sol
     */
    function test_isValidYieldSource_assetCallReverts() public {
        // Deploy a contract that doesn't implement asset()
        MockNonERC4626 nonVault = new MockNonERC4626();
        bool isValid = ReHypothecationLib.isValidYieldSource(address(nonVault), currency0);
        assertFalse(isValid, "Should be invalid when asset() reverts");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            validateTickRange TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test validateTickRange succeeds for valid range
     */
    function test_validateTickRange_valid() public pure {
        int24 tickLower = -120;
        int24 tickUpper = 120;
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, TICK_SPACING);
        // No revert means success
    }

    /**
     * @notice Test validateTickRange reverts when tickLower >= tickUpper
     */
    function test_validateTickRange_lowerGreaterThanUpper() public {
        int24 tickLower = 120;
        int24 tickUpper = -120;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector, tickLower, tickUpper));
        wrapper.validateTickRange(tickLower, tickUpper, TICK_SPACING);
    }

    /**
     * @notice Test validateTickRange reverts when tickLower == tickUpper
     */
    function test_validateTickRange_equal() public {
        int24 tick = 120;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector, tick, tick));
        wrapper.validateTickRange(tick, tick, TICK_SPACING);
    }

    /**
     * @notice Test validateTickRange reverts when tickLower < MIN_TICK
     */
    function test_validateTickRange_belowMinTick() public {
        int24 tickLower = TickMath.MIN_TICK - 1;
        int24 tickUpper = 120;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector, tickLower, tickUpper));
        wrapper.validateTickRange(tickLower, tickUpper, TICK_SPACING);
    }

    /**
     * @notice Test validateTickRange reverts when tickUpper > MAX_TICK
     */
    function test_validateTickRange_aboveMaxTick() public {
        int24 tickLower = -120;
        int24 tickUpper = TickMath.MAX_TICK + 1;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector, tickLower, tickUpper));
        wrapper.validateTickRange(tickLower, tickUpper, TICK_SPACING);
    }

    /**
     * @notice Test validateTickRange reverts when tickLower not aligned
     */
    function test_validateTickRange_lowerNotAligned() public {
        int24 tickLower = -121; // Not divisible by 60
        int24 tickUpper = 120;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector, tickLower, tickUpper));
        wrapper.validateTickRange(tickLower, tickUpper, TICK_SPACING);
    }

    /**
     * @notice Test validateTickRange reverts when tickUpper not aligned
     */
    function test_validateTickRange_upperNotAligned() public {
        int24 tickLower = -120;
        int24 tickUpper = 121; // Not divisible by 60
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector, tickLower, tickUpper));
        wrapper.validateTickRange(tickLower, tickUpper, TICK_SPACING);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            validateYieldTaxPips TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test validateYieldTaxPips succeeds for valid tax
     */
    function test_validateYieldTaxPips_valid() public pure {
        ReHypothecationLib.validateYieldTaxPips(100_000); // 10%
    }

    /**
     * @notice Test validateYieldTaxPips succeeds for zero
     */
    function test_validateYieldTaxPips_zero() public pure {
        ReHypothecationLib.validateYieldTaxPips(0);
    }

    /**
     * @notice Test validateYieldTaxPips succeeds for max (100%)
     */
    function test_validateYieldTaxPips_max() public pure {
        ReHypothecationLib.validateYieldTaxPips(uint24(LPFeeLibrary.MAX_LP_FEE)); // 1_000_000 = 100%
    }

    /**
     * @notice Test validateYieldTaxPips reverts when exceeding max
     */
    function test_validateYieldTaxPips_exceedsMax() public {
        uint24 invalidTax = uint24(LPFeeLibrary.MAX_LP_FEE + 1);
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidYieldTaxPips.selector, invalidTax));
        wrapper.validateYieldTaxPips(invalidTax);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            depositToYieldSource TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test depositToYieldSource returns 0 for zero amount
     */
    function test_depositToYieldSource_zeroAmount() public {
        uint256 shares = ReHypothecationLib.depositToYieldSource(address(vault0), currency0, 0);
        assertEq(shares, 0, "Should return 0 shares for 0 amount");
    }

    /**
     * @notice Test depositToYieldSource works for valid amount
     */
    function test_depositToYieldSource_validAmount() public {
        uint256 amount = 100e18;
        token0.approve(address(vault0), amount);
        // no-op to reset any approval issues - using require to satisfy linter
        require(token0.transfer(address(this), 0), "Transfer failed");

        // The library will approve and deposit
        token0.approve(address(this), amount);
        uint256 shares = ReHypothecationLib.depositToYieldSource(address(vault0), currency0, amount);

        assertGt(shares, 0, "Should receive shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            withdrawFromYieldSourceTo TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test withdrawFromYieldSourceTo returns 0 for zero amount
     */
    function test_withdrawFromYieldSourceTo_zeroAmount() public {
        address recipient = makeAddr("recipient");
        uint256 shares = ReHypothecationLib.withdrawFromYieldSourceTo(address(vault0), 0, recipient);
        assertEq(shares, 0, "Should return 0 shares for 0 amount");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            getShareUnit TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test getShareUnit returns DEFAULT_RATE_PRECISION for zero address
     * @dev This hits line 147 (branch: yieldSource == address(0))
     */
    function test_getShareUnit_zeroAddress() public view {
        uint256 unit = ReHypothecationLib.getShareUnit(address(0));
        assertEq(unit, 1e18, "Should return 1e18 for zero address");
    }

    /**
     * @notice Test getShareUnit returns correct value for valid vault
     */
    function test_getShareUnit_validVault() public view {
        uint256 unit = ReHypothecationLib.getShareUnit(address(vault0));
        assertEq(unit, 1e18, "Should return 10^decimals for vault");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            getCurrentRate TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test getCurrentRate returns defaults for zero address
     */
    function test_getCurrentRate_zeroAddress() public view {
        (uint256 rate, uint256 shareUnit) = ReHypothecationLib.getCurrentRate(address(0));
        assertEq(rate, 1e18, "Should return default rate");
        assertEq(shareUnit, 1e18, "Should return default share unit");
    }

    /**
     * @notice Test getCurrentRate returns correct values for valid vault
     */
    function test_getCurrentRate_validVault() public view {
        (uint256 rate, uint256 shareUnit) = ReHypothecationLib.getCurrentRate(address(vault0));
        assertEq(shareUnit, 1e18, "Share unit should be 10^18");
        assertGt(rate, 0, "Rate should be positive");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            getAmountInYieldSource TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test getAmountInYieldSource returns 0 for zero shares
     */
    function test_getAmountInYieldSource_zeroShares() public view {
        uint256 amount = ReHypothecationLib.getAmountInYieldSource(address(vault0), 0);
        assertEq(amount, 0, "Should return 0 for 0 shares");
    }

    /**
     * @notice Test getAmountInYieldSource returns 0 for zero address
     */
    function test_getAmountInYieldSource_zeroAddress() public view {
        uint256 amount = ReHypothecationLib.getAmountInYieldSource(address(0), 100e18);
        assertEq(amount, 0, "Should return 0 for zero address");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            migrateYieldSource TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test migrateYieldSource returns 0 for zero shares
     */
    function test_migrateYieldSource_zeroShares() public {
        MockYieldVault newVault = new MockYieldVault(IERC20(address(token0)));
        uint256 newShares = ReHypothecationLib.migrateYieldSource(address(vault0), address(newVault), currency0, 0);
        assertEq(newShares, 0, "Should return 0 for 0 shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            calculateYieldFromRate TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test calculateYieldFromRate returns 0 when rate hasn't increased
     */
    function test_calculateYieldFromRate_noIncrease() public view {
        (uint256 currentRate,) = ReHypothecationLib.getCurrentRate(address(vault0));
        (uint256 yield, uint256 newRate) =
            ReHypothecationLib.calculateYieldFromRate(address(vault0), 100e18, currentRate);
        assertEq(yield, 0, "Should return 0 yield when rate hasn't increased");
        assertEq(newRate, currentRate, "Rate should be unchanged");
    }

    /**
     * @notice Test calculateYieldFromRate returns 0 for zero shares
     */
    function test_calculateYieldFromRate_zeroShares() public view {
        (uint256 yield,) = ReHypothecationLib.calculateYieldFromRate(address(vault0), 0, 1e18);
        assertEq(yield, 0, "Should return 0 yield for 0 shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            calculateTaxFromYield TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test calculateTaxFromYield returns 0 for zero yield
     */
    function test_calculateTaxFromYield_zeroYield() public pure {
        uint256 tax = ReHypothecationLib.calculateTaxFromYield(0, 100_000);
        assertEq(tax, 0, "Should return 0 tax for 0 yield");
    }

    /**
     * @notice Test calculateTaxFromYield returns 0 for zero tax rate
     */
    function test_calculateTaxFromYield_zeroTax() public pure {
        uint256 tax = ReHypothecationLib.calculateTaxFromYield(100e18, 0);
        assertEq(tax, 0, "Should return 0 tax for 0 tax rate");
    }

    /**
     * @notice Test calculateTaxFromYield returns correct tax amount
     */
    function test_calculateTaxFromYield_validTax() public pure {
        uint256 yieldAmount = 100e18;
        uint24 taxPips = 100_000; // 10%
        uint256 tax = ReHypothecationLib.calculateTaxFromYield(yieldAmount, taxPips);
        assertEq(tax, 10e18, "Should return 10% of yield");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            convertSharesToAmounts TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test convertSharesToAmounts returns 0 for zero total shares
     */
    function test_convertSharesToAmounts_zeroTotalShares() public pure {
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmounts(100e18, 0, 1000e18, 1000e18);
        assertEq(amount0, 0, "Should return 0 amount0");
        assertEq(amount1, 0, "Should return 0 amount1");
    }

    /**
     * @notice Test convertSharesToAmounts returns proportional amounts
     */
    function test_convertSharesToAmounts_proportional() public pure {
        uint256 shares = 50e18;
        uint256 totalShares = 100e18;
        uint256 totalAmount0 = 1000e18;
        uint256 totalAmount1 = 2000e18;

        (uint256 amount0, uint256 amount1) =
            ReHypothecationLib.convertSharesToAmounts(shares, totalShares, totalAmount0, totalAmount1);

        assertEq(amount0, 500e18, "Should return 50% of amount0");
        assertEq(amount1, 1000e18, "Should return 50% of amount1");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        convertSharesToAmountsRoundUp TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test convertSharesToAmountsRoundUp returns 0 for zero total shares
     */
    function test_convertSharesToAmountsRoundUp_zeroTotalShares() public pure {
        (uint256 amount0, uint256 amount1) =
            ReHypothecationLib.convertSharesToAmountsRoundUp(100e18, 0, 1000e18, 1000e18);
        assertEq(amount0, 0, "Should return 0 amount0");
        assertEq(amount1, 0, "Should return 0 amount1");
    }

    /**
     * @notice Test convertSharesToAmountsRoundUp rounds up correctly
     */
    function test_convertSharesToAmountsRoundUp_roundsUp() public pure {
        uint256 shares = 1;
        uint256 totalShares = 3;
        uint256 totalAmount0 = 10;
        uint256 totalAmount1 = 10;

        (uint256 amount0, uint256 amount1) =
            ReHypothecationLib.convertSharesToAmountsRoundUp(shares, totalShares, totalAmount0, totalAmount1);

        // 1/3 of 10 = 3.33... should round up to 4
        assertEq(amount0, 4, "Should round up amount0");
        assertEq(amount1, 4, "Should round up amount1");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            getLiquidityToUse TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test getLiquidityToUse returns liquidity for valid inputs
     */
    function test_getLiquidityToUse_valid() public pure {
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // sqrt(1) * 2^96
        int24 tickLower = -120;
        int24 tickUpper = 120;
        uint256 amount0 = 1000e18;
        uint256 amount1 = 1000e18;

        uint128 liquidity = ReHypothecationLib.getLiquidityToUse(sqrtPriceX96, tickLower, tickUpper, amount0, amount1);

        assertGt(liquidity, 0, "Should return positive liquidity");
    }

    // Exclude from coverage
    function test() public {}
}

/**
 * @title MockNonERC4626
 * @notice A contract that doesn't implement ERC4626 to test error handling
 */
contract MockNonERC4626 {
    // This contract doesn't implement asset(), so calling it will revert
    function notAsset() external pure returns (address) {
        return address(0);
    }
}

/**
 * @title ReHypothecationLibWrapper
 * @notice Wrapper contract to test library functions that revert
 * @dev External calls allow us to use expectRevert properly
 */
contract ReHypothecationLibWrapper {
    function validateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) external pure {
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, tickSpacing);
    }

    function validateYieldTaxPips(uint24 taxPips) external pure {
        ReHypothecationLib.validateYieldTaxPips(taxPips);
    }
}
