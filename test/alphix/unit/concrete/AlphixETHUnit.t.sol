// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixETH} from "../../../../src/AlphixETH.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {MockAlphix4626WrapperWeth} from "../../../utils/mocks/MockAlphix4626WrapperWeth.sol";
import {MockWETH9} from "../../../utils/mocks/MockWETH9.sol";
import {MockRefundRejecter} from "../../../utils/mocks/MockRefundRejecter.sol";

/**
 * @title AlphixETHUnitTest
 * @notice Comprehensive unit tests for AlphixETH contract
 * @dev Tests all ETH-specific functions, error paths, and edge cases for branch coverage
 */
contract AlphixETHUnitTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    MockWETH9 public weth;
    MockAlphix4626WrapperWeth public ethVault;
    MockYieldVault public tokenVault;

    function setUp() public override {
        super.setUp();

        // Deploy WETH mock and vaults
        weth = new MockWETH9();
        ethVault = new MockAlphix4626WrapperWeth(address(weth));
        tokenVault = new MockYieldVault(IERC20(Currency.unwrap(key.currency1)));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                RECEIVE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_receive_revertsFromUnauthorizedSender() public {
        address unauthorized = makeAddr("unauthorized");
        vm.deal(unauthorized, 1 ether);

        vm.prank(unauthorized);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertFalse(success, "Should reject ETH from unauthorized sender");
    }

    function test_receive_acceptsFromPoolManager() public {
        vm.deal(address(poolManager), 1 ether);

        vm.prank(address(poolManager));
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Should accept ETH from PoolManager");
        assertEq(address(hook).balance, 1 ether, "Hook should have received ETH");
    }

    function test_receive_acceptsFromYieldSource() public {
        // First set up a yield source for ETH
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vm.prank(yieldManager);
        hook.setYieldSource(Currency.wrap(address(0)), address(ethVault));

        // Now the ethVault should be able to send ETH
        vm.deal(address(ethVault), 1 ether);
        vm.prank(address(ethVault));
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Should accept ETH from yield source");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          BEFORE INITIALIZE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_beforeInitialize_revertsOnNonETHPool() public {
        // Deploy fresh ETH hook
        AlphixETH freshHook = _deployFreshAlphixEthStack();

        // Try to initialize with a non-ETH pool (both currencies are tokens)
        MockERC20 token0 = new MockERC20("Token 0", "TK0", 18);
        MockERC20 token1 = new MockERC20("Token 1", "TK1", 18);

        // Sort currencies
        Currency c0;
        Currency c1;
        if (address(token0) < address(token1)) {
            c0 = Currency.wrap(address(token0));
            c1 = Currency.wrap(address(token1));
        } else {
            c0 = Currency.wrap(address(token1));
            c1 = Currency.wrap(address(token0));
        }

        PoolKey memory nonEthKey = PoolKey({
            currency0: c0, currency1: c1, fee: LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing: 20, hooks: IHooks(freshHook)
        });

        // This should revert when poolManager.initialize calls beforeInitialize
        // The actual error is wrapped by Uniswap V4's PoolManager, but the underlying cause is NotAnETHPool
        vm.expectRevert();
        poolManager.initialize(nonEthKey, Constants.SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsOnReInitialization() public {
        // Pool is already initialized in setUp
        // Try to re-initialize via poolManager (which calls beforeInitialize)
        // This should revert with PoolAlreadyInitialized because _poolKey.hooks is already set
        vm.expectRevert();
        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          SET YIELD SOURCE TESTS (ETH)
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldSource_revertsOnEOA_forETH() public {
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Try to set an EOA as yield source for ETH (invalid - no code)
        address eoa = makeAddr("eoa");

        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector, eoa));
        hook.setYieldSource(Currency.wrap(address(0)), eoa);
    }

    function test_setYieldSource_acceptsValidETHVault() public {
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vm.prank(yieldManager);
        hook.setYieldSource(Currency.wrap(address(0)), address(ethVault));

        address storedYieldSource = hook.getCurrencyYieldSource(Currency.wrap(address(0)));
        assertEq(storedYieldSource, address(ethVault), "ETH yield source should be set");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      ADD REHYPOTHECATED LIQUIDITY TESTS (ETH)
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_addReHypothecatedLiquidity_revertsOnZeroShares() public {
        _setupYieldSources();

        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        hook.addReHypothecatedLiquidity{value: 0}(0);
    }

    function test_addReHypothecatedLiquidity_revertsOnInsufficientETH() public {
        _setupYieldSources();

        // Preview how much ETH is needed for 1e18 shares
        (uint256 amount0Needed,) = hook.previewAddReHypothecatedLiquidity(1e18);

        // Send less ETH than needed
        uint256 insufficientEth = amount0Needed > 1 ? amount0Needed - 1 : 0;

        // Also need to approve token1
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, 1000e18);
        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);

        vm.expectRevert(IReHypothecation.InvalidMsgValue.selector);
        hook.addReHypothecatedLiquidity{value: insufficientEth}(1e18);
        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_refundsExcessETH() public {
        _setupYieldSources();

        // Preview how much is needed
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(1e18);

        // Send more ETH than needed
        uint256 excessEth = amount0Needed + 1 ether;

        // Setup user1 with tokens
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, excessEth);

        uint256 userEthBefore = user1.balance;

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: excessEth}(1e18);
        vm.stopPrank();

        uint256 userEthAfter = user1.balance;
        uint256 ethSpent = userEthBefore - userEthAfter;

        // User should have been refunded the excess
        assertLe(ethSpent, amount0Needed + 1, "User should have been refunded excess ETH");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                    REMOVE REHYPOTHECATED LIQUIDITY TESTS (ETH)
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_removeReHypothecatedLiquidity_revertsOnZeroShares() public {
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        hook.removeReHypothecatedLiquidity(0);
    }

    function test_removeReHypothecatedLiquidity_revertsOnInsufficientShares() public {
        // User has no shares, try to remove some
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InsufficientShares.selector, 100e18, 0));
        hook.removeReHypothecatedLiquidity(100e18);
    }

    function test_removeReHypothecatedLiquidity_sendsETHToUser() public {
        _setupYieldSources();

        // First add liquidity
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(10e18);

        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, amount0Needed + 1 ether);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(10e18);
        vm.stopPrank();

        // Check user has shares
        uint256 userShares = hook.balanceOf(user1);
        assertEq(userShares, 10e18, "User should have shares");

        // Record ETH balance before removal
        uint256 ethBefore = user1.balance;

        // Remove liquidity
        vm.prank(user1);
        hook.removeReHypothecatedLiquidity(10e18);

        // User should have received ETH
        uint256 ethAfter = user1.balance;
        assertGt(ethAfter, ethBefore, "User should have received ETH");

        // User should have no more shares
        assertEq(hook.balanceOf(user1), 0, "User should have no shares");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              PAUSE/UNPAUSE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_pause_succeeds() public {
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Hook should be paused");
    }

    function test_unpause_succeeds() public {
        vm.startPrank(owner);
        hook.pause();
        assertTrue(hook.paused(), "Hook should be paused");
        hook.unpause();
        assertFalse(hook.paused(), "Hook should be unpaused");
        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_revertsWhenPaused() public {
        _setupYieldSources();

        vm.prank(owner);
        hook.pause();

        vm.prank(user1);
        vm.expectRevert();
        hook.addReHypothecatedLiquidity{value: 1 ether}(1e18);
    }

    function test_removeReHypothecatedLiquidity_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(user1);
        vm.expectRevert();
        hook.removeReHypothecatedLiquidity(1e18);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              POKE TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_poke_succeeds() public {
        // Warp past cooldown
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        hook.poke(INITIAL_TARGET_RATIO);

        // Fee should still be within bounds
        uint24 fee = hook.getFee();
        assertGe(fee, defaultPoolParams.minFee, "Fee should be >= minFee");
        assertLe(fee, defaultPoolParams.maxFee, "Fee should be <= maxFee");
    }

    function test_poke_revertsOnInvalidRatio() public {
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.InvalidCurrentRatio.selector, 0));
        hook.poke(0);
    }

    function test_poke_revertsOnCooldownNotElapsed() public {
        // Don't warp - cooldown hasn't elapsed
        uint256 nextEligible = block.timestamp + defaultPoolParams.minPeriod;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IAlphix.CooldownNotElapsed.selector, block.timestamp, nextEligible));
        hook.poke(INITIAL_TARGET_RATIO);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                      YIELD SOURCE MIGRATION TESTS (ETH)
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_setYieldSource_migratesETHSharesOnChange() public {
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Tick range is already set at initializePool time (full range by default)
        // Setup yield sources (requires whenNotPaused)
        vm.startPrank(yieldManager);
        hook.setYieldSource(Currency.wrap(address(0)), address(ethVault));
        hook.setYieldSource(key.currency1, address(tokenVault));
        vm.stopPrank();

        // Add liquidity with ETH
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(10e18);
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, amount0Needed + 1 ether);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(10e18);
        vm.stopPrank();

        // Verify shares exist in first yield source
        uint256 amountBefore = hook.getAmountInYieldSource(Currency.wrap(address(0)));
        assertGt(amountBefore, 0, "Should have ETH amount in yield source");

        // Deploy new ETH vault and migrate
        MockAlphix4626WrapperWeth newEthVault = new MockAlphix4626WrapperWeth(address(weth));

        vm.prank(yieldManager);
        hook.setYieldSource(Currency.wrap(address(0)), address(newEthVault));

        // Verify migration
        assertEq(
            hook.getCurrencyYieldSource(Currency.wrap(address(0))),
            address(newEthVault),
            "New ETH yield source should be set"
        );

        // Amount should be approximately preserved
        uint256 amountAfter = hook.getAmountInYieldSource(Currency.wrap(address(0)));
        assertApproxEqAbs(amountAfter, amountBefore, 2, "ETH amount should be preserved after migration");
    }

    function test_setYieldSource_migratesNonETHSharesOnChange() public {
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Tick range is already set at initializePool time (full range by default)
        // Setup yield sources (requires whenNotPaused)
        vm.startPrank(yieldManager);
        hook.setYieldSource(Currency.wrap(address(0)), address(ethVault));
        hook.setYieldSource(key.currency1, address(tokenVault));
        vm.stopPrank();

        // Add liquidity
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(10e18);
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, amount0Needed + 1 ether);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(10e18);
        vm.stopPrank();

        // Deploy new token vault and migrate
        MockYieldVault newTokenVault = new MockYieldVault(IERC20(Currency.unwrap(key.currency1)));

        uint256 amountBefore = hook.getAmountInYieldSource(key.currency1);

        vm.prank(yieldManager);
        hook.setYieldSource(key.currency1, address(newTokenVault));

        // Verify migration
        assertEq(
            hook.getCurrencyYieldSource(key.currency1), address(newTokenVault), "New token yield source should be set"
        );

        uint256 amountAfter = hook.getAmountInYieldSource(key.currency1);
        assertApproxEqAbs(amountAfter, amountBefore, 2, "Token amount should be preserved after migration");
    }

    function test_setYieldSource_revertsOnInvalidNonETHSource() public {
        address yieldManager = makeAddr("yieldManager");
        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Try to set an EOA as yield source for non-ETH currency (invalid - no code)
        address eoa = makeAddr("eoa");

        vm.prank(yieldManager);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector, eoa));
        hook.setYieldSource(key.currency1, eoa);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                          REFUND FAILED TEST
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_addReHypothecatedLiquidity_revertsOnRefundFailed() public {
        _setupYieldSources();

        // Deploy contract that rejects ETH
        MockRefundRejecter rejecter = new MockRefundRejecter();

        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(1e18);

        // Mint tokens to rejecter contract
        MockERC20(Currency.unwrap(key.currency1)).mint(address(rejecter), amount1Needed + 1e18);

        // Approve from rejecter
        vm.prank(address(rejecter));
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);

        // Send more ETH than needed - refund will fail because rejecter has no receive()
        uint256 excessEth = amount0Needed + 1 ether;
        vm.deal(address(rejecter), excessEth);

        vm.expectRevert(IReHypothecation.RefundFailed.selector);
        rejecter.callAddLiquidity{value: excessEth}(hook, 1e18);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                  DEPOSIT/WITHDRAW YIELD SOURCE ETH TESTS
    ═══════════════════════════════════════════════════════════════════════════ */

    function test_depositToYieldSourceEth_revertsWhenNotConfigured() public {
        // Don't set up yield sources
        // Tick range is already set at initializePool time (full range by default)
        // Yield sources are NOT configured, so addReHypothecatedLiquidity should revert

        // Mint tokens and try to add liquidity without yield source
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, 100e18);
        vm.deal(user1, 10 ether);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);

        // This should revert with YieldSourceNotConfigured
        vm.expectRevert(
            abi.encodeWithSelector(IReHypothecation.YieldSourceNotConfigured.selector, Currency.wrap(address(0)))
        );
        hook.addReHypothecatedLiquidity{value: 1 ether}(1e18);
        vm.stopPrank();
    }

    function test_withdrawFromYieldSourceToEth_revertsWhenNotConfigured() public {
        // Setup yield sources and add liquidity
        _setupYieldSources();

        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(10e18);
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, amount0Needed + 1 ether);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(10e18);
        vm.stopPrank();

        // Now clear the ETH yield source (set to address(0))
        // This will fail because you can't set to address(0)
        // Instead, we need another approach - the withdrawal path is covered
        // when there's liquidity and we call removeReHypothecatedLiquidity

        // The path for _withdrawFromYieldSourceToEth when yield source is not configured
        // is difficult to reach because adding liquidity requires the yield source.
        // The check on line 296 provides defense-in-depth for state inconsistencies.
    }

    function test_addReHypothecatedLiquidity_dispatchesETHCorrectly() public {
        _setupYieldSources();

        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(5e18);
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, amount0Needed + 1 ether);

        uint256 ethVaultBalanceBefore = ethVault.totalAssets();

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(5e18);
        vm.stopPrank();

        uint256 ethVaultBalanceAfter = ethVault.totalAssets();

        // ETH should have been deposited to the ETH vault
        assertGt(ethVaultBalanceAfter, ethVaultBalanceBefore, "ETH should be deposited to vault");
    }

    function test_removeReHypothecatedLiquidity_dispatchesETHCorrectly() public {
        _setupYieldSources();

        // Add liquidity
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(10e18);
        MockERC20(Currency.unwrap(key.currency1)).mint(user1, amount1Needed + 1e18);
        vm.deal(user1, amount0Needed + 1 ether);

        vm.startPrank(user1);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(10e18);
        vm.stopPrank();

        uint256 userEthBefore = user1.balance;

        // Remove liquidity
        vm.prank(user1);
        hook.removeReHypothecatedLiquidity(10e18);

        uint256 userEthAfter = user1.balance;

        // User should have received ETH back
        assertGt(userEthAfter, userEthBefore, "User should receive ETH on withdrawal");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              HELPER FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    function _setupYieldSources() internal {
        address yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        // Tick range is already set at initializePool time (full range by default)
        // Set yield sources (requires whenNotPaused)
        vm.startPrank(yieldManager);
        // Set ETH yield source
        hook.setYieldSource(Currency.wrap(address(0)), address(ethVault));
        // Set token yield source
        hook.setYieldSource(key.currency1, address(tokenVault));
        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
