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
import {AlphixLVR} from "../../src/AlphixLVR.sol";

/**
 * @title BaseAlphixLVRTest
 * @notice Base test contract for AlphixLVR hook tests.
 */
abstract contract BaseAlphixLVRTest is Test, Deployers {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    /* ---- CONSTANTS ---- */
    uint64 public constant FEE_POKER_ROLE = 1;
    uint64 public constant PAUSER_ROLE = 2;

    /* ---- STATE ---- */
    AlphixLVR public hook;
    AccessManager public accessManager;
    PoolKey public poolKey;
    Currency public currency0;
    Currency public currency1;

    address public admin = address(this);
    address public feePoker = makeAddr("feePoker");
    address public unauthorized = makeAddr("unauthorized");

    function setUp() public virtual {
        // Deploy V4 infrastructure
        deployArtifacts();

        // Deploy tokens
        (currency0, currency1) = deployCurrencyPair();

        // Deploy AccessManager
        accessManager = new AccessManager(admin);

        // Deploy AlphixLVR at correct hook address
        address hookAddr = _computeHookAddress();
        deployCodeTo("src/AlphixLVR.sol:AlphixLVR", abi.encode(poolManager, address(accessManager)), hookAddr);
        hook = AlphixLVR(hookAddr);
        vm.label(hookAddr, "AlphixLVR");

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
        bytes4 pokeSelector = AlphixLVR.poke.selector;
        accessManager.setTargetFunctionRole(address(hook), _asSingletonArray(pokeSelector), FEE_POKER_ROLE);
        accessManager.grantRole(FEE_POKER_ROLE, feePoker, 0);

        // Grant PAUSER_ROLE for pause/unpause
        bytes4[] memory pauseSelectors = new bytes4[](2);
        pauseSelectors[0] = AlphixLVR.pause.selector;
        pauseSelectors[1] = AlphixLVR.unpause.selector;
        accessManager.setTargetFunctionRole(address(hook), pauseSelectors, PAUSER_ROLE);
        accessManager.grantRole(PAUSER_ROLE, admin, 0);
    }

    function _computeHookAddress() internal pure returns (address) {
        // Only afterInitialize flag is needed (no beforeSwap/afterSwap hooks).
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG);
        // The high-bit prefix (0x8000 << 144) creates a deterministic, non-colliding
        // address for CREATE2 test mining while the low bits encode the hook permissions.
        return address(flags | uint160(0x8000) << 144);
    }

    function _asSingletonArray(bytes4 element) internal pure returns (bytes4[] memory array) {
        array = new bytes4[](1);
        array[0] = element;
    }

    function _initializePool() internal {
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));
    }

    function _initializePool(int24 tick) internal {
        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(tick));
    }
}
