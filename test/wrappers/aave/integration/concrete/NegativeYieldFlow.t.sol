// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";

/**
 * @title NegativeYieldFlowTest
 * @author Alphix
 * @notice Integration tests for negative yield (slashing) scenarios.
 */
contract NegativeYieldFlowTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Test complete slashing flow: deposit, yield, slash, deposit.
     */
    function test_negativeYieldFlow_depositYieldSlashDeposit() public {
        // Initial deposit
        _depositAsHook(100e6, alphixHook);

        uint256 initialShares = wrapper.balanceOf(alphixHook);
        uint256 initialTotalAssets = wrapper.totalAssets();

        // Generate yield
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterYield = wrapper.getClaimableFees();
        uint256 totalAssetsAfterYield = wrapper.totalAssets();

        assertGt(feesAfterYield, 0, "Should have fees from yield");
        assertGt(totalAssetsAfterYield, initialTotalAssets, "Total assets should increase");

        // Simulate 25% slashing
        uint256 balanceBeforeSlash = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balanceBeforeSlash * 25 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 feesAfterSlash = wrapper.getClaimableFees();
        uint256 totalAssetsAfterSlash = wrapper.totalAssets();

        assertLt(feesAfterSlash, feesAfterYield, "Fees should decrease after slash");
        assertLt(totalAssetsAfterSlash, totalAssetsAfterYield, "Total assets should decrease");

        // New deposit after slashing
        _depositAsHook(50e6, alphixHook);

        uint256 finalShares = wrapper.balanceOf(alphixHook);
        assertGt(finalShares, initialShares, "Should have more shares after second deposit");

        // Verify solvency
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency should be maintained");
    }

    /**
     * @notice Test slashing with multiple depositors.
     */
    function test_negativeYieldFlow_multipleDepositors() public {
        // Hook deposits
        _depositAsHook(100e6, alphixHook);
        uint256 hookShares = wrapper.balanceOf(alphixHook);

        // Owner deposits
        asset.mint(owner, 50e6);
        vm.startPrank(owner);
        asset.approve(address(wrapper), 50e6);
        wrapper.deposit(50e6, owner);
        vm.stopPrank();
        uint256 ownerShares = wrapper.balanceOf(owner);

        // Generate yield
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Slash 30%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 30 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Shares should remain the same (slashing affects assets, not shares)
        assertEq(wrapper.balanceOf(alphixHook), hookShares, "Hook shares unchanged");
        assertEq(wrapper.balanceOf(owner), ownerShares, "Owner shares unchanged");

        // But share value (convertToAssets) should decrease
        uint256 hookAssetsAfter = wrapper.convertToAssets(hookShares);
        uint256 ownerAssetsAfter = wrapper.convertToAssets(ownerShares);

        // Proportional loss
        uint256 hookRatio = hookShares * 1e18 / (hookShares + ownerShares);

        // Both should have roughly proportional losses
        assertApproxEqRel(
            hookAssetsAfter * 1e18 / (hookAssetsAfter + ownerAssetsAfter),
            hookRatio,
            0.01e18, // 1% tolerance
            "Hook should maintain proportional share"
        );
    }

    /**
     * @notice Test recovery after slashing with new yield.
     */
    function test_negativeYieldFlow_recoveryWithNewYield() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);

        // Generate yield
        _simulateYieldPercent(20);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsBeforeSlash = wrapper.totalAssets();

        // Slash 20%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 20 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterSlash = wrapper.totalAssets();
        assertLt(totalAssetsAfterSlash, totalAssetsBeforeSlash, "Assets should decrease");

        // Generate recovery yield (30%)
        _simulateYieldPercent(30);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        uint256 totalAssetsAfterRecovery = wrapper.totalAssets();

        // Should have recovered some value
        assertGt(totalAssetsAfterRecovery, totalAssetsAfterSlash, "Should recover with new yield");
    }

    /**
     * @notice Test extreme scenario: multiple slashes interspersed with deposits.
     */
    function test_negativeYieldFlow_complexScenario() public {
        // Phase 1: Initial deposit and yield
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 2: First slash
        uint256 balance1 = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance1 * 15 / 100);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 3: New deposit
        _depositAsHook(50e6, alphixHook);

        // Phase 4: More yield
        _simulateYieldPercent(10);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 5: Second slash
        uint256 balance2 = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance2 * 10 / 100);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Phase 6: Final yield
        _simulateYieldPercent(20);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify invariants hold
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency maintained in complex scenario");
        assertGt(totalAssets, 0, "Total assets should be positive");
    }

    /**
     * @notice Test slashing down to near-zero balance.
     */
    function test_negativeYieldFlow_extremeSlash() public {
        // Deposit
        _depositAsHook(100e6, alphixHook);
        _simulateYieldPercent(10);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Extreme slash: 95%
        uint256 balance = aToken.balanceOf(address(wrapper));
        aToken.simulateSlash(address(wrapper), balance * 95 / 100);

        // Trigger accrual
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE);

        // Verify contract still functions
        uint256 totalAssets = wrapper.totalAssets();
        uint256 claimableFees = wrapper.getClaimableFees();

        assertGt(totalAssets, 0, "Should have some assets remaining");

        // Solvency should still hold
        uint256 aTokenBalance = aToken.balanceOf(address(wrapper));
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency should hold");

        // Should still be able to deposit
        _depositAsHook(10e6, alphixHook);
        assertGt(wrapper.totalAssets(), totalAssets, "Should be able to deposit after extreme slash");
    }
}
