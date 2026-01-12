// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {OlympixUnitTest} from "../utils/OlympixUnitTest.sol";
import {BaseAlphixTest} from "../alphix/BaseAlphix.t.sol";
import {AlphixLogic} from "../../src/AlphixLogic.sol";
import {IAlphixLogic} from "../../src/interfaces/IAlphixLogic.sol";
import {IReHypothecation} from "../../src/interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";
import {MockYieldVault} from "../utils/mocks/MockYieldVault.sol";

/**
 * @title AlphixLogicTest
 * @notice Olympix-generated unit tests for AlphixLogic contract
 * @dev Tests the upgradeable logic contract functionality including:
 *      - Pool activation and configuration
 *      - Dynamic fee computation
 *      - EMA target ratio updates
 *      - Rehypothecation (yield source deposits/withdrawals)
 *      - ERC20 share token functionality
 *      - Yield tax collection
 */
contract AlphixLogicTest is OlympixUnitTest("AlphixLogic"), BaseAlphixTest {
    // Yield sources for testing rehypothecation
    MockYieldVault public vault0;
    MockYieldVault public vault1;

    /* ========================================================================== */
    /*                              SETUP                                         */
    /* ========================================================================== */

    function setUp() public override {
        super.setUp();

        // Deploy mock yield vaults
        vm.startPrank(owner);
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    /**
     * @notice Helper to configure rehypothecation for testing
     */
    function _setupRehypothecation() internal {
        vm.startPrank(owner);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        AlphixLogic(address(logic)).setYieldTaxPips(100_000); // 10%
        AlphixLogic(address(logic)).setYieldTreasury(owner);
        vm.stopPrank();
    }

    /**
     * @notice Helper to add rehypothecated liquidity
     * @param user The user adding liquidity
     * @param shares Amount of shares to mint
     */
    function _addRehypothecatedLiquidity(address user, uint256 shares) internal {
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewAddReHypothecatedLiquidity(shares);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).mint(user, amount0);
        MockERC20(Currency.unwrap(currency1)).mint(user, amount1);
        MockERC20(Currency.unwrap(currency0)).approve(address(logic), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(logic), amount1);
        AlphixLogic(address(logic)).addReHypothecatedLiquidity(shares);
        vm.stopPrank();
    }

    /**
     * @notice Helper to simulate yield in vault
     * @dev Yield is simulated by directly transferring tokens to the vault WITHOUT minting shares.
     *      This increases the exchange rate (assets per share), which is how real yield works in ERC4626.
     * @param vault The vault to add yield to
     * @param token The token to add
     * @param amount The yield amount
     */
    function _simulateYield(MockYieldVault vault, Currency token, uint256 amount) internal {
        // Directly transfer tokens to vault to increase rate (don't use deposit which mints shares)
        MockERC20(Currency.unwrap(token)).mint(address(vault), amount);
    }

    /**
     * @notice Helper to get pool params
     */
    function _getPoolParams() internal view returns (DynamicFeeLib.PoolParams memory) {
        return logic.getPoolParams();
    }

    /**
     * @notice Helper to get pool config
     */
    function _getPoolConfig() internal view returns (IAlphixLogic.PoolConfig memory) {
        return logic.getPoolConfig();
    }

    /* ========================================================================== */
    /*                           EXAMPLE TESTS                                    */
    /* ========================================================================== */

    /**
     * @notice Test that logic contract is properly initialized
     */
    function test_logicInitialized() public view {
        assertTrue(address(logic) != address(0), "Logic should be deployed");
        IAlphixLogic.PoolConfig memory config = _getPoolConfig();
        assertTrue(config.isConfigured, "Pool should be configured");
    }

    /**
     * @notice Test pool params are set correctly
     */
    function test_poolParamsSet() public view {
        DynamicFeeLib.PoolParams memory params = _getPoolParams();
        assertTrue(params.minFee > 0, "Min fee should be set");
        assertTrue(params.maxFee >= params.minFee, "Max fee should be >= min fee");
        assertTrue(params.minPeriod > 0, "Min period should be set");
    }

    /**
     * @notice Test rehypothecation configuration
     */
    function test_configureRehypothecation() public {
        _setupRehypothecation();

        address configuredVault0 = AlphixLogic(address(logic)).getCurrencyYieldSource(currency0);
        address configuredVault1 = AlphixLogic(address(logic)).getCurrencyYieldSource(currency1);

        assertEq(configuredVault0, address(vault0), "Vault0 should be configured");
        assertEq(configuredVault1, address(vault1), "Vault1 should be configured");
    }

    /**
     * @notice Test adding rehypothecated liquidity mints shares
     */
    function test_addRehypothecatedLiquidity() public {
        _setupRehypothecation();

        uint256 shares = 100e18;
        _addRehypothecatedLiquidity(user1, shares);

        uint256 balance = AlphixLogic(address(logic)).balanceOf(user1);
        assertEq(balance, shares, "User should have shares");
    }

    /**
     * @notice Test removing rehypothecated liquidity burns shares
     */
    function test_removeRehypothecatedLiquidity() public {
        _setupRehypothecation();

        uint256 shares = 100e18;
        _addRehypothecatedLiquidity(user1, shares);

        uint256 sharesToRemove = 50e18;
        vm.prank(user1);
        AlphixLogic(address(logic)).removeReHypothecatedLiquidity(sharesToRemove);

        uint256 remainingBalance = AlphixLogic(address(logic)).balanceOf(user1);
        assertEq(remainingBalance, shares - sharesToRemove, "Should have remaining shares");
    }

    /**
     * @notice Test ERC20 share transfers
     */
    function test_shareTransfer() public {
        _setupRehypothecation();

        uint256 shares = 100e18;
        _addRehypothecatedLiquidity(user1, shares);

        uint256 transferAmount = 30e18;
        vm.prank(user1);
        require(AlphixLogic(address(logic)).transfer(user2, transferAmount), "Transfer failed");

        assertEq(AlphixLogic(address(logic)).balanceOf(user1), shares - transferAmount, "User1 balance after transfer");
        assertEq(AlphixLogic(address(logic)).balanceOf(user2), transferAmount, "User2 balance after transfer");
    }

    /**
     * @notice Test yield tax accumulation
     * @dev Tax is accumulated during collectAccumulatedTax, beforeSwap, or liquidity operations.
     *      The poke function only updates fees and does not trigger yield tax accumulation.
     */
    function test_yieldTaxAccumulation() public {
        _setupRehypothecation();

        // Add initial liquidity (this deposits to vaults)
        _addRehypothecatedLiquidity(user1, 100e18);

        // Simulate yield on vault0 by minting tokens directly to the vault
        // This increases the exchange rate (assets per share) without minting new shares
        _simulateYield(vault0, currency0, 10e18);

        // Simulate yield on vault1 as well to keep balanced
        _simulateYield(vault1, currency1, 10e18);

        // Now call collectAccumulatedTax to trigger _accumulateYieldTax and then collect
        // First, check before accumulation - should be 0
        // Note: taxBefore intentionally unused, just verifying the function can be called

        // Call collectAccumulatedTax - this will:
        // 1. Call _accumulateYieldTax (calculate yield, add tax to accumulatedTax)
        // 2. Collect the tax and send to treasury
        (uint256 collected0, uint256 collected1) = AlphixLogic(address(logic)).collectAccumulatedTax();

        // Tax should have been collected (collected > 0 means accumulation worked)
        assertTrue(collected0 > 0 || collected1 > 0, "Tax should be collected");
    }

    /**
     * @notice Test owner can update pool params
     */
    function test_setPoolParams() public {
        DynamicFeeLib.PoolParams memory newParams = _getPoolParams();
        newParams.minFee = 500; // Change min fee

        vm.prank(owner);
        AlphixLogic(address(logic)).setPoolParams(newParams);

        DynamicFeeLib.PoolParams memory updatedParams = _getPoolParams();
        assertEq(updatedParams.minFee, 500, "Min fee should be updated");
    }

    function test_beforeInitialize_revertsUnsupportedNativeCurrency_whenCurrency0IsZero() public {
        // Call must come from the Alphix hook address (onlyAlphixHook)
        vm.startPrank(address(hook));

        // Build a PoolKey with currency0 = native ETH (address(0)) to make the branch true
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            hooks: key.hooks
        });

        // Expect UnsupportedNativeCurrency custom error
        vm.expectRevert(IReHypothecation.UnsupportedNativeCurrency.selector);
        AlphixLogic(address(logic)).beforeInitialize(address(0), ethKey, Constants.SQRT_PRICE_1_1);

        vm.stopPrank();
    }

    function test_getPoolKey_branch800True_returnsStoredKey() public view {
        // opix-target-branch-800-True is trivially hit by calling getPoolKey.
        // BaseAlphixTest's setUp already configures the pool and stores `key` in logic.
        PoolKey memory got = AlphixLogic(address(logic)).getPoolKey();

        // Compare fields explicitly (PoolKey contains a hooks address).
        assertEq(Currency.unwrap(got.currency0), Currency.unwrap(key.currency0), "currency0 mismatch");
        assertEq(Currency.unwrap(got.currency1), Currency.unwrap(key.currency1), "currency1 mismatch");
        assertEq(got.fee, key.fee, "fee mismatch");
        assertEq(got.tickSpacing, key.tickSpacing, "tickSpacing mismatch");
        assertEq(address(got.hooks), address(key.hooks), "hooks mismatch");
    }

    function test_isPoolActivated_branch809True_returnsTrueWhenPoolActivated() public view {
        // opix-target-branch-809-True is the always-true guard inside isPoolActivated().
        // In BaseAlphixTest setup, the pool is configured and activated, so this should return true.
        assertTrue(AlphixLogic(address(logic)).isPoolActivated(), "pool should be activated");
    }

    function test_getPoolId_branch827True_returnsStoredPoolId() public view {
        // opix-target-branch-827-True is inside getPoolId(): if (true) { return _poolId; }
        // We just need to call the getter and ensure it matches the expected cached PoolId.

        PoolId expected = key.toId();
        PoolId returned = AlphixLogic(address(logic)).getPoolId();

        assertEq(PoolId.unwrap(returned), PoolId.unwrap(expected), "getPoolId should return cached poolId");
    }

    function test_previewAddFromAmount0_totalSupplyZero_branch938True_returnsZeroWhenAmountTooSmall() public {
        // Hit opix-target-branch-938-True (currentTotalSupply == 0) but choose amount0
        // so small that LiquidityAmounts.getLiquidityForAmount0(...) returns 0, which
        // makes previewAddFromAmount0 early-return (0,0).

        // Ensure tick range is set (restricted; owner is authorized in BaseAlphixTest)
        vm.prank(owner);
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);

        // Use a tiny amount0 that will produce 0 liquidity for the full-range position
        uint256 amount0In = 1; // 1 wei of token0

        (uint256 amount1Required, uint256 shares) = AlphixLogic(address(logic)).previewAddFromAmount0(amount0In);

        assertEq(shares, 0, "shares should be 0 when amount0 too small on initial deposit path");
        assertEq(amount1Required, 0, "amount1Required should be 0 when shares are 0");
    }

    function test_previewAddFromAmount1_totalSupplyZero_branch991True_returnsZeroWhenAmountTooSmall() public {
        // Hit opix-target-branch-991-True (currentTotalSupply == 0) but choose amount1
        // so small that LiquidityAmounts.getLiquidityForAmount1(...) returns 0, which
        // makes previewAddFromAmount1 early-return (0,0).

        // Ensure tick range is set (restricted; owner is authorized via AccessManager in BaseAlphixTest)
        vm.prank(owner);
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);

        // Use a tiny amount1 that will produce 0 liquidity for the full-range position
        uint256 amount1In = 1; // 1 wei of token1

        (uint256 amount0Required, uint256 shares) = AlphixLogic(address(logic)).previewAddFromAmount1(amount1In);

        assertEq(shares, 0, "shares should be 0 when amount1 too small on initial deposit path");
        assertEq(amount0Required, 0, "amount0Required should be 0 when shares are 0");
    }

    function test_previewRemoveReHypothecatedLiquidity_totalSupplyZero_branch1361True_returnsZeroZero() public view {
        // opix-target-branch-1361-True is inside _convertSharesToAmountsForWithdrawal:
        // it returns (0,0) when totalSupply() == 0.
        // In the provided BaseAlphixTest setup, logic is configured/activated but no shares are minted yet,
        // so totalSupply should be 0.

        // Sanity: ensure no shares exist
        assertEq(AlphixLogic(address(logic)).totalSupply(), 0, "totalSupply should start at 0");

        // Call the external view function that uses _convertSharesToAmountsForWithdrawal internally
        (uint256 amount0, uint256 amount1) = AlphixLogic(address(logic)).previewRemoveReHypothecatedLiquidity(1e18);

        // Should hit the branch and return zeros
        assertEq(amount0, 0, "amount0 should be 0 when totalSupply is 0");
        assertEq(amount1, 0, "amount1 should be 0 when totalSupply is 0");
    }

    function test_computeBeforeSwapJit_branch1547_elseBranch_executesWhenConfigured() public {
        // Make the guard IF in _computeBeforeSwapJit evaluate to FALSE by ensuring:
        // - yield sources are configured for both currencies (non-zero)
        // - tickLower != tickUpper
        _setupRehypothecation();

        // Set a valid, non-degenerate tick range (restricted; owner authorized in BaseAlphixTest)
        vm.prank(owner);
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);

        // Add some rehypothecated liquidity so user-available amounts are non-zero
        _addRehypothecatedLiquidity(user1, 100e18);

        // Call beforeSwap from hook address to satisfy onlyAlphixHook
        vm.startPrank(address(hook));
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0});
        (,,, IAlphixLogic.JitParams memory jit) =
            AlphixLogic(address(logic)).beforeSwap(address(0), key, sp, Constants.ZERO_BYTES);
        vm.stopPrank();

        // We should have entered the ELSE branch (configured path) and proceeded to compute JIT.
        // With funds available, it should request execution with configured ticks.
        assertTrue(jit.shouldExecute, "JIT should execute when configured and funds available");
        assertEq(jit.tickLower, tickLower, "tickLower should match configured range");
        assertEq(jit.tickUpper, tickUpper, "tickUpper should match configured range");
        assertTrue(jit.liquidityDelta > 0, "liquidityDelta should be positive for beforeSwap add-liquidity");
    }

    function test_beforeSwap_computeBeforeSwapJit_branch1555True_returnsNoOpWhenNoUserFunds() public {
        // Hit opix-target-branch-1555-True in AlphixLogic::_computeBeforeSwapJit:
        // if (amount0Available == 0 && amount1Available == 0) return no-op JIT params.

        // Ensure tick range is configured so we don't exit early due to tickLower == tickUpper.
        vm.prank(owner);
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);

        // Ensure yield sources are configured so we don't exit early due to missing yield sources.
        // (restricted; owner is authorized in BaseAlphixTest)
        vm.startPrank(owner);
        AlphixLogic(address(logic)).setYieldSource(currency0, address(vault0));
        AlphixLogic(address(logic)).setYieldSource(currency1, address(vault1));
        vm.stopPrank();

        // Do NOT add rehypothecated liquidity: sharesOwned == 0, so user-available amounts are both 0.

        // Call beforeSwap as the hook address (onlyAlphixHook).
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: 0});

        vm.startPrank(address(hook));
        (,, uint24 feeOverride, IAlphixLogic.JitParams memory jit) =
            AlphixLogic(address(logic)).beforeSwap(address(0), key, sp, Constants.ZERO_BYTES);
        vm.stopPrank();

        assertEq(feeOverride, 0, "fee override should be 0");
        assertFalse(jit.shouldExecute, "shouldExecute should be false when no user funds available");
        assertEq(jit.liquidityDelta, 0, "liquidityDelta should be 0 when no user funds available");
        assertEq(jit.tickLower, 0, "tickLower should be 0 when no user funds available");
        assertEq(jit.tickUpper, 0, "tickUpper should be 0 when no user funds available");
    }

    function test_computeBeforeSwapJit_branch1574True_returnsNoOpWhenLiquidityToAddIsOne() public {
        // Goal: hit opix-target-branch-1574-True in _computeBeforeSwapJit:
        // if (liquidityToAdd <= 1) return no-op.
        // We must pass the initial config checks (yield sources set + tick range non-degenerate),
        // and have some user funds, but extremely small such that computed liquidityToAdd is 1.

        _setupRehypothecation();

        // Configure a valid tick range (non-degenerate) so we don't hit the earlier guard return.
        vm.prank(owner);
        AlphixLogic(address(logic)).setTickRange(tickLower, tickUpper);

        // Add minimal rehypothecated liquidity (1 share) to make user-available amounts non-zero,
        // but small enough that computed liquidity from LiquidityAmounts should be <= 1.
        _addRehypothecatedLiquidity(user1, 1);

        // Call beforeSwap from hook address to satisfy onlyAlphixHook.
        vm.startPrank(address(hook));
        SwapParams memory sp = SwapParams({zeroForOne: true, amountSpecified: int256(1), sqrtPriceLimitX96: 0});
        (,, uint24 feeOverride, IAlphixLogic.JitParams memory jit) =
            AlphixLogic(address(logic)).beforeSwap(address(0), key, sp, Constants.ZERO_BYTES);
        vm.stopPrank();

        // Since liquidityToAdd <= 1, branch returns no-op params.
        assertEq(feeOverride, 0, "fee override should be 0");
        assertFalse(jit.shouldExecute, "shouldExecute should be false when liquidityToAdd <= 1");
        assertEq(jit.liquidityDelta, 0, "liquidityDelta should be 0 when liquidityToAdd <= 1");
        assertEq(jit.tickLower, 0, "tickLower should be 0 when liquidityToAdd <= 1");
        assertEq(jit.tickUpper, 0, "tickUpper should be 0 when liquidityToAdd <= 1");
    }
}
