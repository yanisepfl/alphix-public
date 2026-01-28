// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "./BaseDynamicFee.sol";
import {IAlphix} from "./interfaces/IAlphix.sol";
import {IReHypothecation} from "./interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "./libraries/DynamicFee.sol";
import {AlphixGlobalConstants} from "./libraries/AlphixGlobalConstants.sol";
import {ReHypothecationLib} from "./libraries/ReHypothecation.sol";

/**
 * @title Alphix
 * @notice Uniswap v4 Dynamic Fee Hook with JIT liquidity rehypothecation.
 * @dev Single contract combining hook, dynamic fee logic, and rehypothecation.
 *      Each instance serves exactly one pool. Shares are ERC20 tokens.
 *      For ETH pools, use AlphixETH instead.
 */
contract Alphix is
    BaseDynamicFee,
    Ownable2Step,
    AccessManaged,
    ReentrancyGuardTransient,
    Pausable,
    ERC20,
    IAlphix,
    IReHypothecation
{
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /* STORAGE */

    /// @dev The global max adjustment rate value.
    uint256 internal _globalMaxAdjRate;

    /// @dev The pool key this contract serves (single pool per instance).
    PoolKey internal _poolKey;

    /// @dev The cached pool ID (computed once at activation).
    PoolId internal _poolId;

    /// @dev Pool configuration (initial fee and target ratio).
    PoolConfig internal _poolConfig;

    /// @dev Out-Of-Bound state for dynamic fee algorithm.
    DynamicFeeLib.OobState internal _oobState;

    /// @dev Current target ratio for EMA.
    uint256 internal _targetRatio;

    /// @dev Last fee update timestamp for cooldown.
    uint256 internal _lastFeeUpdate;

    /// @dev Pool parameters for dynamic fee algorithm.
    DynamicFeeLib.PoolParams internal _poolParams;

    /// @dev Rehypothecation configuration (tick ranges).
    ReHypothecationConfig internal _reHypothecationConfig;

    /// @dev Per-currency yield source state.
    mapping(Currency currency => YieldSourceState state) internal _yieldSourceState;

    /* STRUCTS */

    /**
     * @dev Parameters for JIT liquidity operations.
     */
    struct JitParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bool shouldExecute;
    }

    /* MODIFIERS */

    modifier poolUnconfigured() {
        _poolUnconfigured();
        _;
    }

    modifier poolConfigured() {
        _poolConfigured();
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @notice Initialize with PoolManager, owner, accessManager, name and symbol.
     * @param _poolManager The Uniswap V4 PoolManager.
     * @param _owner The owner of this contract.
     * @param _accessManager The AccessManager for role-based access control.
     * @param name_ The ERC20 share token name.
     * @param symbol_ The ERC20 share token symbol.
     */
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _accessManager,
        string memory name_,
        string memory symbol_
    ) BaseDynamicFee(_poolManager) Ownable(_owner) AccessManaged(_accessManager) ERC20(name_, symbol_) {
        if (address(_poolManager) == address(0) || _accessManager == address(0)) {
            revert InvalidAddress();
        }
        _setGlobalMaxAdjRate(AlphixGlobalConstants.TEN_WAD);
        _pause(); // Start paused until pool is initialized
    }

    /* HOOK PERMISSIONS */

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /* HOOK ENTRY POINTS */

    /**
     * @dev Validates pool initialization conditions.
     *      Only owner can initialize, prevents re-initialization, and rejects native ETH pools.
     * @param sender The address that initiated the pool initialization (passed by PoolManager).
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160)
        internal
        view
        virtual
        override
        returns (bytes4)
    {
        // Only owner can initialize the pool at PoolManager level
        if (sender != owner()) revert OwnableUnauthorizedAccount(sender);

        // Prevent re-initialization if pool already configured
        if (address(_poolKey.hooks) != address(0)) revert PoolAlreadyInitialized();

        // Reject native ETH pools - use AlphixETH for those
        if (key.currency0.isAddressZero()) revert UnsupportedNativeCurrency();
        return BaseHook.beforeInitialize.selector;
    }

    /**
     * @dev beforeSwap: Compute and execute JIT liquidity addition.
     *      NO settlement here - flash accounting carries delta to afterSwap.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Compute JIT params
        JitParams memory jitParams = _computeBeforeSwapJit();

        // Execute JIT liquidity addition if needed - NO settlement (flash accounting)
        if (jitParams.shouldExecute) {
            _executeJitLiquidity(key, jitParams);
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /**
     * @dev afterSwap: Remove JIT liquidity and resolve ALL deltas.
     *      Settlement happens here following OpenZeppelin flash accounting pattern.
     */
    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        override
        whenNotPaused
        returns (bytes4, int128)
    {
        // Compute JIT removal params
        JitParams memory jitParams = _computeAfterSwapJit();

        // Execute JIT liquidity removal and resolve all deltas
        if (jitParams.shouldExecute) {
            _executeJitLiquidity(key, jitParams);

            // Resolve net hook deltas (from add + remove)
            _resolveHookDelta(key.currency0);
            _resolveHookDelta(key.currency1);
        }

        return (BaseHook.afterSwap.selector, 0);
    }

    /* ADMIN FUNCTIONS */

    /**
     * @inheritdoc IAlphix
     * @dev NOTE: For JIT liquidity operations to execute during swaps, BOTH yield sources must be
     *      configured via setYieldSource() BEFORE or shortly AFTER calling initializePool().
     *      If yield sources are not configured, JIT operations will simply not execute (swaps still work).
     *      This is safe because _computeBeforeSwapJit() checks yield source configuration.
     */
    function initializePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        DynamicFeeLib.PoolParams calldata params,
        int24 _tickLower,
        int24 _tickUpper
    ) external override onlyOwner nonReentrant whenPaused poolUnconfigured {
        // Validate that the pool key references this hook
        if (address(key.hooks) != address(this)) revert HookMismatch();

        // Store pool params
        _setPoolParams(params);

        // Validate initial fee against the pool params bounds
        if (_initialFee < params.minFee || _initialFee > params.maxFee) {
            revert InvalidInitialFee(_initialFee, params.minFee, params.maxFee);
        }

        // Validate initial target ratio against pool params
        if (!_isValidRatio(_initialTargetRatio)) {
            revert InvalidCurrentRatio();
        }

        // Cache pool key and ID
        _poolKey = key;
        _poolId = key.toId();

        // Set initial state
        _poolConfig = PoolConfig({initialFee: _initialFee, initialTargetRatio: _initialTargetRatio, isConfigured: true});
        _targetRatio = _initialTargetRatio;
        _lastFeeUpdate = block.timestamp;

        // Set JIT tick range (immutable after initialization)
        ReHypothecationLib.validateTickRange(_tickLower, _tickUpper, key.tickSpacing);
        _reHypothecationConfig.tickLower = _tickLower;
        _reHypothecationConfig.tickUpper = _tickUpper;

        // Update fee in PoolManager
        poolManager.updateDynamicLPFee(key, _initialFee);

        // Unpause
        _unpause();

        emit FeeUpdated(_poolId, 0, _initialFee, 0, _initialTargetRatio, _initialTargetRatio);
    }

    /// @inheritdoc IAlphix
    function pause() external override onlyOwner {
        _pause();
    }

    /// @inheritdoc IAlphix
    function unpause() external override onlyOwner {
        _unpause();
    }

    /// @inheritdoc IAlphix
    function setPoolParams(DynamicFeeLib.PoolParams calldata params)
        external
        override
        onlyOwner
        poolConfigured
        whenNotPaused
    {
        _setPoolParams(params);

        // Clamp _targetRatio to the new maxCurrentRatio to maintain state consistency
        if (_targetRatio > params.maxCurrentRatio) {
            _targetRatio = params.maxCurrentRatio;
        }
    }

    /// @inheritdoc IAlphix
    function setGlobalMaxAdjRate(uint256 globalMaxAdjRate_) external override onlyOwner whenNotPaused {
        _setGlobalMaxAdjRate(globalMaxAdjRate_);
    }

    /* FEE RELATED FUNCTIONS */

    /// @inheritdoc IAlphix
    function poke(uint256 currentRatio)
        external
        override(BaseDynamicFee, IAlphix)
        restricted
        nonReentrant
        whenNotPaused
    {
        if (!_isValidRatio(currentRatio)) revert InvalidCurrentRatio();

        // Cooldown check
        if (block.timestamp < _lastFeeUpdate + _poolParams.minPeriod) {
            revert CooldownNotElapsed(block.timestamp, _lastFeeUpdate + _poolParams.minPeriod);
        }

        // Get current fee from PoolManager
        (,,, uint24 currentFee) = poolManager.getSlot0(_poolId);

        // Capture old target ratio for event
        uint256 oldTargetRatio = _targetRatio;

        // Compute new fee using current target ratio
        (uint24 newFee, DynamicFeeLib.OobState memory newOobState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, _targetRatio, _globalMaxAdjRate, _poolParams, _oobState
        );

        // Compute new target ratio using EMA
        uint256 newTargetRatio = DynamicFeeLib.ema(currentRatio, _targetRatio, _poolParams.lookbackPeriod);

        // Clamp to maxCurrentRatio to prevent extreme values
        if (newTargetRatio > _poolParams.maxCurrentRatio) {
            newTargetRatio = _poolParams.maxCurrentRatio;
        }

        if (newTargetRatio == 0) {
            newTargetRatio = 1;
        }

        // Update state
        _targetRatio = newTargetRatio;
        _oobState = newOobState;
        _lastFeeUpdate = block.timestamp;

        // Update fee in PoolManager
        if (currentFee != newFee) {
            poolManager.updateDynamicLPFee(_poolKey, newFee);
        }

        emit FeeUpdated(_poolId, currentFee, newFee, oldTargetRatio, currentRatio, newTargetRatio);
    }

    /// @inheritdoc IAlphix
    function computeFeeUpdate(uint256 currentRatio)
        external
        view
        override
        whenNotPaused
        returns (uint24 newFee, DynamicFeeLib.OobState memory newOobState, bool wouldUpdate)
    {
        if (!_isValidRatio(currentRatio)) revert InvalidCurrentRatio();

        (,,, uint24 currentFee) = poolManager.getSlot0(_poolId);
        (newFee, newOobState) = DynamicFeeLib.computeNewFee(
            currentFee, currentRatio, _targetRatio, _globalMaxAdjRate, _poolParams, _oobState
        );
        wouldUpdate = (newFee != currentFee) && (block.timestamp >= _lastFeeUpdate + _poolParams.minPeriod);
    }

    /* REHYPOTHECATION - YIELD MANAGER FUNCTIONS */

    /**
     * @inheritdoc IReHypothecation
     * @dev SECURITY: This function can send tokens to arbitrary addresses during migration.
     *      The newYieldSource parameter is trusted as the AccessManager restricts this function
     *      to authorized yield managers only. The owner/AccessManager admin is assumed to be
     *      a secure multisig that validates yield sources before configuration.
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
            revert InvalidYieldSource();
        }

        YieldSourceState storage state = _yieldSourceState[currency];
        address oldYieldSource = state.yieldSource;

        // Migrate if old yield source exists with shares
        if (oldYieldSource != address(0)) {
            if (state.sharesOwned > 0) {
                state.sharesOwned =
                    ReHypothecationLib.migrateYieldSource(oldYieldSource, newYieldSource, currency, state.sharesOwned);
            }
        }

        state.yieldSource = newYieldSource;

        emit YieldSourceUpdated(currency, oldYieldSource, newYieldSource);
    }

    /* REHYPOTHECATION - LIQUIDITY OPERATIONS */

    /// @inheritdoc IReHypothecation
    function addReHypothecatedLiquidity(uint256 shares, uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage)
        external
        payable
        virtual
        override
        whenNotPaused
        poolConfigured
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();
        if (msg.value > 0) revert InvalidMsgValue();

        // Check slippage before any state changes
        _checkPriceSlippage(expectedSqrtPriceX96, maxPriceSlippage);

        // Calculate amounts with rounding up (protocol-favorable for deposits)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForDeposit(shares);

        if (amount0 == 0) {
            if (amount1 == 0) revert ZeroAmounts();
        }

        // Transfer tokens from sender (ERC20 only)
        _transferFromSender(_poolKey.currency0, amount0);
        _transferFromSender(_poolKey.currency1, amount1);

        // Deposit to yield sources
        _depositToYieldSource(_poolKey.currency0, amount0);
        _depositToYieldSource(_poolKey.currency1, amount1);

        // Mint shares
        _mint(msg.sender, shares);

        emit ReHypothecatedLiquidityAdded(msg.sender, shares, amount0, amount1);

        // Safe: amounts bounded by yield source deposits, never exceed int256.max
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(-int256(amount0).toInt128(), -int256(amount1).toInt128());
    }

    /// @inheritdoc IReHypothecation
    function removeReHypothecatedLiquidity(uint256 shares, uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage)
        external
        virtual
        override
        whenNotPaused
        poolConfigured
        nonReentrant
        returns (BalanceDelta delta)
    {
        if (shares == 0) revert ZeroShares();

        uint256 userBalance = balanceOf(msg.sender);
        if (userBalance < shares) revert InsufficientShares();

        // Check slippage before any state changes
        _checkPriceSlippage(expectedSqrtPriceX96, maxPriceSlippage);

        // Calculate amounts with rounding down (protocol-favorable for withdrawals)
        (uint256 amount0, uint256 amount1) = _convertSharesToAmountsForWithdrawal(shares);

        // Prevent burning shares when both amounts round to zero
        if (amount0 == 0 && amount1 == 0) revert ZeroAmounts();

        // Burn shares first
        _burn(msg.sender, shares);

        // Withdraw from yield sources directly to sender
        _withdrawFromYieldSourceTo(_poolKey.currency0, amount0, msg.sender);
        _withdrawFromYieldSourceTo(_poolKey.currency1, amount1, msg.sender);

        emit ReHypothecatedLiquidityRemoved(msg.sender, shares, amount0, amount1);

        // Safe: amounts bounded by yield source deposits, never exceed int256.max
        // forge-lint: disable-next-line(unsafe-typecast)
        return toBalanceDelta(int256(amount0).toInt128(), int256(amount1).toInt128());
    }

    /* GETTERS */

    /// @inheritdoc IAlphix
    function getPoolKey() external view override(IAlphix, IReHypothecation) returns (PoolKey memory) {
        return _poolKey;
    }

    /// @inheritdoc IAlphix
    function getPoolId() external view override returns (PoolId) {
        return _poolId;
    }

    /// @inheritdoc IAlphix
    function getFee() external view override returns (uint24 fee) {
        (,,, fee) = poolManager.getSlot0(_poolId);
    }

    /// @inheritdoc IAlphix
    function getPoolConfig() external view override returns (PoolConfig memory) {
        return _poolConfig;
    }

    /// @inheritdoc IAlphix
    function getPoolParams() external view override returns (DynamicFeeLib.PoolParams memory) {
        return _poolParams;
    }

    /// @inheritdoc IAlphix
    function getGlobalMaxAdjRate() external view override returns (uint256) {
        return _globalMaxAdjRate;
    }

    /// @inheritdoc IReHypothecation
    function getCurrencyYieldSource(Currency currency) external view override returns (address yieldSource) {
        return _yieldSourceState[currency].yieldSource;
    }

    /// @inheritdoc IReHypothecation
    function getAmountInYieldSource(Currency currency) external view override returns (uint256 amount) {
        YieldSourceState storage state = _yieldSourceState[currency];
        return ReHypothecationLib.getAmountInYieldSource(state.yieldSource, state.sharesOwned);
    }

    /// @inheritdoc IReHypothecation
    function getReHypothecationConfig() external view override returns (ReHypothecationConfig memory config) {
        return _reHypothecationConfig;
    }

    /* PREVIEW FUNCTIONS */

    /// @inheritdoc IReHypothecation
    function previewAddReHypothecatedLiquidity(uint256 shares)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmountsForDeposit(shares);
    }

    /// @inheritdoc IReHypothecation
    function previewRemoveReHypothecatedLiquidity(uint256 shares)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return _convertSharesToAmountsForWithdrawal(shares);
    }

    /// @inheritdoc IReHypothecation
    function previewAddFromAmount0(uint256 amount0) external view override returns (uint256 amount1, uint256 shares) {
        uint256 currentTotalSupply = totalSupply();

        if (currentTotalSupply == 0) {
            (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickUpper);

            // where amount0 is fully utilized at the current price (token0 exists between current and upper)
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(currentSqrtPriceX96, sqrtPriceUpperX96, amount0);
            if (liquidity == 0) return (0, 0);

            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
            );

            if (amt0 + 1 > amount0) {
                if (liquidity > 1) {
                    liquidity -= 1;
                    (, amt1) = LiquidityAmounts.getAmountsForLiquidity(
                        currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
                    );
                }
            }

            return (amt1 + 1, uint256(liquidity));
        }

        uint256 totalAmount0 = _getAmountInYieldSource(_poolKey.currency0);
        if (totalAmount0 == 0) return (0, 0);

        shares = FullMath.mulDiv(amount0, currentTotalSupply, totalAmount0);
        if (shares == 0) return (0, 0);

        (, uint256 reqAmt1) = _convertSharesToAmountsForDeposit(shares);
        return (reqAmt1, shares);
    }

    /// @inheritdoc IReHypothecation
    function previewAddFromAmount1(uint256 amount1) external view override returns (uint256 amount0, uint256 shares) {
        uint256 currentTotalSupply = totalSupply();

        if (currentTotalSupply == 0) {
            (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
            uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickLower);
            uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickUpper);

            // where amount1 is fully utilized at the current price (token1 exists between lower and current)
            uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(sqrtPriceLowerX96, currentSqrtPriceX96, amount1);
            if (liquidity == 0) return (0, 0);

            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
            );

            if (amt1 + 1 > amount1) {
                if (liquidity > 1) {
                    liquidity -= 1;
                    (amt0,) = LiquidityAmounts.getAmountsForLiquidity(
                        currentSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity
                    );
                }
            }

            return (amt0 + 1, uint256(liquidity));
        }

        uint256 totalAmount1 = _getAmountInYieldSource(_poolKey.currency1);
        if (totalAmount1 == 0) return (0, 0);

        shares = FullMath.mulDiv(amount1, currentTotalSupply, totalAmount1);
        if (shares == 0) return (0, 0);

        (uint256 reqAmt0,) = _convertSharesToAmountsForDeposit(shares);
        return (reqAmt0, shares);
    }

    /* INTERNAL FUNCTIONS */

    /**
     * @dev Validates and stores pool parameters for the dynamic fee algorithm.
     * @param params The pool parameters to set.
     */
    function _setPoolParams(DynamicFeeLib.PoolParams memory params) internal {
        if (
            params.minFee < AlphixGlobalConstants.MIN_FEE || params.minFee > params.maxFee
                || params.maxFee > LPFeeLibrary.MAX_LP_FEE
        ) {
            revert InvalidFeeBounds();
        }

        if (params.baseMaxFeeDelta < AlphixGlobalConstants.MIN_FEE || params.baseMaxFeeDelta > LPFeeLibrary.MAX_LP_FEE)
        {
            revert InvalidParameter();
        }

        if (params.minPeriod < AlphixGlobalConstants.MIN_PERIOD || params.minPeriod > AlphixGlobalConstants.MAX_PERIOD)
        {
            revert InvalidParameter();
        }

        if (
            params.lookbackPeriod < AlphixGlobalConstants.MIN_LOOKBACK_PERIOD
                || params.lookbackPeriod > AlphixGlobalConstants.MAX_LOOKBACK_PERIOD
        ) {
            revert InvalidParameter();
        }

        if (
            params.ratioTolerance < AlphixGlobalConstants.MIN_RATIO_TOLERANCE
                || params.ratioTolerance > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();

        if (
            params.linearSlope < AlphixGlobalConstants.MIN_LINEAR_SLOPE
                || params.linearSlope > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();

        if (params.maxCurrentRatio == 0 || params.maxCurrentRatio > AlphixGlobalConstants.MAX_CURRENT_RATIO) {
            revert InvalidParameter();
        }

        if (
            params.upperSideFactor < AlphixGlobalConstants.ONE_TENTH_WAD
                || params.upperSideFactor > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();
        if (
            params.lowerSideFactor < AlphixGlobalConstants.ONE_TENTH_WAD
                || params.lowerSideFactor > AlphixGlobalConstants.TEN_WAD
        ) revert InvalidParameter();

        _poolParams = params;
        emit PoolParamsUpdated();
    }

    /**
     * @dev Validates and stores the global max adjustment rate.
     * @param globalMaxAdjRate_ The new global max adjustment rate.
     */
    function _setGlobalMaxAdjRate(uint256 globalMaxAdjRate_) internal {
        if (globalMaxAdjRate_ == 0 || globalMaxAdjRate_ > AlphixGlobalConstants.MAX_ADJUSTMENT_RATE) {
            revert InvalidParameter();
        }
        _globalMaxAdjRate = globalMaxAdjRate_;
    }

    /**
     * @dev Checks if a ratio is within valid bounds.
     * @param ratio The ratio to validate.
     * @return True if the ratio is valid, false otherwise.
     */
    function _isValidRatio(uint256 ratio) internal view returns (bool) {
        return ratio > 0 && ratio <= _poolParams.maxCurrentRatio;
    }

    /**
     * @dev Validates that current price is within acceptable slippage of expected price.
     * @param expectedSqrtPriceX96 The price user expects.
     * @param maxPriceSlippage Maximum allowed deviation, same scale as LP fee (1000000 = 100%).
     */
    function _checkPriceSlippage(uint160 expectedSqrtPriceX96, uint24 maxPriceSlippage) internal view {
        // Skip check if no slippage protection requested
        if (expectedSqrtPriceX96 == 0) return;

        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);

        // Calculate absolute difference
        uint256 priceDiff = currentSqrtPriceX96 > expectedSqrtPriceX96
            ? currentSqrtPriceX96 - expectedSqrtPriceX96
            : expectedSqrtPriceX96 - currentSqrtPriceX96;

        // Check: priceDiff / expectedPrice <= maxSlippage / MAX_LP_FEE
        // Rearranged: priceDiff * MAX_LP_FEE <= expectedPrice * maxSlippage
        if (priceDiff * LPFeeLibrary.MAX_LP_FEE > uint256(expectedSqrtPriceX96) * maxPriceSlippage) {
            revert PriceSlippageExceeded(expectedSqrtPriceX96, currentSqrtPriceX96, maxPriceSlippage);
        }
    }

    /* REHYPOTHECATION INTERNAL FUNCTIONS */

    /**
     * @dev Transfers tokens from sender to this contract.
     * @param currency The currency to transfer.
     * @param amount The amount to transfer.
     */
    function _transferFromSender(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @dev Gets the total assets in the yield source for a currency.
     * @param currency The currency to query.
     * @return The amount of assets in the yield source.
     */
    function _getAmountInYieldSource(Currency currency) internal view returns (uint256) {
        YieldSourceState storage state = _yieldSourceState[currency];
        return ReHypothecationLib.getAmountInYieldSource(state.yieldSource, state.sharesOwned);
    }

    /**
     * @dev Converts shares to asset amounts for withdrawal (rounds down, protocol-favorable).
     * @param shares The number of shares to convert.
     * @return amount0 The amount of currency0 the user will receive.
     * @return amount1 The amount of currency1 the user will receive.
     */
    function _convertSharesToAmountsForWithdrawal(uint256 shares)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 currentTotalSupply = totalSupply();
        if (currentTotalSupply == 0) return (0, 0);

        uint256 totalAmount0 = _getAmountInYieldSource(_poolKey.currency0);
        uint256 totalAmount1 = _getAmountInYieldSource(_poolKey.currency1);

        return ReHypothecationLib.convertSharesToAmounts(shares, currentTotalSupply, totalAmount0, totalAmount1);
    }

    /**
     * @dev Converts shares to asset amounts for deposit (rounds up, protocol-favorable).
     *      First depositor case uses liquidity-based calculation with +1 wei protection.
     * @param shares The number of shares to mint.
     * @return amount0 The amount of currency0 required.
     * @return amount1 The amount of currency1 required.
     */
    function _convertSharesToAmountsForDeposit(uint256 shares)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 currentTotalSupply = totalSupply();

        if (currentTotalSupply == 0) {
            (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
            uint128 liquidityFromShares = shares.toUint128();
            (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
                currentSqrtPriceX96,
                TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickLower),
                TickMath.getSqrtPriceAtTick(_reHypothecationConfig.tickUpper),
                liquidityFromShares
            );
            return (amount0 + 1, amount1 + 1);
        }

        uint256 totalAmount0 = _getAmountInYieldSource(_poolKey.currency0);
        uint256 totalAmount1 = _getAmountInYieldSource(_poolKey.currency1);

        return ReHypothecationLib.convertSharesToAmountsRoundUp(shares, currentTotalSupply, totalAmount0, totalAmount1);
    }

    /**
     * @dev Deposits assets to the yield source for a currency.
     * @param currency The currency to deposit.
     * @param amount The amount to deposit.
     */
    function _depositToYieldSource(Currency currency, uint256 amount) internal virtual {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured();

        uint256 sharesReceived = ReHypothecationLib.depositToYieldSource(state.yieldSource, currency, amount);
        state.sharesOwned += sharesReceived;
    }

    /**
     * @dev Withdraws assets from the yield source to a recipient.
     * @param currency The currency to withdraw.
     * @param amount The amount to withdraw.
     * @param recipient The address to receive the assets.
     */
    function _withdrawFromYieldSourceTo(Currency currency, uint256 amount, address recipient) internal virtual {
        if (amount == 0) return;

        YieldSourceState storage state = _yieldSourceState[currency];
        if (state.yieldSource == address(0)) revert YieldSourceNotConfigured();

        uint256 sharesRedeemed = ReHypothecationLib.withdrawFromYieldSourceTo(state.yieldSource, amount, recipient);
        // Safe: subtraction only executes when sharesOwned > sharesRedeemed (explicit guard)
        unchecked {
            state.sharesOwned = state.sharesOwned > sharesRedeemed ? state.sharesOwned - sharesRedeemed : 0;
        }
    }

    /* JIT LIQUIDITY INTERNAL FUNCTIONS */

    /**
     * @dev Executes a JIT liquidity operation (add or remove).
     * @param key The pool key.
     * @param jitParams The JIT operation parameters.
     * @return The balance delta from the liquidity modification.
     */
    function _executeJitLiquidity(PoolKey calldata key, JitParams memory jitParams) internal returns (BalanceDelta) {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: jitParams.tickLower,
                tickUpper: jitParams.tickUpper,
                liquidityDelta: jitParams.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        return delta;
    }

    /**
     * @notice Compute JIT liquidity parameters for adding liquidity before a swap.
     */
    function _computeBeforeSwapJit() internal view returns (JitParams memory params) {
        // Check if JIT is configured - both yield sources must be set
        if (
            _yieldSourceState[_poolKey.currency0].yieldSource == address(0)
                || _yieldSourceState[_poolKey.currency1].yieldSource == address(0)
        ) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }

        if (_reHypothecationConfig.tickLower == _reHypothecationConfig.tickUpper) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }

        // Get available amounts from yield sources
        uint256 amount0Available = _getAmountInYieldSource(_poolKey.currency0);
        uint256 amount1Available = _getAmountInYieldSource(_poolKey.currency1);

        if (amount0Available == 0) {
            if (amount1Available == 0) {
                return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
            }
        }

        // Compute liquidity to add
        (uint160 currentSqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        uint128 liquidityToAdd = ReHypothecationLib.getLiquidityToUse(
            currentSqrtPriceX96,
            _reHypothecationConfig.tickLower,
            _reHypothecationConfig.tickUpper,
            amount0Available,
            amount1Available
        );

        // Safety margin
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
     */
    function _computeAfterSwapJit() internal view returns (JitParams memory params) {
        bytes32 positionKey = Position.calculatePositionKey(
            address(this), _reHypothecationConfig.tickLower, _reHypothecationConfig.tickUpper, bytes32(0)
        );
        uint128 currentLiquidity = StateLibrary.getPositionLiquidity(poolManager, _poolId, positionKey);

        if (currentLiquidity == 0) {
            return JitParams({tickLower: 0, tickUpper: 0, liquidityDelta: 0, shouldExecute: false});
        }

        return JitParams({
            tickLower: _reHypothecationConfig.tickLower,
            tickUpper: _reHypothecationConfig.tickUpper,
            liquidityDelta: -int256(uint256(currentLiquidity)),
            shouldExecute: true
        });
    }

    /**
     * @notice Resolve hook delta for a currency (following OpenZeppelin's pattern).
     * @dev Takes or settles any pending currencyDelta with the PoolManager.
     *
     * SECURITY (Reentrancy): External calls to yield source occur before state updates, but
     * reentrancy is prevented by: (1) public entry points use nonReentrant modifier,
     * (2) hook callbacks are protected by Uniswap V4's unlock pattern,
     * (3) yield sources are trusted (configured by AccessManager).
     */
    function _resolveHookDelta(Currency currency) internal virtual {
        int256 currencyDelta = poolManager.currencyDelta(address(this), currency);
        if (currencyDelta > 0) {
            // Hook is owed tokens - take and deposit to yield source
            // Safe: currencyDelta > 0 guarantees positive value
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(currencyDelta);
            currency.take(poolManager, address(this), amount, false);
            _depositToYieldSource(currency, amount);
        } else if (currencyDelta < 0) {
            // Hook owes tokens - withdraw from yield source and settle
            // Safe: currencyDelta < 0
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount = uint256(-currencyDelta);
            _withdrawFromYieldSourceTo(currency, amount, address(this));
            currency.settle(poolManager, address(this), amount, false);
        }
    }

    /* MODIFIER HELPERS */

    /**
     * @dev Reverts if the pool is already configured.
     */
    function _poolUnconfigured() internal view {
        if (_poolConfig.isConfigured) revert PoolAlreadyConfigured();
    }

    /**
     * @dev Reverts if the pool is not configured.
     */
    function _poolConfigured() internal view {
        if (!_poolConfig.isConfigured) revert PoolNotConfigured();
    }
}
