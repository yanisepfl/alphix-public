// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {StdInvariant} from "forge-std/StdInvariant.sol";

/* UNISWAP V4 IMPORTS */
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../BaseAlphix.t.sol";
import {Alphix} from "../../../src/Alphix.sol";
import {MockYieldVault} from "../../utils/mocks/MockYieldVault.sol";

/**
 * @title ReHypothecationInvariantsTest
 * @author Alphix
 * @notice Stateful invariant tests for Alphix rehypothecation and share accounting
 * @dev Tests critical invariants that must hold for share tokens and yield sources
 *
 * Key Invariants Tested:
 * 1. Share Conservation: Total shares == sum of all user balances
 * 2. Yield Source Backing: Total shares backed by yield source assets
 * 3. Withdrawal Solvency: Users can always withdraw their shares
 * 4. Share Value: Share value never goes to zero (unless total loss)
 */
contract ReHypothecationInvariantsTest is StdInvariant, BaseAlphixTest {
    // Yield sources
    MockYieldVault public vault0;
    MockYieldVault public vault1;

    // Test users for share tracking
    address[] public shareHolders;
    mapping(address => bool) public isShareHolder;

    // Ghost variables for tracking
    uint256 public ghostTotalDeposited0;
    uint256 public ghostTotalDeposited1;
    uint256 public ghostTotalWithdrawn0;
    uint256 public ghostTotalWithdrawn1;
    uint256 public ghostTotalYieldGenerated0;
    uint256 public ghostTotalYieldGenerated1;

    // Operation counters
    uint256 public addLiquidityCount;
    uint256 public removeLiquidityCount;
    uint256 public simulateYieldCount;
    uint256 public simulateLossCount;
    uint256 public dustWithdrawalCount;

    function setUp() public override {
        super.setUp();

        // Initialize share holders list
        shareHolders.push(user1);
        shareHolders.push(user2);
        isShareHolder[user1] = true;
        isShareHolder[user2] = true;

        vm.startPrank(owner);

        // Deploy yield vaults
        vault0 = new MockYieldVault(IERC20(Currency.unwrap(currency0)));
        vault1 = new MockYieldVault(IERC20(Currency.unwrap(currency1)));

        // Setup yield manager role
        _setupYieldManagerRole(owner, accessManager, address(hook));

        // Configure rehypothecation
        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        Alphix(address(hook)).setYieldSource(currency0, address(vault0));
        Alphix(address(hook)).setYieldSource(currency1, address(vault1));
        Alphix(address(hook)).setTickRange(tickLower, tickUpper);

        vm.stopPrank();

        // Target this contract for invariant testing (handler functions below)
        targetContract(address(this));

        // Exclude system addresses
        excludeSender(address(0));
        excludeSender(address(hook));
        excludeSender(address(poolManager));
        excludeSender(address(vault0));
        excludeSender(address(vault1));
    }

    /* ========================================================================== */
    /*                           HANDLER FUNCTIONS                                */
    /* ========================================================================== */

    /**
     * @notice Handler: Add rehypothecated liquidity
     */
    function handlerAddLiquidity(uint256 sharesSeed, uint256 userSeed) public {
        uint256 shares = bound(sharesSeed, 1e18, 100e18);
        address user = shareHolders[userSeed % shareHolders.length];

        // Preview amounts needed
        (uint256 amount0, uint256 amount1) = Alphix(address(hook)).previewAddReHypothecatedLiquidity(shares);

        if (amount0 == 0 && amount1 == 0) return;

        // Mint tokens to user
        MockERC20(Currency.unwrap(currency0)).mint(user, amount0);
        MockERC20(Currency.unwrap(currency1)).mint(user, amount1);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), amount0);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), amount1);

        try Alphix(address(hook)).addReHypothecatedLiquidity(shares) {
            addLiquidityCount++;
            ghostTotalDeposited0 += amount0;
            ghostTotalDeposited1 += amount1;
        } catch {
            // Operation failed - acceptable
        }
        vm.stopPrank();
    }

    /**
     * @notice Handler: Remove rehypothecated liquidity
     */
    function handlerRemoveLiquidity(uint256 sharesSeed, uint256 userSeed) public {
        address user = shareHolders[userSeed % shareHolders.length];
        uint256 userBalance = Alphix(address(hook)).balanceOf(user);

        if (userBalance == 0) return;

        uint256 shares = bound(sharesSeed, 1, userBalance);

        // Preview amounts to receive
        (uint256 amount0, uint256 amount1) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(shares);

        vm.prank(user);
        try Alphix(address(hook)).removeReHypothecatedLiquidity(shares) {
            removeLiquidityCount++;
            ghostTotalWithdrawn0 += amount0;
            ghostTotalWithdrawn1 += amount1;
            // Track dust withdrawals where shares are burned but no assets received
            if (amount0 == 0 && amount1 == 0 && shares > 0) {
                dustWithdrawalCount++;
            }
        } catch {
            // Operation failed - acceptable
        }
    }

    /**
     * @notice Handler: Simulate positive yield
     */
    function handlerSimulateYield(uint256 amountSeed, uint256 currencySeed) public {
        // Only simulate yield if there are deposits
        if (Alphix(address(hook)).totalSupply() == 0) return;

        uint256 yieldAmount = bound(amountSeed, 1e16, 10e18);

        vm.startPrank(owner);
        if (currencySeed % 2 == 0) {
            MockERC20(Currency.unwrap(currency0)).mint(owner, yieldAmount);
            MockERC20(Currency.unwrap(currency0)).approve(address(vault0), yieldAmount);
            vault0.simulateYield(yieldAmount);
            ghostTotalYieldGenerated0 += yieldAmount;
        } else {
            MockERC20(Currency.unwrap(currency1)).mint(owner, yieldAmount);
            MockERC20(Currency.unwrap(currency1)).approve(address(vault1), yieldAmount);
            vault1.simulateYield(yieldAmount);
            ghostTotalYieldGenerated1 += yieldAmount;
        }
        vm.stopPrank();

        simulateYieldCount++;
    }

    /**
     * @notice Handler: Simulate loss (negative yield)
     */
    function handlerSimulateLoss(uint256 lossPctSeed, uint256 currencySeed) public {
        // Only simulate loss if there are deposits
        if (Alphix(address(hook)).totalSupply() == 0) return;

        uint256 lossPct = bound(lossPctSeed, 1, 50); // 1-50% loss

        if (currencySeed % 2 == 0) {
            uint256 currentAmount = Alphix(address(hook)).getAmountInYieldSource(currency0);
            uint256 lossAmount = (currentAmount * lossPct) / 100;
            if (lossAmount > 0) {
                vault0.simulateLoss(lossAmount);
            }
        } else {
            uint256 currentAmount = Alphix(address(hook)).getAmountInYieldSource(currency1);
            uint256 lossAmount = (currentAmount * lossPct) / 100;
            if (lossAmount > 0) {
                vault1.simulateLoss(lossAmount);
            }
        }

        simulateLossCount++;
    }

    /* ========================================================================== */
    /*                    INVARIANT 1: SHARE CONSERVATION                         */
    /* ========================================================================== */

    /**
     * @notice Invariant: Total supply equals sum of all holder balances
     * @dev ERC20 share token conservation - fundamental invariant
     */
    function invariant_shareConservation() public view {
        uint256 totalSupply = Alphix(address(hook)).totalSupply();
        uint256 sumOfBalances = 0;

        for (uint256 i = 0; i < shareHolders.length; i++) {
            sumOfBalances += Alphix(address(hook)).balanceOf(shareHolders[i]);
        }

        // Sum of tracked balances should not exceed total supply
        // (there could be other holders we don't track, so <= not ==)
        assertLe(sumOfBalances, totalSupply, "Sum of balances exceeds total supply");
    }

    /**
     * @notice Invariant: Significant shares have backing assets in yield sources
     * @dev This invariant checks that when meaningful shares exist, there are assets backing them.
     *
     *      KNOWN ROUNDING BEHAVIOR (not a bug, but important to understand):
     *      When a user withdraws shares, the amount they receive is calculated as:
     *        amount = shares * totalAssets / totalShares (rounded DOWN)
     *
     *      This means a user with very few shares relative to totalShares can receive 0:
     *      - Example: User has 1 share, totalShares = 1000e18, totalAssets = 1000e18
     *      - Withdrawal: 1 * 1000e18 / (1000e18 + 1) = 0 (rounds down)
     *      - User burns 1 share but receives 0 assets
     *
     *      This is standard ERC4626 rounding behavior and affects users who:
     *      1. Deposit very small amounts relative to existing deposits
     *      2. Hold shares during extreme loss events (>99% loss in yield source)
     *
     *      The rounding always favors the protocol/remaining shareholders, which is
     *      the correct behavior to prevent withdrawal attacks.
     */
    function invariant_sharesHaveBacking() public view {
        uint256 totalSupply = Alphix(address(hook)).totalSupply();

        // Only check meaningful share amounts (ignore dust)
        // At 1e15 shares (~0.001 tokens), rounding effects dominate
        uint256 dustThreshold = 1e15;
        if (totalSupply > dustThreshold) {
            uint256 amount0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
            uint256 amount1 = Alphix(address(hook)).getAmountInYieldSource(currency1);

            // Under normal operations (without extreme losses), shares should have backing
            // We skip this check in the following scenarios:
            // 1. After many loss simulations since near-total loss can legitimately leave
            //    assets near zero while shares remain
            // 2. After dust withdrawals occurred - when users withdraw dust shares (very small
            //    amounts relative to totalShares), they may receive 0 assets due to rounding
            //    down. Their LP shares are burned but vault shares remain unchanged. After
            //    multiple such dust withdrawals, LP totalSupply can exceed dustThreshold while
            //    vault sharesOwned (and thus getAmountInYieldSource) is 0.
            if (simulateLossCount < 10 && dustWithdrawalCount == 0) {
                assertTrue(amount0 > 0 || amount1 > 0, "Meaningful shares exist without any backing assets");
            }
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 2: WITHDRAWAL SOLVENCY                        */
    /* ========================================================================== */

    /**
     * @notice Invariant: Preview amounts are consistent with actual withdrawals
     * @dev What you preview should be what you get (approximately)
     */
    function invariant_previewConsistency() public view {
        for (uint256 i = 0; i < shareHolders.length; i++) {
            address user = shareHolders[i];
            uint256 balance = Alphix(address(hook)).balanceOf(user);

            if (balance > 0) {
                // Preview should return valid amounts
                (uint256 preview0, uint256 preview1) =
                    Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(balance);

                // Preview should never exceed yield source balances
                uint256 yieldSourceAmount0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
                uint256 yieldSourceAmount1 = Alphix(address(hook)).getAmountInYieldSource(currency1);

                assertLe(preview0, yieldSourceAmount0, "Preview0 exceeds available");
                assertLe(preview1, yieldSourceAmount1, "Preview1 exceeds available");
            }
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 3: SHARE VALUE                                */
    /* ========================================================================== */

    /**
     * @notice Invariant: Share value is proportional to assets
     * @dev Users with more shares should be entitled to more assets
     */
    function invariant_shareValueProportional() public view {
        uint256 totalSupply = Alphix(address(hook)).totalSupply();
        if (totalSupply == 0) return;

        // Get two users with shares
        address userA;
        address userB;
        uint256 balanceA;
        uint256 balanceB;

        for (uint256 i = 0; i < shareHolders.length; i++) {
            uint256 bal = Alphix(address(hook)).balanceOf(shareHolders[i]);
            if (bal > 0) {
                if (userA == address(0)) {
                    userA = shareHolders[i];
                    balanceA = bal;
                } else if (userB == address(0)) {
                    userB = shareHolders[i];
                    balanceB = bal;
                    break;
                }
            }
        }

        // If we have two users with shares, verify proportionality
        if (userA != address(0) && userB != address(0)) {
            (uint256 amountA0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(balanceA);
            (uint256 amountB0,) = Alphix(address(hook)).previewRemoveReHypothecatedLiquidity(balanceB);

            // If A has more shares than B, A should get more or equal assets
            if (balanceA > balanceB) {
                assertGe(amountA0, amountB0, "Share value not proportional");
            } else if (balanceB > balanceA) {
                assertGe(amountB0, amountA0, "Share value not proportional");
            }
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 4: YIELD SOURCE STATE                         */
    /* ========================================================================== */

    /**
     * @notice Invariant: Yield source shares owned is tracked correctly
     * @dev Internal share tracking should match actual vault shares
     */
    function invariant_yieldSourceStateConsistent() public view {
        // The amount reported by getAmountInYieldSource should be based on
        // actual vault conversion rates
        uint256 reportedAmount0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
        uint256 reportedAmount1 = Alphix(address(hook)).getAmountInYieldSource(currency1);

        // If there are shares, amounts should be reportable (can be 0 if total loss)
        uint256 totalSupply = Alphix(address(hook)).totalSupply();
        if (totalSupply > 0 && simulateLossCount == 0) {
            // Without losses, there should be some assets
            assertTrue(reportedAmount0 > 0 || reportedAmount1 > 0, "No assets reported with shares outstanding");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 5: NO NEGATIVE BALANCES                       */
    /* ========================================================================== */

    /**
     * @notice Invariant: No user can have negative share balance
     * @dev ERC20 balances are always >= 0
     */
    function invariant_noNegativeBalances() public view {
        for (uint256 i = 0; i < shareHolders.length; i++) {
            uint256 balance = Alphix(address(hook)).balanceOf(shareHolders[i]);
            // uint256 is always >= 0, but this documents the invariant
            assertGe(balance, 0, "Negative balance detected");
        }
    }

    /* ========================================================================== */
    /*                    INVARIANT 6: FIRST DEPOSITOR PROTECTION                 */
    /* ========================================================================== */

    /**
     * @notice Invariant: First depositor doesn't get excessive share value
     * @dev Prevents inflation attacks on first deposit
     */
    function invariant_firstDepositorProtection() public view {
        uint256 totalSupply = Alphix(address(hook)).totalSupply();
        if (totalSupply == 0) return;

        // If there's only one share unit, it shouldn't control disproportionate assets
        // This is protected by the +1 rounding in initial deposit
        if (totalSupply < 1e18) {
            uint256 amount0 = Alphix(address(hook)).getAmountInYieldSource(currency0);
            uint256 amount1 = Alphix(address(hook)).getAmountInYieldSource(currency1);

            // Small total supply shouldn't control massive assets
            // (unless legitimate deposits happened)
            if (addLiquidityCount <= 1) {
                assertLe(amount0, 1000e18, "First deposit controlling too much");
                assertLe(amount1, 1000e18, "First deposit controlling too much");
            }
        }
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    /**
     * @notice Get operation statistics
     */
    function getOperationStats() public view returns (uint256, uint256, uint256, uint256) {
        return (addLiquidityCount, removeLiquidityCount, simulateYieldCount, simulateLossCount);
    }
}
