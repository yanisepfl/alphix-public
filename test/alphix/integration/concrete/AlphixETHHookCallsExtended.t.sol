// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* OZ IMPORTS */

/* SOLMATE IMPORTS */

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {IAlphix} from "../../../../src/interfaces/IAlphix.sol";
import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";

/**
 * @title AlphixETHHookCallsExtendedTest
 * @notice Extended tests for AlphixETH hook callbacks covering more code paths
 * @dev Tests swap and liquidity operations without ReHypothecation to avoid JIT arithmetic issues
 */
contract AlphixETHHookCallsExtendedTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;
    using EasyPosm for IPositionManager;
    using StateLibrary for IPoolManager;

    address public alice;
    address public bob;
    uint256 public lpTokenId;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        token.mint(alice, INITIAL_TOKEN_AMOUNT);
        token.mint(bob, INITIAL_TOKEN_AMOUNT);

        // Add initial liquidity (NO ReHypothecation configured)
        _addInitialLiquidity();
    }

    function _addInitialLiquidity() internal {
        vm.startPrank(owner);

        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        (lpTokenId,) = positionManager.mint(
            key, tickLower, tickUpper, 100e18, 100 ether, 100e18, owner, block.timestamp + 60, Constants.ZERO_BYTES
        );

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           SWAP TESTS WITHOUT REHYPOTHECATION               */
    /* ========================================================================== */

    function test_swap_zeroForOne_noReHypothecation() public {
        vm.startPrank(alice);

        uint256 swapAmount = 1 ether;
        uint256 tokenBalanceBefore = token.balanceOf(alice);

        swapRouter.swapExactTokensForTokens{value: swapAmount}({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        assertGt(token.balanceOf(alice), tokenBalanceBefore, "Should receive tokens");

        vm.stopPrank();
    }

    function test_swap_oneForZero_noReHypothecation() public {
        vm.startPrank(alice);

        uint256 swapAmount = 1e18;
        uint256 ethBalanceBefore = alice.balance;

        token.approve(address(swapRouter), swapAmount);

        swapRouter.swapExactTokensForTokens({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: false,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        assertGt(alice.balance, ethBalanceBefore, "Should receive ETH");

        vm.stopPrank();
    }

    function test_swap_multipleSwaps_maintainsFeeState() public {
        // Do several swaps and verify fee state is maintained
        vm.startPrank(alice);

        uint256 swapAmount = 1 ether;

        for (uint256 i = 0; i < 5; i++) {
            swapRouter.swapExactTokensForTokens{value: swapAmount}({
                amountIn: swapAmount,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: Constants.ZERO_BYTES,
                receiver: alice,
                deadline: block.timestamp + 100
            });
        }

        // Fee should still be set
        uint24 fee = hook.getFee();
        assertGt(fee, 0, "Fee should be set after swaps");

        vm.stopPrank();
    }

    function test_swap_smallSwap_succeeds() public {
        vm.startPrank(alice);

        uint256 swapAmount = 1000 wei;

        swapRouter.swapExactTokensForTokens{value: swapAmount}({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        // Should not revert
        vm.stopPrank();
    }

    function test_swap_largeSwap_succeeds() public {
        vm.startPrank(alice);

        uint256 swapAmount = 50 ether;

        swapRouter.swapExactTokensForTokens{value: swapAmount}({
            amountIn: swapAmount,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });

        // Should not revert
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           LIQUIDITY TESTS                                  */
    /* ========================================================================== */

    function test_addLiquidity_succeeds() public {
        vm.startPrank(alice);

        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        (uint256 newTokenId,) = positionManager.mint(
            key, tickLower, tickUpper, 10e18, 10 ether, 10e18, alice, block.timestamp + 60, Constants.ZERO_BYTES
        );

        assertGt(newTokenId, 0, "Should receive LP token");

        vm.stopPrank();
    }

    function test_removeLiquidity_succeeds() public {
        // First add liquidity
        vm.startPrank(alice);

        int24 tickLower = TickMath.minUsableTick(defaultTickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(defaultTickSpacing);

        token.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token), address(positionManager), type(uint160).max, uint48(block.timestamp + 100));

        (uint256 newTokenId,) = positionManager.mint(
            key, tickLower, tickUpper, 10e18, 10 ether, 10e18, alice, block.timestamp + 60, Constants.ZERO_BYTES
        );
        uint128 liquidity = uint128(10e18);

        // Then remove it
        uint256 ethBefore = alice.balance;
        uint256 tokenBefore = token.balanceOf(alice);

        positionManager.decreaseLiquidity(
            newTokenId, liquidity / 2, 0, 0, alice, block.timestamp + 60, Constants.ZERO_BYTES
        );

        assertGt(alice.balance, ethBefore, "Should receive ETH back");
        assertGt(token.balanceOf(alice), tokenBefore, "Should receive tokens back");

        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           PAUSE STATE TESTS                                */
    /* ========================================================================== */

    function test_swap_revertsWhenPaused() public {
        vm.prank(owner);
        hook.pause();

        vm.startPrank(alice);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    function test_swap_resumesAfterUnpause() public {
        vm.prank(owner);
        hook.pause();

        vm.prank(owner);
        hook.unpause();

        vm.startPrank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           DEACTIVATED POOL TESTS                           */
    /* ========================================================================== */

    function test_swap_revertsWhenPoolDeactivated() public {
        vm.prank(owner);
        hook.deactivatePool();

        vm.startPrank(alice);
        vm.expectRevert();
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    function test_swap_resumesAfterReactivation() public {
        vm.prank(owner);
        hook.deactivatePool();

        vm.prank(owner);
        hook.activatePool();

        vm.startPrank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           FEE UPDATE TESTS                                 */
    /* ========================================================================== */

    function test_poke_updatesFee() public {
        // Wait for cooldown
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        uint24 feeBefore = hook.getFee();

        vm.prank(owner);
        hook.poke(8e17); // 80% ratio (higher than initial 50%)

        uint24 feeAfter = hook.getFee();
        assertGt(feeAfter, feeBefore, "Fee should increase with higher ratio");
    }

    function test_poke_emitsFeeUpdatedEvent() public {
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);

        vm.prank(owner);
        vm.expectEmit(true, false, false, false);
        emit IAlphix.FeeUpdated(poolId, 0, 0, 0, 0, 0);
        hook.poke(7e17);
    }

    function test_swap_usesDynamicFee() public {
        // Wait for cooldown and change fee
        vm.warp(block.timestamp + defaultPoolParams.minPeriod + 1);
        vm.prank(owner);
        hook.poke(8e17);

        uint24 fee = hook.getFee();
        assertGt(fee, INITIAL_FEE, "Fee should be higher");

        // Swap should still work with new fee
        vm.startPrank(alice);
        swapRouter.swapExactTokensForTokens{value: 1 ether}({
            amountIn: 1 ether,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: Constants.ZERO_BYTES,
            receiver: alice,
            deadline: block.timestamp + 100
        });
        vm.stopPrank();
    }

    /* ========================================================================== */
    /*                           RECEIVE ETH TESTS                                */
    /* ========================================================================== */

    /**
     * @notice Test receive() accepts ETH from any sender.
     * @dev Simplified receive() for bytecode savings - accepts all ETH transfers.
     */
    function test_receive_acceptsFromRandom() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Should accept from any sender (bytecode optimization)");
    }

    function test_receive_acceptsFromPoolManager() public {
        vm.deal(address(poolManager), 1 ether);
        vm.prank(address(poolManager));
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Should accept from PoolManager");
    }

    function test_receive_acceptsFromLogic() public {
        address logicAddr = hook.getLogic();
        vm.deal(logicAddr, 1 ether);
        vm.prank(logicAddr);
        (bool success,) = address(hook).call{value: 1 ether}("");
        assertTrue(success, "Should accept from Logic");
    }
}
