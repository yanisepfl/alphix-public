// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Test} from "forge-std/Test.sol";

import {AlphixLVR} from "../../../src/AlphixLVR.sol";
import {BaseAlphixLVRTest} from "../BaseAlphixLVR.t.sol";

/**
 * @title AlphixLVRInvariantHandler
 * @notice Handler contract for invariant testing of AlphixLVR.
 */
contract AlphixLVRInvariantHandler is Test {
    AlphixLVR public hook;
    PoolKey public poolKey;
    address public feePoker;

    uint256 public pokeCount;
    uint24 public lastPokedFee;

    constructor(AlphixLVR _hook, PoolKey memory _poolKey, address _feePoker) {
        hook = _hook;
        poolKey = _poolKey;
        feePoker = _feePoker;
    }

    function poke(uint24 fee) external {
        fee = uint24(_bound(uint256(fee), 0, uint256(LPFeeLibrary.MAX_LP_FEE)));

        vm.prank(feePoker);
        hook.poke(poolKey, fee);

        lastPokedFee = fee;
        pokeCount++;
    }
}

/**
 * @title AlphixLVR_Invariant
 * @notice Invariant tests for AlphixLVR.
 */
contract AlphixLVR_Invariant is BaseAlphixLVRTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    AlphixLVRInvariantHandler public handler;

    function setUp() public override {
        super.setUp();
        _initializePool();

        handler = new AlphixLVRInvariantHandler(hook, poolKey, feePoker);

        // Target the handler for invariant testing
        targetContract(address(handler));
    }

    /// @dev Invariant: stored fee in hook must always match PoolManager's lpFee
    function invariant_feeInSyncWithPoolManager() public view {
        if (handler.pokeCount() == 0) return;

        uint24 storedFee = hook.getFee(poolKey.toId());
        (,,, uint24 pmFee) = poolManager.getSlot0(poolKey.toId());

        assertEq(storedFee, pmFee, "Hook fee must match PoolManager fee");
    }

    /// @dev Invariant: stored fee must always be <= MAX_LP_FEE
    function invariant_feeWithinBounds() public view {
        uint24 storedFee = hook.getFee(poolKey.toId());
        assertTrue(storedFee <= LPFeeLibrary.MAX_LP_FEE, "Fee must be <= MAX_LP_FEE");
    }

    /// @dev Invariant: last poked fee must equal current stored fee
    function invariant_lastPokeReflected() public view {
        if (handler.pokeCount() == 0) return;

        assertEq(hook.getFee(poolKey.toId()), handler.lastPokedFee(), "Stored fee must equal last poked fee");
    }
}
