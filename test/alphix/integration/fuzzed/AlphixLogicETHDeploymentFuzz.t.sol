// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixLogicETH} from "../../../../src/AlphixLogicETH.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";

/**
 * @title AlphixLogicETHDeploymentFuzzTest
 * @notice Fuzz tests for AlphixLogicETH deployment, initialization, and liquidity operations
 */
contract AlphixLogicETHDeploymentFuzzTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    address public yieldManager;
    address public treasury;

    MockYieldVault public wethVault;
    MockYieldVault public tokenVault;

    function setUp() public override {
        super.setUp();
        yieldManager = makeAddr("yieldManager");
        treasury = makeAddr("treasury");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, payable(address(logic)));
        vm.stopPrank();

        // Deploy yield vaults
        wethVault = new MockYieldVault(IERC20(address(weth)));
        tokenVault = new MockYieldVault(IERC20(address(token)));

        // Setup yield sources
        vm.startPrank(yieldManager);
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);
        AlphixLogicETH(payable(address(logic))).setTickRange(tickLower, tickUpper);
        AlphixLogicETH(payable(address(logic))).setYieldSource(Currency.wrap(address(0)), address(wethVault));
        AlphixLogicETH(payable(address(logic))).setYieldSource(tokenCurrency, address(tokenVault));
        AlphixLogicETH(payable(address(logic))).setYieldTaxPips(100_000); // 10%
        AlphixLogicETH(payable(address(logic))).setYieldTreasury(treasury);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           RECEIVE FUZZ                                     */
    /* ========================================================================== */

    function testFuzz_receive_revertsFromUnauthorized(address sender) public {
        // Exclude authorized senders
        vm.assume(sender != address(weth));
        vm.assume(sender != address(poolManager));
        vm.assume(sender != address(0));
        vm.assume(uint160(sender) > 100);

        vm.deal(sender, 1 ether);
        vm.prank(sender);
        (bool success,) = address(logic).call{value: 1 ether}("");
        assertFalse(success, "Should revert from unauthorized sender");
    }

    function testFuzz_receive_acceptsFromWETH(uint256 amount) public {
        amount = bound(amount, 1 wei, 100 ether);

        vm.deal(address(weth), amount);
        vm.prank(address(weth));
        (bool success,) = address(logic).call{value: amount}("");
        assertTrue(success, "Should accept from WETH");
        assertEq(address(logic).balance, amount, "Logic should have received ETH");
    }

    function testFuzz_receive_acceptsFromPoolManager(uint256 amount) public {
        amount = bound(amount, 1 wei, 100 ether);

        vm.deal(address(poolManager), amount);
        vm.prank(address(poolManager));
        (bool success,) = address(logic).call{value: amount}("");
        assertTrue(success, "Should accept from PoolManager");
        assertEq(address(logic).balance, amount, "Logic should have received ETH");
    }

    /* ========================================================================== */
    /*                           ADD LIQUIDITY FUZZ                               */
    /* ========================================================================== */

    function testFuzz_addReHypothecatedLiquidity_withVariousShares(uint256 shares) public {
        // Bound shares to reasonable range
        shares = bound(shares, 1e15, 1000e18);

        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        // Skip if amounts would be too large
        vm.assume(amount0 < type(uint128).max && amount1 < type(uint128).max);
        vm.assume(amount0 > 0 || amount1 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Verify shares were minted
        assertEq(AlphixLogicETH(payable(address(logic))).balanceOf(alice), shares, "Shares should be minted");
    }

    function testFuzz_addReHypothecatedLiquidity_refundsExcess(uint256 shares, uint256 excess) public {
        // Bound shares to reasonable range
        shares = bound(shares, 1e15, 100e18);
        excess = bound(excess, 1 wei, 10 ether);

        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0 || amount1 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0 + excess);
        token.mint(alice, amount1);

        uint256 balanceBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0 + excess}(shares);
        vm.stopPrank();

        // Verify excess was refunded
        assertEq(alice.balance, balanceBefore - amount0, "Excess should be refunded");
    }

    function testFuzz_addReHypothecatedLiquidity_revertsWithInsufficientETH(uint256 shares) public {
        // Bound shares
        shares = bound(shares, 1e15, 100e18);

        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        // Require at least some ETH needed
        vm.assume(amount0 > 1 wei);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0 / 2); // Only half needed
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        vm.expectRevert(IReHypothecation.InvalidMsgValue.selector);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0 / 2}(shares);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           REMOVE LIQUIDITY FUZZ                            */
    /* ========================================================================== */

    function testFuzz_removeReHypothecatedLiquidity_fullRemoval(uint256 shares) public {
        // Bound shares
        shares = bound(shares, 1e15, 100e18);

        // First add liquidity
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0 || amount1 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);

        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);

        // Remove all liquidity
        AlphixLogicETH(payable(address(logic))).removeReHypothecatedLiquidity(shares);
        vm.stopPrank();

        // Verify assets returned (approximately same amount)
        assertApproxEqRel(alice.balance, ethBefore + amount0, 1e16, "Should return ETH");
        assertApproxEqRel(token.balanceOf(alice), tokenBefore + amount1, 1e16, "Should return tokens");
        assertEq(AlphixLogicETH(payable(address(logic))).balanceOf(alice), 0, "Shares should be burned");
    }

    function testFuzz_removeReHypothecatedLiquidity_partialRemoval(uint256 shares, uint256 removeRatio) public {
        // Bound parameters
        shares = bound(shares, 10e18, 100e18);
        removeRatio = bound(removeRatio, 1, 99); // 1-99%

        // First add liquidity
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0 || amount1 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);

        // Remove partial
        uint256 sharesToRemove = (shares * removeRatio) / 100;
        AlphixLogicETH(payable(address(logic))).removeReHypothecatedLiquidity(sharesToRemove);
        vm.stopPrank();

        // Verify remaining shares
        uint256 remaining = AlphixLogicETH(payable(address(logic))).balanceOf(alice);
        assertEq(remaining, shares - sharesToRemove, "Should have remaining shares");
    }

    function testFuzz_removeReHypothecatedLiquidity_revertsWithExcessiveShares(uint256 shares, uint256 extra) public {
        // Bound parameters
        shares = bound(shares, 1e15, 100e18);
        extra = bound(extra, 1, 100e18);

        // First add liquidity
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0 || amount1 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);

        // Try to remove more than owned
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InsufficientShares.selector, shares + extra, shares));
        AlphixLogicETH(payable(address(logic))).removeReHypothecatedLiquidity(shares + extra);
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           YIELD ACCUMULATION FUZZ                          */
    /* ========================================================================== */

    function testFuzz_yieldAccumulation_distributesCorrectly(uint256 shares, uint256 yieldAmount) public {
        // Bound parameters
        shares = bound(shares, 10e18, 100e18);
        yieldAmount = bound(yieldAmount, 1e15, 10e18);

        // Add liquidity
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Simulate yield
        vm.startPrank(owner);
        weth.deposit{value: yieldAmount}();
        weth.approve(address(wethVault), yieldAmount);
        wethVault.simulateYield(yieldAmount);
        vm.stopPrank();

        // Preview should reflect yield (minus 10% tax)
        (uint256 preview0,) = AlphixLogicETH(payable(address(logic))).previewRemoveReHypothecatedLiquidity(shares);

        // User should get original + 90% of yield
        uint256 expectedMin = amount0 + (yieldAmount * 90) / 100;
        assertGe(preview0, expectedMin - 1e16, "Should include yield minus tax");
    }

    function testFuzz_collectAccumulatedTax_collectsCorrectAmount(uint256 shares, uint256 yieldAmount) public {
        // Bound parameters
        shares = bound(shares, 100e18, 1000e18);
        yieldAmount = bound(yieldAmount, 1e18, 10e18);

        // Add liquidity
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Simulate yield
        vm.startPrank(owner);
        weth.deposit{value: yieldAmount}();
        weth.approve(address(wethVault), yieldAmount);
        wethVault.simulateYield(yieldAmount);
        vm.stopPrank();

        // Collect tax
        uint256 treasuryBefore = treasury.balance;
        (uint256 collected0,) = AlphixLogicETH(payable(address(logic))).collectAccumulatedTax();

        uint256 treasuryReceived = treasury.balance - treasuryBefore;

        // Treasury should receive approximately 10% of yield
        uint256 expectedTax = (yieldAmount * 100_000) / 1_000_000; // 10%
        assertApproxEqRel(treasuryReceived, expectedTax, 5e16, "Tax should be ~10% of yield");
        assertEq(collected0, treasuryReceived, "Returned amount should match received");
    }

    /* ========================================================================== */
    /*                           NEGATIVE YIELD FUZZ                              */
    /* ========================================================================== */

    function testFuzz_negativeYield_reflectsLoss(uint256 shares, uint256 lossPercent) public {
        // Bound parameters
        shares = bound(shares, 10e18, 100e18);
        lossPercent = bound(lossPercent, 1, 20); // 1-20% loss

        // Add liquidity
        (uint256 amount0, uint256 amount1) =
            AlphixLogicETH(payable(address(logic))).previewAddReHypothecatedLiquidity(shares);

        vm.assume(amount0 > 0);

        address alice = makeAddr("alice");
        vm.deal(alice, amount0);
        token.mint(alice, amount1);

        vm.startPrank(alice);
        token.approve(address(logic), amount1);
        AlphixLogicETH(payable(address(logic))).addReHypothecatedLiquidity{value: amount0}(shares);
        vm.stopPrank();

        // Simulate loss
        uint256 lossAmount = (amount0 * lossPercent) / 100;
        wethVault.simulateLoss(lossAmount);

        // Preview should reflect loss
        (uint256 preview0,) = AlphixLogicETH(payable(address(logic))).previewRemoveReHypothecatedLiquidity(shares);

        assertLt(preview0, amount0, "Should reflect loss in preview");
        assertApproxEqRel(preview0, amount0 - lossAmount, 2e16, "Loss should be approximately correct");
    }
}
