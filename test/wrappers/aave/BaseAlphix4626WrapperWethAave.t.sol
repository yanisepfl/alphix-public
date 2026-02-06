// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Alphix4626WrapperWethAave} from "../../../src/wrappers/aave/Alphix4626WrapperWethAave.sol";

import {MockWETH} from "./mocks/MockWETH.sol";
import {MockAToken} from "./mocks/MockAToken.sol";
import {MockAavePool} from "./mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "./mocks/MockPoolAddressesProvider.sol";

/**
 * @title BaseAlphix4626WrapperWethAave
 * @author Alphix
 * @notice Base test contract for Alphix4626WrapperWethAave tests.
 * @dev Provides common setup for WETH-specific tests.
 */
abstract contract BaseAlphix4626WrapperWethAave is Test {
    /* CONSTANTS */

    /// @notice Default fee: 10% (100_000 hundredths of a bip)
    uint24 internal constant DEFAULT_FEE = 100_000;

    /// @notice Max fee: 100% (1_000_000 hundredths of a bip)
    uint24 internal constant MAX_FEE = 1_000_000;

    /// @notice Default seed liquidity for wrapper deployment (1 WETH = 1e18)
    uint256 internal constant DEFAULT_SEED_LIQUIDITY = 1e18;

    /// @notice WETH decimals
    uint8 internal constant WETH_DECIMALS = 18;

    /* STATE VARIABLES */

    /// @notice The WETH wrapper contract under test
    Alphix4626WrapperWethAave internal wethWrapper;

    /// @notice The mock WETH token
    MockWETH internal weth;

    /// @notice The mock Aave aToken (aWETH)
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
    address internal unauthorized;

    /// @notice Fee receiver (yield treasury)
    address internal treasury;

    /* EVENTS - Redeclared for testing */

    event DepositETH(address indexed caller, address indexed receiver, uint256 ethAmount, uint256 shares);
    event WithdrawETH(
        address indexed caller, address indexed receiver, address indexed owner, uint256 ethAmount, uint256 shares
    );

    /* SETUP */

    /**
     * @notice Sets up the test environment.
     */
    function setUp() public virtual {
        // Setup test accounts
        owner = makeAddr("owner");
        alphixHook = makeAddr("alphixHook");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        unauthorized = makeAddr("unauthorized");
        treasury = makeAddr("treasury");

        // Deploy mock WETH
        weth = new MockWETH();

        // Deploy mock Aave pool
        aavePool = new MockAavePool();

        // Deploy mock aToken (aWETH)
        aToken = new MockAToken("Aave WETH", "aWETH", WETH_DECIMALS, address(weth), address(aavePool));

        // Initialize reserve in pool
        aavePool.initReserve(
            address(weth),
            address(aToken),
            true, // active
            false, // not frozen
            false, // not paused
            0 // no supply cap
        );

        // Deploy mock pool addresses provider
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));

        // Fund owner with WETH for seed deposit
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        weth.deposit{value: DEFAULT_SEED_LIQUIDITY}();

        // Deploy wrapper as owner
        vm.startPrank(owner);

        // Pre-compute wrapper address for approval
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        weth.approve(expectedWrapper, type(uint256).max);

        wethWrapper = new Alphix4626WrapperWethAave(
            address(weth),
            treasury,
            address(poolAddressesProvider),
            "Alphix WETH Vault",
            "alphWETH",
            DEFAULT_FEE,
            DEFAULT_SEED_LIQUIDITY
        );

        // Add alphixHook as authorized hook
        wethWrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Fund test users with ETH
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(alphixHook, 100 ether);
        vm.deal(owner, 100 ether);

        // Approve wrapper for WETH operations (for standard deposit/withdraw)
        vm.prank(alphixHook);
        weth.approve(address(wethWrapper), type(uint256).max);
        vm.prank(owner);
        weth.approve(address(wethWrapper), type(uint256).max);
    }

    /* HELPERS */

    /**
     * @notice Deposits ETH as the Alphix Hook.
     * @param amount The amount of ETH to deposit.
     * @return shares The shares minted.
     */
    function _depositETHAsHook(uint256 amount) internal returns (uint256 shares) {
        vm.prank(alphixHook);
        shares = wethWrapper.depositETH{value: amount}(alphixHook);
    }

    /**
     * @notice Deposits ETH as the owner.
     * @param amount The amount of ETH to deposit.
     * @return shares The shares minted.
     */
    function _depositETHAsOwner(uint256 amount) internal returns (uint256 shares) {
        vm.prank(owner);
        shares = wethWrapper.depositETH{value: amount}(owner);
    }

    /**
     * @notice Simulates yield by minting aTokens to the wrapper.
     * @param yieldPercent The yield percentage (10 = 10%).
     */
    function _simulateYieldPercent(uint256 yieldPercent) internal {
        uint256 currentBalance = aToken.balanceOf(address(wethWrapper));
        uint256 yieldAmount = currentBalance * yieldPercent / 100;
        aToken.simulateYield(address(wethWrapper), yieldAmount);
    }
}
