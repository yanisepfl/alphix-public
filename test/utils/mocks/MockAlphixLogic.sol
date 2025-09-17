// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC165Upgradeable, IERC165
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "../../../src/interfaces/IAlphixLogic.sol";

/**
 * @title MockAlphixLogic
 * @author Alphix
 * @notice Layout-compatible mock that appends a new storage var and uses it in getFee
 * @dev Appends `mockFee` after all original storage and shrinks the gap to keep alignment
 */
contract MockAlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC165Upgradeable,
    IAlphixLogic
{
    using LPFeeLibrary for uint24;

    /* MATCHING STORAGE */

    // Original 1
    address private alphixHook;

    // Original 2
    uint24 private baseFee;

    // Original 3
    mapping(PoolId => bool) private poolActive;

    // Original 4
    mapping(PoolId => PoolConfig) private poolConfig;

    // Original 5
    mapping(PoolType => PoolTypeBounds) private poolTypeBounds;

    // NEW APPENDED STORAGE (v2)
    // Appended after all original storage; consumes part of one slot
    uint24 private mockFee;

    // GAP SHRUNK BY ONE SLOT (from 50 to 49)
    uint256[49] private __gap;

    /* MODIFIERS */

    modifier onlyAlphixHook() {
        if (msg.sender != alphixHook) revert InvalidCaller();
        _;
    }

    modifier poolActivated(PoolKey calldata key) {
        PoolId id = key.toId();
        if (!poolActive[id]) revert PoolPaused();
        _;
    }

    modifier poolUnconfigured(PoolKey calldata key) {
        PoolId id = key.toId();
        if (poolConfig[id].isConfigured) revert PoolAlreadyConfigured();
        _;
    }

    modifier poolConfigured(PoolKey calldata key) {
        PoolId id = key.toId();
        if (!poolConfig[id].isConfigured) revert PoolNotConfigured();
        _;
    }

    /* CONSTRUCTOR */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER (same signature as v1) */

    function initialize(
        address _owner,
        address _alphixHook,
        uint24 _baseFee,
        PoolTypeBounds memory _stableBounds,
        PoolTypeBounds memory _standardBounds,
        PoolTypeBounds memory _volatileBounds
    ) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC165_init();

        if (_owner == address(0) || _alphixHook == address(0)) revert InvalidAddress();

        _transferOwnership(_owner);
        alphixHook = _alphixHook;
        baseFee = _baseFee;

        _setPoolTypeBounds(PoolType.STABLE, _stableBounds);
        _setPoolTypeBounds(PoolType.STANDARD, _standardBounds);
        _setPoolTypeBounds(PoolType.VOLATILE, _volatileBounds);
    }

    /* NEW REINITIALIZER (v2) */

    function initializeV2(uint24 _mockFee) public reinitializer(2) {
        // Set appended storage in a dedicated reinitializer
        mockFee = _mockFee;
    }

    /* ERC165 */

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAlphixLogic).interfaceId || super.supportsInterface(interfaceId);
    }

    /* CORE HOOK LOGIC (stubbed to satisfy interface) */

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    /* POOL MANAGEMENT */

    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        PoolType _poolType
    ) external override onlyAlphixHook poolUnconfigured(key) whenNotPaused {
        PoolId id = key.toId();
        poolConfig[id].initialFee = _initialFee;
        poolConfig[id].initialTargetRatio = _initialTargetRatio;
        poolConfig[id].poolType = _poolType;
        poolConfig[id].isConfigured = true;
        poolActive[id] = true;
    }

    function activatePool(PoolKey calldata key) external override onlyAlphixHook whenNotPaused poolConfigured(key) {
        poolActive[key.toId()] = true;
    }

    function deactivatePool(PoolKey calldata key) external override onlyAlphixHook whenNotPaused {
        poolActive[key.toId()] = false;
    }

    function setPoolTypeBounds(PoolType poolType, PoolTypeBounds calldata bounds)
        external
        override
        onlyAlphixHook
        whenNotPaused
    {
        _setPoolTypeBounds(poolType, bounds);
    }

    function isValidFeeForPoolType(PoolType poolType, uint24 fee)
        external
        view
        override
        onlyAlphixHook
        returns (bool)
    {
        PoolTypeBounds memory b = poolTypeBounds[poolType];
        return fee >= b.minFee && fee <= b.maxFee;
    }

    /* ADMIN */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* GETTERS */

    function getAlphixHook() external view override returns (address) {
        return alphixHook;
    }

    // Use appended storage if set, otherwise preserve pre-upgrade observable behavior (3000)
    function getFee(PoolKey calldata) external view override returns (uint24) {
        uint24 f = mockFee;
        return f == 0 ? 3000 : f;
    }

    function getPoolConfig(PoolId id) external view override returns (PoolConfig memory) {
        return poolConfig[id];
    }

    function getPoolTypeBounds(PoolType poolType) external view override returns (PoolTypeBounds memory) {
        return poolTypeBounds[poolType];
    }

    /* INTERNAL */

    function _setPoolTypeBounds(PoolType poolType, PoolTypeBounds memory bounds) internal {
        if (bounds.minFee > bounds.maxFee || bounds.maxFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFeeBounds(bounds.minFee, bounds.maxFee);
        }
        poolTypeBounds[poolType] = bounds;
        emit PoolTypeBoundsUpdated(poolType, bounds.minFee, bounds.maxFee);
    }

    /* UUPS AUTHORIZATION */

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!IERC165(newImplementation).supportsInterface(type(IAlphixLogic).interfaceId)) {
            revert InvalidLogicContract();
        }
    }
}
