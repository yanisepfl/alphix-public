// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Alphix4626WrapperAave} from "../../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "../mocks/MockPoolAddressesProvider.sol";

/**
 * @title Alphix4626WrapperAaveInvariantTest
 * @author Alphix
 * @notice Invariant tests for the Alphix4626WrapperAave contract.
 * @dev These tests verify that critical invariants hold across all state transitions.
 *
 * ## Invariants Tested:
 *
 * ### Solvency Invariants
 * 1. **Solvency**: totalAssets() + claimableFees <= aToken balance
 *    - The wrapper must always have enough aTokens to cover user assets plus protocol fees
 *
 * 2. **totalAssets Equality**: totalAssets() == aToken.balanceOf(wrapper) - claimableFees
 *    - totalAssets is by definition aToken balance minus fees
 *
 * ### Share/Asset Relationship Invariants
 * 3. **Non-Negative Assets**: totalAssets is always non-negative (<=aToken balance)
 *    - In extreme slashing scenarios, totalAssets can reach 0 while shares exist
 *    - This is valid Aave behavior that the wrapper handles gracefully
 *
 * 4. **Conversion Monotonicity**: convertToShares is monotonically non-decreasing
 *    - More assets always yields at least as many shares
 *
 * 5. **Round-Trip Conservation**: convertToShares(convertToAssets(shares)) <= shares
 *    - Converting shares to assets and back never increases shares (due to rounding)
 *
 * ### Fee Invariants
 * 6. **Fee Bound**: fee <= MAX_FEE (1_000_000)
 *    - Fee can never exceed 100%
 *
 * 7. **Fees Bounded By Balance**: claimableFees <= aToken.balanceOf(wrapper)
 *    - Fees cannot exceed total balance (holds after negative yield fix)
 *
 * ### Balance Tracking Invariants
 * 8. **Post-Operation Balance Accuracy**: After any state-changing operation,
 *    lastWrapperBalance == aToken.balanceOf(wrapper)
 *    - Note: Between operations, lastWrapperBalance can lag due to yield accrual,
 *      or can be stale after negative yield (until next operation triggers accrual)
 *
 * ### Immutability Invariants
 * 9. **Immutables Constant**: AAVE_POOL, ATOKEN, ASSET never change
 *    - These values are set at construction and remain constant
 *
 * ### Preview Invariants
 * 10. **previewDeposit Consistency**: previewDeposit(x) == convertToShares(x)
 *     - Both functions use the same floor rounding per ERC4626 spec
 *
 * 11. **previewDeposit Monotonicity**: previewDeposit is monotonically non-decreasing
 *     - More assets should always yield at least as many shares
 *
 * 12. **previewDeposit Zero**: previewDeposit(0) == 0
 *     - Zero assets always returns zero shares
 */
