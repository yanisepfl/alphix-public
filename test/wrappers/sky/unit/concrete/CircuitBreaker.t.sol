// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title CircuitBreakerTest
 * @author Alphix
 * @notice Unit tests for the rate circuit breaker mechanism.
 * @dev Tests the 1% bidirectional rate change limit that reverts on breach.
 *      The circuit breaker protects against oracle manipulation by blocking
 *      any transaction that would process a rate change exceeding 1%.
 */
contract CircuitBreakerTest is BaseAlphix4626WrapperSky {
    /// @notice Event emitted when circuit breaker triggers
    event CircuitBreakerTriggered(uint256 lastRate, uint256 currentRate, uint256 changeBps);

    /* POSITIVE DIRECTION TESTS */

    /**
     * @notice Tests that small positive rate changes (below 1%) are allowed.
     */
    function test_circuitBreaker_allowsSmallPositiveChange() public {
        // First deposit to establish state
        _depositAsHook(10_000e18, alphixHook);

        // Use setRate to simulate a small change (0.5%)
        uint256 currentRate = _getCurrentRate();
        uint256 newRate = currentRate * 1005 / 1000; // 0.5% increase
        _setRate(newRate);

        // Trigger accrual via deposit (should succeed)
        _depositAsHook(100e18, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests that exactly 1% positive rate change is allowed (threshold is <=).
     */
    function test_circuitBreaker_exactThreshold_positive_passes() public {
        _depositAsHook(10_000e18, alphixHook);

        // Exactly 1% yield should pass
        _simulateYieldPercent(1);

        // Trigger accrual via deposit
        _depositAsHook(100e18, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests that large positive rate changes (2%) trigger the circuit breaker and revert.
     */
    function test_circuitBreaker_triggersOnLargePositiveChange() public {
        _depositAsHook(10_000e18, alphixHook);

        // 2% yield should trigger circuit breaker
        _simulateYieldPercent(2);

        // Attempt to trigger accrual via deposit - should revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that 5% positive rate change reverts (exceeds 1% threshold).
     */
    function test_circuitBreaker_largePositiveChange_reverts() public {
        _depositAsHook(10_000e18, alphixHook);

        // 5% yield should trigger circuit breaker (exceeds 1% threshold)
        _simulateYieldPercent(5);

        // Attempt operation that triggers accrual - should revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that circuit breaker reverts with ExcessiveRateChange error.
     */
    function test_circuitBreaker_positiveChange_revertsWithError() public {
        _depositAsHook(10_000e18, alphixHook);

        uint256 lastRate = _getCurrentRate();

        // 5% yield (exceeds 1% threshold)
        _simulateYieldPercent(5);
        uint256 currentRate = _getCurrentRate();
        uint256 expectedChangeBps = ((currentRate - lastRate) * 10_000) / lastRate;

        // Expect specific revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphix4626WrapperSky.ExcessiveRateChange.selector, lastRate, currentRate, expectedChangeBps
            )
        );
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /* NEGATIVE DIRECTION TESTS */

    /**
     * @notice Tests that small negative rate changes (below 1%) are allowed.
     */
    function test_circuitBreaker_allowsSmallNegativeChange() public {
        _depositAsHook(10_000e18, alphixHook);

        // Use setRate to simulate a small change (0.5%)
        uint256 currentRate = _getCurrentRate();
        uint256 newRate = currentRate * 995 / 1000; // 0.5% decrease
        _setRate(newRate);

        // Trigger accrual via deposit
        _depositAsHook(100e18, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests that exactly 1% negative rate change is allowed.
     */
    function test_circuitBreaker_exactThreshold_negative_passes() public {
        _depositAsHook(10_000e18, alphixHook);

        // Exactly 1% slash should pass
        _simulateSlashPercent(1);

        // Trigger accrual via deposit
        _depositAsHook(100e18, alphixHook);

        _assertSolvent();
    }

    /**
     * @notice Tests that large negative rate changes (2%) trigger the circuit breaker.
     */
    function test_circuitBreaker_triggersOnLargeNegativeChange() public {
        _depositAsHook(10_000e18, alphixHook);

        // 2% slash should trigger circuit breaker
        _simulateSlashPercent(2);

        // Attempt to trigger accrual via deposit - should revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that 5% negative rate change reverts (exceeds 1% threshold).
     */
    function test_circuitBreaker_largeNegativeChange_reverts() public {
        _depositAsHook(10_000e18, alphixHook);

        // 5% slash should trigger circuit breaker (exceeds 1% threshold)
        _simulateSlashPercent(5);

        // Attempt operation that triggers accrual - should revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Tests that circuit breaker reverts with ExcessiveRateChange on negative breach.
     */
    function test_circuitBreaker_negativeChange_revertsWithError() public {
        _depositAsHook(10_000e18, alphixHook);

        uint256 lastRate = _getCurrentRate();

        // 5% slash (exceeds 1% threshold)
        _simulateSlashPercent(5);
        uint256 currentRate = _getCurrentRate();
        uint256 expectedChangeBps = ((lastRate - currentRate) * 10_000) / lastRate;

        // Expect specific revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAlphix4626WrapperSky.ExcessiveRateChange.selector, lastRate, currentRate, expectedChangeBps
            )
        );
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /* EDGE CASE TESTS */

    /**
     * @notice Tests that first user deposit works normally.
     * @dev On deployment, lastRate is set to initial rate, so first accrual already has a baseline.
     */
    function test_circuitBreaker_firstUserDeposit_works() public {
        // First user deposit should work
        _depositAsHook(1000e18, alphixHook);
    }

    /**
     * @notice Tests that multiple small changes are allowed sequentially.
     * @dev Each change is checked independently against the updated baseline.
     */
    function test_circuitBreaker_loopedSmallChanges_allowed() public {
        _depositAsHook(10_000e18, alphixHook);

        // Multiple 1% changes should all pass when accrual triggers between each
        for (uint256 i = 0; i < 5; i++) {
            _simulateYieldPercent(1);

            // Trigger accrual to update lastRate
            vm.prank(owner);
            wrapper.setFee(DEFAULT_FEE);
        }

        _assertSolvent();
    }

    /**
     * @notice Tests that cumulative small changes that compound to >1% still work.
     * @dev Because each change is checked independently after accrual updates lastRate.
     */
    function test_circuitBreaker_cumulativeChanges_checkPerAccrual() public {
        _depositAsHook(10_000e18, alphixHook);

        uint256 initialRate = _getCurrentRate();

        // Do 5 cycles of 1% yield with accrual between each
        for (uint256 i = 0; i < 5; i++) {
            _simulateYieldPercent(1);
            vm.prank(owner);
            wrapper.setFee(DEFAULT_FEE);
        }

        uint256 finalRate = _getCurrentRate();

        // Total rate increase is roughly (1.01)^5 - 1 ≈ 5.1%
        assertGt(finalRate, initialRate * 105 / 100, "Rate should have increased >5%");

        _assertSolvent();
    }

    /**
     * @notice Tests that operations work after rate normalizes following a failed attempt.
     */
    function test_circuitBreaker_operationsWorkAfterRateNormalizes() public {
        _depositAsHook(10_000e18, alphixHook);

        // Trigger circuit breaker with 5% change - reverts (exceeds 1% threshold)
        _simulateYieldPercent(5);

        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();

        // Reset rate to something reasonable
        _setRate(INITIAL_RATE);

        // Operations should work
        _depositAsHook(100e18, alphixHook);
    }

    /**
     * @notice Tests that rate unchanged does not trigger circuit breaker.
     */
    function test_circuitBreaker_rateUnchanged_noop() public {
        _depositAsHook(10_000e18, alphixHook);

        // Don't change rate at all

        // Deposit should work
        _depositAsHook(100e18, alphixHook);
    }

    /**
     * @notice Tests circuit breaker reverts on withdraw operation.
     */
    function test_circuitBreaker_triggersOnWithdraw() public {
        _depositAsHook(10_000e18, alphixHook);

        // 5% yield should trigger circuit breaker (exceeds 1%)
        _simulateYieldPercent(5);

        // Attempt withdraw - should revert
        vm.prank(alphixHook);
        vm.expectRevert();
        wrapper.withdraw(1000e18, alphixHook, alphixHook);
    }

    /**
     * @notice Tests circuit breaker reverts on redeem operation.
     */
    function test_circuitBreaker_triggersOnRedeem() public {
        _depositAsHook(10_000e18, alphixHook);

        // 5% slash should trigger circuit breaker (exceeds 1%)
        _simulateSlashPercent(5);

        // Attempt redeem - should revert
        uint256 shares = wrapper.balanceOf(alphixHook);
        vm.prank(alphixHook);
        vm.expectRevert();
        wrapper.redeem(shares / 2, alphixHook, alphixHook);
    }

    /**
     * @notice Tests circuit breaker reverts on fee collection.
     */
    function test_circuitBreaker_triggersOnCollectFees() public {
        _depositAsHook(10_000e18, alphixHook);

        // Generate some fees first (1% is within threshold)
        _simulateYieldPercent(1);
        vm.prank(owner);
        wrapper.setFee(DEFAULT_FEE); // Trigger accrual to generate fees

        // Now simulate excessive rate change (5% exceeds 1% threshold)
        _simulateYieldPercent(5);

        // Attempt fee collection - should revert
        vm.prank(owner);
        vm.expectRevert();
        wrapper.collectFees();
    }

    /**
     * @notice Tests that setFee also triggers circuit breaker revert.
     */
    function test_circuitBreaker_triggersOnSetFee() public {
        _depositAsHook(10_000e18, alphixHook);

        // 5% yield should trigger circuit breaker (exceeds 1%)
        _simulateYieldPercent(5);

        // Attempt to change fee (triggers accrual) - should revert
        vm.prank(owner);
        vm.expectRevert();
        wrapper.setFee(200_000);
    }

    /* FUZZ TESTS FOR CIRCUIT BREAKER */

    /**
     * @notice Fuzz test that changes within threshold always pass.
     */
    function testFuzz_circuitBreaker_withinThreshold_passes(uint256 changePercent) public {
        changePercent = bound(changePercent, 1, 1); // Only 1% passes now

        _depositAsHook(10_000e18, alphixHook);

        _simulateYieldPercent(changePercent);

        // Should succeed
        _depositAsHook(100e18, alphixHook);
    }

    /**
     * @notice Fuzz test that changes exceeding threshold always revert.
     */
    function testFuzz_circuitBreaker_exceedsThreshold_reverts(uint256 changePercent) public {
        changePercent = bound(changePercent, 2, 50); // >1% should revert

        _depositAsHook(10_000e18, alphixHook);

        _simulateYieldPercent(changePercent);

        // Should revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test negative changes within threshold pass.
     */
    function testFuzz_circuitBreaker_negativeWithinThreshold_passes(uint256 slashPercent) public {
        slashPercent = bound(slashPercent, 1, 1); // Only 1% passes now

        _depositAsHook(10_000e18, alphixHook);

        _simulateSlashPercent(slashPercent);

        // Should succeed
        _depositAsHook(100e18, alphixHook);
    }

    /**
     * @notice Fuzz test negative changes exceeding threshold revert.
     */
    function testFuzz_circuitBreaker_negativeExceedsThreshold_reverts(uint256 slashPercent) public {
        slashPercent = bound(slashPercent, 2, 50); // >1% should revert

        _depositAsHook(10_000e18, alphixHook);

        _simulateSlashPercent(slashPercent);

        // Should revert
        usds.mint(alphixHook, 100e18);
        vm.startPrank(alphixHook);
        usds.approve(address(wrapper), 100e18);
        vm.expectRevert();
        wrapper.deposit(100e18, alphixHook);
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test boundary: exactly 1% always passes.
     */
    function testFuzz_circuitBreaker_exactlyOnePercent_passes(bool isPositive) public {
        _depositAsHook(10_000e18, alphixHook);

        if (isPositive) {
            _simulateYieldPercent(1);
        } else {
            _simulateSlashPercent(1);
        }

        // Should succeed at exactly 1%
        _depositAsHook(100e18, alphixHook);
    }
}
