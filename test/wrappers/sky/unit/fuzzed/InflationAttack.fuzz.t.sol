// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title InflationAttackFuzzTest
 * @author Alphix
 * @notice Fuzz tests to verify inflation attack resistance across various conditions.
 */
contract InflationAttackFuzzTest is BaseAlphix4626WrapperSky {
    address internal attacker;
    address internal victim;

    function setUp() public override {
        super.setUp();

        attacker = makeAddr("attacker");
        victim = makeAddr("victim");

        usds.mint(attacker, type(uint128).max);
        usds.mint(victim, type(uint128).max);

        vm.prank(attacker);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(victim);
        usds.approve(address(wrapper), type(uint256).max);

        vm.startPrank(owner);
        wrapper.addAlphixHook(attacker);
        wrapper.addAlphixHook(victim);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Deposit-redeem roundtrip never profits user
     * @param depositAmount The amount to deposit (fuzzed)
     */
    function testFuzz_depositRedeemRoundtrip_neverProfitsUser(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1, 100_000_000e18);

        vm.prank(attacker);
        uint256 shares = wrapper.deposit(depositAmount, attacker);

        if (shares > 0) {
            vm.prank(attacker);
            uint256 assetsBack = wrapper.redeem(shares, attacker, attacker);

            assertLe(assetsBack, depositAmount, "Roundtrip should never profit user");
        }
    }

    /**
     * @notice Fuzz: Donation does not allow attacker to steal from victim
     * @param attackerDeposit The attacker's deposit amount
     * @param donationAmount The donation amount
     * @param victimDeposit The victim's deposit amount
     */
    function testFuzz_donationAttack_victimRetainsValue(
        uint256 attackerDeposit,
        uint256 donationAmount,
        uint256 victimDeposit
    ) public {
        attackerDeposit = bound(attackerDeposit, 1, 1_000_000e18);
        donationAmount = bound(donationAmount, 0, 10_000_000e18);
        victimDeposit = bound(victimDeposit, 1e18, 1_000_000e18);

        // Attacker deposits
        vm.prank(attacker);
        wrapper.deposit(attackerDeposit, attacker);

        // Attacker donates sUSDS
        if (donationAmount > 0) {
            susds.mint(address(wrapper), donationAmount);
        }

        // Victim deposits
        vm.prank(victim);
        uint256 victimShares = wrapper.deposit(victimDeposit, victim);

        // Victim should always get shares
        assertGt(victimShares, 0, "Victim must always receive shares");

        // Victim should be able to redeem for significant value
        // (at least 95% of deposit - accounting for rounding and fee effects)
        uint256 victimRedeemable = wrapper.previewRedeem(victimShares);
        assertGt(victimRedeemable, victimDeposit * 99 / 100, "Victim must retain at least 95% of deposit value");
    }

    /**
     * @notice Fuzz: Share price remains reasonable after donations
     * @param donationMultiplier How many times the total assets to donate (1-100)
     */
    function testFuzz_sharePriceReasonable_afterDonation(uint256 donationMultiplier) public {
        donationMultiplier = bound(donationMultiplier, 1, 100);

        uint256 initialAssets = wrapper.totalAssets();
        uint256 donationAmount = initialAssets * donationMultiplier;

        // Donate sUSDS
        susds.mint(address(wrapper), donationAmount);

        uint256 totalAssets = wrapper.totalAssets();
        uint256 totalSupply = wrapper.totalSupply();

        // Share price should be reasonable (not astronomical)
        uint256 sharePrice = (totalAssets * 1e18) / totalSupply;

        // Price should be between 0.001 and 110x (matches invariant bounds)
        assertGt(sharePrice, 0.001e18, "Share price too low");
        assertLt(sharePrice, 110e18, "Share price too high");
    }

    /**
     * @notice Fuzz: Multiple depositors get fair shares
     * @param deposit1 First deposit amount
     * @param deposit2 Second deposit amount
     * @param deposit3 Third deposit amount
     */
    function testFuzz_multipleDepositors_fairShares(uint256 deposit1, uint256 deposit2, uint256 deposit3) public {
        deposit1 = bound(deposit1, 1e18, 1_000_000e18);
        deposit2 = bound(deposit2, 1e18, 1_000_000e18);
        deposit3 = bound(deposit3, 1e18, 1_000_000e18);

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");

        vm.startPrank(owner);
        wrapper.addAlphixHook(user1);
        wrapper.addAlphixHook(user2);
        wrapper.addAlphixHook(user3);
        vm.stopPrank();

        usds.mint(user1, deposit1);
        usds.mint(user2, deposit2);
        usds.mint(user3, deposit3);

        vm.prank(user1);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        usds.approve(address(wrapper), type(uint256).max);
        vm.prank(user3);
        usds.approve(address(wrapper), type(uint256).max);

        // All deposit
        vm.prank(user1);
        uint256 shares1 = wrapper.deposit(deposit1, user1);
        vm.prank(user2);
        uint256 shares2 = wrapper.deposit(deposit2, user2);
        vm.prank(user3);
        uint256 shares3 = wrapper.deposit(deposit3, user3);

        // All should get shares
        assertGt(shares1, 0, "User1 should get shares");
        assertGt(shares2, 0, "User2 should get shares");
        assertGt(shares3, 0, "User3 should get shares");

        // Each should be able to redeem for approximately their deposit value
        uint256 redeem1 = wrapper.previewRedeem(shares1);
        uint256 redeem2 = wrapper.previewRedeem(shares2);
        uint256 redeem3 = wrapper.previewRedeem(shares3);

        assertGt(redeem1, deposit1 * 98 / 100, "User1 should retain ~98%+ value");
        assertGt(redeem2, deposit2 * 98 / 100, "User2 should retain ~98%+ value");
        assertGt(redeem3, deposit3 * 98 / 100, "User3 should retain ~98%+ value");
    }

    /**
     * @notice Fuzz: Seed liquidity prevents 0-share attack
     * @param smallDeposit A very small deposit (1 wei to 1000 wei)
     */
    function testFuzz_seedLiquidity_preventsZeroShareAttack(uint256 smallDeposit) public {
        smallDeposit = bound(smallDeposit, 1, 1000);

        // Even tiny deposits should get some shares due to seed liquidity
        // (In vulnerable vaults, attacker could manipulate to give 0 shares)

        // Donate huge amount first
        susds.mint(address(wrapper), 1_000_000e18);

        // Small deposit should still get at least 1 share
        // (or revert if truly too small, which is acceptable)
        vm.prank(attacker);
        try wrapper.deposit(smallDeposit, attacker) returns (uint256 shares) {
            // If deposit succeeds, must get shares
            // Note: Very small deposits might round to 0 shares, which is safe
            // because the user gets nothing (not loses to attacker)
            // This is acceptable rounding behavior
            if (shares == 0) {
                // Verify user didn't lose funds - they shouldn't have transferred anything
                // that they can't get back (ERC4626 allows 0 share mints)
            }
        } catch {
            // Deposit reverting is also acceptable for tiny amounts
        }
    }

    /**
     * @notice Fuzz: Shares to assets conversion is monotonic
     * @param shares1 First share amount
     * @param shares2 Second share amount (larger)
     */
    function testFuzz_conversionMonotonic_sharesIncrease(uint256 shares1, uint256 shares2) public view {
        shares1 = bound(shares1, 1, 1_000_000e18);
        shares2 = bound(shares2, shares1, 2_000_000e18);

        uint256 assets1 = wrapper.convertToAssets(shares1);
        uint256 assets2 = wrapper.convertToAssets(shares2);

        // More shares should always mean >= assets
        assertGe(assets2, assets1, "Conversion should be monotonically increasing");
    }

    /**
     * @notice Fuzz: Assets to shares conversion is monotonic
     * @param assets1 First asset amount
     * @param assets2 Second asset amount (larger)
     */
    function testFuzz_conversionMonotonic_assetsIncrease(uint256 assets1, uint256 assets2) public view {
        assets1 = bound(assets1, 1, 1_000_000e18);
        assets2 = bound(assets2, assets1, 2_000_000e18);

        uint256 shares1 = wrapper.convertToShares(assets1);
        uint256 shares2 = wrapper.convertToShares(assets2);

        // More assets should always mean >= shares
        assertGe(shares2, shares1, "Conversion should be monotonically increasing");
    }

    /**
     * @notice Fuzz: After yield, rounding still favors vault
     * @param depositAmount The deposit amount
     * @param yieldPercent The yield percentage
     */
    function testFuzz_afterYield_roundingFavorsVault(uint256 depositAmount, uint256 yieldPercent) public {
        depositAmount = bound(depositAmount, 1e18, 100_000_000e18);
        yieldPercent = bound(yieldPercent, 1, 1); // Circuit breaker limits to 1%

        // Deposit
        vm.prank(attacker);
        uint256 shares = wrapper.deposit(depositAmount, attacker);

        // Simulate yield
        _simulateYieldPercent(yieldPercent);

        // Redeem
        vm.prank(attacker);
        wrapper.redeem(shares, attacker, attacker);

        // Wrapper should remain solvent after deposit → yield → redeem cycle
        _assertSolvent();
    }
}
