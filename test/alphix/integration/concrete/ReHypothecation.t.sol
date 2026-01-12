// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

/* UNISWAP V4 IMPORTS */
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {AlphixLogic} from "../../../../src/AlphixLogic.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title ReHypothecationTest
 * @notice Tests for ReHypothecation functionality in AlphixLogic.
 */
contract ReHypothecationTest is BaseAlphixTest {
    MockYieldVault public vault0;
    MockYieldVault public vault1;

    address public yieldManager;
    address public treasury;

    int24 public reHypoTickLower;
    int24 public reHypoTickUpper;

    function setUp() public override {
        super.setUp();

        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");

        vm.startPrank(owner);

        // Deploy yield vaults for each currency
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        // Configure YIELD_MANAGER_ROLE via AccessManager
        _setupYieldManagerRole(yieldManager, accessManager, address(logic));

        // Configure rehypothecation for the pool
        reHypoTickLower = TickMath.minUsableTick(defaultTickSpacing);
        reHypoTickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        vm.stopPrank();

        // Configure yield sources as yield manager
        vm.startPrank(yieldManager);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setTickRange(reHypoTickLower, reHypoTickUpper);
        AlphixLogic(address(logic)).setYieldTaxPips(100_000); // 10% tax (100000 pips = 10%)
        AlphixLogic(address(logic)).setYieldTreasury(treasury);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    YIELD MANAGER ROLE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_grantYieldManagerRole_success() public {
        address newManager = makeAddr("newManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(newManager, accessManager, address(logic));
        vm.stopPrank();

        // New manager should now be able to call yield manager functions
        vm.prank(newManager);
        AlphixLogic(address(logic)).setYieldTaxPips(50_000);
        assertEq(AlphixLogic(address(logic)).getReHypothecationConfig().yieldTaxPips, 50_000);
    }

    function test_revokeYieldManagerRole_preventsAccess() public {
        // Revoke yield manager role
        vm.prank(owner);
        accessManager.revokeRole(YIELD_MANAGER_ROLE, yieldManager);

        // yieldManager should no longer be able to call yield manager functions
        vm.prank(yieldManager);
        vm.expectRevert();
        AlphixLogic(address(logic)).setYieldTaxPips(50_000);
    }

    function test_ownerWithYieldManagerRoleCanCallFunctions() public {
        // Grant owner the YIELD_MANAGER_ROLE too
        vm.prank(owner);
        accessManager.grantRole(YIELD_MANAGER_ROLE, owner, 0);

        vm.prank(owner);
        AlphixLogic(address(logic)).setYieldTaxPips(50_000); // 5%
        assertEq(AlphixLogic(address(logic)).getReHypothecationConfig().yieldTaxPips, 50_000);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    SET YIELD SOURCE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldSource_success() public {
        MockYieldVault newVault = new MockYieldVault(IERC20(Currency.unwrap(currency0)));

        vm.prank(yieldManager);
        vm.expectEmit(true, true, true, true);
        emit IReHypothecation.YieldSourceUpdated(currency0, address(vault0), address(newVault));
        AlphixLogic(address(logic)).setYieldSource(currency0, address(newVault));

        assertEq(AlphixLogic(address(logic)).getCurrencyYieldSource(currency0), address(newVault));
    }

    function test_setYieldSource_reverts_invalidYieldSource() public {
        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector, address(0)));
        AlphixLogic(address(logic)).setYieldSource(currency0, address(0));
    }

    function test_setYieldSource_reverts_assetMismatch() public {
        // Create a vault for a different token
        MockERC20 otherToken = new MockERC20("Other", "OTH", 18);
        MockYieldVault wrongVault = new MockYieldVault(IERC20(address(otherToken)));

        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector, address(wrongVault)));
        AlphixLogic(address(logic)).setYieldSource(currency0, address(wrongVault));
    }

    function test_setYieldSource_reverts_notYieldManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorized));
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
    }

    function test_setYieldSource_reverts_nativeCurrency() public {
        Currency native = Currency.wrap(address(0));
        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector, address(vault0)));
        AlphixLogic(address(logic)).setYieldSource(native, address(vault0));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    SET TICK RANGE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_setTickRange_success() public {
        int24 newLower = -100 * defaultTickSpacing;
        int24 newUpper = 100 * defaultTickSpacing;

        vm.prank(yieldManager);
        vm.expectEmit(true, true, true, true);
        emit IReHypothecation.TickRangeUpdated(newLower, newUpper);
        AlphixLogic(address(logic)).setTickRange(newLower, newUpper);

        IReHypothecation.ReHypothecationConfig memory config = AlphixLogic(address(logic)).getReHypothecationConfig();
        assertEq(config.tickLower, newLower);
        assertEq(config.tickUpper, newUpper);
    }

    function test_setTickRange_reverts_invalidRange() public {
        vm.prank(yieldManager);
        vm.expectRevert();
        AlphixLogic(address(logic)).setTickRange(100, -100); // lower > upper
    }

    function test_setTickRange_reverts_notAlignedWithTickSpacing() public {
        vm.prank(yieldManager);
        vm.expectRevert();
        AlphixLogic(address(logic)).setTickRange(-101, 100); // not aligned
    }

    function test_setTickRange_reverts_notYieldManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorized));
        AlphixLogic(address(logic)).setTickRange(-100, 100);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    SET YIELD TAX TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldTaxPips_success() public {
        vm.prank(yieldManager);
        vm.expectEmit(true, true, true, true);
        emit IReHypothecation.YieldTaxUpdated(50_000); // 5%
        AlphixLogic(address(logic)).setYieldTaxPips(50_000);

        assertEq(AlphixLogic(address(logic)).getReHypothecationConfig().yieldTaxPips, 50_000);
    }

    function test_setYieldTaxPips_canSetToZero() public {
        vm.prank(yieldManager);
        AlphixLogic(address(logic)).setYieldTaxPips(0);
        assertEq(AlphixLogic(address(logic)).getReHypothecationConfig().yieldTaxPips, 0);
    }

    function test_setYieldTaxPips_canSetToMax() public {
        vm.prank(yieldManager);
        AlphixLogic(address(logic)).setYieldTaxPips(1_000_000); // 100%
        assertEq(AlphixLogic(address(logic)).getReHypothecationConfig().yieldTaxPips, 1_000_000);
    }

    function test_setYieldTaxPips_reverts_exceedsMax() public {
        vm.prank(yieldManager);
        vm.expectRevert();
        AlphixLogic(address(logic)).setYieldTaxPips(1_000_001);
    }

    function test_setYieldTaxPips_reverts_notYieldManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorized));
        AlphixLogic(address(logic)).setYieldTaxPips(50_000);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    SET YIELD TREASURY TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldTreasury_success() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(yieldManager);
        vm.expectEmit(true, true, true, true);
        emit IReHypothecation.YieldTreasuryUpdated(treasury, newTreasury);
        AlphixLogic(address(logic)).setYieldTreasury(newTreasury);

        assertEq(AlphixLogic(address(logic)).getYieldTreasury(), newTreasury);
    }

    function test_setYieldTreasury_reverts_zeroAddress() public {
        vm.prank(yieldManager);
        vm.expectRevert(IAlphixLogic.InvalidAddress.selector);
        AlphixLogic(address(logic)).setYieldTreasury(address(0));
    }

    function test_setYieldTreasury_reverts_notYieldManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorized));
        AlphixLogic(address(logic)).setYieldTreasury(makeAddr("newTreasury"));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                ADD LIQUIDITY TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_addReHypothecatedLiquidity_success() public {
        uint256 shares = 1000e18;

        // Preview amounts
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);

        // Approve tokens
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);

        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(user1);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IReHypothecation.ReHypothecatedLiquidityAdded(user1, shares, amount0, amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);

        // Verify shares minted (ERC20 shares now)
        assertEq(AlphixLogic(address(logic)).balanceOf(user1), shares);
        assertEq(AlphixLogic(address(logic)).totalSupply(), shares);

        // Verify tokens transferred
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(user1), balance0Before - amount0);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(user1), balance1Before - amount1);

        // Verify deposited in yield source
        assertGt(AlphixLogic(address(logic)).getAmountInYieldSource(currency0), 0);
        assertGt(AlphixLogic(address(logic)).getAmountInYieldSource(currency1), 0);

        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_reverts_zeroShares() public {
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(0);
    }

    function test_addReHypothecatedLiquidity_reverts_poolNotActive() public {
        // Deactivate pool (must be called by owner)
        vm.prank(owner);
        hook.deactivatePool();

        vm.prank(user1);
        vm.expectRevert(IAlphixLogic.PoolPaused.selector);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(1000e18);
    }

    function test_addReHypothecatedLiquidity_multipleUsers() public {
        uint256 shares1 = 1000e18;
        uint256 shares2 = 500e18;

        // User1 deposits
        (uint256 amount0User1, uint256 amount1User1) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares1);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User1);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares1);
        vm.stopPrank();

        // User2 deposits
        (uint256 amount0User2, uint256 amount1User2) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares2);
        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User2);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User2);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares2);
        vm.stopPrank();

        // Verify balances
        assertEq(AlphixLogic(address(logic)).balanceOf(user1), shares1);
        assertEq(AlphixLogic(address(logic)).balanceOf(user2), shares2);
        assertEq(AlphixLogic(address(logic)).totalSupply(), shares1 + shares2);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                REMOVE LIQUIDITY TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_removeReHypothecatedLiquidity_success() public {
        // First add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);

        // Remove liquidity
        uint256 balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(user1);
        uint256 balance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(user1);

        vm.expectEmit(true, true, true, true);
        emit IReHypothecation.ReHypothecatedLiquidityRemoved(user1, shares, amount0, amount1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(shares);

        // Verify shares burned
        assertEq(AlphixLogic(address(logic)).balanceOf(user1), 0);
        assertEq(AlphixLogic(address(logic)).totalSupply(), 0);

        // Verify tokens returned
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(user1), balance0Before + amount0);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(user1), balance1Before + amount1);

        vm.stopPrank();
    }

    function test_removeReHypothecatedLiquidity_reverts_zeroShares() public {
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(0);
    }

    function test_removeReHypothecatedLiquidity_reverts_insufficientShares() public {
        // Add some liquidity first
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);

        // Try to remove more than owned
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InsufficientShares.selector, shares + 1, shares));
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(shares + 1);
        vm.stopPrank();
    }

    function test_removeReHypothecatedLiquidity_partial() public {
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);

        // Remove half
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(shares / 2);

        assertEq(AlphixLogic(address(logic)).balanceOf(user1), shares / 2);
        assertEq(AlphixLogic(address(logic)).totalSupply(), shares / 2);
        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                            COLLECT ACCUMULATED TAX TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_collectAccumulatedTax_withPositiveYield() public {
        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate yield
        uint256 yield0 = 100e18;
        uint256 yield1 = 100e18;
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency1)).mint(owner, yield1);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        MockERC20(Currency.unwrap(currency1)).approve(address(vault1), yield1);
        vault0.simulateYield(yield0);
        vault1.simulateYield(yield1);
        vm.stopPrank();

        uint256 treasuryBalance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(treasury);
        uint256 treasuryBalance1Before = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        // Collect accumulated tax
        (uint256 collected0, uint256 collected1) = AlphixLogic(address(logic)).collectAccumulatedTax();

        // Verify tax is approximately 10% of yield (allow some tolerance for rounding)
        assertApproxEqAbs(collected0, yield0 / 10, 2);
        assertApproxEqAbs(collected1, yield1 / 10, 2);

        // Verify treasury received tax (allow rounding tolerance)
        assertApproxEqAbs(
            MockERC20(Currency.unwrap(currency0)).balanceOf(treasury), treasuryBalance0Before + collected0, 1
        );
        assertApproxEqAbs(
            MockERC20(Currency.unwrap(currency1)).balanceOf(treasury), treasuryBalance1Before + collected1, 1
        );

        // Verify accumulated tax is reset
        assertEq(AlphixLogic(address(logic)).getAccumulatedTax(currency0), 0);
        assertEq(AlphixLogic(address(logic)).getAccumulatedTax(currency1), 0);
    }

    function test_collectAccumulatedTax_noYield() public {
        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Collect with no yield - should return 0
        (uint256 collected0, uint256 collected1) = AlphixLogic(address(logic)).collectAccumulatedTax();

        assertEq(collected0, 0);
        assertEq(collected1, 0);
    }

    function test_collectAccumulatedTax_withZeroTax() public {
        // Set tax to 0
        vm.prank(yieldManager);
        AlphixLogic(address(logic)).setYieldTaxPips(0);

        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate yield
        uint256 yield0 = 100e18;
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        vault0.simulateYield(yield0);
        vm.stopPrank();

        // Collect - should return 0 since tax is 0
        (uint256 collected0,) = AlphixLogic(address(logic)).collectAccumulatedTax();

        assertEq(collected0, 0);
    }

    function test_collectAccumulatedTax_negativeYield() public {
        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate loss (negative yield)
        uint256 loss = amount0 / 10; // 10% loss
        vault0.simulateLoss(loss);

        // Collect - should report 0 since no positive yield
        (uint256 collected0,) = AlphixLogic(address(logic)).collectAccumulatedTax();

        assertEq(collected0, 0);
    }

    function test_collectAccumulatedTax_permissionless() public {
        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Anyone can call collectAccumulatedTax
        vm.prank(unauthorized);
        AlphixLogic(address(logic)).collectAccumulatedTax();
    }

    function test_yieldTaxAccumulatesOnLiquidityModification() public {
        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate yield
        uint256 yield0 = 100e18;
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yield0);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yield0);
        vault0.simulateYield(yield0);
        vm.stopPrank();

        // Add more liquidity - this should accumulate tax
        uint256 shares2 = 500e18;
        (uint256 amount0User2, uint256 amount1User2) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares2);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User2);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User2);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares2);
        vm.stopPrank();

        // Verify accumulated tax is non-zero (approximately 10% of yield)
        uint256 accumulatedTax = AlphixLogic(address(logic)).getAccumulatedTax(currency0);
        assertApproxEqAbs(accumulatedTax, yield0 / 10, 2);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                VIEW FUNCTIONS TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_getCurrencyYieldSource() public view {
        assertEq(AlphixLogic(address(logic)).getCurrencyYieldSource(currency0), address(vault0));
        assertEq(AlphixLogic(address(logic)).getCurrencyYieldSource(currency1), address(vault1));
    }

    function test_getReHypothecationConfig() public view {
        IReHypothecation.ReHypothecationConfig memory config = AlphixLogic(address(logic)).getReHypothecationConfig();

        assertEq(config.tickLower, reHypoTickLower);
        assertEq(config.tickUpper, reHypoTickUpper);
        assertEq(config.yieldTaxPips, 100_000); // 10% = 100000 pips
    }

    function test_getYieldTreasury() public view {
        assertEq(AlphixLogic(address(logic)).getYieldTreasury(), treasury);
    }

    function test_previewAddReHypothecatedLiquidity_initial() public view {
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);

        // Initial deposit uses pool price - amounts should be non-zero
        assertGt(amount0, 0);
        assertGt(amount1, 0);
    }

    function test_previewAddReHypothecatedLiquidity_afterDeposit() public {
        // First deposit
        uint256 shares1 = 1000e18;
        (uint256 amount0User1, uint256 amount1User1) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares1);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User1);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares1);
        vm.stopPrank();

        // Preview second deposit
        uint256 shares2 = 500e18;
        (uint256 amount0User2, uint256 amount1User2) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares2);

        // Should be proportional to existing balances
        assertApproxEqRel(amount0User2, amount0User1 / 2, 1e16); // 1% tolerance
        assertApproxEqRel(amount1User2, amount1User1 / 2, 1e16);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                MIGRATION TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldSource_migratesLiquidity() public {
        // Add liquidity
        uint256 shares = 1000e18;
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        uint256 amountInOldVault = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        assertGt(amountInOldVault, 0);

        // Create new vault and migrate
        MockYieldVault newVault = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vm.prank(yieldManager);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(newVault));

        // Verify migration
        assertEq(AlphixLogic(address(logic)).getCurrencyYieldSource(currency0), address(newVault));
        uint256 amountInNewVault = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        assertApproxEqRel(amountInNewVault, amountInOldVault, 1e16); // Allow 1% slippage due to vault operations
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                ERC165 TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    function test_supportsInterface_IReHypothecation() public view {
        assertTrue(AlphixLogic(address(logic)).supportsInterface(type(IReHypothecation).interfaceId));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                        YIELD SOURCE FAILURE / NEGATIVE YIELD TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test partial loss in yield source - user withdrawals still work
     * @dev Simulates a 10% loss scenario where users receive less than deposited
     */
    function test_negativeYield_partialLoss_withdrawalStillWorks() public {
        uint256 shares = 1000e18;

        // Add liquidity
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Record balances before loss
        uint256 amountInVault0Before = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);

        // Simulate 10% loss
        uint256 loss = amountInVault0Before / 10;
        vault0.simulateLoss(loss);

        // Preview withdrawal - should show reduced amounts
        (uint256 previewAmount0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares);

        // Amount should be less than originally deposited
        assertLt(previewAmount0, amount0, "Preview should show loss");

        // Withdrawal should still succeed
        uint256 user1Balance0Before = MockERC20(Currency.unwrap(currency0)).balanceOf(user1);

        vm.prank(user1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(shares);

        uint256 user1Balance0After = MockERC20(Currency.unwrap(currency0)).balanceOf(user1);

        // User should have received less than deposited (loss absorbed)
        assertEq(user1Balance0After - user1Balance0Before, previewAmount0);
        assertLt(user1Balance0After - user1Balance0Before, amount0);
    }

    /**
     * @notice Test significant loss (50%) - system remains functional
     * @dev Ensures the protocol doesn't break with major losses
     */
    function test_negativeYield_majorLoss_50percent() public {
        uint256 shares = 1000e18;

        // Add liquidity
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate 50% loss on currency0
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss(amountInVault0 / 2);

        // Preview and verify reduced amounts
        (uint256 previewAmount0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares);
        assertApproxEqRel(previewAmount0, amount0 / 2, 1e16); // ~50% remaining, 1% tolerance

        // Withdrawal should still work
        vm.prank(user1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(shares);

        // Shares should be burned
        assertEq(AlphixLogic(address(logic)).balanceOf(user1), 0);
    }

    /**
     * @notice Test that tax accumulation handles negative yield correctly
     * @dev No tax should be accumulated when yield is negative
     */
    function test_negativeYield_noTaxAccumulated() public {
        uint256 shares = 1000e18;

        // Add liquidity
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate loss
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss(amountInVault0 / 10);

        // Trigger tax accumulation via collectAccumulatedTax
        (uint256 collected0, uint256 collected1) = AlphixLogic(address(logic)).collectAccumulatedTax();

        // No tax should be collected on negative yield
        assertEq(collected0, 0, "No tax on negative yield for currency0");
        assertEq(collected1, 0, "No tax on negative yield for currency1");
    }

    /**
     * @notice Test multiple users during loss - proportional loss distribution
     * @dev Ensures losses are distributed fairly among all LPs
     */
    function test_negativeYield_multipleUsers_proportionalLoss() public {
        uint256 shares1 = 1000e18;
        uint256 shares2 = 500e18;

        // User1 deposits
        (uint256 amount0User1, uint256 amount1User1) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares1);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User1);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares1);
        vm.stopPrank();

        // User2 deposits
        (uint256 amount0User2, uint256 amount1User2) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares2);
        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User2);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User2);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares2);
        vm.stopPrank();

        // Simulate 20% loss
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss(amountInVault0 / 5);

        // Preview withdrawals
        (uint256 preview0User1,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares1);
        (uint256 preview0User2,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares2);

        // Loss should be proportional to shares
        // User1 has 2x the shares of User2, so should have 2x the remaining amount
        assertApproxEqRel(preview0User1, preview0User2 * 2, 1e16);
    }

    /**
     * @notice Test recovery after loss - new deposits work correctly
     * @dev Ensures new depositors don't subsidize old losses
     */
    function test_negativeYield_recoveryAfterLoss_newDepositsWork() public {
        uint256 shares1 = 1000e18;

        // User1 deposits
        (uint256 amount0User1, uint256 amount1User1) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares1);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User1);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares1);
        vm.stopPrank();

        // Simulate 30% loss
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss((amountInVault0 * 30) / 100);

        // User2 deposits AFTER the loss
        uint256 shares2 = 500e18;
        (uint256 amount0User2, uint256 amount1User2) =
            AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares2);

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0User2);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1User2);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares2);
        vm.stopPrank();

        // Now preview User2's withdrawal - should get back what they deposited (no extra loss)
        (uint256 preview0User2,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares2);

        // User2 should get back approximately what they deposited (within rounding)
        assertApproxEqRel(preview0User2, amount0User2, 1e16);
    }

    /**
     * @notice Test loss followed by yield - correct accounting
     * @dev Ensures yield after loss is tracked correctly
     */
    function test_negativeYield_thenPositiveYield_correctAccounting() public {
        uint256 shares = 1000e18;

        // Add liquidity
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate 20% loss
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss(amountInVault0 / 5);

        // Collect tax (should be 0 due to loss)
        (uint256 collected0AfterLoss,) = AlphixLogic(address(logic)).collectAccumulatedTax();
        assertEq(collected0AfterLoss, 0);

        // Now simulate positive yield (30% of remaining)
        uint256 amountAfterLoss = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        uint256 yieldAmount = (amountAfterLoss * 30) / 100;
        vm.startPrank(owner);
        MockERC20(Currency.unwrap(currency0)).mint(owner, yieldAmount);
        MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yieldAmount);
        vault0.simulateYield(yieldAmount);
        vm.stopPrank();

        // Now collect tax - should collect 10% of the NEW yield only
        (uint256 collected0AfterYield,) = AlphixLogic(address(logic)).collectAccumulatedTax();
        assertApproxEqAbs(collected0AfterYield, yieldAmount / 10, 2);
    }

    /**
     * @notice Test near-total loss (90%) - edge case handling
     * @dev Ensures the system handles extreme loss scenarios
     */
    function test_negativeYield_nearTotalLoss_90percent() public {
        uint256 shares = 1000e18;

        // Add liquidity
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate 90% loss
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss((amountInVault0 * 90) / 100);

        // Preview should show ~10% remaining
        (uint256 preview0,) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares);
        assertApproxEqRel(preview0, amount0 / 10, 1e16);

        // Withdrawal should still work
        vm.prank(user1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(shares);

        // Verify user got the reduced amount
        assertEq(AlphixLogic(address(logic)).balanceOf(user1), 0);
    }

    /**
     * @notice Test loss on only one currency - other currency unaffected
     * @dev Ensures currency isolation in loss scenarios
     */
    function test_negativeYield_oneCurrencyLoss_otherUnaffected() public {
        uint256 shares = 1000e18;

        // Add liquidity
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Simulate 50% loss on currency0 ONLY
        uint256 amountInVault0 = AlphixLogic(address(logic)).getAmountInYieldSource(currency0);
        vault0.simulateLoss(amountInVault0 / 2);

        // Preview withdrawal
        (uint256 preview0, uint256 preview1) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(shares);

        // Currency0 should show ~50% loss
        assertApproxEqRel(preview0, amount0 / 2, 1e16);

        // Currency1 should be unaffected
        assertApproxEqRel(preview1, amount1, 1e16);
    }

    // Exclude from coverage
    function test() public {}
}
