// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title InflationAttackTest
 * @author Alphix
 * @notice Tests demonstrating that ERC4626 inflation attacks do not work on the Sky wrapper.
 * @dev Classic inflation attack pattern:
 *      1. Attacker deposits minimal amount (1 wei) to get 1 share
 *      2. Attacker "donates" a large amount to inflate share price
 *      3. Victim deposits, but due to rounding, gets 0 shares (or very few)
 *      4. Attacker redeems their 1 share and gets victim's funds
 *
 *      Protection mechanisms in this wrapper:
 *      1. Seed liquidity (1e18) deposited at deployment, preventing empty vault manipulation
 *      2. Proper rounding (floor for deposits = less shares, ceil for withdrawals = more shares burned)
 *      3. sUSDS-space conversion ensures consistent share calculation
 */
contract InflationAttackTest is BaseAlphix4626WrapperSky {
    address internal attacker;
    address internal victim;

    function setUp() public override {
        super.setUp();

        attacker = makeAddr("attacker");
        victim = makeAddr("victim");

        // Fund attacker and victim
        usds.mint(attacker, 1_000_000e18);
        usds.mint(victim, 1_000_000e18);

        vm.prank(attacker);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(victim);
        usds.approve(address(wrapper), type(uint256).max);
    }

    /**
     * @notice Classic inflation attack scenario (should fail to profit attacker)
     * @dev Steps:
     *      1. Attacker deposits 1 wei (gets tiny shares due to seed liquidity)
     *      2. Attacker donates large amount directly to inflate share price
     *      3. Victim deposits normal amount
     *      4. Verify victim gets fair shares (attacker cannot steal)
     */
    function test_classicInflationAttack_fails() public {
        // Step 1: Attacker deposits minimal amount
        vm.startPrank(owner);
        wrapper.addAlphixHook(attacker);
        wrapper.addAlphixHook(victim);
        vm.stopPrank();

        vm.prank(attacker);
        uint256 attackerShares = wrapper.deposit(1, attacker);

        // Record state before "donation"
        uint256 totalSupplyBefore = wrapper.totalSupply();
        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Step 2: Attacker tries to donate sUSDS directly to wrapper to inflate share price
        // In a real scenario, they would need sUSDS. We mint it for testing.
        uint256 donationAmount = 1_000_000e18;
        susds.mint(address(wrapper), donationAmount);

        // Share price after donation
        uint256 totalSupplyAfter = wrapper.totalSupply();
        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Supply unchanged (donation doesn't mint shares)
        assertEq(totalSupplyAfter, totalSupplyBefore, "Supply should not change from donation");
        // Assets increased (but this doesn't help attacker due to seed liquidity)
        assertGt(totalAssetsAfter, totalAssetsBefore, "Assets should increase from donation");

        // Step 3: Victim deposits a normal amount
        uint256 victimDeposit = 100_000e18;
        vm.prank(victim);
        uint256 victimShares = wrapper.deposit(victimDeposit, victim);

        // Step 4: Verify victim got meaningful shares (not stolen)
        // With seed liquidity protecting, victim should get proportional shares
        assertGt(victimShares, 0, "Victim should get non-zero shares");

        // Victim should be able to redeem for approximately their deposit
        // (minus small rounding loss which is acceptable)
        uint256 victimRedeemable = wrapper.previewRedeem(victimShares);
        assertGt(victimRedeemable, victimDeposit * 99 / 100, "Victim should be able to redeem ~99%+ of deposit");

        // Attacker's tiny deposit means they can only redeem tiny amount
        // The donation doesn't belong to them
        uint256 attackerRedeemable = wrapper.previewRedeem(attackerShares);
        assertLt(attackerRedeemable, 1e18, "Attacker should only be able to redeem minimal amount");
    }

    /**
     * @notice Test that first depositor cannot manipulate empty vault
     * @dev Seed liquidity ensures vault is never truly empty
     */
    function test_firstDepositor_cannotManipulateEmptyVault() public {
        // Vault already has seed liquidity from deployment
        uint256 initialSupply = wrapper.totalSupply();
        uint256 initialAssets = wrapper.totalAssets();

        // Seed liquidity should exist
        assertEq(initialSupply, DEFAULT_SEED_LIQUIDITY, "Should have seed liquidity shares");
        assertGt(initialAssets, 0, "Should have seed liquidity assets");

        // Seed liquidity prevents the first depositor attack
        // because the vault is never in a 0 supply state

        // Next depositor gets fair shares based on existing ratio
        vm.startPrank(owner);
        wrapper.addAlphixHook(victim);
        vm.stopPrank();

        vm.prank(victim);
        uint256 victimShares = wrapper.deposit(100e18, victim);

        // Shares should be proportional (approximately 1:1 at initial rate)
        assertApproxEqAbs(victimShares, 100e18, 1, "Victim should get ~100e18 shares");
    }

    /**
     * @notice Test that donation attack doesn't profit attacker
     * @dev Even with large donations, attacker cannot steal depositor funds
     */
    function test_donationAttack_doesNotProfitAttacker() public {
        vm.startPrank(owner);
        wrapper.addAlphixHook(attacker);
        wrapper.addAlphixHook(victim);
        vm.stopPrank();

        // Attacker deposits first (after seed liquidity)
        vm.prank(attacker);
        uint256 attackerShares = wrapper.deposit(1000e18, attacker);

        // Attacker donates huge amount
        susds.mint(address(wrapper), 1_000_000e18);

        // Victim deposits
        vm.prank(victim);
        uint256 victimShares = wrapper.deposit(1000e18, victim);

        // Now check: if attacker redeems, do they profit from victim's deposit?
        uint256 victimRedeemValue = wrapper.previewRedeem(victimShares);

        // Attacker should NOT have stolen victim's funds
        // Key assertion: victim's redeem value should be close to their deposit
        // (they get proportional share of donation too, but that's not theft)
        assertGt(victimRedeemValue, 500e18, "Victim should retain significant value");

        // Verify attacker didn't steal - they only get their deposit + share of donation
        uint256 attackerRedeemValue = wrapper.previewRedeem(attackerShares);
        assertLt(attackerRedeemValue, 1_100_000e18, "Attacker should not have stolen victim funds");
    }

    /**
     * @notice Test deposit-redeem roundtrip never profits user
     * @dev ERC4626 standard: deposit(assets) → redeem(shares) ≤ assets
     */
    function test_depositRedeemRoundtrip_neverProfitsUser() public {
        vm.startPrank(owner);
        wrapper.addAlphixHook(attacker);
        vm.stopPrank();

        uint256 depositAmount = 10_000e18;

        vm.prank(attacker);
        uint256 shares = wrapper.deposit(depositAmount, attacker);

        vm.prank(attacker);
        uint256 assetsBack = wrapper.redeem(shares, attacker, attacker);

        // User should get back ≤ what they deposited (rounding favors vault)
        assertLe(assetsBack, depositAmount, "Roundtrip should not profit user");
    }

    /**
     * @notice Test withdraw roundtrip never profits user
     * @dev deposit(assets) → withdraw(assets) should burn ≥ shares received
     * @dev Note: mint() is not implemented in Sky wrapper (NotImplemented error)
     */
    function test_depositWithdrawRoundtrip_neverProfitsUser() public {
        vm.startPrank(owner);
        wrapper.addAlphixHook(attacker);
        vm.stopPrank();

        uint256 depositAmount = 10_000e18;

        vm.prank(attacker);
        uint256 sharesMinted = wrapper.deposit(depositAmount, attacker);

        // Withdraw same amount of assets
        uint256 withdrawAmount = wrapper.maxWithdraw(attacker);

        vm.prank(attacker);
        uint256 sharesBurned = wrapper.withdraw(withdrawAmount, attacker, attacker);

        // User should burn all shares to withdraw all assets
        assertEq(sharesBurned, sharesMinted, "Should burn all shares to withdraw all assets");
    }

    /**
     * @notice Test share price manipulation via direct sUSDS transfer
     * @dev Direct transfers should not allow attacker to profit
     */
    function test_directTransfer_cannotManipulateSharePrice() public {
        vm.startPrank(owner);
        wrapper.addAlphixHook(attacker);
        wrapper.addAlphixHook(victim);
        vm.stopPrank();

        // Attacker deposits
        vm.prank(attacker);
        uint256 attackerShares = wrapper.deposit(1000e18, attacker);

        // Attacker sends sUSDS directly (donation)
        uint256 donation = 100_000e18;
        susds.mint(attacker, donation);
        vm.prank(attacker);
        bool success = susds.transfer(address(wrapper), donation);
        assertTrue(success, "Transfer should succeed");

        // Victim deposits after manipulation
        vm.prank(victim);
        uint256 victimShares = wrapper.deposit(1000e18, victim);

        // Both should have reasonable share amounts
        assertGt(attackerShares, 0, "Attacker should have shares");
        assertGt(victimShares, 0, "Victim should have shares");

        // Victim's shares should be proportionally fair
        // The donation benefits everyone proportionally, not just the attacker
        uint256 victimValue = wrapper.previewRedeem(victimShares);
        assertGt(victimValue, 500e18, "Victim should retain significant value");
    }
}
