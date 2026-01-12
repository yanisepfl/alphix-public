// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC165Upgradeable,
    IERC165
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/* UNISWAP V4 IMPORTS */
import {BaseDynamicFee} from "./BaseDynamicFee.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "v4-core/src/libraries/Position.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "./interfaces/IAlphixLogic.sol";
import {IReHypothecation} from "./interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "./libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "./libraries/AlphixGlobalConstants.sol";
import {ReHypothecationLib} from "./libraries/ReHypothecation.sol";

/**
 * @title AlphixLogic.
 * @notice Upgradeable logic for Alphix Hook - ERC20-only pools (no native ETH).
 * @dev Deployed behind an ERC1967Proxy. Each instance serves exactly one pool.
 *      Shares are ERC20 tokens (inherits ERC20Upgradeable).
 *      For ETH pools, use AlphixLogicETH instead.
 */
contract AlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    AccessManagedUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    PausableUpgradeable,
    ERC165Upgradeable,
    ERC20Upgradeable,
    IAlphixLogic,
    IReHypothecation
{
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /* STORAGE */

    /**
     * @dev The global max adjustment rate value.
     */
    uint256 internal _globalMaxAdjRate;

    /**
     * @dev The address of the Alphix Hook.
     */
    address internal _alphixHook;

    /**
     * @dev The pool key this contract serves (single pool per instance).
     */
    PoolKey internal _poolKey;

    /**
     * @dev Whether the pool has been activated.
     */
    bool internal _poolActivated;

    /**
     * @dev Pool configuration.
     */
    PoolConfig internal _poolConfig;

    /**
     * @dev Out-Of-Bound state.
     */
    DynamicFeeLib.OobState internal _oobState;

    /**
     * @dev Current target ratio.
     */
    uint256 internal _targetRatio;

    /**
     * @dev Last fee update timestamp.
     */
    uint256 internal _lastFeeUpdate;

    /**
     * @dev The cached pool ID (computed once at activation).
     */
    PoolId internal _poolId;

    /**
     * @dev Pool parameters for dynamic fee algorithm.
     */
    DynamicFeeLib.PoolParams internal _poolParams;

    /* REHYPOTHECATION STORAGE */

    /**
     * @dev Rehypothecation configuration (tick ranges and tax).
     */
    ReHypothecationConfig internal _reHypothecationConfig;

    /**
     * @dev Per-currency yield source state.
     */
    mapping(Currency currency => YieldSourceState state) internal _yieldSourceState;

    /**
     * @dev Address of the yield treasury for tax collection.
     */
    address internal _yieldTreasury;

    /* STORAGE GAP */

    uint256[50] internal _gap;

    /* MODIFIERS */

    /**
     * @notice Enforce sender logic to be alphix hook.
     */
    modifier onlyAlphixHook() {
        _onlyAlphixHook();
        _;
    }

    /**
     * @notice Check if pool is active.
     */
    modifier poolActivated() {
        _requirePoolActivated();
        _;
    }

    /**
     * @notice Check if pool has not already been configured.
     */
    modifier poolUnconfigured() {
        _poolUnconfigured();
        _;
    }

    /**
     * @notice Check if pool has already been configured.
     */
    modifier poolConfigured() {
        _poolConfigured();
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
        address owner_,
        address alphixHook_,
        address accessManager_,
        string memory name_,
        string memory symbol_
    ) public virtual initializer {
        _initializeCommon(owner_, alphixHook_, accessManager_, name_, symbol_);
    }

    /* ERC165 SUPPORT */

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAlphixLogic).interfaceId || interfaceId == type(IReHypothecation).interfaceId
            || interfaceId == type(IERC20).interfaceId || super.supportsInterface(interfaceId);
    }

    /* CORE HOOK LOGIC */

    /**
     * @dev See {IAlphixLogic-beforeInitialize}.
     */
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        view
        virtual
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        // Reject ETH pools - use AlphixLogicETH for those
        if (key.currency0.isAddressZero()) revert UnsupportedNativeCurrency();
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
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.beforeAddLiquidity.selector;
    }

    /**
     * @dev See {IAlphixLogic-beforeRemoveLiquidity}.
     */
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated
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
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated whenNotPaused returns (bytes4, BalanceDelta) {
        return (BaseHook.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev See {IAlphixLogic-afterRemoveLiquidity}.
     */
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated whenNotPaused returns (bytes4, BalanceDelta) {
        return (BaseHook.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /**
     * @dev See {IAlphixLogic-beforeSwap}.
     * @notice Returns JIT liquidity parameters for adding liquidity before the swap.
     */
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        override
        onlyAlphixHook
        poolActivated
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24, JitParams memory jitParams)
    {
        // Accumulate yield tax before computing JIT to ensure latest yield is taxed
        _accumulateYieldTax(_poolKey.currency0);
        _accumulateYieldTax(_poolKey.currency1);
        // compute before swap JIT params
        jitParams = _computeBeforeSwapJit();
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0, jitParams);
    }

    /**
     * @dev See {IAlphixLogic-afterSwap}.
     * @notice Returns JIT liquidity parameters for removing liquidity after the swap.
     */
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated
        whenNotPaused
        returns (bytes4, int128, JitParams memory jitParams)
    {
        jitParams = _computeAfterSwapJit();
        return (BaseHook.afterSwap.selector, 0, jitParams);
    }

    /**
     * @dev See {IAlphixLogic-depositToYieldSource}.
     * @notice Called by hook when it has positive currencyDelta (is owed tokens).
     *         Tokens have already been transferred to this contract by PoolManager.
     *         Gracefully returns if no yield source configured (for JIT flow).
     */
    function depositToYieldSource(Currency currency, uint256 amount)
        external
        virtual
        override
        onlyAlphixHook
        nonReentrant
    {
        if (amount == 0) return;
        if (_yieldSourceState[currency].yieldSource == address(0)) return;
        _depositToYieldSource(currency, amount);
    }

    /**
     * @dev See {IAlphixLogic-withdrawAndApprove}.
     * @notice Called by hook when it has negative currencyDelta (owes tokens).
     *         Withdraws from yield source and approves Hook for settlement.
     *         The Hook then calls CurrencySettler.settle which does transferFrom(Logic, PoolManager).
     *         Gracefully returns if no yield source configured (for JIT flow).
     */
    function withdrawAndApprove(Currency currency, uint256 amount)
        external
        virtual
        override
        onlyAlphixHook
        nonReentrant
    {
        if (amount == 0) return;
        if (_yieldSourceState[currency].yieldSource == address(0)) return;

        _withdrawFromYieldSourceTo(currency, amount, address(this));

        // Approve Hook to pull tokens during settle (Hook calls transferFrom as msg.sender)
        IERC20(Currency.unwrap(currency)).forceApprove(_alphixHook, amount);
    }

    /**
     * @dev See {IAlphixLogic-beforeDonate}.
     */
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.beforeDonate.selector;
    }

    /**
     * @dev See {IAlphixLogic-afterDonate}.
     */
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated
        whenNotPaused
        returns (bytes4)
    {
        return BaseHook.afterDonate.selector;
    }

    /**
     * @dev See {IAlphixLogic-computeFeeUpdate}.
     * @notice View function of what a poke would produce, without any state changes.
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
        DynamicFeeLib.PoolParams memory pp = _poolParams;

        // Check currentRatio is valid
        if (!_isValidRatio(currentRatio)) {
            revert InvalidRatio(currentRatio);
        }

        // Get current fee from pool (use cached _poolId)
        (,,, oldFee) = BaseDynamicFee(_alphixHook).poolManager().getSlot0(_poolId);

        uint256 maxCurrentRatioCache = pp.maxCurrentRatio;
        // Load and clamp old target ratio
        oldTargetRatio = _targetRatio;
        if (oldTargetRatio > maxCurrentRatioCache) {
            oldTargetRatio = maxCurrentRatioCache;
        }

        // Compute the new fee (clamped as per pool params)
        (newFee, newOobState) =
            DynamicFeeLib.computeNewFee(oldFee, currentRatio, oldTargetRatio, _globalMaxAdjRate, pp, _oobState);

        // Compute new target ratio via EMA and clamp
        newTargetRatio = DynamicFeeLib.ema(currentRatio, oldTargetRatio, pp.lookbackPeriod);
        if (newTargetRatio > maxCurrentRatioCache) {
            newTargetRatio = maxCurrentRatioCache;
        }
        if (newTargetRatio == 0) {
            revert InvalidRatio(newTargetRatio);
        }
    }

    /**
     * @dev See {IAlphixLogic-poke}.
     * @notice Encapsulates all fee computation and state update logic internally.
     *         Alphix treats this as a black box: ratio in, fee + event data out.
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
        // Revert if cooldown not elapsed
        uint256 nextTs = _lastFeeUpdate + _poolParams.minPeriod;
        if (block.timestamp < nextTs) revert CooldownNotElapsed(_poolId, nextTs, _poolParams.minPeriod);

        // Compute the fee update (view function does all the math)
        DynamicFeeLib.OobState memory newOobState;
        (newFee, oldFee, oldTargetRatio, newTargetRatio, newOobState) = computeFeeUpdate(currentRatio);

        // Update storage
        _targetRatio = newTargetRatio;
        _oobState = newOobState;
        _lastFeeUpdate = block.timestamp;
    }

    /* POOL MANAGEMENT */

    /**
     * @dev See {IAlphixLogic-activateAndConfigurePool}.
     */
    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 initialFee_,
        uint256 initialTargetRatio_,
        DynamicFeeLib.PoolParams calldata poolParams_
    ) external override onlyAlphixHook poolUnconfigured whenNotPaused {
        // Validate and store pool params (includes global bounds validation)
        _setPoolParams(poolParams_);

        // Validate fee is within bounds for the params
        if (!_isValidFee(initialFee_)) {
            revert InvalidFee(initialFee_);
        }

        // Validate ratio is within bounds for the params
        if (!_isValidRatio(initialTargetRatio_)) {
            revert InvalidRatio(initialTargetRatio_);
        }

        // Store pool key and cached pool ID
        _poolKey = key;
        _poolId = key.toId();

        _lastFeeUpdate = block.timestamp;
        _targetRatio = initialTargetRatio_;
        _poolConfig.initialFee = initialFee_;
        _poolConfig.initialTargetRatio = initialTargetRatio_;
        _poolConfig.isConfigured = true;
        _poolActivated = true;
    }

    /**
     * @dev See {IAlphixLogic-activatePool}.
     */
    function activatePool() external override onlyAlphixHook whenNotPaused poolConfigured {
        _poolActivated = true;
    }

    /**
     * @dev See {IAlphixLogic-deactivatePool}.
     */
    function deactivatePool() external override onlyAlphixHook whenNotPaused {
        _poolActivated = false;
    }

    /**
     * @dev See {IAlphixLogic-setPoolParams}.
     */
    function setPoolParams(DynamicFeeLib.PoolParams calldata params) external override onlyOwner whenNotPaused {
        _setPoolParams(params);
    }

    /**
     * @dev See {IAlphixLogic-setGlobalMaxAdjRate}.
     */
    function setGlobalMaxAdjRate(uint256 globalMaxAdjRate_) external override onlyOwner whenNotPaused {
        _setGlobalMaxAdjRate(globalMaxAdjRate_);
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

    /* ═══════════════════════════════════════════════════════════════════════════════════════════════════════
                                         REHYPOTHECATION FUNCTIONS
       ═══════════════════════════════════════════════════════════════════════════════════════════════════════ */

    /* YIELD MANAGER FUNCTIONS */

    /**
     * @dev See {IReHypothecation-setYieldSource}.
     * @notice Gated by YIELD_MANAGER_ROLE via AccessManager. Harvests yield and migrates liquidity if yield source exists.
     */
    function setYieldSource(Currency currency, address newYieldSource)
        external
        virtual
        override
        restricted
        poolConfigured
        whenNotPaused
        nonReentrant
    {
        if (!ReHypothecationLib.isValidYieldSource(newYieldSource, currency)) {
            revert InvalidYieldSource(newYieldSource);
        }

        YieldSourceState storage state = _yieldSourceState[currency];
        address oldYieldSource = state.yieldSource;

        // Harvest accrued yield before migration (accumulates tax)
        if (oldYieldSource != address(0) && state.sharesOwned > 0) {
            _accumulateYieldTax(currency);

            // Now migrate
            state.sharesOwned =
                ReHypothecationLib.migrateYieldSource(oldYieldSource, newYieldSource, currency, state.sharesOwned);
        }

        state.yieldSource = newYieldSource;
        // Record the rate for the new yield source
        (state.lastRecordedRate,) = ReHypothecationLib.getCurrentRate(newYieldSource);

        emit YieldSourceUpdated(currency, oldYieldSource, newYieldSource);
    }

    /**
     * @dev See {IReHypothecation-setTickRange}.
     * @notice Gated by YIELD_MANAGER_ROLE via AccessManager.
     */
    function setTickRange(int24 tickLower, int24 tickUpper) external override restricted poolConfigured whenNotPaused {
        ReHypothecationLib.validateTickRange(tickLower, tickUpper, _poolKey.tickSpacing);

        _reHypothecationConfig.tickLower = tickLower;
        _reHypothecationConfig.tickUpper = tickUpper;

        emit TickRangeUpdated(tickLower, tickUpper);
    }

    /**
     * @dev See {IReHypothecation-setYieldTaxPips}.
     * @notice Gated by YIELD_MANAGER_ROLE via AccessManager.
     */
    function setYieldTaxPips(uint24 yieldTaxPips_) external override restricted poolConfigured whenNotPaused {
        ReHypothecationLib.validateYieldTaxPips(yieldTaxPips_);

        _reHypothecationConfig.yieldTaxPips = yieldTaxPips_;

        emit YieldTaxUpdated(yieldTaxPips_);
    }

    /**
     * @dev See {IReHypothecation-setYieldTreasury}.
     * @notice Gated by YIELD_MANAGER_ROLE via AccessManager.
     */
    function setYieldTreasury(address treasury) external override restricted whenNotPaused {
        if (treasury == address(0)) revert InvalidAddress();
        address oldTreasury = _yieldTreasury;
        _yieldTreasury = treasury;
        emit YieldTreasuryUpdated(oldTreasury, treasury);
    }

    /* GETTERS */

    /**
     * @dev See {IAlphixLogic-getAlphixHook}.
     */
    function getAlphixHook() external view override returns (address) {
        return _alphixHook;
    }

    /**
     * @dev See {IAlphixLogic-getPoolKey}.
     */
    function getPoolKey() external view override(IAlphixLogic, IReHypothecation) returns (PoolKey memory) {
        return _poolKey;
    }

    /**
     * @dev See {IAlphixLogic-isPoolActivated}.
     */
    function isPoolActivated() external view override returns (bool) {
        return _poolActivated;
    }

    /**
     * @dev See {IAlphixLogic-getPoolConfig}.
     */
    function getPoolConfig() external view override returns (PoolConfig memory) {
        return _poolConfig;
    }

    /**
     * @dev See {IAlphixLogic-getPoolId}.
     */
    function getPoolId() external view override returns (PoolId) {
        return _poolId;
    }

    /**
     * @dev See {IAlphixLogic-getPoolParams}.
     */
    function getPoolParams() external view override returns (DynamicFeeLib.PoolParams memory) {
        return _poolParams;
    }

    /**
     * @dev See {IAlphixLogic-getGlobalMaxAdjRate}.
     */
    function getGlobalMaxAdjRate() external view override returns (uint256) {
        return _globalMaxAdjRate;
    }

    /**
     * @dev See {IReHypothecation-getCurrencyYieldSource}.
     */
    function getCurrencyYieldSource(Currency currency) external view override returns (address yieldSource) {
        return _yieldSourceState[currency].yieldSource;
    }

    /**
     * @dev See {IReHypothecation-getAmountInYieldSource}.
     * @notice Returns user-available amount (total minus accumulated tax).
     */
    function getAmountInYieldSource(Currency currency) external view override returns (uint256 amount) {
        return _getUserAvailableAmount(currency);
    }

    /**
     * @dev See {IReHypothecation-getReHypothecationConfig}.
     */
    function getReHypothecationConfig() external view override returns (ReHypothecationConfig memory config) {
        return _reHypothecationConfig;
    }

    /**
     * @dev See {IReHypothecation-getYieldTreasury}.
     */
    function getYieldTreasury() external view override returns (address treasury) {
        return _yieldTreasury;
    }

    /**
     * @dev See {IReHypothecation-getAccumulatedTax}.
     */
    function getAccumulatedTax(Currency currency) external view override returns (uint256 amount) {
        return _yieldSourceState[currency].accumulatedTax;
    }

    /* VIEW FUNCTIONS */

    /**
     * @dev See {IReHypothecation-previewAddReHypothecatedLiquidity}.
     * @notice Returns amounts needed for a deposit (rounds up for protocol-favorable).
     *         Excludes accumulated tax from calculations - users only get their share of user funds.
     */
    function previewAddReHypothecatedLiquidity(uint256 shares)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmountsForDeposit(shares);
    }

    /**
     * @dev See {IReHypothecation-previewRemoveReHypothecatedLiquidity}.
     * @notice Returns amounts received for a withdrawal (rounds down for protocol-favorable).
     *         Excludes accumulated tax from calculations - users only get their share of user funds.
     */
    function previewRemoveReHypothecatedLiquidity(uint256 shares)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmountsForWithdrawal(shares);
    }

    /**
     * @dev See {IReHypothecation-previewAddFromAmount0}.
     * @notice Computes shares and required amount1 from a given amount0.
     */
    function previewAddFromAmount0(uint256 amount0) external view override returns (uint256 amount1, uint256 shares) {
        uint256 currentTotalSupply = totalSupply();
        IPoolManager pm = BaseDynamicFee(_alphixHook).poolManager();

        if (currentTotalSupply == 0) {
            // Initial deposit: compute shares from amount0 using pool price
            (uint160 currentSqrtPriceX96,,,) = pm.getSlot0(_poolKey.toId());
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickUpper);

            // Get liquidity from amount0
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLowerX96, sqrtPriceUpperX96, amount0);
            if (liquidity == 0) return (0, 0);

            // Get amounts for that liquidity (this is what _convertSharesToAmountsForDeposit returns + 1)
            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
            );

            // Check if deposit rounding (+1) would exceed amount0, if so reduce liquidity by 1
            if (amt0 + 1 > amount0 && liquidity > 1) {
                liquidity -= 1;
                (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
                    currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
                );
            }

            // Return amounts with +1 rounding to match _convertSharesToAmountsForDeposit
            return (amt1 + 1, uint256(liquidity));
        }

        // Existing pool: compute shares proportionally from amount0
        uint256 userAmount0 = _getUserAvailableAmount(_poolKey.currency0);
        if (userAmount0 == 0) return (0, 0);

        // shares = amount0 * totalSupply / userAmount0 (round down)
        shares = FullMath.mulDiv(amount0, currentTotalSupply, userAmount0);
        if (shares == 0) return (0, 0);

        // Get required amounts for these shares
        (, uint256 reqAmt1) = _convertSharesToAmountsForDeposit(shares);

        return (reqAmt1, shares);
    }

    /**
     * @dev See {IReHypothecation-previewAddFromAmount1}.
     * @notice Computes shares and required amount0 from a given amount1.
     */
    function previewAddFromAmount1(uint256 amount1) external view override returns (uint256 amount0, uint256 shares) {
        uint256 currentTotalSupply = totalSupply();
        IPoolManager pm = BaseDynamicFee(_alphixHook).poolManager();

        if (currentTotalSupply == 0) {
            // Initial deposit: compute shares from amount1 using pool price
            (uint160 currentSqrtPriceX96,,,) = pm.getSlot0(_poolKey.toId());
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickUpper);

            // Get liquidity from amount1
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, amount1);
            if (liquidity == 0) return (0, 0);

            // Get amounts for that liquidity (this is what _convertSharesToAmountsForDeposit returns + 1)
            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
            );

            // Check if deposit rounding (+1) would exceed amount1, if so reduce liquidity by 1
            if (amt1 + 1 > amount1 && liquidity > 1) {
                liquidity -= 1;
                (amt0, amt1) = LiquidityAmounts.getAmountsForLiquidity(
                    currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
                );
            }

            // Return amounts with +1 rounding to match _convertSharesToAmountsForDeposit
            return (amt0 + 1, uint256(liquidity));
        }

        // Existing pool: compute shares proportionally from amount1
        uint256 userAmount1 = _getUserAvailableAmount(_poolKey.currency1);
        if (userAmount1 == 0) return (0, 0);

        // shares = amount1 * totalSupply / userAmount1 (round down)
        shares = FullMath.mulDiv(amount1, currentTotalSupply, userAmount1);
        if (shares == 0) return (0, 0);

        // Get required amounts for these shares
        (uint256 reqAmt0,) = _convertSharesToAmountsForDeposit(shares);

        return (reqAmt0, shares);
    }

    /* LIQUIDITY OPERATIONS (permissionless, pool must be active) */

    /**
     * @dev See {IReHypothecation-addReHypothecatedLiquidity}.
     * @notice Accumulates yield tax before depositing.
     */
    function addReHypothecatedLiquidity(uint256 shares)
        external
        payable
        virtual
        override
        poolActivated
        whenNotPaused
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        // Accumulate yield tax before modifying position
        _accumulateYieldTax(_poolKey.currency0);
        _accumulateYieldTax(_poolKey.currency1);

        // Calculate amounts with rounding up (protocol-favorable for deposits)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForDeposit(shares);

        // Prevent minting shares for zero deposits
        if (amount0 == 0 && amount1 == 0) revert ZeroAmounts();

        // Transfer tokens from sender (ERC20 only - no ETH support in this variant)
        _transferFromSender(_poolKey.currency0, amount0);
        _transferFromSender(_poolKey.currency1, amount1);

        // Deposit to yield sources
        _depositToYieldSource(_poolKey.currency0, amount0);
        _depositToYieldSource(_poolKey.currency1, amount1);

        // Mint shares (ERC20)
        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, shares, amount0, amount1);

        // Safe: toInt128() uses SafeCast which reverts if value exceeds int128 max (~1.7e38), far above realistic token amounts
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128());
    }

    /**
     * @dev See {IReHypothecation-removeReHypothecatedLiquidity}.
     * @notice Accumulates yield tax before withdrawing.
     */
    function removeReHypothecatedLiquidity(uint256 shares)
        external
        virtual
        override
        poolActivated
        whenNotPaused
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < shares) revert InsufficientShares(shares, userBalance);

        // Accumulate yield tax before modifying position
        _accumulateYieldTax(_poolKey.currency0);
        _accumulateYieldTax(_poolKey.currency1);

        // Calculate amounts with rounding down (protocol-favorable for withdrawals)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForWithdrawal(shares);

        // Burn shares first (ERC20)
        _burn(msg.sender, shares);

        // Withdraw from yield sources directly to sender (more efficient than withdraw + transfer)
        _withdrawFromYieldSourceTo(_poolKey.currency0, amount0, msg.sender);
        _withdrawFromYieldSourceTo(_poolKey.currency1, amount1, msg.sender);

        emit ReHypothecatedLiquidityRemoved(msg.sender, shares, amount0, amount1);

        // Safe: toInt128() uses SafeCast which reverts if value exceeds int128 max (~1.7e38), far above realistic token amounts
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /**
     * @dev See {IReHypothecation-collectAccumulatedTax}.
     * @notice Permissionless. Withdraws accumulated tax from yield sources and sends to treasury.
     */
    function collectAccumulatedTax()
        external
        virtual
        override
        poolActivated
        whenNotPaused
        nonReentrant
        returns (uint256 collected0, uint256 collected1)
    {
        collected0 = _collectCurrencyTax(_poolKey.currency0);
        collected1 = _collectCurrencyTax(_poolKey.currency1);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @notice Internal function to set pool params.
     * @param params The params to set.
     */
    function _setPoolParams(DynamicFeeLib.PoolParams memory params) internal {
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

    /**
     * @dev Common initialization logic shared by AlphixLogic and AlphixLogicETH.
     *      Called by initialize() and initializeETH().
     */
    function _initializeCommon(
        address owner_,
        address alphixHook_,
        address accessManager_,
        string memory name_,
        string memory symbol_
    ) internal onlyInitializing {
        __Ownable2Step_init();
        __AccessManaged_init(accessManager_);
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        __Pausable_init();
        __ERC165_init();
        __ERC20_init(name_, symbol_);

        if (owner_ == address(0) || alphixHook_ == address(0) || accessManager_ == address(0)) {
            revert InvalidAddress();
        }

        _transferOwnership(owner_);

        _alphixHook = alphixHook_;

        // Sets the default globalMaxAdjustmentRate
        _setGlobalMaxAdjRate(AlphixGlobalConstants.TEN_WAD);
    }

    /**
     * @notice Internal function to set the global max adjustment rate.
     * @param globalMaxAdjRate_ The global max adjustment rate to set.
     */
    function _setGlobalMaxAdjRate(uint256 globalMaxAdjRate_) internal {
        if (globalMaxAdjRate_ == 0 || globalMaxAdjRate_ > AlphixGlobalConstants.MAX_ADJUSTMENT_RATE) {
            revert InvalidParameter();
        }
        emit GlobalMaxAdjRateUpdated(_globalMaxAdjRate, globalMaxAdjRate_);
        _globalMaxAdjRate = globalMaxAdjRate_;
    }

    /**
     * @notice Check if fee is valid for pool params.
     * @dev Internal helper function to validate fee against stored pool params.
     * @param fee The fee to validate.
     * @return isValid True if fee is within bounds.
     */
    function _isValidFee(uint24 fee) internal view returns (bool) {
        return fee >= _poolParams.minFee && fee <= _poolParams.maxFee;
    }

    /**
     * @notice Check if ratio is valid for pool params.
     * @dev Internal helper function to validate ratio against stored pool params.
     * @param ratio The ratio to validate.
     * @return isValid True if ratio is within bounds.
     */
    function _isValidRatio(uint256 ratio) internal view returns (bool) {
        return ratio > 0 && ratio <= _poolParams.maxCurrentRatio;
    }

    /* REHYPOTHECATION INTERNAL FUNCTIONS */

    /**
     * @notice Transfer ERC20 tokens from sender.
     * @dev ERC20-only variant - no ETH support.
     * @param currency The currency to transfer.
     * @param amount The amount to transfer.
     */
    function _transferFromSender(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Get user-available amount for a single currency (total minus accumulated tax).
     * @param currency The currency to check.
     * @return userAmount User-available amount (total minus accumulated tax).
     */
    function _getUserAvailableAmount(Currency currency) internal view returns (uint256 userAmount) {
        YieldSourceState storage state = _yieldSourceState[currency];
        uint256 totalAmount = ReHypothecationLib.getAmountInYieldSource(state.yieldSource, state.sharesOwned);
        return totalAmount > state.accumulatedTax ? totalAmount - state.accumulatedTax : 0;
    }

    /**
     * @notice Get user-available amounts (total minus accumulated tax).
     * @dev Used to ensure accumulated tax is not counted as user funds.
     * @return userAmount0 User-available amount of currency0.
     * @return userAmount1 User-available amount of currency1.
     */
    function _getUserAvailableAmounts() internal view returns (uint256 userAmount0, uint256 userAmount1) {
        userAmount0 = _getUserAvailableAmount(_poolKey.currency0);
        userAmount1 = _getUserAvailableAmount(_poolKey.currency1);
    }

    /**
     * @notice Convert shares to underlying amounts for withdrawals (rounds down).
     * @dev Excludes accumulated tax - users only get their share of user funds.
     *      Rounding down is protocol-favorable for withdrawals.
     * @param shares Number of shares.
     * @return amount0 Amount of currency0.
     * @return amount1 Amount of currency1.
     */
    function _convertSharesToAmountsForWithdrawal(uint256 shares)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 currentTotalSupply = totalSupply();

        if (currentTotalSupply == 0) {
            return (0, 0);
        }

        // Get user-available amounts (excluding accumulated tax)
        (uint256 userAmount0, uint256 userAmount1) = _getUserAvailableAmounts();

        return ReHypothecationLib.convertSharesToAmounts(shares, currentTotalSupply, userAmount0, userAmount1);
    }

    /**
     * @notice Convert shares to underlying amounts for deposits (rounds up).
     * @dev Excludes accumulated tax - users only get their share of user funds.
     *      Rounding up is protocol-favorable for deposits (user provides more).
     * @param shares Number of shares.
     * @return amount0 Amount of currency0.
     * @return amount1 Amount of currency1.
     */
    function _convertSharesToAmountsForDeposit(uint256 shares)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 currentTotalSupply = totalSupply();

        if (currentTotalSupply == 0) {
            // Initial deposit: use pool price to determine amounts
            IPoolManager pm = BaseDynamicFee(_alphixHook).poolManager();
            (uint160 currentSqrtPriceX96,,,) = pm.getSlot0(_poolKey.toId());
            // SafeCast.toUint128 reverts if shares exceeds uint128.max
            uint128 liquidityFromShares = shares.toUint128();
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96,
                TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickLower),
                TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickUpper),
                liquidityFromShares
            );
            // Round up in favor of protocol (first depositor provides slightly more)
            return (amount0 + 1, amount1 + 1);
        }

        // Get user-available amounts (excluding accumulated tax)
        (uint256 userAmount0, uint256 userAmount1) = _getUserAvailableAmounts();

        return ReHypothecationLib.convertSharesToAmountsRoundUp(shares, currentTotalSupply, userAmount0, userAmount1);
    }

    /**
     * @notice Deposit assets to yield source.
     * @dev Rate is NOT updated here - caller must ensure _accumulateYieldTax was called first,
     *      which already updates the rate. This avoids redundant external calls.
     * @param currency The currency to deposit.
     * @param amount The amount to deposit.
     */
    function _depositToYieldSource(Currency currency, uint256 amount) internal {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured(currency);

        uint256 sharesReceived = ReHypothecationLib.depositToYieldSource(state.yieldSource, currency, amount);
        state.sharesOwned += sharesReceived;
    }

    /**
     * @notice Withdraw assets from yield source to a recipient.
     * @dev Used for both JIT flow (recipient = address(this)) and user withdrawals.
     *      Rate is NOT updated here - caller must ensure _accumulateYieldTax was called first,
     *      which already updates the rate. This avoids redundant external calls.
     * @param currency The currency to withdraw.
     * @param amount The amount to withdraw.
     * @param recipient The address to receive the withdrawn assets.
     */
    function _withdrawFromYieldSourceTo(Currency currency, uint256 amount, address recipient) internal virtual {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured(currency);

        uint256 sharesRedeemed = ReHypothecationLib.withdrawFromYieldSourceTo(state.yieldSource, amount, recipient);
        state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;
    }

    /**
     * @notice Accumulate yield tax for a single currency.
     * @dev Calculates yield since last rate, computes tax, and adds to accumulated tax.
     *      Does NOT withdraw - tax is collected lazily via collectAccumulatedTax.
     * @param currency The currency.
     */
    function _accumulateYieldTax(Currency currency) internal {
        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0) || state.sharesOwned == 0) return;

        uint24 yieldTaxPips_ = _reHypothecationConfig.yieldTaxPips;
        if (yieldTaxPips_ == 0) {
            // Still update rate even if no tax
            (state.lastRecordedRate,) = ReHypothecationLib.getCurrentRate(state.yieldSource);
            return;
        }

        // Calculate yield based on rate change
        (uint256 yieldAmount, uint256 currentRate) =
            ReHypothecationLib.calculateYieldFromRate(state.yieldSource, state.sharesOwned, state.lastRecordedRate);

        if (yieldAmount > 0) {
            // Calculate and accumulate tax
            uint256 taxAmount = ReHypothecationLib.calculateTaxFromYield(yieldAmount, yieldTaxPips_);
            state.accumulatedTax += taxAmount;
            emit YieldTaxAccumulated(currency, yieldAmount, taxAmount);
        }

        // Update rate
        state.lastRecordedRate = currentRate;
    }

    /**
     * @notice Collect accumulated tax for a single currency.
     * @dev Withdraws accumulated tax from yield source directly to treasury.
     * @param currency The currency.
     * @return collected The amount collected.
     */
    function _collectCurrencyTax(Currency currency) internal returns (uint256 collected) {
        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) return 0;

        // First accumulate any pending yield tax
        _accumulateYieldTax(currency);

        collected = state.accumulatedTax;
        if (collected == 0 || _yieldTreasury == address(0)) return 0;

        // Reset accumulated tax
        state.accumulatedTax = 0;

        // Withdraw directly to treasury (saves one transfer vs withdraw + transfer)
        uint256 sharesRedeemed = IERC4626(state.yieldSource).withdraw(collected, _yieldTreasury, address(this));
        state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;

        // Update rate after withdrawal
        (state.lastRecordedRate,) = ReHypothecationLib.getCurrentRate(state.yieldSource);

        emit AccumulatedTaxCollected(currency, collected);
    }

    /* JIT LIQUIDITY INTERNAL FUNCTIONS */

    /**
     * @notice Compute JIT liquidity parameters for adding liquidity before a swap.
     * @dev Internal helper called by beforeSwap. Does NOT pre-withdraw - Alphix will call
     *      updateYieldSourcesAfterJIT with the actual delta after modifyLiquidity.
     *      Uses (liquidity - 1) as safety margin against rounding edge cases.
     * @return params The JIT parameters.
     */
    function _computeBeforeSwapJit() internal view returns (JitParams memory params) {
        // Check if JIT is configured (yield sources set and tick range configured)
        if (
            _yieldSourceState[_poolKey.currency0].yieldSource == address(0)
                || _yieldSourceState[_poolKey.currency1].yieldSource == address(0)
                || _reHypothecationConfig.tickLower == _reHypothecationConfig.tickUpper
        ) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }

        // Get user-available amounts (excludes accumulated tax)
        uint256 amount0Available = _getUserAvailableAmount(_poolKey.currency0);
        uint256 amount1Available = _getUserAvailableAmount(_poolKey.currency1);

        if (amount0Available == 0 && amount1Available == 0) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }

        // Compute liquidity to add
        IPoolManager pm = BaseDynamicFee(_alphixHook).poolManager();
        (uint160 currentSqrtPriceX96,,,) = pm.getSlot0(_poolKey.toId());
        uint128 liquidityToAdd = ReHypothecationLib.getLiquidityToUse(
            currentSqrtPriceX96,
            _reHypothecationConfig.tickLower,
            _reHypothecationConfig.tickUpper,
            amount0Available,
            amount1Available
        );

        // Apply safety margin: use (liquidity - 1) to avoid rounding edge cases.
        // If liquidity <= 1, treat as 0 (not worth executing JIT for 1 unit)
        if (liquidityToAdd <= 1) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }
        uint128 safetyAdjustedLiquidity = liquidityToAdd - 1;

        return JitParams({
            tickLower: _reHypothecationConfig.tickLower,
            tickUpper: _reHypothecationConfig.tickUpper,
            liquidityDelta: int256(uint256(safetyAdjustedLiquidity)),
            shouldExecute: true
        });
    }

    /**
     * @notice Compute JIT liquidity parameters for removing liquidity after a swap.
     * @dev Internal helper called by afterSwap. Removes all hook position liquidity.
     * @return params The JIT parameters.
     */
    function _computeAfterSwapJit() internal view returns (JitParams memory params) {
        // Get current hook position liquidity directly via StateLibrary
        IPoolManager pm = BaseDynamicFee(_alphixHook).poolManager();
        bytes32 positionKey = Position.calculatePositionKey(
            _alphixHook, _reHypothecationConfig.tickLower, _reHypothecationConfig.tickUpper, bytes32(0)
        );
        uint128 currentLiquidity = StateLibrary.getPositionLiquidity(pm, _poolKey.toId(), positionKey);

        if (currentLiquidity == 0) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }

        // Remove all liquidity
        return JitParams({
            tickLower: _reHypothecationConfig.tickLower,
            tickUpper: _reHypothecationConfig.tickUpper,
            liquidityDelta: -int256(uint256(currentLiquidity)),
            shouldExecute: true
        });
    }

    /* MODIFIER FUNCTIONS */

    /**
     * @dev Internal function to validate caller is Alphix hook (reduces contract size)
     */
    function _onlyAlphixHook() internal view {
        if (msg.sender != _alphixHook) {
            revert InvalidCaller();
        }
    }

    /**
     * @dev Internal function to validate pool is active (reduces contract size)
     */
    function _requirePoolActivated() internal view {
        if (!_poolActivated) {
            revert PoolPaused();
        }
    }

    /**
     * @dev Internal function to validate pool is unconfigured (reduces contract size)
     */
    function _poolUnconfigured() internal view {
        if (_poolConfig.isConfigured) {
            revert PoolAlreadyConfigured();
        }
    }

    /**
     * @dev Internal function to validate pool is configured (reduces contract size)
     */
    function _poolConfigured() internal view {
        if (!_poolConfig.isConfigured) {
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
