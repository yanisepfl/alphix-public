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
 * @title ReHypothecationUnitTest
 * @notice Unit tests for ReHypothecationLib library
 * @dev Tests all functions, branches, and edge cases in the library
 */
contract ReHypothecationUnitTest is Test {
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockYieldVault public vaultA;
    MockYieldVault public vaultB;

    // Test harness to call internal library functions
    ReHypothecationTestHarness public harness;

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);

        // Deploy yield vaults
        vaultA = new MockYieldVault(IERC20(address(tokenA)));
        vaultB = new MockYieldVault(IERC20(address(tokenB)));

        // Deploy test harness
        harness = new ReHypothecationTestHarness();

        // Mint tokens for testing
        tokenA.mint(address(this), 1_000_000e18);
        tokenB.mint(address(this), 1_000_000e18);
        tokenA.mint(address(harness), 1_000_000e18);
        tokenB.mint(address(harness), 1_000_000e18);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                             isValidYieldSource TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_isValidYieldSource_zeroAddress() public view {
        bool isValid = harness.isValidYieldSource(address(0), Currency.wrap(address(tokenA)));
        assertFalse(isValid, "Zero address should be invalid");
    }

    function test_isValidYieldSource_eoa() public {
        // An EOA has no code
        address eoa = makeAddr("eoa");
        bool isValid = harness.isValidYieldSource(eoa, Currency.wrap(address(tokenA)));
        assertFalse(isValid, "EOA should be invalid (no code)");
    }

    function test_isValidYieldSource_nativeETH() public view {
        // Native ETH (address(0) currency) is not supported
        bool isValid = harness.isValidYieldSource(address(vaultA), Currency.wrap(address(0)));
        assertFalse(isValid, "Native ETH currency should be invalid");
    }

    function test_isValidYieldSource_assetMismatch() public view {
        // vaultA is for tokenA, but we pass tokenB
        bool isValid = harness.isValidYieldSource(address(vaultA), Currency.wrap(address(tokenB)));
        assertFalse(isValid, "Asset mismatch should be invalid");
    }

    function test_isValidYieldSource_nonERC4626Contract() public {
        // Deploy a contract that doesn't implement IERC4626
        NonERC4626Contract notVault = new NonERC4626Contract();
        bool isValid = harness.isValidYieldSource(address(notVault), Currency.wrap(address(tokenA)));
        assertFalse(isValid, "Non-ERC4626 contract should be invalid");
    }

    function test_isValidYieldSource_valid() public view {
        bool isValid = harness.isValidYieldSource(address(vaultA), Currency.wrap(address(tokenA)));
        assertTrue(isValid, "Valid vault should be valid");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                             validateTickRange TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_validateTickRange_lowerEqualsUpper() public {
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector));
        harness.validateTickRange(100, 100, 60);
    }

    function test_validateTickRange_lowerGreaterThanUpper() public {
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector));
        harness.validateTickRange(200, 100, 60);
    }

    function test_validateTickRange_lowerBelowMin() public {
        int24 belowMin = TickMath.MIN_TICK - 60;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector));
        harness.validateTickRange(belowMin, 0, 60);
    }

    function test_validateTickRange_upperAboveMax() public {
        int24 aboveMax = TickMath.MAX_TICK + 60;
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector));
        harness.validateTickRange(0, aboveMax, 60);
    }

    function test_validateTickRange_lowerMisaligned() public {
        // 55 is not divisible by 60
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector));
        harness.validateTickRange(55, 120, 60);
    }

    function test_validateTickRange_upperMisaligned() public {
        // 125 is not divisible by 60
        vm.expectRevert(abi.encodeWithSelector(ReHypothecationLib.InvalidTickRange.selector));
        harness.validateTickRange(0, 125, 60);
    }

    function test_validateTickRange_valid() public pure {
        // Valid full range with tick spacing 60
        int24 tickLower = (TickMath.MIN_TICK / 60) * 60;
        int24 tickUpper = (TickMath.MAX_TICK / 60) * 60;
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, 60);
        // No revert means success
    }

    function test_validateTickRange_validNarrowRange() public pure {
        // Valid narrow range
        ReHypothecationLib.validateTickRange(-120, 120, 60);
        // No revert means success
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                             depositToYieldSource TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_depositToYieldSource_zeroAmount() public {
        uint256 shares = harness.depositToYieldSource(address(vaultA), Currency.wrap(address(tokenA)), 0);
        assertEq(shares, 0, "Zero deposit should return zero shares");
    }

    function test_depositToYieldSource_normalDeposit() public {
        uint256 depositAmount = 100e18;
        uint256 shares = harness.depositToYieldSource(address(vaultA), Currency.wrap(address(tokenA)), depositAmount);
        assertGt(shares, 0, "Should receive shares for deposit");
        assertEq(vaultA.balanceOf(address(harness)), shares, "Harness should own the shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          withdrawFromYieldSourceTo TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_withdrawFromYieldSourceTo_zeroAmount() public {
        // First deposit some
        harness.depositToYieldSource(address(vaultA), Currency.wrap(address(tokenA)), 100e18);

        // Withdraw zero
        uint256 shares = harness.withdrawFromYieldSourceTo(address(vaultA), 0, address(this));
        assertEq(shares, 0, "Zero withdrawal should return zero shares");
    }

    function test_withdrawFromYieldSourceTo_normalWithdrawal() public {
        uint256 depositAmount = 100e18;
        harness.depositToYieldSource(address(vaultA), Currency.wrap(address(tokenA)), depositAmount);

        uint256 balanceBefore = tokenA.balanceOf(address(this));
        uint256 withdrawAmount = 50e18;
        uint256 sharesRedeemed = harness.withdrawFromYieldSourceTo(address(vaultA), withdrawAmount, address(this));

        assertGt(sharesRedeemed, 0, "Should redeem shares");
        assertEq(tokenA.balanceOf(address(this)) - balanceBefore, withdrawAmount, "Should receive tokens");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          getAmountInYieldSource TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_getAmountInYieldSource_zeroShares() public view {
        uint256 amount = harness.getAmountInYieldSource(address(vaultA), 0);
        assertEq(amount, 0, "Zero shares should return zero amount");
    }

    function test_getAmountInYieldSource_nullYieldSource() public view {
        uint256 amount = harness.getAmountInYieldSource(address(0), 100e18);
        assertEq(amount, 0, "Null yield source should return zero");
    }

    function test_getAmountInYieldSource_validAmount() public {
        // Deposit to get shares
        tokenA.approve(address(vaultA), 100e18);
        uint256 shares = vaultA.deposit(100e18, address(this));

        uint256 amount = harness.getAmountInYieldSource(address(vaultA), shares);
        assertEq(amount, 100e18, "Should return correct amount for shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                           migrateYieldSource TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_migrateYieldSource_zeroShares() public {
        uint256 newShares =
            harness.migrateYieldSource(address(vaultA), address(vaultB), Currency.wrap(address(tokenA)), 0);
        assertEq(newShares, 0, "Zero shares should return zero");
    }

    function test_migrateYieldSource_normalFlow() public {
        // First deposit to vaultA
        uint256 depositAmount = 100e18;
        uint256 sharesA = harness.depositToYieldSource(address(vaultA), Currency.wrap(address(tokenA)), depositAmount);

        // Create a new vault for tokenA to migrate to
        MockYieldVault vaultA2 = new MockYieldVault(IERC20(address(tokenA)));

        // Migrate
        uint256 newShares =
            harness.migrateYieldSource(address(vaultA), address(vaultA2), Currency.wrap(address(tokenA)), sharesA);

        assertGt(newShares, 0, "Should receive new shares");
        assertEq(vaultA.balanceOf(address(harness)), 0, "Should have no shares in old vault");
        assertEq(vaultA2.balanceOf(address(harness)), newShares, "Should have shares in new vault");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                         convertSharesToAmounts TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_convertSharesToAmounts_zeroTotalShares() public pure {
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmounts(100, 0, 1000e18, 500e18);
        assertEq(amount0, 0, "Should return 0 for amount0 when totalShares is 0");
        assertEq(amount1, 0, "Should return 0 for amount1 when totalShares is 0");
    }

    function test_convertSharesToAmounts_normalConversion() public pure {
        // 50 shares out of 100 total = 50%
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmounts(50, 100, 1000e18, 500e18);
        assertEq(amount0, 500e18, "Should get 50% of amount0");
        assertEq(amount1, 250e18, "Should get 50% of amount1");
    }

    function test_convertSharesToAmounts_roundsDown() public pure {
        // 1 share out of 3 total with 10 amount = 3.333... rounds down to 3
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmounts(1, 3, 10, 10);
        assertEq(amount0, 3, "Should round down amount0");
        assertEq(amount1, 3, "Should round down amount1");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      convertSharesToAmountsRoundUp TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_convertSharesToAmountsRoundUp_zeroTotalShares() public pure {
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmountsRoundUp(100, 0, 1000e18, 500e18);
        assertEq(amount0, 0, "Should return 0 for amount0 when totalShares is 0");
        assertEq(amount1, 0, "Should return 0 for amount1 when totalShares is 0");
    }

    function test_convertSharesToAmountsRoundUp_normalConversion() public pure {
        // 50 shares out of 100 total = 50%
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmountsRoundUp(50, 100, 1000e18, 500e18);
        assertEq(amount0, 500e18, "Should get 50% of amount0");
        assertEq(amount1, 250e18, "Should get 50% of amount1");
    }

    function test_convertSharesToAmountsRoundUp_roundsUp() public pure {
        // 1 share out of 3 total with 10 amount = 3.333... rounds up to 4
        (uint256 amount0, uint256 amount1) = ReHypothecationLib.convertSharesToAmountsRoundUp(1, 3, 10, 10);
        assertEq(amount0, 4, "Should round up amount0");
        assertEq(amount1, 4, "Should round up amount1");
    }

    function test_convertSharesToAmounts_roundingDifference() public pure {
        // Verify round down vs round up produces different results
        (uint256 downAmount0,) = ReHypothecationLib.convertSharesToAmounts(1, 3, 10, 10);
        (uint256 upAmount0,) = ReHypothecationLib.convertSharesToAmountsRoundUp(1, 3, 10, 10);
        assertLt(downAmount0, upAmount0, "Round down should be less than round up");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            getLiquidityToUse TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_getLiquidityToUse_zeroAmounts() public pure {
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // ~1:1 price
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint128 liquidity = ReHypothecationLib.getLiquidityToUse(sqrtPriceX96, tickLower, tickUpper, 0, 0);
        assertEq(liquidity, 0, "Zero amounts should produce zero liquidity");
    }

    function test_getLiquidityToUse_normalAmounts() public pure {
        uint160 sqrtPriceX96 = 79228162514264337593543950336; // ~1:1 price
        int24 tickLower = -60;
        int24 tickUpper = 60;

        uint128 liquidity = ReHypothecationLib.getLiquidityToUse(sqrtPriceX96, tickLower, tickUpper, 1000e18, 1000e18);
        assertGt(liquidity, 0, "Should produce non-zero liquidity");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    SECURITY FIX: ZERO SHARES RECEIVED TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_depositToYieldSource_revertsOnZeroSharesReceived() public {
        // Deploy a malicious vault that returns 0 shares
        ZeroSharesVault maliciousVault = new ZeroSharesVault(IERC20(address(tokenA)));

        // Attempt to deposit - should revert with ZeroSharesReceived
        vm.expectRevert(ReHypothecationLib.ZeroSharesReceived.selector);
        harness.depositToYieldSource(address(maliciousVault), Currency.wrap(address(tokenA)), 100e18);
    }

    function test_depositToYieldSource_protectsAssetsFromMaliciousVault() public {
        // Deploy a malicious vault that returns 0 shares
        ZeroSharesVault maliciousVault = new ZeroSharesVault(IERC20(address(tokenA)));

        uint256 balanceBefore = tokenA.balanceOf(address(harness));

        // Attempt to deposit - should revert
        vm.expectRevert(ReHypothecationLib.ZeroSharesReceived.selector);
        harness.depositToYieldSource(address(maliciousVault), Currency.wrap(address(tokenA)), 100e18);

        // Balance should be unchanged (assets protected)
        uint256 balanceAfter = tokenA.balanceOf(address(harness));
        assertEq(balanceAfter, balanceBefore, "Assets should be protected when vault returns 0 shares");
    }
}

/**
 * @title ReHypothecationTestHarness
 * @notice Test harness to expose internal library functions
 */
contract ReHypothecationTestHarness {
    function isValidYieldSource(address yieldSource, Currency currency) external view returns (bool) {
        return ReHypothecationLib.isValidYieldSource(yieldSource, currency);
    }

    function validateTickRange(int24 tickLower, int24 tickUpper, int24 tickSpacing) external pure {
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, tickSpacing);
    }

    function depositToYieldSource(address yieldSource, Currency currency, uint256 amount) external returns (uint256) {
        return ReHypothecationLib.depositToYieldSource(yieldSource, currency, amount);
    }

    function withdrawFromYieldSourceTo(address yieldSource, uint256 amount, address recipient)
        external
        returns (uint256)
    {
        return ReHypothecationLib.withdrawFromYieldSourceTo(yieldSource, amount, recipient);
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

/**
 * @title NonERC4626Contract
 * @notice A contract that doesn't implement ERC4626 for testing
 */
contract NonERC4626Contract {
    // Empty contract - no asset() function

    }

/**
 * @title ZeroSharesVault
 * @notice A malicious ERC4626 vault that returns 0 shares on deposit
 * @dev Used to test the ZeroSharesReceived security fix
 */
contract ZeroSharesVault {
    IERC20 public immutable asset_;

    constructor(IERC20 _asset) {
        asset_ = _asset;
    }

    function asset() external view returns (address) {
        return address(asset_);
    }

    function deposit(uint256 assets, address) external returns (uint256) {
        // Transfer assets but return 0 shares (malicious behavior)
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        asset_.transferFrom(msg.sender, address(this), assets);
        return 0; // Malicious: returns 0 shares
    }
}
