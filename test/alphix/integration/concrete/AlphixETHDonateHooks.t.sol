// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixETHDonateHooksTest
 * @notice Unit tests for beforeDonate and afterDonate hook functionality in AlphixETH
 * @dev Covers the _beforeDonate and _afterDonate functions that have 0 coverage
 */
contract AlphixETHDonateHooksTest is BaseAlphixETHTest {
    using CurrencyLibrary for Currency;
    using EasyPosm for IPositionManager;

    address private donor;
    PoolDonateTest private donateRouter;
    uint256 public lpTokenId;

    function setUp() public override {
        super.setUp();

        // Deploy donate router
        donateRouter = new PoolDonateTest(poolManager);

        // Create a donor address with tokens and ETH
        donor = makeAddr("donor");
        vm.deal(donor, 1000 ether);
        deal(Currency.unwrap(tokenCurrency), donor, 1000e18);

        // Add initial liquidity to enable donations
        _addInitialLiquidity();
    }

    /**
     * @notice Add initial liquidity to the pool to enable donations
     * @dev Uniswap V4 requires liquidity in a pool before donations can be received
     */
    function _addInitialLiquidity() internal {
        vm.startPrank(owner);

        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        // Approve token for position manager
        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        // Mint initial LP position
        (lpTokenId,) = positionManager.mint(
            key,
            tickLower,
            tickUpper,
            100e18, // liquidity amount
            100 ether, // amount0Max (ETH)
            100e18, // amount1Max (token)
            owner,
            block.timestamp + 60,
            Constants.ZERO_BYTES
        );

        vm.stopPrank();
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                                    CONCRETE TESTS
       ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Test that beforeDonate / afterDonate hooks are called and donation succeeds
     * @dev Verifies hooks don't revert and donation transfers tokens correctly
     */
    function test_beforeAndAfterDonate_called_on_donation() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 10e18;

        // Record donor balances before
        uint256 donorEthBefore = donor.balance;
        uint256 donorToken1Before = MockERC20(Currency.unwrap(key.currency1)).balanceOf(donor);

        // Approve tokens (ETH doesn't need approval)
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        // Donate and verify it succeeds (beforeDonate / afterDonate are called internally)
        donateRouter.donate{value: amount0}(key, amount0, amount1, "");
        vm.stopPrank();

        // Verify ETH was transferred from donor
        assertLt(donor.balance, donorEthBefore, "ETH should be transferred from donor");

        // Verify token was transferred from donor
        assertEq(
            MockERC20(Currency.unwrap(key.currency1)).balanceOf(donor),
            donorToken1Before - amount1,
            "Token1 should be transferred from donor"
        );
    }

    /**
     * @notice Test donation with only ETH (currency0)
     */
    function test_donate_only_eth() public {
        uint256 amount0 = 2 ether;
        uint256 amount1 = 0;

        vm.prank(donor);
        donateRouter.donate{value: amount0}(key, amount0, amount1, "");
    }

    /**
     * @notice Test donation with only token1
     */
    function test_donate_only_token1() public {
        uint256 amount0 = 0;
        uint256 amount1 = 20e18;

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate(key, amount0, amount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Test that donate hooks respect pool activation state
     */
    function test_donate_respects_pool_activation() public {
        // Deactivate the pool
        vm.prank(owner);
        hook.deactivatePool();

        // Try to donate - should revert because pool is deactivated
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), 1e18);

        vm.expectRevert(); // Will revert with PoolPaused or similar
        donateRouter.donate{value: 1 ether}(key, 1 ether, 1e18, "");
        vm.stopPrank();
    }

    /**
     * @notice Test donation when contract is paused
     */
    function test_donate_fails_when_paused() public {
        // Pause the hook
        vm.prank(owner);
        hook.pause();

        // Try to donate - should fail
        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), 1e18);

        vm.expectRevert(); // PoolManager wraps the PoolPaused error
        donateRouter.donate{value: 1 ether}(key, 1 ether, 1e18, "");
        vm.stopPrank();
    }

    /**
     * @notice Test large donation amounts
     */
    function test_donate_large_amounts() public {
        uint256 largeAmount0 = 50 ether;
        uint256 largeAmount1 = 500e18;

        // Give donor more tokens and ETH
        vm.deal(donor, largeAmount0 + 10 ether);
        deal(Currency.unwrap(key.currency1), donor, largeAmount1);

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), largeAmount1);

        donateRouter.donate{value: largeAmount0}(key, largeAmount0, largeAmount1, "");
        vm.stopPrank();
    }

    /**
     * @notice Test donation with custom hookData
     */
    function test_donate_with_custom_hookData() public {
        uint256 amount0 = 1 ether;
        uint256 amount1 = 10e18;
        bytes memory customData = abi.encode("test", uint256(123));

        vm.startPrank(donor);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), amount1);

        donateRouter.donate{value: amount0}(key, amount0, amount1, customData);
        vm.stopPrank();
    }

    /**
     * @notice Test multiple consecutive donations
     */
    function test_donate_multiple_consecutive() public {
        vm.startPrank(donor);

        // First donation
        MockERC20(Currency.unwrap(key.currency1)).approve(address(donateRouter), 30e18);
        donateRouter.donate{value: 1 ether}(key, 1 ether, 10e18, "");

        // Second donation
        donateRouter.donate{value: 0.5 ether}(key, 0.5 ether, 10e18, "");

        // Third donation
        donateRouter.donate{value: 0.5 ether}(key, 0.5 ether, 10e18, "");

        vm.stopPrank();
    }

    // Exclude from coverage
    function test() public {}
}
