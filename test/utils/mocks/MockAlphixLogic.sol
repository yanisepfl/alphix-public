// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC165Upgradeable,
    IERC165
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {BaseDynamicFee} from "../../../src/BaseDynamicFee.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "../../../src/interfaces/IAlphixLogic.sol";
import {IReHypothecation} from "../../../src/interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "../../../src/libraries/AlphixGlobalConstants.sol";

/**
 * @title MockAlphixLogic
 * @author Alphix
 * @notice Layout-compatible mock for AlphixLogic that appends a new storage var and uses it in compute paths
 * @dev Mirrors v1 storage order, appends `mockFee`, and shrinks the gap to keep alignment for UUPS upgrade tests
 *      Updated for single-pool architecture with ERC20 shares and no PoolType.
 */
contract MockAlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC165Upgradeable,
    ERC20Upgradeable,
    IAlphixLogic
{
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    /* MATCHING STORAGE (must mirror AlphixLogic order EXACTLY) */

    // 1. Global cap for adjustment rate
    uint256 private _globalMaxAdjRate;

    // 2. Alphix Hook address
    address private _alphixHook;

    // 3. Pool key (single pool)
    PoolKey private _poolKey;

    // 4. Pool activated flag
    bool private _poolActivated;

    // 5. Pool config (single pool - no poolType)
    PoolConfig private _poolConfig;

    // 6. OOB state (single pool)
    DynamicFeeLib.OobState private _oobState;

    // 7. Target ratio (single pool)
    uint256 private _targetRatio;

    // 8. Last fee update timestamp (single pool)
    uint256 private _lastFeeUpdate;

    // 9. Pool ID (cached)
    PoolId private _poolId;

    // 10. Pool params (single pool - replaces per-type mapping)
    DynamicFeeLib.PoolParams private _poolParams;

    // 11. ReHypothecation config (single pool)
    IReHypothecation.ReHypothecationConfig private _reHypothecationConfig;

    // 12. Yield source state (single pool)
    mapping(Currency => IReHypothecation.YieldSourceState) private _yieldSourceState;

    // 13. Yield treasury
    address private _yieldTreasury;

    /* NEW APPENDED STORAGE (v2) */
    uint24 private mockFee;

    /* GAP SHRUNK BY ONE SLOT (from 50 to 49) to account for mockFee */
    uint256[49] private _gap;

    /* MODIFIERS */

    modifier onlyAlphixHook() {
        if (msg.sender != _alphixHook) revert InvalidCaller();
        _;
    }

    modifier poolActivated() {
        if (!_poolActivated || !_poolConfig.isConfigured) revert PoolPaused();
        _;
    }

    modifier poolActivatedKey(PoolKey calldata key) {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolId)) revert PoolNotConfigured();
        if (!_poolActivated || !_poolConfig.isConfigured) revert PoolPaused();
        _;
    }

    modifier poolUnconfigured() {
        if (_poolConfig.isConfigured) revert PoolAlreadyConfigured();
        _;
    }

    modifier poolConfigured() {
        if (!_poolConfig.isConfigured) revert PoolNotConfigured();
        _;
    }

    /* CONSTRUCTOR */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER (aligned with current logic - no PoolType params) */

    /**
     * @notice Initialize the logic with owner, hook, accessManager
     * @dev Pool params are now passed at activateAndConfigurePool, not at initialization
     */
    function initialize(
        address owner_,
        address alphixHook_,
        address accessManager_,
        string memory name_,
        string memory symbol_
    ) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC165_init();
        __ERC20_init(name_, symbol_);

        if (owner_ == address(0) || alphixHook_ == address(0) || accessManager_ == address(0)) revert InvalidAddress();

        _transferOwnership(owner_);
        _alphixHook = alphixHook_;

        // Set default global cap (same as logic)
        _setGlobalMaxAdjRate(AlphixGlobalConstants.TEN_WAD);
    }

    /* ERC165 */

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAlphixLogic).interfaceId || super.supportsInterface(interfaceId);
    }

    /* CORE HOOK LOGIC (stubs) */

    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        // Reject if pool already initialized
        if (_poolActivated) revert PoolAlreadyConfigured();
        // Reject ETH pools (mock only supports ERC20)
        if (Currency.unwrap(key.currency0) == address(0)) revert IReHypothecation.UnsupportedNativeCurrency();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert BaseDynamicFee.NotDynamicFee();
        // Store the pool key
        _poolKey = key;
        _poolActivated = true;
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivatedKey(key)
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
        poolActivatedKey(key)
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
    ) external view override onlyAlphixHook poolActivatedKey(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivatedKey(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivatedKey(key)
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24, JitParams memory jitParams)
    {
        jitParams = JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0, jitParams);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivatedKey(key)
        whenNotPaused
        returns (bytes4, int128, JitParams memory jitParams)
    {
        jitParams = JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        return (this.afterSwap.selector, 0, jitParams);
    }

    function beforeDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivatedKey(key)
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata key, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivatedKey(key)
        whenNotPaused
        returns (bytes4)
    {
        return this.afterDonate.selector;
    }

    /* FEE POKE */

    /**
     * @notice Compute what a poke would produce without any state changes (mock implementation).
     * @dev Simple mock: if mockFee is set, use it; otherwise keep current fee.
     */
    function computeFeeUpdate(uint256 currentRatio)
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
        // Check currentRatio is valid
        if (!_isValidRatio(currentRatio)) {
            revert InvalidRatio(currentRatio);
        }

        // Read current fee from PoolManager (use cached _poolId)
        (,,, oldFee) = BaseDynamicFee(_alphixHook).poolManager().getSlot0(_poolId);

        // If mockFee is set, prefer it (clamped to bounds); otherwise keep current fee
        uint24 mf = mockFee;
        if (mf == 0) {
            newFee = oldFee;
        } else {
            newFee = DynamicFeeLib.clampFee(uint256(mf), _poolParams.minFee, _poolParams.maxFee);
        }

        // Load and clamp old target ratio
        oldTargetRatio = _targetRatio;
        if (oldTargetRatio > _poolParams.maxCurrentRatio) {
            oldTargetRatio = _poolParams.maxCurrentRatio;
        }

        // For mock, keep target ratio unchanged (no-op EMA)
        newTargetRatio = oldTargetRatio;

        // Return empty OobState for mock
        newOobState = DynamicFeeLib.OobState(false, 0);
    }

    /**
     * @notice Compute and apply a fee update for a pool (mock implementation).
     * @dev Uses computeFeeUpdate for calculation, then updates storage.
     */
    function poke(uint256 currentRatio)
        external
        override
        onlyAlphixHook
        poolActivated
        whenNotPaused
        nonReentrant
        returns (uint24 newFee, uint24 oldFee, uint256 oldTargetRatio, uint256 newTargetRatio)
    {
        // Check cooldown
        uint256 nextTs = _lastFeeUpdate + _poolParams.minPeriod;
        if (block.timestamp < nextTs) revert CooldownNotElapsed(_poolId, nextTs, _poolParams.minPeriod);

        // Compute the fee update (view function does all the math)
        DynamicFeeLib.OobState memory newOobState;
        (newFee, oldFee, oldTargetRatio, newTargetRatio, newOobState) = computeFeeUpdate(currentRatio);

        // Update storage (matching production behavior)
        _targetRatio = newTargetRatio;
        _oobState = newOobState;
        _lastFeeUpdate = block.timestamp;
    }

    /* POOL MANAGEMENT */

    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        DynamicFeeLib.PoolParams calldata poolParams_
    ) external override onlyAlphixHook poolUnconfigured whenNotPaused {
        // Verify this is the same pool that was initialized
        if (!_poolActivated) revert PoolNotConfigured();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolKey.toId())) revert PoolNotConfigured();

        // Set pool params first
        _setPoolParams(poolParams_);

        // Cache pool ID
        _poolId = key.toId();

        // Validate fee is within bounds
        if (!_isValidFee(_initialFee)) {
            revert InvalidFee(_initialFee);
        }

        // Validate ratio is within bounds
        if (!_isValidRatio(_initialTargetRatio)) {
            revert InvalidRatio(_initialTargetRatio);
        }

        _lastFeeUpdate = block.timestamp;
        _targetRatio = _initialTargetRatio;
        _poolConfig.initialFee = _initialFee;
        _poolConfig.initialTargetRatio = _initialTargetRatio;
        _poolConfig.isConfigured = true;
    }

    function activatePool() external override onlyAlphixHook whenNotPaused poolConfigured {
        // No-op for single pool (already active if configured)
    }

    function deactivatePool() external override onlyAlphixHook whenNotPaused {
        _poolConfig.isConfigured = false;
    }

    function setPoolParams(DynamicFeeLib.PoolParams calldata params) external override onlyOwner whenNotPaused {
        _setPoolParams(params);
    }

    /* GLOBAL PARAMS */

    function setGlobalMaxAdjRate(uint256 newMaxAdjRate) external override onlyOwner whenNotPaused {
        _setGlobalMaxAdjRate(newMaxAdjRate);
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
        return _alphixHook;
    }

    function getPoolKey() external view override returns (PoolKey memory) {
        return _poolKey;
    }

    function getPoolId() external view override returns (PoolId) {
        return _poolId;
    }

    function isPoolActivated() external view override returns (bool) {
        return _poolActivated;
    }

    function getPoolConfig() external view override returns (PoolConfig memory) {
        return _poolConfig;
    }

    function getPoolParams() external view override returns (DynamicFeeLib.PoolParams memory) {
        return _poolParams;
    }

    function getGlobalMaxAdjRate() external view override returns (uint256) {
        return _globalMaxAdjRate;
    }

    /* INTERNAL */

    function _setPoolParams(DynamicFeeLib.PoolParams memory params) internal {
        // Fee bounds
        if (
            params.minFee < AlphixGlobalConstants.MIN_FEE || params.minFee > params.maxFee
                || params.maxFee > LPFeeLibrary.MAX_LP_FEE
        ) {
            revert InvalidFeeBounds(params.minFee, params.maxFee);
        }
        // baseMaxFeeDelta
        if (params.baseMaxFeeDelta < AlphixGlobalConstants.MIN_FEE || params.baseMaxFeeDelta > LPFeeLibrary.MAX_LP_FEE)
        {
            revert InvalidParameter();
        }
        // minPeriod
        if (params.minPeriod < AlphixGlobalConstants.MIN_PERIOD || params.minPeriod > AlphixGlobalConstants.MAX_PERIOD)
        {
            revert InvalidParameter();
        }
        // lookbackPeriod
        if (
            params.lookbackPeriod < AlphixGlobalConstants.MIN_LOOKBACK_PERIOD
                || params.lookbackPeriod > AlphixGlobalConstants.MAX_LOOKBACK_PERIOD
        ) {
            revert InvalidParameter();
        }
        // ratioTolerance
        if (
            params.ratioTolerance < AlphixGlobalConstants.MIN_RATIO_TOLERANCE
                || params.ratioTolerance > AlphixGlobalConstants.TEN_WAD
        ) {
            revert InvalidParameter();
        }
        // linearSlope
        if (
            params.linearSlope < AlphixGlobalConstants.MIN_LINEAR_SLOPE
                || params.linearSlope > AlphixGlobalConstants.TEN_WAD
        ) {
            revert InvalidParameter();
        }
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

        _poolParams = params;
        emit PoolParamsUpdated(
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

    function _setGlobalMaxAdjRate(uint256 _globalMaxAdjRate_) internal {
        if (_globalMaxAdjRate_ == 0 || _globalMaxAdjRate_ > AlphixGlobalConstants.MAX_ADJUSTMENT_RATE) {
            revert InvalidParameter();
        }
        uint256 old = _globalMaxAdjRate;
        _globalMaxAdjRate = _globalMaxAdjRate_;
        emit GlobalMaxAdjRateUpdated(old, _globalMaxAdjRate);
    }

    /**
     * @dev Internal helper function to validate fee.
     */
    function _isValidFee(uint24 fee) internal view returns (bool) {
        return fee >= _poolParams.minFee && fee <= _poolParams.maxFee;
    }

    /**
     * @notice Check if ratio is valid.
     * @dev Internal helper function to validate ratio.
     * @param ratio The ratio to validate.
     * @return isValid True if ratio is within bounds.
     */
    function _isValidRatio(uint256 ratio) internal view returns (bool) {
        return ratio > 0 && ratio <= _poolParams.maxCurrentRatio;
    }

    /* UUPS AUTHORIZATION */

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!IERC165(newImplementation).supportsInterface(type(IAlphixLogic).interfaceId)) {
            revert InvalidLogicContract();
        }
    }

    /* JIT LIQUIDITY (Flash Accounting Pattern - stubs) */

    /**
     * @notice Deposit tokens to yield source (stub).
     * @dev Mock implementation does nothing.
     */
    function depositToYieldSource(Currency, uint256) external override {}

    /**
     * @notice Withdraw and approve for settlement (stub).
     * @dev Mock implementation does nothing.
     */
    function withdrawAndApprove(Currency, uint256) external override {}

    /* MOCK API */

    /**
     * @notice Reinitializer for mock-only fee override
     * @dev Allows setting a mock fee post-deploy without changing v1 storage
     */
    function initializeV2(uint24 _mockFee) public reinitializer(2) {
        mockFee = _mockFee;
    }
}
