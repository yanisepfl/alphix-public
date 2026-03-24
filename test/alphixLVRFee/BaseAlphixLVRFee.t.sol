// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* FORGE IMPORTS */
import {Test} from "forge-std/Test.sol";

/* UNISWAP V4 IMPORTS */
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* OZ IMPORTS */
import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

/* LOCAL IMPORTS */
import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {Deployers} from "../utils/Deployers.sol";
import {AlphixLVRFee} from "../../src/AlphixLVRFee.sol";

/**
 * @title BaseAlphixLVRFeeTest
 * @notice Base test contract for AlphixLVRFee hook tests.
 */
abstract contract BaseAlphixLVRFeeTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /* ---- CONSTANTS ---- */
    uint64 public constant FEE_POKER_ROLE = 1;
    uint64 public constant PAUSER_ROLE = 2;
    uint64 public constant HOOK_FEE_ROLE = 3;

    /* ---- STATE ---- */
    AlphixLVRFee public hook;
    AccessManager public accessManager;
    PoolKey public poolKey;
    Currency public currency0;
    Currency public currency1;

    address public admin = address(this);
    address public feePoker = makeAddr("feePoker");
    address public treasury = makeAddr("treasury");
    address public unauthorized = makeAddr("unauthorized");

    function setUp() public virtual {
        // Deploy V4 infrastructure
        deployArtifacts();

        // Deploy tokens
        (currency0, currency1) = deployCurrencyPair();

        // Deploy AccessManager
        accessManager = new AccessManager(admin);

        // Deploy AlphixLVRFee at correct hook address
        address hookAddr = _computeHookAddress();
        deployCodeTo(
            "src/AlphixLVRFee.sol:AlphixLVRFee",
            abi.encode(poolManager, address(accessManager), treasury),
            hookAddr
        );
        hook = AlphixLVRFee(hookAddr);
        vm.label(hookAddr, "AlphixLVRFee");

        // Configure roles
        _configureRoles();

        // Create pool key with dynamic fee
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
    }

    function _configureRoles() internal {
        // Grant FEE_POKER_ROLE to feePoker for poke()
        bytes4[] memory pokeSelectors = new bytes4[](1);
        pokeSelectors[0] = AlphixLVRFee.poke.selector;
        accessManager.setTargetFunctionRole(address(hook), pokeSelectors, FEE_POKER_ROLE);
        accessManager.grantRole(FEE_POKER_ROLE, feePoker, 0);

        // Grant HOOK_FEE_ROLE to admin for setHookFee() and setTreasury()
        bytes4[] memory hookFeeSelectors = new bytes4[](2);
        hookFeeSelectors[0] = AlphixLVRFee.setHookFee.selector;
        hookFeeSelectors[1] = AlphixLVRFee.setTreasury.selector;
        accessManager.setTargetFunctionRole(address(hook), hookFeeSelectors, HOOK_FEE_ROLE);
        accessManager.grantRole(HOOK_FEE_ROLE, admin, 0);

        // Grant PAUSER_ROLE for pause/unpause
        bytes4[] memory pauseSelectors = new bytes4[](2);
        pauseSelectors[0] = AlphixLVRFee.pause.selector;
        pauseSelectors[1] = AlphixLVRFee.unpause.selector;
        accessManager.setTargetFunctionRole(address(hook), pauseSelectors, PAUSER_ROLE);
        accessManager.grantRole(PAUSER_ROLE, admin, 0);
    }

    function _computeHookAddress() internal pure returns (address) {
        // afterInitialize (BaseDynamicFee) + afterSwap + afterSwapReturnDelta (BaseHookFee)
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG) | uint160(Hooks.AFTER_SWAP_FLAG) | uint160(Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);
        // High-bit prefix for deterministic test address mining
        return address(flags | uint160(0x8000) << 144);
    }

    function _initializePool() internal {
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
    }
}
