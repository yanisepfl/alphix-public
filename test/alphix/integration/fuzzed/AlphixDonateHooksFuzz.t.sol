// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */

/* UNISWAP V4 IMPORTS */
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixTest} from "../../BaseAlphix.t.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixDonateHooksFuzzTest
 * @author Alphix
 * @notice Extensive fuzz tests for donate hook functionality
 */
contract AlphixDonateHooksFuzzTest is BaseAlphixTest {
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    PoolDonateTest private donateRouter;

    function setUp() public override {
        super.setUp();

        // Deploy donate router
        donateRouter = new PoolDonateTest(poolManager);

        // Note: Base setup already initializes a pool with liquidity (key, poolId)
        // We'll use that default pool for our donation tests
    }

    /* ========================================================================== */
    /*                     EXTENSIVE FUZZ TESTS                                   */
    /* ========================================================================== */

    /**
     * @notice Fuzz: Donate hooks handle large amounts correctly
     */
    function testFuzz_donate_large_amounts(uint128 amount0, uint128 amount1) public {
        // Bound to large but safe values (avoid overflow in calculations)
        amount0 = uint128(bound(amount0, 0, type(uint96).max));
        amount1 = uint128(bound(amount1, 0, type(uint96).max));

        address donor = makeAddr("extremeDonor");
        deal(Currency.unwrap(key.currency0), donor, amount0);
        deal(Currency.unwrap(key.currency1), donor, amount1);

        vm.startPrank(donor);
        if (amount0 > 0) {
            MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        }
        if (amount1 > 0) {
            MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);
        }

        // Should handle extreme values without reverting
        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Rapid successive donations from multiple donors
     */
    function testFuzz_rapid_multiple_donors(
        uint128 donor1Amount0,
        uint128 donor1Amount1,
        uint128 donor2Amount0,
        uint128 donor2Amount1,
        uint128 donor3Amount0,
        uint128 donor3Amount1
    ) public {
        // Bound amounts
        donor1Amount0 = uint128(bound(donor1Amount0, 1e15, 50e18));
        donor1Amount1 = uint128(bound(donor1Amount1, 1e15, 50e18));
        donor2Amount0 = uint128(bound(donor2Amount0, 1e15, 50e18));
        donor2Amount1 = uint128(bound(donor2Amount1, 1e15, 50e18));
        donor3Amount0 = uint128(bound(donor3Amount0, 1e15, 50e18));
        donor3Amount1 = uint128(bound(donor3Amount1, 1e15, 50e18));

        address donor1 = makeAddr("donor1");
        address donor2 = makeAddr("donor2");
        address donor3 = makeAddr("donor3");

        // Setup donors
        _setupDonor(donor1, donor1Amount0, donor1Amount1);
        _setupDonor(donor2, donor2Amount0, donor2Amount1);
        _setupDonor(donor3, donor3Amount0, donor3Amount1);

        // Rapid donations
        _executeDonation(donor1, donor1Amount0, donor1Amount1);
        _executeDonation(donor2, donor2Amount0, donor2Amount1);
        _executeDonation(donor3, donor3Amount0, donor3Amount1);
    }

    /**
     * @notice Fuzz: Multiple consecutive donations with varying amounts
     */
    function testFuzz_consecutive_donations(
        uint128 amount1Token0,
        uint128 amount1Token1,
        uint128 amount2Token0,
        uint128 amount2Token1,
        uint128 amount3Token0,
        uint128 amount3Token1
    ) public {
        // Bound amounts to reasonable range
        amount1Token0 = uint128(bound(amount1Token0, 1e15, 20e18));
        amount1Token1 = uint128(bound(amount1Token1, 1e15, 20e18));
        amount2Token0 = uint128(bound(amount2Token0, 1e15, 20e18));
        amount2Token1 = uint128(bound(amount2Token1, 1e15, 20e18));
        amount3Token0 = uint128(bound(amount3Token0, 1e15, 20e18));
        amount3Token1 = uint128(bound(amount3Token1, 1e15, 20e18));

        address donor = makeAddr("consecutiveDonor");
        uint256 total0 = uint256(amount1Token0) + uint256(amount2Token0) + uint256(amount3Token0);
        uint256 total1 = uint256(amount1Token1) + uint256(amount2Token1) + uint256(amount3Token1);

        deal(Currency.unwrap(key.currency0), donor, total0);
        deal(Currency.unwrap(key.currency1), donor, total1);

        vm.startPrank(donor);

        // First donation
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount1Token0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1Token1);
        donateRouter.donate(key, amount1Token0, amount1Token1, "");

        // Second donation
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount2Token0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount2Token1);
        donateRouter.donate(key, amount2Token0, amount2Token1, "");

        // Third donation
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount3Token0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount3Token1);
        donateRouter.donate(key, amount3Token0, amount3Token1, "");

        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Sequential donations from same donor
     */
    function testFuzz_sequential_donations_same_donor(
        uint128 firstAmount0,
        uint128 firstAmount1,
        uint128 secondAmount0,
        uint128 secondAmount1
    ) public {
        // Bound amounts
        firstAmount0 = uint128(bound(firstAmount0, 1e15, 50e18));
        firstAmount1 = uint128(bound(firstAmount1, 1e15, 50e18));
        secondAmount0 = uint128(bound(secondAmount0, 1e15, 50e18));
        secondAmount1 = uint128(bound(secondAmount1, 1e15, 50e18));

        address donor = makeAddr("sequentialDonor");
        uint256 totalAmount0 = uint256(firstAmount0) + uint256(secondAmount0);
        uint256 totalAmount1 = uint256(firstAmount1) + uint256(secondAmount1);

        // Setup donor with total needed funds
        deal(Currency.unwrap(key.currency0), donor, totalAmount0);
        deal(Currency.unwrap(key.currency1), donor, totalAmount1);

        // First donation
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), firstAmount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), firstAmount1);
        donateRouter.donate(key, firstAmount0, firstAmount1, "");

        // Second donation (sequential)
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), secondAmount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), secondAmount1);
        donateRouter.donate(key, secondAmount0, secondAmount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Zero amount donations (edge case)
     */
    function testFuzz_zero_amount_donations(bool zeroToken0, bool zeroToken1) public {
        uint256 amount0 = zeroToken0 ? 0 : 10e18;
        uint256 amount1 = zeroToken1 ? 0 : 10e18;

        address donor = makeAddr("zeroDonor");
        deal(Currency.unwrap(key.currency0), donor, amount0);
        deal(Currency.unwrap(key.currency1), donor, amount1);

        vm.startPrank(donor);
        if (amount0 > 0) {
            MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        }
        if (amount1 > 0) {
            MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);
        }

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Donations with variable length hookData
     */
    function testFuzz_donate_variable_hookData(uint128 amount0, uint128 amount1, bytes memory hookData) public {
        // Bound amounts
        amount0 = uint128(bound(amount0, 1e15, 100e18));
        amount1 = uint128(bound(amount1, 1e15, 100e18));

        // Bound hookData length to avoid too large data
        vm.assume(hookData.length <= 1024);

        address donor = makeAddr("hookDataDonor");
        deal(Currency.unwrap(key.currency0), donor, amount0);
        deal(Currency.unwrap(key.currency1), donor, amount1);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate(key, amount0, amount1, hookData);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Donations at different time intervals
     */
    function testFuzz_donate_time_intervals(
        uint128 amount0First,
        uint128 amount1First,
        uint32 timeSkip,
        uint128 amount0Second,
        uint128 amount1Second
    ) public {
        // Bound amounts and time
        amount0First = uint128(bound(amount0First, 1e15, 50e18));
        amount1First = uint128(bound(amount1First, 1e15, 50e18));
        timeSkip = uint32(bound(timeSkip, 1, 365 days));
        amount0Second = uint128(bound(amount0Second, 1e15, 50e18));
        amount1Second = uint128(bound(amount1Second, 1e15, 50e18));

        address donor = makeAddr("timeDonor");
        uint256 totalAmount0 = uint256(amount0First) + uint256(amount0Second);
        uint256 totalAmount1 = uint256(amount1First) + uint256(amount1Second);

        deal(Currency.unwrap(key.currency0), donor, totalAmount0);
        deal(Currency.unwrap(key.currency1), donor, totalAmount1);

        // First donation
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0First);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1First);
        donateRouter.donate(key, amount0First, amount1First, "");
        vm.stopPrank();

        // Time skip
        skip(timeSkip);

        // Second donation
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0Second);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1Second);
        donateRouter.donate(key, amount0Second, amount1Second, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Donation ratio variations
     */
    function testFuzz_donate_ratio_variations(uint128 baseAmount, uint8 ratioMultiplier) public {
        baseAmount = uint128(bound(baseAmount, 1e15, 50e18));
        ratioMultiplier = uint8(bound(ratioMultiplier, 1, 100));

        uint256 amount0 = baseAmount;
        uint256 amount1 = uint256(baseAmount) * uint256(ratioMultiplier);

        address donor = makeAddr("ratioDonor");
        deal(Currency.unwrap(key.currency0), donor, amount0);
        deal(Currency.unwrap(key.currency1), donor, amount1);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Donate with various amounts
     */
    function testFuzz_donate_various_amounts(uint128 amount0, uint128 amount1) public {
        // Bound amounts to reasonable range
        amount0 = uint128(bound(amount0, 0, 100e18));
        amount1 = uint128(bound(amount1, 0, 100e18));

        address donor = makeAddr("variousAmountDonor");
        deal(Currency.unwrap(key.currency0), donor, uint256(amount0) + 1e18);
        deal(Currency.unwrap(key.currency1), donor, uint256(amount1) + 1e18);

        vm.startPrank(donor);
        if (amount0 > 0) {
            MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        }
        if (amount1 > 0) {
            MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);
        }

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Stress test with multiple iterations
     */
    function testFuzz_donate_stress_test(uint128 amount0, uint128 amount1, uint8 iterations) public {
        // Bound inputs
        amount0 = uint128(bound(amount0, 1e15, 10e18));
        amount1 = uint128(bound(amount1, 1e15, 10e18));
        iterations = uint8(bound(iterations, 1, 5));

        // Calculate total needed
        uint256 total0 = uint256(amount0) * uint256(iterations);
        uint256 total1 = uint256(amount1) * uint256(iterations);

        address donor = makeAddr("stressDonor");
        deal(Currency.unwrap(key.currency0), donor, total0);
        deal(Currency.unwrap(key.currency1), donor, total1);

        vm.startPrank(donor);
        for (uint256 i = 0; i < iterations; i++) {
            MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
            MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);
            donateRouter.donate(key, amount0, amount1, "");
        }
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Asymmetric donations (favor one token)
     */
    function testFuzz_asymmetric_donations(uint128 amount, bool favorToken0) public {
        amount = uint128(bound(amount, 1e15, 100e18));

        uint256 amount0 = favorToken0 ? amount : amount / 10;
        uint256 amount1 = favorToken0 ? amount / 10 : amount;

        address donor = makeAddr("asymmetricDonor");
        deal(Currency.unwrap(key.currency0), donor, amount0 + 1e18);
        deal(Currency.unwrap(key.currency1), donor, amount1 + 1e18);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz: Verify LPs receive donations proportional to their liquidity
     * @dev Tests that donation fees are distributed based on liquidity amount (2:1 ratio)
     */
    function testFuzz_lp_receives_donations_proportional_to_liquidity(uint128 donateAmount0, uint128 donateAmount1)
        public
    {
        donateAmount0 = uint128(bound(donateAmount0, 2e18, 50e18));
        donateAmount1 = uint128(bound(donateAmount1, 2e18, 50e18));

        // Create two LPs with known different liquidity amounts
        address lp1 = makeAddr("lp1");
        address lp2 = makeAddr("lp2");

        // Add more liquidity for LP1 (50e18) than LP2 (25e18) - 2:1 ratio
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenId1 = seedLiquidity(key, lp1, true, 0, 50e18, 50e18);

        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenId2 = seedLiquidity(key, lp2, true, 0, 25e18, 25e18);

        // Record balances before collection
        uint256 lp1Balance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lp1);
        uint256 lp1Balance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lp1);
        uint256 lp2Balance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lp2);
        uint256 lp2Balance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lp2);

        // Make donation
        _makeDonation(donateAmount0, donateAmount1);

        // Collect fees
        _collectFees(positionTokenId1, lp1);
        _collectFees(positionTokenId2, lp2);

        // Calculate fees received for each token
        uint256 lp1Fees0 = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lp1) - lp1Balance0Before;
        uint256 lp1Fees1 = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lp1) - lp1Balance1Before;
        uint256 lp2Fees0 = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lp2) - lp2Balance0Before;
        uint256 lp2Fees1 = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lp2) - lp2Balance1Before;

        // Both LPs should receive fees
        assertTrue(lp1Fees0 > 0, "LP1 should receive token0 fees");
        assertTrue(lp1Fees1 > 0, "LP1 should receive token1 fees");
        assertTrue(lp2Fees0 > 0, "LP2 should receive token0 fees");
        assertTrue(lp2Fees1 > 0, "LP2 should receive token1 fees");

        // LP1 provided 2x liquidity, should receive more fees
        assertTrue(lp1Fees0 > lp2Fees0, "LP1 should receive more token0 fees than LP2");
        assertTrue(lp1Fees1 > lp2Fees1, "LP1 should receive more token1 fees than LP2");

        // Fee ratio should be approximately 2:1 for each token
        assertApproxEqRel(lp1Fees0, lp2Fees0 * 2, 1e17, "Token0 fee ratio should be approximately 2:1");
        assertApproxEqRel(lp1Fees1, lp2Fees1 * 2, 1e17, "Token1 fee ratio should be approximately 2:1");
    }

    /**
     * @notice Fuzz: Verify LPs in range receive donations
     * @dev Tests that LPs with ranges overlapping the current price receive fees
     */
    function testFuzz_lp_in_range_receives_donations(uint128 donateAmount0, uint128 donateAmount1) public {
        donateAmount0 = uint128(bound(donateAmount0, 1e18, 50e18));
        donateAmount1 = uint128(bound(donateAmount1, 1e18, 50e18));

        // Create two LPs: one full range, one narrow range
        address lpFullRange = makeAddr("lpFullRange");
        address lpNarrowRange = makeAddr("lpNarrowRange");

        // Add full-range liquidity
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdFull = seedLiquidity(key, lpFullRange, true, 0, 50e18, 50e18);

        // Add narrow-range liquidity (50% range around current price)
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdNarrow = seedLiquidity(key, lpNarrowRange, false, 0.5e18, 50e18, 50e18);

        // Make donation
        _makeDonation(donateAmount0, donateAmount1);

        // Both should receive fees (both ranges include current price)
        assertTrue(_lpReceivedFees(positionTokenIdFull, lpFullRange), "Full range LP should receive fees");
        assertTrue(_lpReceivedFees(positionTokenIdNarrow, lpNarrowRange), "Narrow range LP should receive fees");
    }

    /**
     * @notice Fuzz: Verify LP that adds liquidity AFTER donation doesn't receive those fees
     * @dev Tests that only LPs present during donation receive fees from that donation
     */
    function testFuzz_lp_added_after_donation_receives_no_fees(uint128 donationAmount0, uint128 donationAmount1)
        public
    {
        donationAmount0 = uint128(bound(donationAmount0, 1e18, 20e18));
        donationAmount1 = uint128(bound(donationAmount1, 1e18, 20e18));

        address lateLp = makeAddr("lateLp");

        // Make donation BEFORE LP adds liquidity
        _makeDonation(donationAmount0, donationAmount1);

        // LP adds liquidity AFTER donation
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdLate = seedLiquidity(key, lateLp, true, 0, 30e18, 30e18);

        // Late LP should NOT have received fees from the donation that happened before they provided liquidity
        assertFalse(
            _lpReceivedFees(positionTokenIdLate, lateLp), "LP added after donation should not receive those fees"
        );
    }

    /**
     * @notice Fuzz: Verify LP with more concentrated liquidity receives more fees
     * @dev Tests that with same liquidity amounts added at same time, concentrated range earns more
     */
    function testFuzz_concentrated_lp_receives_more_fees(uint128 donationAmount0, uint128 donationAmount1) public {
        donationAmount0 = uint128(bound(donationAmount0, 2e18, 20e18));
        donationAmount1 = uint128(bound(donationAmount1, 2e18, 20e18));

        address lpWide = makeAddr("lpWide");
        address lpConcentrated = makeAddr("lpConcentrated");

        // Both LPs add same token amounts at same time
        // Wide LP: full range
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdWide = seedLiquidity(key, lpWide, true, 0, 50e18, 50e18);

        // Concentrated LP: 50% range around current price (more concentrated = more liquidity for same tokens)
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdConcentrated = seedLiquidity(key, lpConcentrated, false, 0.5e18, 50e18, 50e18);

        // Record balances before
        uint256 wideBalance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpWide);
        uint256 wideBalance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpWide);
        uint256 concBalance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpConcentrated);
        uint256 concBalance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpConcentrated);

        // Make donation
        _makeDonation(donationAmount0, donationAmount1);

        // Collect fees
        _collectFees(positionTokenIdWide, lpWide);
        _collectFees(positionTokenIdConcentrated, lpConcentrated);

        // Calculate fees received for each token separately
        uint256 wideFees0 = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpWide) - wideBalance0Before;
        uint256 wideFees1 = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpWide) - wideBalance1Before;
        uint256 concFees0 = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpConcentrated) - concBalance0Before;
        uint256 concFees1 = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpConcentrated) - concBalance1Before;

        // Both LPs should receive fees from both tokens
        assertTrue(wideFees0 > 0, "Wide LP should receive token0 fees");
        assertTrue(wideFees1 > 0, "Wide LP should receive token1 fees");
        assertTrue(concFees0 > 0, "Concentrated LP should receive token0 fees");
        assertTrue(concFees1 > 0, "Concentrated LP should receive token1 fees");

        // Concentrated LP should receive MORE fees for EACH token (more liquidity in active range)
        assertTrue(concFees0 > wideFees0, "Concentrated LP should receive more token0 fees than wide LP");
        assertTrue(concFees1 > wideFees1, "Concentrated LP should receive more token1 fees than wide LP");
    }

    /**
     * @notice Fuzz: Verify LP that adds MORE liquidity receives MORE fees
     * @dev Tests that on same range at same time, more liquidity = more fees
     */
    function testFuzz_larger_lp_receives_more_fees(uint128 donationAmount0, uint128 donationAmount1) public {
        donationAmount0 = uint128(bound(donationAmount0, 2e18, 20e18));
        donationAmount1 = uint128(bound(donationAmount1, 2e18, 20e18));

        address lpSmall = makeAddr("lpSmall");
        address lpLarge = makeAddr("lpLarge");

        // Both LPs provide same range (full range) at same time
        // Small LP provides less liquidity
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdSmall = seedLiquidity(key, lpSmall, true, 0, 25e18, 25e18);

        // Large LP provides MORE liquidity (2x)
        deal(Currency.unwrap(key.currency0), address(this), 1000e18);
        deal(Currency.unwrap(key.currency1), address(this), 1000e18);
        uint256 positionTokenIdLarge = seedLiquidity(key, lpLarge, true, 0, 50e18, 50e18);

        // Record balances before
        uint256 smallBalance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpSmall);
        uint256 smallBalance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpSmall);
        uint256 largeBalance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpLarge);
        uint256 largeBalance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpLarge);

        // Make donation
        _makeDonation(donationAmount0, donationAmount1);

        // Collect fees
        _collectFees(positionTokenIdSmall, lpSmall);
        _collectFees(positionTokenIdLarge, lpLarge);

        // Calculate fees received for each token separately
        uint256 smallFees0 = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpSmall) - smallBalance0Before;
        uint256 smallFees1 = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpSmall) - smallBalance1Before;
        uint256 largeFees0 = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lpLarge) - largeBalance0Before;
        uint256 largeFees1 = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lpLarge) - largeBalance1Before;

        // Both LPs should receive fees from both tokens
        assertTrue(smallFees0 > 0, "Small LP should receive token0 fees");
        assertTrue(smallFees1 > 0, "Small LP should receive token1 fees");
        assertTrue(largeFees0 > 0, "Large LP should receive token0 fees");
        assertTrue(largeFees1 > 0, "Large LP should receive token1 fees");

        // Large LP should receive MORE fees for EACH token (provided 2x liquidity)
        assertTrue(largeFees0 > smallFees0, "Large LP should receive more token0 fees than small LP");
        assertTrue(largeFees1 > smallFees1, "Large LP should receive more token1 fees than small LP");

        // Fee ratio should be approximately 2:1 for EACH token (with tolerance for rounding and existing liquidity)
        // Large LP provided 2x liquidity, so should get roughly 2x fees (allow 30% tolerance due to base pool liquidity)
        assertApproxEqRel(largeFees0, smallFees0 * 2, 0.3e18, "Token0 fee ratio should be approximately 2:1");
        assertApproxEqRel(largeFees1, smallFees1 * 2, 0.3e18, "Token1 fee ratio should be approximately 2:1");
    }

    /* ========================================================================== */
    /*                     HELPER FUNCTIONS                                       */
    /* ========================================================================== */

    function _collectFees(uint256 positionTokenId, address recipient) internal {
        vm.startPrank(recipient);
        positionManager.collect(positionTokenId, 0, 0, recipient, block.timestamp + 1, Constants.ZERO_BYTES);
        vm.stopPrank();
    }

    function _makeDonation(uint256 amount0, uint256 amount1) internal {
        address donor = makeAddr("testDonor");
        deal(Currency.unwrap(key.currency0), donor, amount0);
        deal(Currency.unwrap(key.currency1), donor, amount1);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);
        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    function _lpReceivedFees(uint256 positionTokenId, address lp) internal returns (bool) {
        uint256 balance0Before = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lp);
        uint256 balance1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lp);

        _collectFees(positionTokenId, lp);

        uint256 balance0After = MockERC20(Currency.unwrap(key.currency0)).balanceOf(lp);
        uint256 balance1After = MockERC20(Currency.unwrap(key.currency1)).balanceOf(lp);

        return (balance0After > balance0Before) || (balance1After > balance1Before);
    }

    function _setupDonor(address donor, uint256 amount0, uint256 amount1) internal {
        deal(Currency.unwrap(key.currency0), donor, amount0);
        deal(Currency.unwrap(key.currency1), donor, amount1);
    }

    function _executeDonation(address donor, uint256 amount0, uint256 amount1) internal {
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency0)).approve(address(donateRouter), amount0);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);
        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }
}
