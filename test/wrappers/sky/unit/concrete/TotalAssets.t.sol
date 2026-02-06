// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";

/**
 * @title TotalAssetsTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky totalAssets function.
 * @dev totalAssets returns the USDS value of sUSDS holdings minus claimable fees.
 *      Uses rate provider to convert sUSDS to USDS equivalent.
 */
contract TotalAssetsTest is BaseAlphix4626WrapperSky {
    /**
     * @notice Tests that totalAssets equals seed liquidity after deployment.
     */
    function test_totalAssets_afterDeployment_equalsSeedLiquidity() public view {
        uint256 totalAssets = wrapper.totalAssets();
        assertEq(totalAssets, DEFAULT_SEED_LIQUIDITY, "Total assets should equal seed liquidity");
    }

    /**
     * @notice Tests that totalAssets increases after deposit.
     */
    function test_totalAssets_afterDeposit_increases() public {
        uint256 depositAmount = 1000e18;
        uint256 totalAssetsBefore = wrapper.totalAssets();

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore + depositAmount, "Total assets should increase by deposit amount");
    }

    /**
     * @notice Tests that totalAssets reflects yield minus fees.
     */
    function test_totalAssets_withYield_increasesMinusFees() public {
        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate 1% yield via rate increase (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total yield = 1% of (seed + deposit) - limited by circuit breaker
        // Fee = 10% of yield (DEFAULT_FEE = 100_000 = 10%)
        // Net increase = yield - fee = 90% of yield
        uint256 grossYield = (DEFAULT_SEED_LIQUIDITY + depositAmount) * 1 / 100;
        uint256 expectedIncrease = grossYield * (MAX_FEE - DEFAULT_FEE) / MAX_FEE;

        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after yield");
        _assertApproxEq(
            totalAssetsAfter - totalAssetsBefore, expectedIncrease, 1e15, "Net increase should match expected"
        );
    }

    /**
     * @notice Tests that totalAssets with zero fee gets full yield.
     */
    function test_totalAssets_zeroFee_getsFullYield() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // With 0% fee, all yield goes to totalAssets (1% yield)
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + depositAmount) * 1 / 100;

        _assertApproxEq(
            totalAssetsAfter - totalAssetsBefore, expectedYield, 1e15, "Should get full yield with zero fee"
        );
    }

    /**
     * @notice Tests that totalAssets with max fee gets no yield.
     */
    function test_totalAssets_maxFee_getsNoYield() public {
        // Set fee to 100%
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        uint256 depositAmount = 1000e18;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate 1% yield (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // With 100% fee, no yield goes to totalAssets
        assertEq(totalAssetsAfter, totalAssetsBefore, "Should get no yield with max fee");
    }

    /**
     * @notice Tests that totalAssets does not revert.
     */
    function test_totalAssets_doesNotRevert() public view {
        wrapper.totalAssets();
    }

    /**
     * @notice Tests totalAssets after multiple deposits.
     */
    function test_totalAssets_multipleDeposits() public {
        uint256 deposit1 = 500e18;
        uint256 deposit2 = 750e18;
        uint256 deposit3 = 1000e18;

        // Hook deposits to self
        _depositAsHook(deposit1, alphixHook);
        // Hook deposits again to self
        _depositAsHook(deposit2, alphixHook);
        // Owner deposits to self
        _depositAsOwner(deposit3, owner);

        uint256 expectedTotal = DEFAULT_SEED_LIQUIDITY + deposit1 + deposit2 + deposit3;
        uint256 actualTotal = wrapper.totalAssets();

        assertEq(actualTotal, expectedTotal, "Total assets should equal sum of all deposits");
    }

    /**
     * @notice Tests that totalAssets equals sUSDS value in USDS minus fees.
     */
    function test_totalAssets_equalsSusdsValueMinusFees() public {
        _depositAsHook(1000e18, alphixHook);

        // Simulate yield to create fees
        _simulateYieldPercent(1);

        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 totalAssets = wrapper.totalAssets();

        // Net sUSDS = balance - fees (in sUSDS)
        uint256 netSusds = susdsBalance - claimableFees;
        // Convert to USDS using rate
        uint256 netUsds = _susdsToUsds(netSusds);

        _assertApproxEq(totalAssets, netUsds, 2, "totalAssets should equal sUSDS value minus fees");
    }

    /**
     * @notice Tests totalAssets after rate increase (yield).
     */
    function test_totalAssets_afterRateIncrease() public {
        _depositAsHook(1000e18, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Increase rate by 1% (circuit breaker limit)
        _simulateYieldPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should increase (90% of yield if 10% fee)
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after rate increase");
    }

    /**
     * @notice Tests totalAssets after rate decrease (slash).
     */
    function test_totalAssets_afterRateDecrease() public {
        _depositAsHook(1000e18, alphixHook);

        // First generate some yield to have fees
        _simulateYieldPercent(1);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Decrease rate by 1% (slash)
        _simulateSlashPercent(1);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total assets should decrease
        assertLt(totalAssetsAfter, totalAssetsBefore, "Total assets should decrease after slash");
    }
}
