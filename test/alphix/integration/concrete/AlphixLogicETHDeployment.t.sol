// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* OZ IMPORTS */
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixETH} from "../../../../src/AlphixETH.sol";
import {AlphixLogicETH} from "../../../../src/AlphixLogicETH.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title AlphixLogicETHDeploymentTest
 * @notice Comprehensive tests for AlphixLogicETH deployment, initialization, and configuration
 */
contract AlphixLogicETHDeploymentTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    address public yieldManager;
    address public treasury;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, payable(address(logic)));
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           CONSTRUCTOR TESTS                                */
    /* ========================================================================== */

    function test_constructor_succeeds() public view {
        // AlphixLogicETH should be deployed and initialized correctly
        assertEq(AlphixLogicETH(payable(address(logic))).getWeth9(), address(weth));
        assertEq(AlphixLogicETH(payable(address(logic))).owner(), owner);
    }

    /* ========================================================================== */
    /*                           INITIALIZE TESTS                                 */
    /* ========================================================================== */

    function test_initialize_revertsWithInvalidWETHAddress() public {
        // The base initialize() function is disabled in AlphixLogicETH
        vm.startPrank(owner);

        AlphixLogicETH newImpl = new AlphixLogicETH();

        // Try to call initialize() which should revert
        vm.expectRevert(AlphixLogicETH.InvalidWETHAddress.selector);
        newImpl.initialize(owner, address(hook), address(accessManager), "Test", "TST");

        vm.stopPrank();
    }

    function test_initializeEth_revertsWithZeroWETH() public {
        vm.startPrank(owner);

        AlphixLogicETH newImpl = new AlphixLogicETH();

        // Try to initialize with zero WETH address
        vm.expectRevert(AlphixLogicETH.InvalidWETHAddress.selector);
        bytes memory initData = abi.encodeCall(
            newImpl.initializeEth, (owner, address(hook), address(accessManager), address(0), "Test", "TST")
        );
        new ERC1967Proxy(address(newImpl), initData);

        vm.stopPrank();
    }

    function test_initializeEth_setsCorrectWETH() public view {
        // Verify the WETH address is set correctly
        address weth9 = AlphixLogicETH(payable(address(logic))).getWeth9();
        assertEq(weth9, address(weth));
    }

    /* ========================================================================== */
    /*                           RECEIVE TESTS                                    */
    /* ========================================================================== */

    function test_receive_revertsFromUnauthorizedSender() public {
        address randomUser = makeAddr("randomUser");
        vm.deal(randomUser, 1 ether);

        vm.prank(randomUser);
        (bool success,) = address(logic).call{value: 1 ether}("");
        assertFalse(success, "Should revert from unauthorized sender");
    }

    function test_receive_acceptsFromWETH() public {
        // WETH can send ETH (during unwrap operations)
        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (bool success,) = address(logic).call{value: 1 ether}("");
        assertTrue(success, "Should accept from WETH");
    }

    function test_receive_acceptsFromPoolManager() public {
        // PoolManager can send ETH (during settlement)
        vm.deal(address(poolManager), 1 ether);
        vm.prank(address(poolManager));
        (bool success,) = address(logic).call{value: 1 ether}("");
        assertTrue(success, "Should accept from PoolManager");
    }

    function test_receive_revertsFromOwner() public {
        vm.prank(owner);
        (bool success,) = address(logic).call{value: 1 ether}("");
        assertFalse(success, "Should revert from owner");
    }

    /* ========================================================================== */
    /*                           BEFORE INITIALIZE TESTS                          */
    /* ========================================================================== */

    function test_beforeInitialize_revertsForNonETHPool() public {
        // Deploy a fresh ETH stack (already does startPrank/stopPrank internally)
        (AlphixETH freshHook,) = _deployFreshAlphixEthStack();

        // Try to initialize a pool where currency0 is NOT native (ETH)
        vm.startPrank(owner);

        // Create a pool key where currency0 is a token (not ETH)
        MockERC20 token0 = new MockERC20("Token0", "TK0", 18);
        MockERC20 token1 = new MockERC20("Token1", "TK1", 18);

        // Ensure token0 < token1 for proper ordering
        address t0 = address(token0);
        address t1 = address(token1);
        if (t0 > t1) {
            (t0, t1) = (t1, t0);
        }

        PoolKey memory nonEthKey = PoolKey({
            currency0: Currency.wrap(t0), // NOT native ETH
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(freshHook)
        });

        // Initialize should fail because currency0 is not ETH
        // The error is wrapped by PoolManager, so we just check for revert
        vm.expectRevert();
        poolManager.initialize(nonEthKey, Constants.SQRT_PRICE_1_1);

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           YIELD SOURCE TESTS                               */
    /* ========================================================================== */

    function test_setYieldSource_revertsWithWrongAssetForNativeCurrency() public {
        // Create a vault with wrong asset (not WETH)
        MockERC20 wrongAsset = new MockERC20("Wrong", "WRG", 18);
        MockYieldVault wrongVault = new MockYieldVault(IERC20(address(wrongAsset)));

        vm.prank(yieldManager);
        vm.expectRevert(AlphixLogicETH.YieldSourceAssetMismatch.selector);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wrongVault));
    }

    function test_setYieldSource_acceptsCorrectWETHVault() public {
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));

        vm.prank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));

        // Verify yield source is set
        address yieldSource = AlphixLogicETH(payable(address(logic))).getCurrencyYieldSource(Currency.wrap(address(0)));
        assertEq(yieldSource, address(wethVault));
    }

    function test_setYieldSource_clearsYieldSourceWithZeroAddress() public {
        // First set a yield source
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));

        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));

        // Then clear it
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(0));
        vm.stopPrank();

        // Verify yield source is cleared
        address yieldSource = AlphixLogicETH(payable(address(logic))).getCurrencyYieldSource(Currency.wrap(address(0)));
        assertEq(yieldSource, address(0));
    }

    function test_setYieldSource_migratesFromOldToNewVault() public {
        // Create two WETH vaults
        MockYieldVault vault1 = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault vault2 = new MockYieldVault(IERC20(address(weth)));

        // Set first vault
        vm.startPrank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(vault1));

        // Set tick range to enable rehypothecation
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);

        // Also set token vault
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        // Add some rehypothecated liquidity
        uint256 shares = 10e18;
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0 + 1 ether);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Now migrate to second vault
        vm.prank(yieldManager);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(vault2));

        // Verify new vault is set
        address yieldSource = AlphixLogicETH(payable(address(logic))).getCurrencyYieldSource(Currency.wrap(address(0)));
        assertEq(yieldSource, address(vault2));

        // Verify funds migrated - vault2 should have shares
        uint256 vault2Balance = vault2.balanceOf(address(logic));
        assertGt(vault2Balance, 0, "Funds should be migrated to new vault");
    }

    /* ========================================================================== */
    /*                           ADD LIQUIDITY TESTS                              */
    /* ========================================================================== */

    function test_addReHypothecatedLiquidity_revertsWithInsufficientETH() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        uint256 shares = 10e18;
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0 / 2); // Only half the required ETH
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        vm.expectRevert(IReHypothecation.InvalidMsgValue.selector);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0 / 2}(shares);
        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_refundsExcessETH() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        uint256 shares = 10e18;
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        address alice = makeAddr("alice");
        uint256 excessEth = 5 ether;
        vm.deal(alice, amount0 + excessEth);
        token.mint(alice, amount1);

        uint256 balanceBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0 + excessEth}(shares);
        vm.stopPrank();

        // Verify excess was refunded
        assertEq(alice.balance, balanceBefore - amount0, "Excess ETH should be refunded");
    }

    function test_addReHypothecatedLiquidity_revertsWithZeroShares() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        vm.stopPrank();

        address alice = makeAddr("alice");
        vm.deal(alice, 1 ether);

        vm.startPrank(alice);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: 1 ether}(0);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           REMOVE LIQUIDITY TESTS                           */
    /* ========================================================================== */

    function test_removeReHypothecatedLiquidity_revertsWithZeroShares() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        AlphixLogicETH(payable(address(logic))).removeReHypothecatedLiquidity(0);
    }

    function test_removeReHypothecatedLiquidity_revertsWithInsufficientShares() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InsufficientShares.selector, 100e18, 0));
        AlphixLogicETH(payable(address(logic))).removeReHypothecatedLiquidity(100e18);
    }

    function test_removeReHypothecatedLiquidity_sendsETHToUser() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        // Add liquidity
        uint256 shares = 10e18;
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);

        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);

        // Remove liquidity
        AlphixLogicETH(payable(address(logic))).removeReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Verify ETH and tokens were returned
        assertGt(alice.balance, ethBefore, "Should receive ETH");
        assertGt(token.balanceOf(alice), tokenBefore, "Should receive tokens");
    }

    /* ========================================================================== */
    /*                           COLLECT TAX TESTS                                */
    /* ========================================================================== */

    function test_collectAccumulatedTax_collectsETHTax() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000); // 10%
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        // Add liquidity
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Simulate yield
        uint256 yieldAmount = 10e18;
        vm.startPrank(owner);
        weth.deposit{value: yieldAmount}();
        weth.approve(address(wethVault), yieldAmount);
        wethVault.simulateYield(yieldAmount);
        vm.stopPrank();

        // Collect tax
        uint256 treasuryBefore = treasury.balance;
        AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();

        // Verify treasury received ETH (approximately 10% of yield)
        uint256 treasuryReceived = treasury.balance - treasuryBefore;
        assertGt(treasuryReceived, 0, "Treasury should receive tax");
    }

    function test_collectAccumulatedTax_returnsZeroWithNoYieldSource() public {
        // No yield sources configured, should return 0,0
        (uint256 collected0, uint256 collected1) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();
        assertEq(collected0, 0, "Should return 0 for currency0");
        assertEq(collected1, 0, "Should return 0 for currency1");
    }

    /* ========================================================================== */
    /*                           DEPOSIT/WITHDRAW TO YIELD SOURCE                 */
    /* ========================================================================== */

    function test_depositToYieldSource_revertsFromNonHook() public {
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        AlphixLogicETH(payable(address(logic))).depositToYieldSource(Currency.wrap(address(0)), 1 ether);
    }

    function test_withdrawAndApprove_revertsFromNonHook() public {
        vm.prank(owner);
        vm.expectRevert(IAlphixLogic.InvalidCaller.selector);
        AlphixLogicETH(payable(address(logic))).withdrawAndApprove(Currency.wrap(address(0)), 1 ether);
    }

    /* ========================================================================== */
    /*                           GETTER TESTS                                     */
    /* ========================================================================== */

    function test_getWeth9_returnsCorrectAddress() public view {
        address weth9 = AlphixLogicETH(payable(address(logic))).getWeth9();
        assertEq(weth9, address(weth));
    }

    /* ========================================================================== */
    /*                           ETH TRANSFER FAILURE                             */
    /* ========================================================================== */

    function test_addReHypothecatedLiquidity_handlesExcessRefund() public {
        // Setup yield sources
        MockYieldVault wethVault = new MockYieldVault(IERC20(address(weth)));
        MockYieldVault tokenVault = new MockYieldVault(IERC20(address(token)));

        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000);
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();

        // Add liquidity with exact amount (no refund needed)
        uint256 shares = 10e18;
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Verify balance is 0 (all ETH was used)
        assertEq(alice.balance, 0, "All ETH should be used");
    }
}
