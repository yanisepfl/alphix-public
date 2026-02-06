// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title TotalAssetsTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave totalAssets function.
 * @dev totalAssets returns the aToken balance minus claimable fees.
 */
contract TotalAssetsTest is BaseAlphix4626WrapperAave {
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
        uint256 depositAmount = 100e6;
        uint256 totalAssetsBefore = wrapper.totalAssets();

        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore + depositAmount, "Total assets should increase by deposit amount");
    }

    /**
     * @notice Tests that totalAssets reflects yield minus fees.
     */
    function test_totalAssets_withYield_increasesMinusFees() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // Total yield = 10% of (seed + deposit) = 10% of 101e6 = 10.1e6
        // Fee = 10% of yield (DEFAULT_FEE = 100_000 = 10%) = 1.01e6
        // Net increase = yield - fee = 10.1e6 - 1.01e6 = 9.09e6
        uint256 grossYield = (DEFAULT_SEED_LIQUIDITY + depositAmount) * 10 / 100;
        uint256 expectedIncrease = grossYield * (MAX_FEE - DEFAULT_FEE) / MAX_FEE;

        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after yield");
        _assertApproxEq(totalAssetsAfter - totalAssetsBefore, expectedIncrease, 1, "Net increase should match expected");
    }

    /**
     * @notice Tests that totalAssets with zero fee gets full yield.
     */
    function test_totalAssets_zeroFee_getsFullYield() public {
        // Set fee to 0
        vm.prank(owner);
        wrapper.setFee(0);

        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 totalAssetsAfter = wrapper.totalAssets();

        // With 0% fee, all yield goes to totalAssets
        uint256 expectedYield = (DEFAULT_SEED_LIQUIDITY + depositAmount) * 10 / 100;

        _assertApproxEq(totalAssetsAfter - totalAssetsBefore, expectedYield, 1, "Should get full yield with zero fee");
    }

    /**
     * @notice Tests that totalAssets with max fee gets no yield.
     */
    function test_totalAssets_maxFee_getsNoYield() public {
        // Set fee to 100%
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        uint256 totalAssetsBefore = wrapper.totalAssets();

        // Simulate 10% yield
        _simulateYieldPercent(10);

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
        uint256 deposit1 = 50e6;
        uint256 deposit2 = 75e6;
        uint256 deposit3 = 100e6;

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
     * @notice Tests that totalAssets equals aToken balance minus fees.
     */
    function test_totalAssets_equalsATokenMinusFees() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate yield to create fees
        _simulateYieldPercent(10);

        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 claimableFees = wrapper.getClaimableFees();
        uint256 totalAssets = wrapper.totalAssets();

        assertEq(totalAssets, aTokenBalance - claimableFees, "totalAssets should equal aToken balance minus fees");
    }
}
