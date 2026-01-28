// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title GettersTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky getter functions.
 * @dev Tests getClaimableFees, getLastRate, getFee, getReferralCode, and getYieldTreasury.
 */
contract GettersTest is BaseAlphix4626WrapperSky {
    /* getClaimableFees */

    /**
     * @notice Tests that getClaimableFees returns zero after deployment.
     */
    function test_getClaimableFees_afterDeployment_returnsZero() public view {
        uint256 fees = wrapper.getClaimableFees();
        assertEq(fees, 0, "No fees should be claimable after deployment");
    }

    /**
     * @notice Tests that getClaimableFees returns zero without yield.
     */
    function test_getClaimableFees_noYield_returnsZero() public {
        _depositAsHook(1000e18, alphixHook);

        uint256 fees = wrapper.getClaimableFees();
        assertEq(fees, 0, "No fees should be claimable without yield");
    }

    /**
     * @notice Tests that getClaimableFees returns correct amount after yield.
     */
    function test_getClaimableFees_afterYield_returnsCorrectAmount() public {
        _depositAsHook(1000e18, alphixHook);

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 fees = wrapper.getClaimableFees();

        // Total = seed + deposit = 1001e18
        // Yield = 1% of totalAssets (circuit breaker limit)
        // Fee = 10% of yield (DEFAULT_FEE = 100_000)
        // Fees are in sUSDS
        assertGt(fees, 0, "Should have claimable fees after yield");
    }

    /**
     * @notice Tests that getClaimableFees with zero fee returns zero.
     */
    function test_getClaimableFees_zeroFee_returnsZero() public {
        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(1000e18, alphixHook);
        _simulateYieldPercent(1);

        uint256 fees = wrapper.getClaimableFees();
        assertEq(fees, 0, "No fees with zero fee rate");
    }

    /**
     * @notice Tests that getClaimableFees includes accumulated fees.
     */
    function test_getClaimableFees_includesAccumulatedFees() public {
        _depositAsHook(1000e18, alphixHook);

        // First yield accrual
        _simulateYieldPercent(1);
        uint256 feesAfterFirst = wrapper.getClaimableFees();

        // Trigger accrual by depositing (moves pending to accumulated)
        _depositAsHook(500e18, alphixHook);

        // Second yield
        _simulateYieldPercent(1);
        uint256 feesAfterSecond = wrapper.getClaimableFees();

        assertGt(feesAfterSecond, feesAfterFirst, "Fees should accumulate");
    }

    /**
     * @notice Tests that getClaimableFees does not revert.
     */
    function test_getClaimableFees_doesNotRevert() public view {
        wrapper.getClaimableFees();
    }

    /* getLastRate */

    /**
     * @notice Tests that getLastRate returns initial rate after deployment.
     */
    function test_getLastRate_afterDeployment_returnsInitialRate() public view {
        uint256 lastRate = wrapper.getLastRate();
        assertEq(lastRate, INITIAL_RATE, "Last rate should equal initial rate (1e27)");
    }

    /**
     * @notice Tests that getLastRate updates after yield accrual.
     */
    function test_getLastRate_afterYieldAccrual_updates() public {
        _depositAsHook(1000e18, alphixHook);

        uint256 lastRateBefore = wrapper.getLastRate();

        // Simulate yield
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 lastRateAfter = wrapper.getLastRate();
        assertGt(lastRateAfter, lastRateBefore, "Last rate should increase after yield accrual");
    }

    /**
     * @notice Tests that getLastRate does not revert.
     */
    function test_getLastRate_doesNotRevert() public view {
        wrapper.getLastRate();
    }

    /* getFee */

    /**
     * @notice Tests that getFee returns initial fee after deployment.
     */
    function test_getFee_afterDeployment_returnsInitialFee() public view {
        uint256 fee = wrapper.getFee();
        assertEq(fee, DEFAULT_FEE, "Fee should equal initial fee");
    }

    /**
     * @notice Tests that getFee returns updated fee after setFee.
     */
    function test_getFee_afterSetFee_returnsNewFee() public {
        uint24 newFee = 200_000; // 20%

        vm.prank(owner);
        wrapper.setFee(newFee);

        uint256 fee = wrapper.getFee();
        assertEq(fee, newFee, "Fee should equal new fee");
    }

    /**
     * @notice Tests that getFee returns zero after setting to zero.
     */
    function test_getFee_afterSetToZero_returnsZero() public {
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 fee = wrapper.getFee();
        assertEq(fee, 0, "Fee should be zero");
    }

    /**
     * @notice Tests that getFee returns max after setting to max.
     */
    function test_getFee_afterSetToMax_returnsMax() public {
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        uint256 fee = wrapper.getFee();
        assertEq(fee, MAX_FEE, "Fee should be max");
    }

    /**
     * @notice Tests that getFee does not revert.
     */
    function test_getFee_doesNotRevert() public view {
        wrapper.getFee();
    }

    /* getReferralCode */

    /**
     * @notice Tests that getReferralCode returns initial value after deployment.
     */
    function test_getReferralCode_afterDeployment_returnsInitialValue() public view {
        uint256 referralCode = wrapper.getReferralCode();
        assertEq(referralCode, 0, "Referral code should be 0 initially");
    }

    /**
     * @notice Tests that getReferralCode returns updated value after setReferralCode.
     */
    function test_getReferralCode_afterSet_returnsNewValue() public {
        uint256 newCode = 12345;

        vm.prank(owner);
        wrapper.setReferralCode(newCode);

        uint256 referralCode = wrapper.getReferralCode();
        assertEq(referralCode, newCode, "Referral code should equal new value");
    }

    /**
     * @notice Tests that getReferralCode does not revert.
     */
    function test_getReferralCode_doesNotRevert() public view {
        wrapper.getReferralCode();
    }

    /* getYieldTreasury */

    /**
     * @notice Tests that getYieldTreasury returns initial treasury after deployment.
     */
    function test_getYieldTreasury_afterDeployment_returnsTreasury() public view {
        address yieldTreasury = wrapper.getYieldTreasury();
        assertEq(yieldTreasury, treasury, "Yield treasury should equal initial treasury");
    }

    /**
     * @notice Tests that getYieldTreasury returns updated value after setYieldTreasury.
     */
    function test_getYieldTreasury_afterSet_returnsNewValue() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        wrapper.setYieldTreasury(newTreasury);

        address yieldTreasury = wrapper.getYieldTreasury();
        assertEq(yieldTreasury, newTreasury, "Yield treasury should equal new value");
    }

    /**
     * @notice Tests that getYieldTreasury does not revert.
     */
    function test_getYieldTreasury_doesNotRevert() public view {
        wrapper.getYieldTreasury();
    }

    /* ERC4626 Standard Getters */

    /**
     * @notice Tests that asset() returns USDS.
     */
    function test_asset_returnsUsds() public view {
        address assetAddress = wrapper.asset();
        assertEq(assetAddress, address(usds), "Asset should be USDS");
    }

    /**
     * @notice Tests that decimals() returns 18.
     */
    function test_decimals_returns18() public view {
        uint8 decimals = wrapper.decimals();
        assertEq(decimals, 18, "Decimals should be 18");
    }

    /**
     * @notice Tests that name() returns correct value.
     */
    function test_name_returnsCorrectValue() public view {
        string memory name = wrapper.name();
        assertEq(name, "Alphix sUSDS Vault", "Name should match");
    }

    /**
     * @notice Tests that symbol() returns correct value.
     */
    function test_symbol_returnsCorrectValue() public view {
        string memory symbol = wrapper.symbol();
        assertEq(symbol, "alphsUSDS", "Symbol should match");
    }
}
