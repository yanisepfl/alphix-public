// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title DepositFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave deposit function.
 * @dev All tests fuzz asset decimals (6-18) to ensure decimal-agnostic behavior.
 */
contract DepositFuzzTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Fuzz test for deposit with varying amounts and decimals.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The deposit amount multiplier (1-1B tokens).
     */
    function testFuzz_deposit_varyingAmounts(uint8 decimals, uint256 amountMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        // Bound to reasonable range (1 to 1B tokens)
        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        uint256 amount = amountMultiplier * 10 ** d.decimals;

        d.asset.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), amount);

        uint256 sharesBefore = d.wrapper.balanceOf(alphixHook);
        uint256 shares = d.wrapper.deposit(amount, alphixHook);
        uint256 sharesAfter = d.wrapper.balanceOf(alphixHook);

        assertGt(shares, 0, "Should mint non-zero shares");
        assertEq(sharesAfter - sharesBefore, shares, "Share balance should increase by minted shares");
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that unauthorized callers always revert.
     * @param decimals The asset decimals (6-18).
     * @param caller Random caller address.
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_unauthorizedCaller_reverts(uint8 decimals, address caller, uint256 amountMultiplier)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        // Exclude authorized callers
        vm.assume(caller != alphixHook && caller != owner && caller != address(0));
        amountMultiplier = bound(amountMultiplier, 1, 1_000_000);
        uint256 amount = amountMultiplier * 10 ** d.decimals;

        d.asset.mint(caller, amount);

        vm.startPrank(caller);
        d.asset.approve(address(d.wrapper), amount);

        vm.expectRevert(IAlphix4626WrapperAave.UnauthorizedCaller.selector);
        d.wrapper.deposit(amount, caller);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that deposit to different receiver reverts (receiver != msg.sender).
     * @param decimals The asset decimals (6-18).
     * @param receiver Random receiver address.
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_differentReceiver_reverts(uint8 decimals, address receiver, uint256 amountMultiplier)
        public
    {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        // Receiver must be different from caller (alphixHook)
        vm.assume(receiver != alphixHook && receiver != address(0));
        amountMultiplier = bound(amountMultiplier, 1, 1_000_000);
        uint256 amount = amountMultiplier * 10 ** d.decimals;

        d.asset.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), amount);

        // InvalidReceiver because receiver != msg.sender
        vm.expectRevert(IAlphix4626WrapperAave.InvalidReceiver.selector);
        d.wrapper.deposit(amount, receiver);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test that deposit maintains solvency.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_maintainsSolvency(uint8 decimals, uint256 amountMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        uint256 amount = amountMultiplier * 10 ** d.decimals;

        d.asset.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), amount);
        d.wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        // Solvency check
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }

    /**
     * @notice Fuzz test that previewDeposit matches actual deposit.
     * @param decimals The asset decimals (6-18).
     * @param amountMultiplier The deposit amount multiplier.
     */
    function testFuzz_deposit_matchesPreview(uint8 decimals, uint256 amountMultiplier) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        amountMultiplier = bound(amountMultiplier, 1, 1_000_000_000);
        uint256 amount = amountMultiplier * 10 ** d.decimals;

        uint256 previewedShares = d.wrapper.previewDeposit(amount);

        d.asset.mint(alphixHook, amount);

        vm.startPrank(alphixHook);
        d.asset.approve(address(d.wrapper), amount);
        uint256 actualShares = d.wrapper.deposit(amount, alphixHook);
        vm.stopPrank();

        assertEq(actualShares, previewedShares, "Actual shares should match preview");
    }

    /**
     * @notice Fuzz test multiple sequential deposits.
     * @param decimals The asset decimals (6-18).
     * @param amountMultipliers Array of deposit amount multipliers.
     */
    function testFuzz_deposit_multipleDeposits(uint8 decimals, uint256[5] memory amountMultipliers) public {
        WrapperDeployment memory d = _createWrapperWithDecimals(decimals);

        uint256 totalShares;

        for (uint256 i = 0; i < amountMultipliers.length; i++) {
            amountMultipliers[i] = bound(amountMultipliers[i], 1, 100_000_000);
            uint256 amount = amountMultipliers[i] * 10 ** d.decimals;

            d.asset.mint(alphixHook, amount);

            vm.startPrank(alphixHook);
            d.asset.approve(address(d.wrapper), amount);
            totalShares += d.wrapper.deposit(amount, alphixHook);
            vm.stopPrank();
        }

        assertEq(d.wrapper.balanceOf(alphixHook), totalShares, "Total shares should match sum of deposits");

        // Solvency check
        uint256 aTokenBalance = d.aToken.balanceOf(address(d.wrapper));
        uint256 totalAssets = d.wrapper.totalAssets();
        uint256 claimableFees = d.wrapper.getClaimableFees();
        assertEq(totalAssets + claimableFees, aTokenBalance, "Solvency violated");
    }
}
