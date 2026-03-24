// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {EasyPosm} from "../../../utils/libraries/EasyPosm.sol";
import {AlphixLVRFee} from "../../../../src/AlphixLVRFee.sol";
import {IAlphixLVRFee} from "../../../../src/interfaces/IAlphixLVRFee.sol";
import {BaseAlphixLVRFeeTest} from "../../BaseAlphixLVRFee.t.sol";

/**
 * @title AlphixLVRFee_HookFee
 * @notice Integration tests verifying hook fee capture during swaps.
 */
contract AlphixLVRFee_HookFee is BaseAlphixLVRFeeTest {
    using PoolIdLibrary for *;
    using StateLibrary for IPoolManager;
    using EasyPosm for IPositionManager;

    int24 constant TICK_LOWER = -120;
    int24 constant TICK_UPPER = 120;
    uint128 constant LIQUIDITY = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        _initializePool();
        _seedLiquidity();
    }

    function _seedLiquidity() internal {
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            TickMath.getSqrtPriceAtTick(0),
            TickMath.getSqrtPriceAtTick(TICK_LOWER),
            TickMath.getSqrtPriceAtTick(TICK_UPPER),
            LIQUIDITY
        );

        MockERC20(Currency.unwrap(currency0)).approve(address(permit2), amount0 + 1);
        MockERC20(Currency.unwrap(currency1)).approve(address(permit2), amount1 + 1);
        uint48 expiry = uint48(block.timestamp + 100);
        permit2.approve(Currency.unwrap(currency0), address(positionManager), uint160(amount0 + 1), expiry);
        permit2.approve(Currency.unwrap(currency1), address(positionManager), uint160(amount1 + 1), expiry);

        positionManager.mint(
            poolKey, TICK_LOWER, TICK_UPPER, LIQUIDITY, amount0 + 1, amount1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES
        );
    }

    function _performSwap(uint256 amount, bool zeroForOne) internal {
        Currency inputCurrency = zeroForOne ? currency0 : currency1;
        MockERC20(Currency.unwrap(inputCurrency)).approve(address(swapRouter), amount);

        swapRouter.swapExactTokensForTokens({
            amountIn: amount,
            amountOutMin: 0,
            zeroForOne: zeroForOne,
            poolKey: poolKey,
            hookData: Constants.ZERO_BYTES,
            receiver: address(this),
            deadline: block.timestamp + 100
        });
    }

    function test_hookFeeZero_noFeeTaken() public {
        // hookFee defaults to 0 — swap should produce same output
        vm.prank(feePoker);
        hook.poke(poolKey, 3000); // 0.3% LP fee

        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(received > 0, "Should receive output with no hook fee");

        // No ERC-6909 claims should be held by hook
        uint256 hookClaims = poolManager.balanceOf(address(hook), currency1.toId());
        assertEq(hookClaims, 0, "No claims should be minted when hookFee=0");
    }

    function test_hookFeeApplied_feeDeducted() public {
        vm.prank(feePoker);
        hook.poke(poolKey, 3000); // 0.3% LP fee

        // Set 5% hook fee
        hook.setHookFee(poolKey, 50_000);

        // Snapshot to compare
        uint256 snapshotId = vm.snapshot();

        // Swap with hook fee
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 receivedWithFee = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;

        // Check hook has ERC-6909 claims
        uint256 hookClaims = poolManager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookClaims > 0, "Hook should hold ERC-6909 claims");

        // Revert and swap without hook fee for comparison
        vm.revertTo(snapshotId);
        hook.setHookFee(poolKey, 0);

        vm.prank(feePoker);
        hook.poke(poolKey, 3000);

        balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(1e18, true);
        uint256 receivedNoFee = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;

        // With hook fee, user should receive less
        assertTrue(receivedWithFee < receivedNoFee, "Hook fee should reduce output");
    }

    function test_hookFeeChangeMidSession() public {
        vm.prank(feePoker);
        hook.poke(poolKey, 3000);

        // Start with no hook fee
        _performSwap(0.1e18, true);

        // Set hook fee
        hook.setHookFee(poolKey, 100_000); // 10%

        // Swap still works
        uint256 balBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this));
        _performSwap(0.1e18, true);
        uint256 received = MockERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balBefore;
        assertTrue(received > 0, "Swap should work after hook fee change");

        // Hook should have claims
        uint256 hookClaims = poolManager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookClaims > 0, "Hook should hold claims after fee swap");
    }

    function test_handleHookFees_transfersToTreasury() public {
        vm.prank(feePoker);
        hook.poke(poolKey, 3000);
        hook.setHookFee(poolKey, 50_000); // 5%

        // Execute swap to accumulate fees
        _performSwap(1e18, true);

        uint256 hookClaims = poolManager.balanceOf(address(hook), currency1.toId());
        assertTrue(hookClaims > 0, "Should have claims");

        uint256 treasuryBalBefore = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);

        // Collect fees — handleHookFees internally calls poolManager.unlock()
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = currency1;
        hook.handleHookFees(currencies);

        uint256 treasuryBalAfter = MockERC20(Currency.unwrap(currency1)).balanceOf(treasury);
        assertTrue(treasuryBalAfter > treasuryBalBefore, "Treasury should receive tokens");

        // Hook claims should be 0 after collection
        uint256 hookClaimsAfter = poolManager.balanceOf(address(hook), currency1.toId());
        assertEq(hookClaimsAfter, 0, "Claims should be burned");
    }

    function test_setHookFee_emitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit IAlphixLVRFee.HookFeeSet(poolKey.toId(), 25_000);

        hook.setHookFee(poolKey, 25_000);
    }

    function test_setHookFee_unauthorized_reverts() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        hook.setHookFee(poolKey, 10_000);
    }

    function test_getHookFee_returnsStoredValue() public {
        hook.setHookFee(poolKey, 75_000);
        assertEq(hook.getHookFee(poolKey.toId()), 75_000);
    }

    function test_multiPool_independentHookFees() public {
        // Pool 2
        (Currency c2, Currency c3) = deployCurrencyPair();
        PoolKey memory key2 = PoolKey({
            currency0: c2,
            currency1: c3,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 10,
            hooks: hook
        });
        poolManager.initialize(key2, TickMath.getSqrtPriceAtTick(0));

        // Set different hook fees
        hook.setHookFee(poolKey, 10_000); // 1%
        hook.setHookFee(key2, 50_000); // 5%

        assertEq(hook.getHookFee(poolKey.toId()), 10_000);
        assertEq(hook.getHookFee(key2.toId()), 50_000);
    }
}
