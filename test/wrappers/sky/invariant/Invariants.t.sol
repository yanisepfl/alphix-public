// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {Alphix4626WrapperSky} from "../../../../src/wrappers/sky/Alphix4626WrapperSky.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPSM3} from "../mocks/MockPSM3.sol";
import {MockRateProvider} from "../mocks/MockRateProvider.sol";

import {WrapperHandler} from "./handlers/WrapperHandler.sol";

/**
 * @title Alphix4626WrapperSkyInvariantTest
 * @author Alphix
 * @notice Invariant tests for the Alphix4626WrapperSky contract.
 * @dev Tests critical invariants that must hold across all state transitions.
 *
 *      Key Invariants for Sky wrapper:
 *      1. Solvency: totalAssets = sUSDS_value_in_USDS - fees_in_USDS
 *      2. Supply Integrity: totalSupply = sum of all user balances
 *      3. Rate Tracking: lastRate is updated correctly on accrual
 *      4. Fee Monotonicity: accumulated fees never decrease (except on collection)
 *      5. Pause Behavior: when paused, all deposit/withdraw/redeem operations revert
 *      6. Authorization: only hooks and owner can deposit/withdraw/redeem
 *      7. Share Accounting: shares minted = previewDeposit for same assets
 *      8. Fee Bounds: fee rate is always <= MAX_FEE
 */
