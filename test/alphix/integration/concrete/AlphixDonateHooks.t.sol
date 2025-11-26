// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {IAlphixLogic} from "../../../../src/interfaces/IAlphixLogic.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";

/**
 * @title AlphixDonateHooksTest
 * @author Alphix
 * @notice Unit tests for beforeDonate and afterDonate hook functionality
 */
contract AlphixDonateHooksTest is BaseAlphixTest {
    using CurrencyLibrary for Currency;

    address private donor;
    PoolDonateTest private donateRouter;

    function setUp() public override {
        super.setUp();

        // Deploy donate router
        donateRouter = new PoolDonateTest(poolManager);

        // Note: Base setup already initializes a pool with liquidity (key, poolId)
        // We'll use that default pool for our donation tests

        // Create a donor address with tokens
        donor = makeAddr("donor");
        deal(Currency.unwrap(currency0), donor, 1000e18);
        deal(Currency.unwrap(currency1), donor, 1000e18);
    }

    /* ========================================================================== */
    /*                            CONCRETE TESTS                                  */
    /* ========================================================================== */

    /**
     * @notice Test that beforeDonate / afterDonate hooks are called and do not revert
     */
    function test_beforeAndAfterDonate_called_on_donation() public {
        uint256 amount0 = 10e18;
        uint256 amount1 = 10e18;

        // Approve tokens
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        // Donate and verify it succeeds (beforeDonate / afterDonate are called internally)
        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Test donation with only token0
     */
    function test_donate_only_token0() public {
        uint256 amount0 = 20e18;
        uint256 amount1 = 0;

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Test donation with only token1
     */
    function test_donate_only_token1() public {
        uint256 amount0 = 0;
        uint256 amount1 = 20e18;

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Test that donate hooks respect pool activation state
     */
    function test_donate_respects_pool_activation() public {
        // Create a new pool but don't activate it
        (PoolKey memory inactiveKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.startPrank(owner);
        // Initialize on hook but then deactivate
        hook.initializePool(inactiveKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);
        hook.deactivatePool(inactiveKey);
        vm.stopPrank();

        // Try to donate - should revert because pool is deactivated
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(inactiveKey.currency0)).approve(address(donateRouter), 1e18);
        MockERC20(Currency.unwrap(inactiveKey.currency1)).approve(address(donateRouter), 1e18);

        vm.expectRevert(); // Will revert with PoolNotActivated or similar
        donateRouter.donate(inactiveKey, 1e18, 1e18, "");
        vm.stopPrank();
    }

    /**
     * @notice Test donation when contract is paused
     */
    function test_donate_fails_when_paused() public {
        // Pause the hook
        vm.prank(owner);
        hook.pause();

        // Try to donate - should fail
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), 1e18);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), 1e18);

        vm.expectRevert(); // Will revert with Paused error
        donateRouter.donate(key, 1e18, 1e18, "");
        vm.stopPrank();
    }

    /**
     * @notice Test large donation amounts
     */
    function test_donate_large_amounts() public {
        uint256 largeAmount0 = 500e18;
        uint256 largeAmount1 = 500e18;

        // Give donor more tokens
        deal(Currency.unwrap(key.currency0), donor, largeAmount0);
        deal(Currency.unwrap(key.currency1), donor, largeAmount1);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), largeAmount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), largeAmount1);

        donateRouter.donate(key, largeAmount0, largeAmount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Test donation with custom hookData
     */
    function test_donate_with_custom_hookData() public {
        uint256 amount0 = 10e18;
        uint256 amount1 = 10e18;
        bytes memory customData = abi.encode("test", uint256(123));

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate(key, amount0, amount1, customData);
        vm.stopPrank();
    }

    /**
     * @notice Test donation to pool without liquidity reverts, but succeeds with liquidity
     * @dev Uniswap V4 reverts donations to pools with no liquidity since there are no recipients
     */
    function test_donate_to_pool_without_liquidity_reverts() public {
        // Create and initialize a new pool without adding liquidity
        (PoolKey memory emptyKey,) =
            _newUninitializedPoolWithHook(18, 18, defaultTickSpacing, Constants.SQRT_PRICE_1_1, hook);

        vm.prank(owner);
        hook.initializePool(emptyKey, INITIAL_FEE, INITIAL_TARGET_RATIO, IAlphixLogic.PoolType.STANDARD);

        // Donate to empty pool - should revert with NoLiquidityToReceiveFees
        uint256 donateAmount0 = 10e18;
        uint256 donateAmount1 = 10e18;

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(emptyKey.currency0)).approve(address(donateRouter), donateAmount0);
        MockERC20(Currency.unwrap(emptyKey.currency1)).approve(address(donateRouter), donateAmount1);

        vm.expectRevert(); // NoLiquidityToReceiveFees()
        donateRouter.donate(emptyKey, donateAmount0, donateAmount1, "");
        vm.stopPrank();

        // Now add liquidity to the same pool (give this test contract tokens for the new currencies)
        deal(Currency.unwrap(emptyKey.currency0), address(this), 1000e18);
        deal(Currency.unwrap(emptyKey.currency1), address(this), 1000e18);
        seedLiquidity(emptyKey, owner, true, 0, 10e18, 10e18);

        // Donation should now succeed on the same pool (give donor tokens for emptyKey currencies)
        deal(Currency.unwrap(emptyKey.currency0), donor, donateAmount0);
        deal(Currency.unwrap(emptyKey.currency1), donor, donateAmount1);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(emptyKey.currency0)).approve(address(donateRouter), donateAmount0);
        MockERC20(Currency.unwrap(emptyKey.currency1)).approve(address(donateRouter), donateAmount1);

        donateRouter.donate(emptyKey, donateAmount0, donateAmount1, "");
        vm.stopPrank();
    }
}
