// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Alphix4626WrapperAave} from "../../../src/wrappers/aave/Alphix4626WrapperAave.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "./mocks/MockPoolAddressesProvider.sol";

/**
 * @title BaseAlphix4626WrapperAave
 * @author Alphix
 * @notice Base test contract for Alphix4626WrapperAave tests.
 * @dev Provides common setup, helpers, and constants for all test contracts.
 *      Uses mock contracts to simulate Aave V3 behavior.
 */
abstract contract BaseAlphix4626WrapperAave is Test {
    /* CONSTANTS */

    /// @notice Default fee: 10% (100_000 hundredths of a bip)
    uint24 internal constant DEFAULT_FEE = 100_000;

    /// @notice Max fee: 100% (1_000_000 hundredths of a bip)
    uint24 internal constant MAX_FEE = 1_000_000;

    /// @notice Default seed liquidity for wrapper deployment
    uint256 internal constant DEFAULT_SEED_LIQUIDITY = 1e6; // 1 USDC

    /// @notice Default token decimals (USDC-like)
    uint8 internal constant DEFAULT_DECIMALS = 6;

    /// @notice RAY constant for Aave math
    uint256 internal constant RAY = 1e27;

    /* STATE VARIABLES */

    /// @notice The wrapper contract under test
    Alphix4626WrapperAave internal wrapper;

    /// @notice The underlying asset (mock USDC)
    MockERC20 internal asset;

    /// @notice The mock Aave aToken
    MockAToken internal aToken;

    /// @notice The mock Aave pool
    MockAavePool internal aavePool;

    /// @notice The mock pool addresses provider
    MockPoolAddressesProvider internal poolAddressesProvider;

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
    event YieldAccrued(uint256 yieldAmount, uint256 feeAmount, uint256 newWrapperBalance);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event Transfer(address indexed from, address indexed to, uint256 value);

    /* SETUP */

    /**
     * @notice Sets up the test environment.
     * @dev Deploys mock contracts and the wrapper with mock USDC as underlying.
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

        // Deploy mock underlying asset (USDC-like)
        asset = new MockERC20("USD Coin", "USDC", DEFAULT_DECIMALS);

        // Deploy mock Aave pool
        aavePool = new MockAavePool();

        // Deploy mock aToken
        aToken = new MockAToken("Aave USDC", "aUSDC", DEFAULT_DECIMALS, address(asset), address(aavePool));

        // Initialize reserve in pool
        aavePool.initReserve(
            address(asset),
            address(aToken),
            true, // active
            false, // not frozen
            false, // not paused
            0 // no supply cap
        );

        // Deploy mock pool addresses provider
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));

        // Fund owner with asset for seed deposit
        asset.mint(owner, DEFAULT_SEED_LIQUIDITY);

        // Deploy wrapper as owner
        vm.startPrank(owner);

        // Pre-compute wrapper address for approval
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        asset.approve(expectedWrapper, type(uint256).max);

        wrapper = new Alphix4626WrapperAave(
            address(asset),
            treasury,
            address(poolAddressesProvider),
            "Alphix USDC Vault",
            "alphUSDC",
            DEFAULT_FEE,
            DEFAULT_SEED_LIQUIDITY
        );

        // Add alphixHook as authorized hook
        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Fund test users
        asset.mint(alice, 1_000_000e6); // 1M USDC
        asset.mint(bob, 1_000_000e6);
        asset.mint(charlie, 1_000_000e6);

        // Approve wrapper for all test users
        vm.prank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(charlie);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(alphixHook);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(owner);
        asset.approve(address(wrapper), type(uint256).max);
    }

    /// @notice Scale for yield calculations (1e18 = 1.0x)
    uint256 internal constant SCALE = 1e18;

    /* HELPERS */

    /**
     * @notice Simulates yield accrual by minting aTokens to the wrapper.
     * @param yieldMultiplier The yield multiplier (SCALE = 1e18 = 1.0x, 1.1e18 = 10% yield).
     */
    function _simulateYield(uint256 yieldMultiplier) internal {
        aavePool.simulateYield(address(asset), address(wrapper), yieldMultiplier);
    }

    /**
     * @notice Simulates yield accrual with a percentage.
     * @param yieldPercent The yield percentage (100 = 100% = 2x, 10 = 10% = 1.1x).
     */
    function _simulateYieldPercent(uint256 yieldPercent) internal {
        uint256 multiplier = SCALE + (SCALE * yieldPercent / 100);
        _simulateYield(multiplier);
    }

    /**
     * @notice Deposits assets into the wrapper as the Alphix Hook.
     * @param amount The amount to deposit.
     * @param receiver The receiver of the shares (must be alphixHook due to receiver == msg.sender constraint).
     * @return shares The shares minted.
     * @dev Note: receiver must equal alphixHook (the caller) due to the contract's receiver constraint.
     */
    function _depositAsHook(uint256 amount, address receiver) internal returns (uint256 shares) {
        require(receiver == alphixHook, "receiver must equal alphixHook");
        asset.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        asset.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, receiver);
        vm.stopPrank();
    }

    /**
     * @notice Deposits assets into the wrapper as the owner.
     * @param amount The amount to deposit.
     * @param receiver The receiver of the shares (must be owner due to receiver == msg.sender constraint).
     * @return shares The shares minted.
     * @dev Note: receiver must equal owner (the caller) due to the contract's receiver constraint.
     */
    function _depositAsOwner(uint256 amount, address receiver) internal returns (uint256 shares) {
        require(receiver == owner, "receiver must equal owner");
        asset.mint(owner, amount);
        vm.startPrank(owner);
        asset.approve(address(wrapper), amount);
        shares = wrapper.deposit(amount, receiver);
        vm.stopPrank();
    }

    /**
     * @notice Gets the current aToken balance of the wrapper.
     * @return The aToken balance.
     */
    function _getWrapperATokenBalance() internal view returns (uint256) {
        return aToken.balanceOf(address(wrapper));
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
     * @notice Creates a new wrapper with custom parameters.
     * @param decimals_ The asset decimals.
     * @param fee_ The initial fee.
     * @param seedLiquidity_ The seed liquidity.
     * @return The new wrapper instance.
     */
    function _createWrapperWithParams(uint8 decimals_, uint24 fee_, uint256 seedLiquidity_)
        internal
        returns (Alphix4626WrapperAave)
    {
        // Deploy new mock asset with custom decimals
        MockERC20 newAsset = new MockERC20("Test Token", "TEST", decimals_);

        // Deploy new mock aToken
        MockAToken newAToken = new MockAToken("Aave Test", "aTEST", decimals_, address(newAsset), address(aavePool));

        // Initialize reserve
        aavePool.initReserve(address(newAsset), address(newAToken), true, false, false, 0);

        // Fund deployer
        newAsset.mint(owner, seedLiquidity_);

        // Deploy wrapper
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        newAsset.approve(expectedWrapper, type(uint256).max);

        Alphix4626WrapperAave newWrapper = new Alphix4626WrapperAave(
            address(newAsset), treasury, address(poolAddressesProvider), "Test Vault", "tVAULT", fee_, seedLiquidity_
        );

        // Add alphixHook as authorized hook
        newWrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        return newWrapper;
    }

    /**
     * @notice Struct to hold a complete wrapper deployment for decimal-fuzzed tests.
     */
    struct WrapperDeployment {
        Alphix4626WrapperAave wrapper;
        MockERC20 asset;
        MockAToken aToken;
        MockAavePool aavePool;
        uint8 decimals;
        uint256 seedLiquidity;
    }

    /**
     * @notice Creates a complete wrapper deployment with fuzzed decimals.
     * @param decimals_ The asset decimals (will be bounded to 6-18).
     * @return deployment The complete wrapper deployment.
     */
    function _createWrapperWithDecimals(uint8 decimals_) internal returns (WrapperDeployment memory deployment) {
        // Bound decimals to valid range
        decimals_ = uint8(bound(decimals_, 6, 18));
        deployment.decimals = decimals_;
        deployment.seedLiquidity = 10 ** decimals_;

        // Deploy new mock asset with custom decimals
        deployment.asset = new MockERC20("Test Token", "TEST", decimals_);

        // Deploy new mock Aave pool
        deployment.aavePool = new MockAavePool();

        // Deploy new mock aToken
        deployment.aToken =
            new MockAToken("Aave Test", "aTEST", decimals_, address(deployment.asset), address(deployment.aavePool));

        // Initialize reserve
        deployment.aavePool.initReserve(address(deployment.asset), address(deployment.aToken), true, false, false, 0);

        // Deploy pool addresses provider
        MockPoolAddressesProvider newPoolAddressesProvider = new MockPoolAddressesProvider(address(deployment.aavePool));

        // Fund deployer
        deployment.asset.mint(owner, deployment.seedLiquidity);

        // Deploy wrapper
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        deployment.asset.approve(expectedWrapper, type(uint256).max);

        deployment.wrapper = new Alphix4626WrapperAave(
            address(deployment.asset),
            treasury,
            address(newPoolAddressesProvider),
            "Test Vault",
            "tVAULT",
            DEFAULT_FEE,
            deployment.seedLiquidity
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
        uint256 currentBalance = deployment.aToken.balanceOf(address(deployment.wrapper));
        uint256 yieldAmount = currentBalance * yieldPercent / 100;
        deployment.aToken.simulateYield(address(deployment.wrapper), yieldAmount);
    }

    /**
     * @notice Helper to simulate slash on a specific deployment.
     * @param deployment The wrapper deployment.
     * @param slashPercent The slash percentage (e.g., 10 for 10%).
     */
    function _simulateSlashOnDeployment(WrapperDeployment memory deployment, uint256 slashPercent) internal {
        uint256 currentBalance = deployment.aToken.balanceOf(address(deployment.wrapper));
        uint256 slashAmount = currentBalance * slashPercent / 100;
        deployment.aToken.simulateSlash(address(deployment.wrapper), slashAmount);
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
        deployment.asset.mint(alphixHook, amount);
        vm.startPrank(alphixHook);
        deployment.asset.approve(address(deployment.wrapper), amount);
        shares = deployment.wrapper.deposit(amount, alphixHook);
        vm.stopPrank();
    }

    /* ASSERTIONS */

    /**
     * @notice Asserts that the wrapper is solvent (has enough aTokens to cover all shares).
     */
    function _assertSolvent() internal view {
        uint256 totalAssets = wrapper.totalAssets();
        uint256 aTokenBalance = _getWrapperATokenBalance();
        assertGe(aTokenBalance, totalAssets, "Wrapper is insolvent: aToken balance < totalAssets");
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