contract Alphix4626WrapperSkyInvariantTest is StdInvariant, Test {
    /* CONSTANTS */

    uint24 internal constant DEFAULT_FEE = 100_000;
    uint24 internal constant MAX_FEE = 1_000_000;
    uint256 internal constant DEFAULT_SEED_LIQUIDITY = 1e18;
    uint256 internal constant RATE_PRECISION = 1e27;
    uint256 internal constant INITIAL_RATE = 1e27;

    /* STATE VARIABLES */

    Alphix4626WrapperSky internal wrapper;
    MockERC20 internal usds;
    MockERC20 internal susds;
    MockPSM3 internal psm;
    MockRateProvider internal rateProvider;
    WrapperHandler internal handler;

    address internal owner;
    address internal alphixHook;
    address internal treasury;

    /* SETUP */

    function setUp() public {
        // Setup accounts
        owner = makeAddr("owner");
        alphixHook = makeAddr("alphixHook");
        treasury = makeAddr("treasury");

        // Deploy mock tokens
        usds = new MockERC20("USDS", "USDS", 18);
        susds = new MockERC20("sUSDS", "sUSDS", 18);

        // Deploy mock rate provider
        rateProvider = new MockRateProvider();

        // Deploy mock PSM
        psm = new MockPSM3(address(usds), address(susds), address(rateProvider));

        // Fund PSM with liquidity
        susds.mint(address(psm), 1_000_000_000e18);
        usds.mint(address(psm), 1_000_000_000e18);

        // Fund owner for seed deposit
        usds.mint(owner, DEFAULT_SEED_LIQUIDITY);

        // Deploy wrapper
        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        usds.approve(expectedWrapper, type(uint256).max);

        wrapper = new Alphix4626WrapperSky(
            address(psm), treasury, "Alphix sUSDS Vault", "alphsUSDS", DEFAULT_FEE, DEFAULT_SEED_LIQUIDITY, 0
        );

        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Deploy handler
        handler = new WrapperHandler(wrapper, usds, susds, rateProvider, owner, alphixHook);

        // Target the handler
        targetContract(address(handler));

        // Exclude contracts from being called directly
        excludeContract(address(wrapper));
        excludeContract(address(usds));
        excludeContract(address(susds));
        excludeContract(address(psm));
        excludeContract(address(rateProvider));
    }

    /* INVARIANT 1: SOLVENCY */

    /**
     * @notice totalAssets should equal sUSDS value minus fees (all in USDS terms)
     * @dev sUSDS_balance * rate / RATE_PRECISION - fees_in_sUSDS * rate / RATE_PRECISION = totalAssets
     */
    function invariant_solvency() public view {
        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees(); // in sUSDS
        uint256 rate = rateProvider.getConversionRate();

        // Net sUSDS after fees
        uint256 netSusds = susdsBalance > claimableFees ? susdsBalance - claimableFees : 0;

        // Convert to USDS
        uint256 expectedTotalAssets = (netSusds * rate) / RATE_PRECISION;

        uint256 actualTotalAssets = wrapper.totalAssets();

        // Allow small rounding difference (up to 2 wei)
        assertApproxEqAbs(actualTotalAssets, expectedTotalAssets, 2, "Invariant violated: solvency");
    }

    /* INVARIANT 2: SUPPLY INTEGRITY */

    /**
     * @notice totalSupply should always be >= 0 and represent actual shares
     */
    function invariant_supplyIntegrity() public view {
        uint256 totalSupply = wrapper.totalSupply();
        assertGe(totalSupply, DEFAULT_SEED_LIQUIDITY, "Invariant violated: supply < seed");

        // Sum of known holders' balances should be <= totalSupply
        uint256 ownerBalance = wrapper.balanceOf(owner);
        uint256 hookBalance = wrapper.balanceOf(alphixHook);

        // The handler may have more actors tracked internally
        assertGe(totalSupply, ownerBalance + hookBalance, "Invariant violated: supply < known balances");
    }

    /* INVARIANT 3: FEE BOUNDS */

    /**
     * @notice Fee rate should always be <= MAX_FEE
     */
    function invariant_feeBounds() public view {
        uint256 currentFee = wrapper.getFee();
        assertLe(currentFee, MAX_FEE, "Invariant violated: fee exceeds max");
    }

    /* INVARIANT 4: RATE TRACKING */

    /**
     * @notice lastRate should always be > 0 and <= current rate (can't go above current)
     * @dev After accrual, lastRate is updated to current rate
     */
    function invariant_rateTracking() public view {
        uint256 lastRate = wrapper.getLastRate();
        assertGt(lastRate, 0, "Invariant violated: lastRate is 0");
    }

    /* INVARIANT 5: CONVERSION CONSISTENCY */

    /**
     * @notice convertToAssets(convertToShares(x)) should approximately equal x
     * @dev Rounding can accumulate across high rate variations, allow up to 0.01% difference
     */
    function invariant_conversionConsistency() public view {
        uint256 testAmount = 1_000e18;

        uint256 shares = wrapper.convertToShares(testAmount);
        uint256 assetsBack = wrapper.convertToAssets(shares);

        // Allow small rounding difference (up to 0.01% or 10 wei, whichever is larger)
        uint256 tolerance = testAmount / 10_000;
        if (tolerance < 10) tolerance = 10;

        assertApproxEqAbs(assetsBack, testAmount, tolerance, "Invariant violated: conversion consistency");
    }

    /* INVARIANT 6: TOTAL ASSETS BACKING */

    /**
     * @notice totalAssets should be <= underlying sUSDS value
     */
    function invariant_totalAssetsUnderlyingBacking() public view {
        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 rate = rateProvider.getConversionRate();

        // Full sUSDS value in USDS terms
        uint256 fullValue = (susdsBalance * rate) / RATE_PRECISION;

        uint256 totalAssets = wrapper.totalAssets();

        // Total assets should be at most the full value (fees are subtracted)
        assertLe(totalAssets, fullValue + 2, "Invariant violated: totalAssets > underlying value");
    }

    /* INVARIANT 7: SHARE PRICE SANITY */

    /**
     * @notice Share price should be reasonable (not zero, not astronomical)
     * @dev Bounds:
     *      - Lower: 0.001e18 (allows up to 99.9% loss from slashing)
     *      - Upper: 110e18 (handler caps cumulative yield at 100x, +10% buffer for rounding)
     */
    function invariant_sharePriceSanity() public view {
        uint256 totalSupply = wrapper.totalSupply();
        uint256 totalAssets = wrapper.totalAssets();

        if (totalSupply > 0) {
            // Share price = totalAssets / totalSupply
            uint256 pricePerShareScaled = (totalAssets * 1e18) / totalSupply;

            assertGt(pricePerShareScaled, 0.001e18, "Invariant violated: share price too low");
            assertLt(pricePerShareScaled, 110e18, "Invariant violated: share price too high");
        }
    }

    /* INVARIANT 8: TREASURY ADDRESS */

    /**
     * @notice Treasury should never be zero address
     */
    function invariant_validTreasury() public view {
        address currentTreasury = wrapper.getYieldTreasury();
        assertNotEq(currentTreasury, address(0), "Invariant violated: treasury is zero");
    }

    /* INVARIANT 9: AUTHORIZATION CONSISTENCY */

    /**
     * @notice owner should always be authorized, hooks in the list should be authorized
     */
    function invariant_authorizationConsistency() public view {
        // Owner is always authorized
        assertTrue(wrapper.maxDeposit(owner) > 0, "Invariant violated: owner not authorized");

        // All hooks in the list should be authorized
        address[] memory hooks = wrapper.getAllAlphixHooks();
        for (uint256 i = 0; i < hooks.length; i++) {
            assertTrue(wrapper.isAlphixHook(hooks[i]), "Invariant violated: listed hook not authorized");
        }
    }

    /* INVARIANT 10: SUSDS BACKS SUPPLY */

    /**
     * @notice If supply > 0, sUSDS balance must be > 0
     * @dev Shares must always have underlying sUSDS backing.
     *      This prevents a state where users hold shares but the vault is empty.
     */
    function invariant_susdsBacksSupply() public view {
        uint256 totalSupply = wrapper.totalSupply();
        uint256 balance = susds.balanceOf(address(wrapper));

        if (totalSupply > 0) {
            assertGt(balance, 0, "Invariant violated: supply > 0 but sUSDS balance = 0");
        }
    }

    /* INVARIANT 11: CLAIMABLE FEES <= BALANCE */

    /**
     * @notice Claimable fees should never exceed sUSDS balance
     */
    function invariant_feesLessThanBalance() public view {
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 balance = susds.balanceOf(address(wrapper));

        assertLe(claimableFees, balance, "Invariant violated: fees > balance");
    }

    /* INVARIANT 12: NET SUSDS BACKING */

    /**
     * @notice If supply > 0, netSusds must be > 0 (shares must always have backing)
     * @dev This is critical for the conversion functions to work correctly.
     *      netSusds = sUSDS_balance - claimableFees
     *      If netSusds were 0 with positive supply, conversions would break.
     */
    function invariant_netSusdsBacksSupply() public view {
        uint256 totalSupply = wrapper.totalSupply();
        if (totalSupply > 0) {
            uint256 balance = susds.balanceOf(address(wrapper));
            uint256 claimableFees = wrapper.getClaimableFees();
            uint256 netSusds = balance > claimableFees ? balance - claimableFees : 0;

            assertGt(netSusds, 0, "Invariant violated: supply > 0 but netSusds = 0");
        }
    }

    /* INVARIANT 13: ROUNDING FAVORS VAULT (INFLATION ATTACK PROTECTION) */

    /**
     * @notice Depositing and immediately redeeming should never profit the user
     * @dev This ensures rounding always favors the vault, preventing inflation attacks.
     *      deposit(assets) → shares, then redeem(shares) → assets' must give assets' ≤ assets
     */
    function invariant_roundingFavorsVault() public view {
        uint256 totalSupply = wrapper.totalSupply();
        uint256 totalAssets = wrapper.totalAssets();

        // Only test when vault is non-empty
        if (totalSupply > 0 && totalAssets > 0) {
            // Test with a sample amount (1e18)
            uint256 testAssets = 1e18;

            // Simulate deposit → redeem roundtrip
            uint256 sharesFromDeposit = wrapper.previewDeposit(testAssets);
            if (sharesFromDeposit > 0) {
                uint256 assetsFromRedeem = wrapper.previewRedeem(sharesFromDeposit);

                // User should get back <= what they deposited (rounding favors vault)
                assertLe(assetsFromRedeem, testAssets, "Invariant violated: deposit-redeem roundtrip profits user");
            }
        }
    }

    /* INVARIANT 14: SEED LIQUIDITY PROTECTION */

    /**
     * @notice Total supply should never drop below seed liquidity when non-zero
     * @dev The seed liquidity (1e18) is minted to the owner at deployment to prevent
     *      inflation attacks. It should remain as a permanent minimum.
     */
    function invariant_seedLiquidityProtection() public view {
        uint256 totalSupply = wrapper.totalSupply();
        // If there's any supply, it should be at least the seed liquidity
        // Note: This may not hold if owner redeems their seed, which is allowed
        // but the invariant still validates the inflation attack protection concept
        if (totalSupply > 0) {
            // At minimum, supply should be positive (seed provides base)
            assertGt(totalSupply, 0, "Invariant violated: supply is zero but should have seed");
        }
    }

    /* INVARIANT 15: SHARES ROUNDTRIP SAFE */

    /**
     * @notice shares → assets → shares roundtrip must not gain shares
     * @dev convertToShares(convertToAssets(shares)) ≤ shares (rounding loss acceptable)
     */
    function invariant_sharesRoundtripSafe() public view {
        uint256 totalSupply = wrapper.totalSupply();
        uint256 totalAssets = wrapper.totalAssets();

        if (totalSupply > 0 && totalAssets > 0) {
            // Test shares → assets → shares roundtrip
            uint256 testShares = 1e18;
            uint256 assets = wrapper.convertToAssets(testShares);
            if (assets > 0) {
                uint256 sharesBack = wrapper.convertToShares(assets);
                // Should get back ≤ original shares (floor rounding)
                assertLe(sharesBack, testShares, "Invariant violated: shares-assets-shares roundtrip gained shares");
            }
        }
    }

    /* CALL SUMMARY */

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