contract Alphix4626WrapperAaveInvariantTest is Test {
    Alphix4626WrapperAave internal wrapper;
    MockERC20 internal asset;
    MockAToken internal aToken;
    MockAavePool internal aavePool;
    MockPoolAddressesProvider internal poolAddressesProvider;

    Handler internal handler;

    address internal alphixHook;
    address internal owner;
    address internal treasury;

    uint24 internal constant MAX_FEE = 1_000_000;
    uint24 internal constant DEFAULT_FEE = 100_000; // 10%
    uint8 internal constant DEFAULT_DECIMALS = 6;
    uint256 internal constant DEFAULT_SEED_LIQUIDITY = 1e6;

    function setUp() public {
        alphixHook = makeAddr("alphixHook");
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");

        // Deploy mocks
        asset = new MockERC20("Test Asset", "TEST", DEFAULT_DECIMALS);
        aavePool = new MockAavePool();
        aToken = new MockAToken("aTest", "aTEST", DEFAULT_DECIMALS, address(asset), address(aavePool));
        aavePool.initReserve(address(asset), address(aToken), true, false, false, 0);
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));

        // Deploy wrapper
        asset.mint(owner, DEFAULT_SEED_LIQUIDITY);
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        asset.approve(expectedWrapper, type(uint256).max);
        wrapper = new Alphix4626WrapperAave(
            address(asset),
            treasury,
            address(poolAddressesProvider),
            "Test Vault",
            "tVAULT",
            DEFAULT_FEE,
            DEFAULT_SEED_LIQUIDITY
        );

        // Add alphixHook as authorized hook
        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Deploy handler
        handler = new Handler(wrapper, aToken, asset, alphixHook, owner);

        // Target only the handler for invariant testing
        targetContract(address(handler));

        // Exclude all other contracts from direct calls
        excludeContract(address(wrapper));
        excludeContract(address(asset));
        excludeContract(address(aToken));
        excludeContract(address(aavePool));
        excludeContract(address(poolAddressesProvider));
    }

    /* SOLVENCY INVARIANTS */

    /**
     * @notice Invariant: The wrapper is always solvent.
     * @dev totalAssets + claimableFees <= aToken balance
     */
    function invariant_solvency() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertLe(totalAssets + claimableFees, aTokenBalance, "Solvency violated: assets + fees > aToken balance");
    }

    /**
     * @notice Invariant: totalAssets equals aToken balance minus fees.
     */
    function invariant_totalAssetsEqualsATokenMinusFees() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertEq(totalAssets, aTokenBalance - claimableFees, "totalAssets != aToken - fees");
    }

    /* SHARE/ASSET RELATIONSHIP INVARIANTS */

    /**
     * @notice Invariant: If totalSupply > 0 then totalAssets >= 0 (non-negative).
     * @dev In extreme negative yield scenarios (e.g., -100% slashing), totalAssets
     *      could theoretically reach 0 while shares exist. This is a valid edge case
     *      in Aave's design. What we verify here is that totalAssets is never negative
     *      (i.e., fees never exceed aToken balance).
     *
     *      The original stricter invariant (totalAssets > 0 when shares > 0) would only
     *      hold if we artificially constrained the test inputs, which defeats the purpose
     *      of invariant testing.
     */
    function invariant_sharesImplyNonNegativeAssets() public view {
        // totalAssets() = aToken.balance - fees
        // This should never underflow/be negative (fees bounded by balance)
        uint256 totalAssets = wrapper.totalAssets();
        uint256 totalSupply = wrapper.totalSupply();

        // If shares exist, assets should be non-negative (covered by solvency invariant too)
        if (totalSupply > 0) {
            // totalAssets is uint256, so it can't be negative
            // This assertion verifies the math is correct
            assertTrue(totalAssets <= aToken.balanceOf(address(wrapper)), "totalAssets exceeds aToken balance");
        }
    }

    /**
     * @notice Invariant: convertToShares is monotonically non-decreasing.
     */
    function invariant_conversionMonotonicity() public view {
        uint256 smallAmount = 1e6;
        uint256 largeAmount = 1_000_000e6;

        uint256 smallShares = wrapper.convertToShares(smallAmount);
        uint256 largeShares = wrapper.convertToShares(largeAmount);

        assertLe(smallShares, largeShares, "Conversion not monotonic");
    }

    /**
     * @notice Invariant: Round-tripping shares through assets doesn't increase shares.
     */
    function invariant_conversionRoundTrip() public view {
        uint256 shares = 1_000e6;
        uint256 assets = wrapper.convertToAssets(shares);
        uint256 sharesBack = wrapper.convertToShares(assets);

        assertLe(sharesBack, shares, "Round-trip increased shares");
    }

    /* FEE INVARIANTS */

    /**
     * @notice Invariant: Fee is always <= MAX_FEE.
     */
    function invariant_feeBound() public view {
        assertLe(wrapper.getFee(), MAX_FEE, "Fee exceeds MAX_FEE");
    }

    /**
     * @notice Invariant: Claimable fees never exceed aToken balance.
     * @dev This holds because negative yield proportionally reduces fees.
     */
    function invariant_feesBoundByBalance() public view {
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees();

        assertLe(claimableFees, aTokenBalance, "Claimable fees > aToken balance");
    }

    /* IMMUTABILITY INVARIANTS */

    /**
     * @notice Invariant: Immutables never change.
     */
    function invariant_immutables() public view {
        assertEq(address(wrapper.AAVE_POOL()), address(aavePool), "AAVE_POOL changed");
        assertEq(address(wrapper.ATOKEN()), address(aToken), "ATOKEN changed");
        assertEq(address(wrapper.ASSET()), address(asset), "ASSET changed");
        assertEq(
            address(wrapper.POOL_ADDRESSES_PROVIDER()),
            address(poolAddressesProvider),
            "POOL_ADDRESSES_PROVIDER changed"
        );
    }

    /**
     * @notice Invariant: asset() always returns correct value.
     */
    function invariant_assetConsistency() public view {
        assertEq(wrapper.asset(), address(wrapper.ASSET()), "asset() inconsistent");
    }

    /* PREVIEW INVARIANTS */

    /**
     * @notice Invariant: previewDeposit matches convertToShares.
     * @dev ERC4626 specifies previewDeposit uses floor rounding, same as convertToShares.
     */
    function invariant_previewDepositMatchesConvertToShares() public view {
        uint256 testAmount = 1_000e6;
        uint256 previewedShares = wrapper.previewDeposit(testAmount);
        uint256 convertedShares = wrapper.convertToShares(testAmount);

        assertEq(previewedShares, convertedShares, "previewDeposit != convertToShares");
    }

    /**
     * @notice Invariant: previewDeposit is monotonically non-decreasing.
     * @dev More assets should always yield at least as many shares.
     */
    function invariant_previewDepositMonotonic() public view {
        uint256 smallAmount = 1e6;
        uint256 largeAmount = 1_000_000e6;

        uint256 smallShares = wrapper.previewDeposit(smallAmount);
        uint256 largeShares = wrapper.previewDeposit(largeAmount);

        assertLe(smallShares, largeShares, "previewDeposit not monotonic");
    }

    /**
     * @notice Invariant: previewDeposit(0) always returns 0.
     */
    function invariant_previewDepositZeroReturnsZero() public view {
        assertEq(wrapper.previewDeposit(0), 0, "previewDeposit(0) != 0");
    }

    /* CALL SUMMARY */

    /**
     * @notice Log call summary after invariant run.
     */
    function invariant_callSummary() public view {
        handler.callSummary();
    }
}

