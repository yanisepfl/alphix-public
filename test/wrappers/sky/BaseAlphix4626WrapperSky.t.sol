// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Alphix4626WrapperSky} from "../../../src/wrappers/sky/Alphix4626WrapperSky.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPSM3} from "./mocks/MockPSM3.sol";
import {MockRateProvider} from "./mocks/MockRateProvider.sol";

/**
 * @title BaseAlphix4626WrapperSky
 * @author Alphix
 * @notice Base test contract for Alphix4626WrapperSky tests.
 * @dev Provides common setup, helpers, and constants for all test contracts.
 *      Uses mock contracts to simulate Spark PSM and rate provider behavior.
 *
 *      Key differences from Aave wrapper tests:
 *      - Uses PSM for swaps (USDS ↔ sUSDS)
 *      - Rate provider tracks sUSDS/USDS rate (27 decimals)
 *      - Yield comes from rate appreciation, not rebasing
 *      - Fees collected in sUSDS, not the underlying asset
 */
abstract contract BaseAlphix4626WrapperSky is Test {
    /* CONSTANTS */

    /// @notice Default fee: 10% (100_000 hundredths of a bip)
    uint24 internal constant DEFAULT_FEE = 100_000;

    /// @notice Max fee: 100% (1_000_000 hundredths of a bip)
    uint24 internal constant MAX_FEE = 1_000_000;

    /// @notice Default seed liquidity for wrapper deployment (1 USDS = 1e18)
    uint256 internal constant DEFAULT_SEED_LIQUIDITY = 1e18;

    /// @notice Token decimals (USDS and sUSDS are both 18 decimals)
    uint8 internal constant DEFAULT_DECIMALS = 18;

    /// @notice Rate precision for rate provider (27 decimals)
    uint256 internal constant RATE_PRECISION = 1e27;

    /// @notice Initial rate: 1:1 (1 sUSDS = 1 USDS)
    uint256 internal constant INITIAL_RATE = 1e27;

    /// @notice Scale for yield calculations (1e18 = 1.0x)
    uint256 internal constant SCALE = 1e18;

    /* STATE VARIABLES */

    /// @notice The wrapper contract under test
    Alphix4626WrapperSky internal wrapper;

    /// @notice The USDS token (ERC4626 asset)
    MockERC20 internal usds;

    /// @notice The sUSDS token (yield-bearing token held internally)
    MockERC20 internal susds;

    /// @notice The mock PSM3
    MockPSM3 internal psm;

    /// @notice The mock rate provider
    MockRateProvider internal rateProvider;

    /// @notice The Alphix Hook address (mock)
    address internal alphixHook;

    /// @notice The contract owner/deployer
    address internal owner;

    /// @notice Test users
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal unauthorized;

    /// @notice Fee receiver (yield treasury)
    address internal treasury;

    /* EVENTS - Redeclared for testing */

    event FeeUpdated(uint24 oldFee, uint24 newFee);
    event YieldAccrued(uint256 yieldAmount, uint256 feeAmount, uint256 newRate);
    event NegativeYield(uint256 lossAmount, uint256 feesReduced, uint256 newRate);
    event FeesCollected(uint256 amount);
    event YieldTreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event AlphixHookAdded(address indexed hook);
    event AlphixHookRemoved(address indexed hook);
    event TokensRescued(address indexed token, uint256 amount);
    event ReferralCodeUpdated(uint256 oldReferralCode, uint256 newReferralCode);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    /* SETUP */

    /**
     * @notice Sets up the test environment.
     * @dev Deploys mock contracts and the wrapper with USDS as underlying.
     */
    function setUp() public virtual {
        // Setup test accounts
        owner = makeAddr("owner");
        alphixHook = makeAddr("alphixHook");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        unauthorized = makeAddr("unauthorized");
        treasury = makeAddr("treasury");

        // Deploy mock tokens
        usds = new MockERC20("USDS Stablecoin", "USDS", DEFAULT_DECIMALS);
        susds = new MockERC20("Savings USDS", "sUSDS", DEFAULT_DECIMALS);

        // Deploy mock rate provider
        rateProvider = new MockRateProvider();

        // Deploy mock PSM3
        psm = new MockPSM3(address(usds), address(susds), address(rateProvider));

        // Fund PSM with liquidity for swaps (both directions)
        susds.mint(address(psm), 1_000_000_000e18); // 1B sUSDS for deposits
        usds.mint(address(psm), 1_000_000_000e18); // 1B USDS for withdrawals

        // Fund owner with USDS for seed deposit
        usds.mint(owner, DEFAULT_SEED_LIQUIDITY);

        // Deploy wrapper as owner
        vm.startPrank(owner);

        // Pre-compute wrapper address for approval
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        usds.approve(expectedWrapper, type(uint256).max);

        wrapper = new Alphix4626WrapperSky(
            address(psm),
            treasury,
            "Alphix sUSDS Vault",
            "alphsUSDS",
            DEFAULT_FEE,
            DEFAULT_SEED_LIQUIDITY,
            0 // referral code
        );

        // Add alphixHook as authorized hook
        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Fund test users with USDS
        usds.mint(alice, 1_000_000e18); // 1M USDS
        usds.mint(bob, 1_000_000e18);
        usds.mint(charlie, 1_000_000e18);

        // Approve wrapper for all test users
        vm.prank(alice);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(bob);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(charlie);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(alphixHook);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(owner);
        usds.approve(address(wrapper), type(uint256).max);
    }

    /* HELPERS */

    /**
     * @notice Simulates yield accrual by increasing the rate provider rate.
     * @param yieldPercent The yield percentage (100 = 100% = 2x, 10 = 10% = 1.1x).
     */
    function _simulateYieldPercent(uint256 yieldPercent) internal {
        rateProvider.simulateYield(yieldPercent);
    }

    /**
     * @notice Simulates negative yield (rate decrease).
     * @param slashPercent The slash percentage (e.g., 10 for 10%).
     */
    function _simulateSlashPercent(uint256 slashPercent) internal {
        rateProvider.simulateSlash(slashPercent);
    }

    /**
     * @notice Sets the rate provider to a specific rate.
     * @param newRate The new rate in 27 decimal precision.
     */
    function _setRate(uint256 newRate) internal {
        rateProvider.setConversionRate(newRate);
    }

    /**
     * @notice Deposits USDS into the wrapper as the Alphix Hook.
     * @param amount The amount to deposit.
     * @param receiver The receiver of the shares (must be alphixHook due to receiver == msg.sender constraint).
     * @return shares The shares minted.
     * @dev Note: receiver must equal alphixHook (the caller) due to the contract's receiver constraint.
     */
    function _depositAsHook(uint256 amount, address receiver) internal returns (uint256 shares) {
        require(receiver == alphixHook, "receiver must equal alphixHook");
        usds.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, receiver);
        vm.stopPrank();
    }

    /**
     * @notice Deposits USDS into the wrapper as the owner.
     * @param amount The amount to deposit.
     * @param receiver The receiver of the shares (must be owner due to receiver == msg.sender constraint).
     * @return shares The shares minted.
     * @dev Note: receiver must equal owner (the caller) due to the contract's receiver constraint.
     */
    function _depositAsOwner(uint256 amount, address receiver) internal returns (uint256 shares) {
        require(receiver == owner, "receiver must equal owner");
        usds.mint(owner, amount);
        vm.startPrank(owner);
        usds.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, receiver);
        vm.stopPrank();
    }

    /**
     * @notice Gets the current sUSDS balance of the wrapper.
     * @return The sUSDS balance.
     */
    function _getWrapperSusdsBalance() internal view returns (uint256) {
        return susds.balanceOf(address(wrapper));
    }

    /**
     * @notice Gets the current rate from the rate provider.
     * @return The rate in 27 decimal precision.
     */
    function _getCurrentRate() internal view returns (uint256) {
        return rateProvider.getConversionRate();
    }

    /**
     * @notice Converts USDS to sUSDS using the current rate.
     * @param usdsAmount The USDS amount.
     * @return The sUSDS equivalent.
     */
    function _usdsToSusds(uint256 usdsAmount) internal view returns (uint256) {
        uint256 rate = _getCurrentRate();
        return (usdsAmount * RATE_PRECISION) / rate;
    }

    /**
     * @notice Converts sUSDS to USDS using the current rate.
     * @param susdsAmount The sUSDS amount.
     * @return The USDS equivalent.
     */
    function _susdsToUsds(uint256 susdsAmount) internal view returns (uint256) {
        uint256 rate = _getCurrentRate();
        return (susdsAmount * rate) / RATE_PRECISION;
    }

    /**
     * @notice Bounds a fuzzed amount to be within valid range.
     * @param amount The fuzzed amount.
     * @param minAmount The minimum amount.
     * @param maxAmount The maximum amount.
     * @return The bounded amount.
     */
    function _boundAmount(uint256 amount, uint256 minAmount, uint256 maxAmount) internal pure returns (uint256) {
        return bound(amount, minAmount, maxAmount);
    }

    /**
     * @notice Bounds a fuzzed fee to be within valid range.
     * @param fee The fuzzed fee.
     * @return The bounded fee.
     */
    function _boundFee(uint24 fee) internal pure returns (uint24) {
        return uint24(bound(uint256(fee), 0, MAX_FEE));
    }

    /**
     * @notice Struct to hold a complete wrapper deployment for fuzzed tests.
     */
    struct WrapperDeployment {
        Alphix4626WrapperSky wrapper;
        MockERC20 usds;
        MockERC20 susds;
        MockPSM3 psm;
        MockRateProvider rateProvider;
        uint256 seedLiquidity;
    }

    /**
     * @notice Creates a complete wrapper deployment with custom parameters.
     * @param fee_ The initial fee.
     * @param seedLiquidity_ The seed liquidity.
     * @return deployment The complete wrapper deployment.
     */
    function _createWrapperWithParams(uint24 fee_, uint256 seedLiquidity_)
        internal
        returns (WrapperDeployment memory deployment)
    {
        deployment.seedLiquidity = seedLiquidity_;

        // Deploy new mock tokens
        deployment.usds = new MockERC20("Test USDS", "tUSDS", DEFAULT_DECIMALS);
        deployment.susds = new MockERC20("Test sUSDS", "tsUSDS", DEFAULT_DECIMALS);

        // Deploy new rate provider
        deployment.rateProvider = new MockRateProvider();

        // Deploy new PSM
        deployment.psm =
            new MockPSM3(address(deployment.usds), address(deployment.susds), address(deployment.rateProvider));

        // Fund PSM with liquidity for swaps (both directions)
        deployment.susds.mint(address(deployment.psm), 1_000_000_000e18);
        deployment.usds.mint(address(deployment.psm), 1_000_000_000e18);

        // Fund deployer
        deployment.usds.mint(owner, seedLiquidity_);

        // Deploy wrapper
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        deployment.usds.approve(expectedWrapper, type(uint256).max);

        deployment.wrapper = new Alphix4626WrapperSky(
            address(deployment.psm), treasury, "Test Vault", "tVAULT", fee_, seedLiquidity_, 0
        );

        // Add alphixHook as authorized hook
        deployment.wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Helper to simulate yield on a specific deployment.
     * @param deployment The wrapper deployment.
     * @param yieldPercent The yield percentage (e.g., 10 for 10%).
     */
    function _simulateYieldOnDeployment(WrapperDeployment memory deployment, uint256 yieldPercent) internal {
        deployment.rateProvider.simulateYield(yieldPercent);
    }

    /**
     * @notice Helper to simulate slash on a specific deployment.
     * @param deployment The wrapper deployment.
     * @param slashPercent The slash percentage (e.g., 10 for 10%).
     */
    function _simulateSlashOnDeployment(WrapperDeployment memory deployment, uint256 slashPercent) internal {
        deployment.rateProvider.simulateSlash(slashPercent);
    }

    /**
     * @notice Helper to deposit as hook on a specific deployment.
     * @param deployment The wrapper deployment.
     * @param amount The amount to deposit.
     * @return shares The shares minted.
     * @dev Deposits to alphixHook (receiver == msg.sender constraint).
     */
    function _depositAsHookOnDeployment(WrapperDeployment memory deployment, uint256 amount)
        internal
        returns (uint256 shares)
    {
        deployment.usds.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        deployment.usds.approve(address(deployment.wrapper), amount);
        shares = deployment.wrapper.deposit(amount, alphixHook);
        vm.stopPrank();
    }

    /* ASSERTIONS */

    /**
     * @notice Asserts that the wrapper is solvent.
     * @dev For Sky wrapper: totalAssets() should be backed by sUSDS holdings (after fee deduction).
     */
    function _assertSolvent() internal view {
        uint256 totalAssets = wrapper.totalAssets();
        uint256 susdsBalance = _getWrapperSusdsBalance();
        uint256 claimableFees = wrapper.getClaimableFees();

        // Net sUSDS (balance - fees) converted to USDS should equal totalAssets
        uint256 netSusds = susdsBalance > claimableFees ? susdsBalance - claimableFees : 0;
        uint256 netUsds = _susdsToUsds(netSusds);

        // Allow for small rounding differences (up to 2 wei due to division rounding)
        assertApproxEqAbs(totalAssets, netUsds, 2, "Wrapper is insolvent");
    }

    /**
     * @notice Asserts that a deposit was successful.
     * @param receiver The receiver of the shares.
     * @param expectedShares The expected shares.
     * @param actualShares The actual shares minted.
     */
    function _assertDepositSuccessful(address receiver, uint256 expectedShares, uint256 actualShares) internal view {
        assertGt(actualShares, 0, "No shares minted");
        assertEq(wrapper.balanceOf(receiver), expectedShares, "Receiver share balance mismatch");
        _assertSolvent();
    }

    /**
     * @notice Asserts approximate equality with a tolerance.
     * @param a First value.
     * @param b Second value.
     * @param tolerance The tolerance in absolute terms.
     * @param message The error message.
     */
    function _assertApproxEq(uint256 a, uint256 b, uint256 tolerance, string memory message) internal pure {
        if (a > b) {
            assertLe(a - b, tolerance, message);
        } else {
            assertLe(b - a, tolerance, message);
        }
    }
}
