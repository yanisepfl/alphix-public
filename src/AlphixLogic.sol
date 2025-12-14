// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC165Upgradeable,
    IERC165
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {BaseDynamicFee} from "./BaseDynamicFee.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "./libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "./libraries/AlphixGlobalConstants.sol";

/**
 * @title AlphixLogic.
 * @notice Upgradeable logic for Alphix Hook.
 * @dev Deployed behind an ERC1967Proxy.
 */
contract AlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable,
    ERC165Upgradeable,
    IAlphixLogic
{
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /* STORAGE */

    /**
     * @dev The global max adjustment rate value (shared to all pools).
     */
    uint256 private globalMaxAdjRate;

    /**
     * @dev The address of the Alphix Hook.
     */
    address private alphixHook;

    /**
     * @dev Store per-pool active status.
     */
    mapping(PoolId poolId => bool isActive) private poolActive;

    /**
     * @dev Store per-pool config.
     */
    mapping(PoolId poolId => PoolConfig config) private poolConfig;

    /**
     * @dev Store per-pool Out-Of-Bound state.
     */
    mapping(PoolId poolId => DynamicFeeLib.OobState state) private oobState;

    /**
     * @dev Store per-pool current target ratio.
     */
    mapping(PoolId poolId => uint256 ratio) private targetRatio;

    /**
     * @dev Store per-pool last fee update.
     */
    mapping(PoolId poolId => uint256 timestamp) private lastFeeUpdate;

    /**
     * @dev Store per-pool-type parameters.
     */
    mapping(PoolType poolType => DynamicFeeLib.PoolTypeParams params) private poolTypeParams;

    /* STORAGE GAP */

    uint256[50] private __gap;

    /* MODIFIERS */

    /**
     * @notice Enforce sender logic to be alphix hook.
     */
    modifier onlyAlphixHook() {
        _onlyAlphixHook();
        _;
    }

    /**
     * @notice Check if pool is not paused.
     */
    modifier poolActivated(PoolKey calldata key) {
        _poolActivated(key);
        _;
    }

    /**
     * @notice Check if pool has not already been configured.
     */
    modifier poolUnconfigured(PoolKey calldata key) {
        _poolUnconfigured(key);
        _;
    }

    /**
     * @notice Check if pool has already been configured.
     */
    modifier poolConfigured(PoolKey calldata key) {
        _poolConfigured(key);
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @dev The deployed logic contract cannot later be initialized.
     */
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER */

    function initialize(
        address _owner,
        address _alphixHook,
        DynamicFeeLib.PoolTypeParams memory _stableParams,
        DynamicFeeLib.PoolTypeParams memory _standardParams,
        DynamicFeeLib.PoolTypeParams memory _volatileParams
    ) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();
        __ERC165_init();

        if (_owner == address(0) || _alphixHook == address(0)) {
            revert InvalidAddress();
        }

        _transferOwnership(_owner);

        alphixHook = _alphixHook;

        // Sets the default globalMaxAdjustmentRate
        _setGlobalMaxAdjRate(AlphixGlobalConstants.TEN_WAD);

        // Initialize params for each pool type
        _setPoolTypeParams(PoolType.STABLE, _stableParams);
        _setPoolTypeParams(PoolType.STANDARD, _standardParams);
        _setPoolTypeParams(PoolType.VOLATILE, _volatileParams);
    }

    /* ERC165 SUPPORT */

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAlphixLogic).interfaceId || super.supportsInterface(interfaceId);
    }

    /* CORE HOOK LOGIC */

    /**
     * @dev See {IAlphixLogic-beforeInitialize}.
     */
    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @dev See {IAlphixLogic-afterInitialize}.
     */
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert BaseDynamicFee.NotDynamicFee();
        return BaseHook.afterInitialize.selector;
    }

    /**
     * @dev See {IAlphixLogic-beforeAddLiquidity}.
     */
    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @dev See {IAlphixLogic-beforeRemoveLiquidity}.
     */
    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    /**
     * @dev See {IAlphixLogic-afterAddLiquidity}.
     */
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev See {IAlphixLogic-afterRemoveLiquidity}.
     */
    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev See {IAlphixLogic-beforeSwap}.
     */
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev See {IAlphixLogic-afterSwap}.
     */
    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4, int128)
    {
        return (BaseHook.afterSwap.selector, 0);
    }

    /**
     * @dev See {IAlphixLogic-beforeDonate}.
     */
    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.beforeDonate.selector;
    }

    /**
     * @dev See {IAlphixLogic-afterDonate}.
     */
    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.afterDonate.selector;
    }

    /**
     * @dev See {IAlphixLogic-computeFeeUpdate}.
     * @notice Pure computation of what a poke would produce, without any state changes.
     */
    function computeFeeUpdate(PoolKey calldata key, uint256 currentRatio)
        public
        view
        override
        returns (
            uint24 newFee,
            uint24 oldFee,
            uint256 oldTargetRatio,
            uint256 newTargetRatio,
            DynamicFeeLib.OobState memory newOobState
        )
    {
        PoolId poolId = key.toId();
        PoolType poolTypeCache = poolConfig[poolId].poolType;
        DynamicFeeLib.PoolTypeParams memory pp = poolTypeParams[poolTypeCache];
        uint256 maxRatio = pp.maxCurrentRatio;

        // Check currentRatio is valid for the pool type
        if (!_isValidRatioForPoolType(poolTypeCache, currentRatio)) {
            revert InvalidRatioForPoolType(poolTypeCache, currentRatio);
        }

        // Get current fee from pool
        (,,, oldFee) = BaseDynamicFee(alphixHook).poolManager().getSlot0(poolId);

        // Load and clamp old target ratio
        oldTargetRatio = targetRatio[poolId];
        if (oldTargetRatio > maxRatio) {
            oldTargetRatio = maxRatio;
        }

        // Compute the new fee (clamped as per pool type)
        (newFee, newOobState) =
            DynamicFeeLib.computeNewFee(oldFee, currentRatio, oldTargetRatio, globalMaxAdjRate, pp, oobState[poolId]);

        // Compute new target ratio via EMA and clamp
        newTargetRatio = DynamicFeeLib.ema(currentRatio, oldTargetRatio, pp.lookbackPeriod);
        if (newTargetRatio > maxRatio) {
            newTargetRatio = maxRatio;
        }
        if (newTargetRatio == 0) {
            revert InvalidRatioForPoolType(poolTypeCache, newTargetRatio);
        }
    }

    /**
     * @dev See {IAlphixLogic-poke}.
     * @notice Encapsulates all fee computation and state update logic internally.
     *         Alphix treats this as a black box: ratio in, fee + event data out.
     */
    function poke(PoolKey calldata key, uint256 currentRatio)
        external
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        nonReentrant
        returns (uint24 newFee, uint24 oldFee, uint256 oldTargetRatio, uint256 newTargetRatio)
    {
        PoolId poolId = key.toId();

        // Revert if cooldown not elapsed
        DynamicFeeLib.PoolTypeParams memory pp = poolTypeParams[poolConfig[poolId].poolType];
        uint256 nextTs = lastFeeUpdate[poolId] + pp.minPeriod;
        if (block.timestamp < nextTs) revert CooldownNotElapsed(poolId, nextTs, pp.minPeriod);

        // Compute the fee update (view function does all the math)
        DynamicFeeLib.OobState memory newOobState;
        (newFee, oldFee, oldTargetRatio, newTargetRatio, newOobState) = computeFeeUpdate(key, currentRatio);

        // Update storage
        targetRatio[poolId] = newTargetRatio;
        oobState[poolId] = newOobState;
        lastFeeUpdate[poolId] = block.timestamp;
    }

    /* POOL MANAGEMENT */

    /**
     * @dev See {IAlphixLogic-activateAndConfigurePool}.
     */
    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        PoolType _poolType
    ) external override onlyAlphixHook poolUnconfigured(key) whenNotPaused {
        // Validate fee is within bounds for the pool type
        if (!_isValidFeeForPoolType(_poolType, _initialFee)) {
            revert InvalidFeeForPoolType(_poolType, _initialFee);
        }

        // Validate ratio is within bounds for the pool type
        if (!_isValidRatioForPoolType(_poolType, _initialTargetRatio)) {
            revert InvalidRatioForPoolType(_poolType, _initialTargetRatio);
        }

        PoolId poolId = key.toId();
        lastFeeUpdate[poolId] = block.timestamp;
        targetRatio[poolId] = _initialTargetRatio;
        poolConfig[poolId].initialFee = _initialFee;
        poolConfig[poolId].initialTargetRatio = _initialTargetRatio;
        poolConfig[poolId].poolType = _poolType;
        poolConfig[poolId].isConfigured = true;
        poolActive[poolId] = true;
    }

    /**
     * @dev See {IAlphixLogic-activatePool}.
     */
    function activatePool(PoolKey calldata key) external override onlyAlphixHook whenNotPaused poolConfigured(key) {
        PoolId poolId = key.toId();
        poolActive[poolId] = true;
    }

    /**
     * @dev See {IAlphixLogic-deactivatePool}.
     */
    function deactivatePool(PoolKey calldata key) external override onlyAlphixHook whenNotPaused {
        PoolId poolId = key.toId();
        poolActive[poolId] = false;
    }

    /**
     * @dev See {IAlphixLogic-setPoolTypeParams}.
     */
    function setPoolTypeParams(PoolType poolType, DynamicFeeLib.PoolTypeParams calldata params)
        external
        override
        onlyOwner
        whenNotPaused
    {
        _setPoolTypeParams(poolType, params);
    }

    /**
     * @dev See {IAlphixLogic-setGlobalMaxAdjRate}.
     */
    function setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) external override onlyOwner whenNotPaused {
        _setGlobalMaxAdjRate(_globalMaxAdjRate);
    }

    /* ADMIN FUNCTIONS */

    /**
     * @notice Pause the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /* GETTERS */

    /**
     * @dev See {IAlphixLogic-getAlphixHook}.
     */
    function getAlphixHook() external view override returns (address) {
        return alphixHook;
    }

    /**
     * @dev See {IAlphixLogic-getPoolConfig}.
     */
    function getPoolConfig(PoolId poolId) external view override returns (PoolConfig memory) {
        return poolConfig[poolId];
    }

    /**
     * @dev See {IAlphixLogic-getPoolTypeParams}.
     */
    function getPoolTypeParams(PoolType poolType) external view override returns (DynamicFeeLib.PoolTypeParams memory) {
        return poolTypeParams[poolType];
    }

    /**
     * @dev See {IAlphixLogic-getGlobalMaxAdjRate}.
     */
    function getGlobalMaxAdjRate() external view override returns (uint256) {
        return globalMaxAdjRate;
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Internal function to set per-pool type params.
     * @param poolType The pool type to set params to.
     * @param params The params to set.
     */
    function _setPoolTypeParams(PoolType poolType, DynamicFeeLib.PoolTypeParams memory params) internal {
        // Fee bounds checks
        if (
            params.minFee < AlphixGlobalConstants.MIN_FEE || params.minFee > params.maxFee
                || params.maxFee > LPFeeLibrary.MAX_LP_FEE
        ) {
            revert InvalidFeeBounds(params.minFee, params.maxFee);
        }

        // baseMaxFeeDelta checks
        if (params.baseMaxFeeDelta < AlphixGlobalConstants.MIN_FEE || params.baseMaxFeeDelta > LPFeeLibrary.MAX_LP_FEE)
        {
            revert InvalidParameter();
        }

        // minPeriod checks
        if (params.minPeriod < AlphixGlobalConstants.MIN_PERIOD || params.minPeriod > AlphixGlobalConstants.MAX_PERIOD)
        {
            revert InvalidParameter();
        }

        // lookbackPeriod checks
        if (
            params.lookbackPeriod < AlphixGlobalConstants.MIN_LOOKBACK_PERIOD
                || params.lookbackPeriod > AlphixGlobalConstants.MAX_LOOKBACK_PERIOD
        ) {
            revert InvalidParameter();
        }

        // ratioTolerance checks
        if (
            params.ratioTolerance < AlphixGlobalConstants.MIN_RATIO_TOLERANCE
                || params.ratioTolerance > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();

        // linearSlope checks
        if (
            params.linearSlope < AlphixGlobalConstants.MIN_LINEAR_SLOPE
                || params.linearSlope > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();

        // maxCurrentRatio checks
        if (params.maxCurrentRatio == 0 || params.maxCurrentRatio > AlphixGlobalConstants.MAX_CURRENT_RATIO) {
            revert InvalidParameter();
        }

        // side multipliers checks (min 0.1x to allow dampening, max 10x)
        if (
            params.upperSideFactor < AlphixGlobalConstants.ONE_TENTH_WAD
                || params.upperSideFactor > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();
        if (
            params.lowerSideFactor < AlphixGlobalConstants.ONE_TENTH_WAD
                || params.lowerSideFactor > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();

        poolTypeParams[poolType] = params;
        emit PoolTypeParamsUpdated(
            poolType,
            params.minFee,
            params.maxFee,
            params.baseMaxFeeDelta,
            params.lookbackPeriod,
            params.minPeriod,
            params.ratioTolerance,
            params.linearSlope,
            params.maxCurrentRatio,
            params.lowerSideFactor,
            params.upperSideFactor
        );
    }

    /**
     * @notice Internal function to set the global max adjustment rate.
     * @param _globalMaxAdjRate The global max adjustment rate to set.
     */
    function _setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) internal {
        if (_globalMaxAdjRate == 0 || _globalMaxAdjRate > AlphixGlobalConstants.MAX_ADJUSTMENT_RATE) {
            revert InvalidParameter();
        }
        emit GlobalMaxAdjRateUpdated(globalMaxAdjRate, _globalMaxAdjRate);
        globalMaxAdjRate = _globalMaxAdjRate;
    }

    /**
     * @notice Check if fee is valid for pool type.
     * @dev Internal helper function to validate fee for pool type.
     * @param poolType The pool type.
     * @param fee The fee to validate.
     * @return isValid True if fee is within bounds.
     */
    function _isValidFeeForPoolType(PoolType poolType, uint24 fee) internal view returns (bool) {
        uint24 minFeeCache = poolTypeParams[poolType].minFee;
        uint24 maxFeeCache = poolTypeParams[poolType].maxFee;
        return fee >= minFeeCache && fee <= maxFeeCache;
    }

    /**
     * @notice Check if ratio is valid for pool type.
     * @dev Internal helper function to validate ratio for pool type.
     * @param poolType The pool type.
     * @param ratio The ratio to validate.
     * @return isValid True if ratio is within bounds.
     */
    function _isValidRatioForPoolType(PoolType poolType, uint256 ratio) internal view returns (bool) {
        uint256 maxCurrentRatioCache = poolTypeParams[poolType].maxCurrentRatio;
        return ratio > 0 && ratio <= maxCurrentRatioCache;
    }

    /* MODIFIER FUNCTIONS */

    /**
     * @dev Internal function to validate caller is Alphix hook (reduces contract size)
     */
    function _onlyAlphixHook() internal view {
        if (msg.sender != alphixHook) {
            revert InvalidCaller();
        }
    }

    /**
     * @dev Internal function to validate pool is active (reduces contract size)
     */
    function _poolActivated(PoolKey calldata key) internal view {
        PoolId poolId = key.toId();
        if (!poolActive[poolId]) {
            revert PoolPaused();
        }
    }

    /**
     * @dev Internal function to validate pool is unconfigured (reduces contract size)
     */
    function _poolUnconfigured(PoolKey calldata key) internal view {
        PoolId poolId = key.toId();
        if (poolConfig[poolId].isConfigured) {
            revert PoolAlreadyConfigured();
        }
    }

    /**
     * @dev Internal function to validate pool is configured (reduces contract size)
     */
    function _poolConfigured(PoolKey calldata key) internal view {
        PoolId poolId = key.toId();
        if (!poolConfig[poolId].isConfigured) {
            revert PoolNotConfigured();
        }
    }

    /* UUPS AUTHORIZATION */

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!IERC165(newImplementation).supportsInterface(type(IAlphixLogic).interfaceId)) {
            revert InvalidLogicContract();
        }
    }
}
