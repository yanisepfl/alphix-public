// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title GettersTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave getter functions.
 * @dev Tests getClaimableFees, getLastWrapperBalance, and getFee.
 */
contract GettersTest is BaseAlphix4626WrapperAave {
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
        _depositAsHook(100e6, alphixHook);

        uint256 fees = wrapper.getClaimableFees();
        assertEq(fees, 0, "No fees should be claimable without yield");
    }

    /**
     * @notice Tests that getClaimableFees returns correct amount after yield.
     */
    function test_getClaimableFees_afterYield_returnsCorrectAmount() public {
        _depositAsHook(100e6, alphixHook);

        // Simulate 10% yield
        _simulateYieldPercent(10);

        uint256 fees = wrapper.getClaimableFees();

        // Total = seed + deposit = 101e6
        // Yield = 10% of 101e6 = 10.1e6
        // Fee = 10% of yield (DEFAULT_FEE = 100_000) = 1.01e6
        uint256 totalBalance = DEFAULT_SEED_LIQUIDITY + 100e6;
        uint256 expectedYield = totalBalance * 10 / 100;
        uint256 expectedFees = expectedYield * DEFAULT_FEE / MAX_FEE;

        _assertApproxEq(fees, expectedFees, 1, "Fees should match expected");
    }

    /**
     * @notice Tests that getClaimableFees with zero fee returns zero.
     */
    function test_getClaimableFees_zeroFee_returnsZero() public {
        vm.prank(owner);
        wrapper.setFee(0);

        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);

        uint256 fees = wrapper.getClaimableFees();
        assertEq(fees, 0, "No fees with zero fee rate");
    }

    /**
     * @notice Tests that getClaimableFees with max fee returns full yield.
     */
    function test_getClaimableFees_maxFee_returnsFullYield() public {
        vm.prank(owner);
        wrapper.setFee(MAX_FEE);

        _depositAsHook(100e6, alphixHook);

        uint256 balanceBefore = aToken.balanceOf(address(wrapper));
        _simulateYieldPercent(10);
        uint256 balanceAfter = aToken.balanceOf(address(wrapper));

        uint256 actualYield = balanceAfter - balanceBefore;
        uint256 fees = wrapper.getClaimableFees();

        assertEq(fees, actualYield, "All yield should be fees with max fee");
    }

    /**
     * @notice Tests that getClaimableFees includes accumulated fees.
     */
    function test_getClaimableFees_includesAccumulatedFees() public {
        _depositAsHook(100e6, alphixHook);

        // First yield accrual
        _simulateYieldPercent(5);
        uint256 feesAfterFirst = wrapper.getClaimableFees();

        // Trigger accrual by depositing (moves pending to accumulated)
        _depositAsHook(50e6, alphixHook);

        // Second yield
        _simulateYieldPercent(5);
        uint256 feesAfterSecond = wrapper.getClaimableFees();

        assertGt(feesAfterSecond, feesAfterFirst, "Fees should accumulate");
    }

    /**
     * @notice Tests that getClaimableFees does not revert.
     */
    function test_getClaimableFees_doesNotRevert() public view {
        wrapper.getClaimableFees();
    }

    /* getLastWrapperBalance */

    /**
     * @notice Tests that getLastWrapperBalance returns seed liquidity after deployment.
     */
    function test_getLastWrapperBalance_afterDeployment_returnsSeedLiquidity() public view {
        uint256 lastBalance = wrapper.getLastWrapperBalance();
        assertEq(lastBalance, DEFAULT_SEED_LIQUIDITY, "Last balance should equal seed liquidity");
    }

    /**
     * @notice Tests that getLastWrapperBalance updates after deposit.
     */
    function test_getLastWrapperBalance_afterDeposit_updates() public {
        uint256 depositAmount = 100e6;
        _depositAsHook(depositAmount, alphixHook);

        uint256 lastBalance = wrapper.getLastWrapperBalance();
        assertEq(lastBalance, DEFAULT_SEED_LIQUIDITY + depositAmount, "Last balance should include deposit");
    }

    /**
     * @notice Tests that getLastWrapperBalance updates after yield accrual.
     */
    function test_getLastWrapperBalance_afterYieldAccrual_updates() public {
        _depositAsHook(100e6, alphixHook);

        uint256 lastBalanceBefore = wrapper.getLastWrapperBalance();

        // Simulate yield
        _simulateYieldPercent(10);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 lastBalanceAfter = wrapper.getLastWrapperBalance();
        assertGt(lastBalanceAfter, lastBalanceBefore, "Last balance should increase after yield accrual");
    }

    /**
     * @notice Tests that getLastWrapperBalance does not revert.
     */
    function test_getLastWrapperBalance_doesNotRevert() public view {
        wrapper.getLastWrapperBalance();
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
}