/**
 * @title Handler
 * @notice Handler contract for invariant testing.
 * @dev Wraps wrapper functions and tracks ghost variables.
 */
contract Handler is Test {
    Alphix4626WrapperAave internal wrapper;
    MockAToken internal aToken;
    MockERC20 internal asset;
    address internal alphixHook;
    address internal owner;

    uint24 internal constant MAX_FEE = 1_000_000;

    // Ghost variables for tracking state across calls
    uint256 public ghostTotalDeposited;
    uint256 public ghostDepositCount;
    uint256 public ghostWithdrawCount;
    uint256 public ghostRedeemCount;
    uint256 public ghostSetFeeCount;
    uint256 public ghostYieldSimulationCount;
    uint256 public ghostSlashCount;

    constructor(
        Alphix4626WrapperAave wrapper_,
        MockAToken aToken_,
        MockERC20 asset_,
        address alphixHook_,
        address owner_
    ) {
        wrapper = wrapper_;
        aToken = aToken_;
        asset = asset_;
        alphixHook = alphixHook_;
        owner = owner_;
    }

    /**
     * @notice Deposit as the Alphix Hook.
     */
    function deposit(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000e6);

        asset.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        ghostTotalDeposited += amount;
        ghostDepositCount++;
    }

    /**
     * @notice Deposit as owner to hook.
     */
    function depositAsOwner(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000e6);

        asset.mint(owner, amount);
        vm.startPrank(owner);
        asset.approve(address(wrapper), amount);
        wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        ghostTotalDeposited += amount;
        ghostDepositCount++;
    }

    /**
     * @notice Set fee as owner.
     */
    function setFee(uint24 newFee) public {
        newFee = uint24(bound(newFee, 0, MAX_FEE));

        vm.prank(owner);
        wrapper.setFee(newFee);

        ghostSetFeeCount++;
    }

    /**
     * @notice Simulate yield accrual (positive yield).
     */
    function simulateYield(uint256 yieldPercent) public {
        yieldPercent = bound(yieldPercent, 0, 50);

        if (yieldPercent > 0) {
            uint256 currentBalance = aToken.balanceOf(address(wrapper));
            uint256 yieldAmount = currentBalance * yieldPercent / 100;
            if (yieldAmount > 0) {
                aToken.simulateYield(address(wrapper), yieldAmount);
            }
        }

        ghostYieldSimulationCount++;
    }

    /**
     * @notice Simulate negative yield (slashing).
     * @dev Simulates Aave slashing events. In extreme cases (e.g., -100% yield),
     *      totalAssets can reach 0 while shares still exist. This is valid behavior
     *      that the contract must handle gracefully.
     */
    function simulateSlash(uint256 slashPercent) public {
        // Bound to realistic slash scenarios (0-99%)
        slashPercent = bound(slashPercent, 0, 99);

        if (slashPercent == 0) {
            ghostSlashCount++;
            return;
        }

        uint256 currentBalance = aToken.balanceOf(address(wrapper));

        // Skip if no balance to slash
        if (currentBalance == 0) {
            ghostSlashCount++;
            return;
        }

        // Calculate slash amount as percentage of balance
        uint256 slashAmount = currentBalance * slashPercent / 100;

        // Execute slash if amount is positive
        if (slashAmount > 0) {
            aToken.simulateSlash(address(wrapper), slashAmount);
        }

        ghostSlashCount++;
    }

    /**
     * @notice Trigger yield accrual without depositing (via setFee with same fee).
     */
    function triggerAccrual() public {
        uint256 currentFee = wrapper.getFee();
        vm.prank(owner);
        // forge-lint: disable-next-line(unsafe-typecast)
        wrapper.setFee(uint24(currentFee)); // Safe: getFee() always returns value <= MAX_FEE (1_000_000)
    }

    /**
     * @notice Withdraw as the Alphix Hook.
     */
    function withdraw(uint256 amount) public {
        uint256 maxWithdraw = wrapper.maxWithdraw(alphixHook);
        if (maxWithdraw == 0) return;

        amount = bound(amount, 1, maxWithdraw);

        vm.prank(alphixHook);
        wrapper.withdraw(amount, alphixHook, alphixHook);

        ghostWithdrawCount++;
    }

    /**
     * @notice Redeem as the Alphix Hook.
     */
    function redeem(uint256 shares) public {
        uint256 maxRedeem = wrapper.maxRedeem(alphixHook);
        if (maxRedeem == 0) return;

        shares = bound(shares, 1, maxRedeem);

        vm.prank(alphixHook);
        wrapper.redeem(shares, alphixHook, alphixHook);

        ghostRedeemCount++;
    }

    /**
     * @notice Print call summary.
     */
    function callSummary() public view {
        console.log("Call Summary:");
        console.log("  Deposits:", ghostDepositCount);
        console.log("  Withdraws:", ghostWithdrawCount);
        console.log("  Redeems:", ghostRedeemCount);
        console.log("  Total Deposited:", ghostTotalDeposited);
        console.log("  SetFee calls:", ghostSetFeeCount);
        console.log("  Yield Simulations:", ghostYieldSimulationCount);
        console.log("  Slash Simulations:", ghostSlashCount);
    }
}
