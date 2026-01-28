// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/* LOCAL IMPORTS */
import {IPSM3} from "./interfaces/IPSM3.sol";
import {IRateProvider} from "./interfaces/IRateProvider.sol";
import {IAlphix4626WrapperSky} from "./interfaces/IAlphix4626WrapperSky.sol";

/**
 * @title Alphix4626WrapperSky
 * @author Alphix
 * @notice ERC4626 wrapper for sUSDS yield exposure on Base via Spark PSM.
 *
 * @dev This contract provides yield exposure to sUSDS while users deposit/withdraw USDS.
 *
 * ## Architecture
 * - ERC4626 Asset: USDS (18 decimals)
 * - Internally holds: sUSDS (18 decimals) for yield
 * - Swaps via PSM: USDS ↔ sUSDS
 * - Yield tracked via rate provider (27 decimals)
 *
 * ## Key Particularities
 * - Rate provider returns USDS per sUSDS (27 decimals)
 * - Fees calculated on yield (rate appreciation)
 *
 * ## ERC4626 Deviations
 * - `mint()` is disabled and reverts with `NotImplemented`.
 * - `previewMint()` reverts since mint is disabled.
 * - `deposit()` requires `receiver == msg.sender` (no depositing on behalf of others).
 * - `withdraw()`/`redeem()` require `owner == msg.sender` (no allowance-based withdrawals).
 *
 * ## Trust Model
 * Owner has full control, hooks have deposit/withdraw access.
 */
contract Alphix4626WrapperSky is ERC4626, IAlphix4626WrapperSky, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* STORAGE */

    /// CONSTANTS ///

    /**
     * @notice Maximum fee in hundredths of a bip (1_000_000 = 100%).
     */
    uint24 private constant MAX_FEE = 1_000_000;

    /**
     * @notice Precision for rate calculations (27 decimals, matches rate provider).
     */
    uint256 private constant RATE_PRECISION = 1e27;

    /**
     * @notice Minimum seed liquidity required at deployment (0.001 USDS).
     */
    uint256 private constant MIN_SEED_LIQUIDITY = 1e15;

    /**
     * @notice Minimum acceptable rate from rate provider (prevents division issues).
     */
    uint256 private constant MIN_RATE = 1e21;

    /**
     * @notice Maximum acceptable rate from rate provider (sanity check).
     */
    uint256 private constant MAX_RATE = 1e30;

    /**
     * @notice Maximum allowed rate change per transaction (1% = 100 basis points).
     * @dev Applies to BOTH increases and decreases to prevent manipulation.
     */
    uint256 private constant MAX_RATE_CHANGE_BPS = 100;

    /// IMMUTABLES ///

    /**
     * @notice The Spark PSM3 contract.
     */
    IPSM3 public immutable PSM;

    /**
     * @notice The rate provider for sUSDS/USDS conversion.
     */
    IRateProvider public immutable RATE_PROVIDER;

    /**
     * @notice The USDS token (18 decimals) - ERC4626 asset.
     */
    IERC20 public immutable USDS;

    /**
     * @notice The sUSDS token (18 decimals) - yield-bearing token held internally.
     */
    IERC20 public immutable SUSDS;

    /// VARIABLES ///

    /**
     * @notice The current fee in hundredths of a bip.
     * @dev 100_000 = 10%, 1_000_000 = 100%.
     */
    uint24 private _fee;

    /**
     * @notice The address where collected fees are sent.
     */
    address private _yieldTreasury;

    /**
     * @notice Set of authorized Alphix Hook addresses.
     */
    EnumerableSet.AddressSet private _alphixHooks;

    /**
     * @notice Last recorded sUSDS/USDS rate (27 decimal precision).
     * @dev Rate = USDS per sUSDS. Used to calculate yield.
     */
    uint256 private _lastRate;

    /**
     * @notice Accumulated fees in sUSDS (18 decimals).
     */
    uint128 private _accumulatedFees;

    /**
     * @notice Referral code for PSM swaps.
     */
    uint256 private _referralCode;

    /* MODIFIERS */

    /**
     * @dev Restricts access to authorized Alphix Hooks or the owner.
     */
    modifier onlyAlphixHookOrOwner() {
        _checkAlphixHookOrOwner();
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @notice Deploys the Alphix4626WrapperSky.
     * @param psm The Spark PSM3 address.
     * @param yieldTreasury The address where fees are sent.
     * @param shareName The name of the vault share token.
     * @param shareSymbol The symbol of the vault share token.
     * @param initialFee The initial fee in hundredths of a bip.
     * @param seedLiquidityUsds The initial USDS amount to seed the vault (prevents inflation attacks).
     * @param referralCode The referral code for PSM swaps (can be 0).
     */
    constructor(
        address psm,
        address yieldTreasury,
        string memory shareName,
        string memory shareSymbol,
        uint24 initialFee,
        uint256 seedLiquidityUsds,
        uint256 referralCode
    ) ERC4626(IERC20(IPSM3(psm).usds())) ERC20(shareName, shareSymbol) Ownable(msg.sender) {
        if (psm == address(0) || yieldTreasury == address(0)) revert InvalidAddress();
        if (seedLiquidityUsds < MIN_SEED_LIQUIDITY) revert InsufficientSeedLiquidity();

        PSM = IPSM3(psm);
        RATE_PROVIDER = IRateProvider(PSM.rateProvider());
        USDS = IERC20(PSM.usds());
        SUSDS = IERC20(PSM.susds());
        _yieldTreasury = yieldTreasury;
        _referralCode = referralCode;

        // Set initial fee
        _setFee(initialFee);

        // Initialize rate tracking
        uint256 initialRate = RATE_PROVIDER.getConversionRate();
        _validateRate(initialRate);
        _lastRate = initialRate;

        // Seed liquidity: USDS → sUSDS
        USDS.safeTransferFrom(msg.sender, address(this), seedLiquidityUsds);
        uint256 susdsExpected = PSM.previewSwapExactIn(address(USDS), address(SUSDS), seedLiquidityUsds);
        USDS.approve(address(PSM), seedLiquidityUsds);
        PSM.swapExactIn(address(USDS), address(SUSDS), seedLiquidityUsds, susdsExpected, address(this), referralCode);

        // Mint initial shares to deployer to prevent inflation attacks (in 1:1 ratio)
        _mint(msg.sender, seedLiquidityUsds);

        emit Deposit(msg.sender, msg.sender, seedLiquidityUsds, seedLiquidityUsds);
        emit YieldTreasuryUpdated(address(0), yieldTreasury);
    }

    /* ERC4626 */

    /// MAIN FUNCTIONS ///

    /**
     * @inheritdoc ERC4626
     * @dev Deposits USDS and swaps to sUSDS. Only callable by authorized hooks or owner.
     *      The receiver must be the caller (receiver == msg.sender).
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        onlyAlphixHookOrOwner
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (receiver != msg.sender) revert InvalidReceiver();
        _accrueYield();
        shares = _convertToShares(assets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();
        _deposit(msg.sender, msg.sender, assets, shares);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Not implemented - reverts if called. Use {deposit} instead.
     */
    function mint(uint256, address) public pure override returns (uint256) {
        revert NotImplemented();
    }

    /**
     * @inheritdoc ERC4626
     * @dev Withdraws USDS by swapping from sUSDS. Only callable by authorized hooks or owner.
     *      The caller must be the owner of the shares (owner_ == msg.sender).
     *      The receiver can be any address - hooks can withdraw to any destination.
     */
    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        onlyAlphixHookOrOwner
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (owner_ != msg.sender) revert CallerNotOwner();
        _accrueYield();
        if (assets > maxWithdraw(msg.sender)) revert WithdrawExceedsMax();
        shares = _convertToShares(assets, Math.Rounding.Ceil);
        if (shares == 0) revert ZeroShares();
        _withdraw(msg.sender, receiver, msg.sender, assets, shares);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Redeems shares for USDS. Only callable by authorized hooks or owner.
     *      The caller must be the owner of the shares (owner_ == msg.sender).
     *      The receiver can be any address - hooks can redeem to any destination.
     */
    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        onlyAlphixHookOrOwner
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        if (owner_ != msg.sender) revert CallerNotOwner();
        _accrueYield();
        if (shares > maxRedeem(msg.sender)) revert RedeemExceedsMax();
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        if (assets == 0) revert ZeroAssets();
        _withdraw(msg.sender, receiver, msg.sender, assets, shares);
    }

    /// VIEW FUNCTIONS ///

    /**
     * @inheritdoc ERC4626
     * @dev Returns 0 if paused or caller is not authorized (hook or owner).
     */
    function maxDeposit(address caller) public view override returns (uint256) {
        if (paused() || !_isAlphixHookOrOwner(caller)) return 0;
        return type(uint256).max;
    }

    /**
     * @inheritdoc ERC4626
     */
    function maxMint(address) public pure override returns (uint256) {
        return 0; // Mint is disabled
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns 0 if paused or caller is not authorized (hook or owner).
     */
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused() || !_isAlphixHookOrOwner(owner_)) return 0;
        return _convertToAssets(balanceOf(owner_), Math.Rounding.Floor);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns 0 if paused or caller is not authorized (hook or owner).
     */
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused() || !_isAlphixHookOrOwner(owner_)) return 0;
        return balanceOf(owner_);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Mint is not supported.
     */
    function previewMint(uint256) public pure override returns (uint256) {
        revert NotImplemented();
    }

    /**
     * @inheritdoc ERC4626
     * @dev Returns total assets in USDS terms (18 decimals).
     */
    function totalAssets() public view override returns (uint256) {
        uint256 netSusds = _getNetSusds();
        if (netSusds == 0) return 0;
        // Convert sUSDS to USDS using rate provider
        // rate = USDS per sUSDS (27 decimals)
        uint256 rate = RATE_PROVIDER.getConversionRate();
        return netSusds.mulDiv(rate, RATE_PRECISION);
    }

    /// INTERNAL FUNCTIONS ///

    /**
     * @notice Returns the net sUSDS balance (total minus claimable fees).
     * @dev Used by conversion functions to compute shares/assets in sUSDS space.
     */
    function _getNetSusds() internal view returns (uint256) {
        uint256 totalSusds = SUSDS.balanceOf(address(this));
        if (totalSusds == 0) return 0;
        uint256 claimableFees = _getClaimableFees();
        return totalSusds > claimableFees ? totalSusds - claimableFees : 0;
    }

    /**
     * @notice Converts assets (USDS) to shares via sUSDS space.
     * @dev Overrides OZ's default to ensure ERC4626 roundtrip safety.
     *
     *      Computing in sUSDS space ensures that redeem(shares) → deposit(assets)
     *      always returns shares' ≤ shares, which is required by ERC4626.
     *
     *      The tradeoff is that convertToShares → convertToAssets roundtrip
     *      may lose up to 3-4 wei due to 4 floor divisions (2 per direction).
     *      This is acceptable as these are view functions for informational purposes.
     *
     * @param assets The amount of USDS to convert.
     * @param rounding The rounding direction (Floor for deposits, Ceil for withdrawals).
     * @return The equivalent shares.
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return assets; // 1:1 for empty vault (protected by seed liquidity)

        uint256 netSusds = _getNetSusds();
        uint256 rate = RATE_PROVIDER.getConversionRate();
        _validateRate(rate);

        uint256 susdsValue = assets.mulDiv(RATE_PRECISION, rate, rounding);

        return susdsValue.mulDiv(supply + 1, netSusds + 1, rounding);
    }

    /**
     * @notice Converts shares to assets (USDS) via sUSDS space.
     * @dev Overrides OZ's default to maintain consistency with _convertToShares.
     *
     * @param shares The amount of shares to convert.
     * @param rounding The rounding direction (Floor for redeems, Ceil for mints).
     * @return The equivalent USDS amount.
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return shares; // 1:1 for empty vault

        uint256 netSusds = _getNetSusds();
        uint256 rate = RATE_PROVIDER.getConversionRate();
        _validateRate(rate);

        // Step 1: Calculate sUSDS value of shares
        uint256 susdsValue = shares.mulDiv(netSusds + 1, supply + 1, rounding);

        // Step 2: Convert sUSDS to USDS
        return susdsValue.mulDiv(rate, RATE_PRECISION, rounding);
    }

    /**
     * @notice Internal deposit: transfer USDS and swap to sUSDS.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        // Transfer USDS from caller
        USDS.safeTransferFrom(caller, address(this), assets);

        // Swap USDS → sUSDS
        uint256 susdsExpected = PSM.previewSwapExactIn(address(USDS), address(SUSDS), assets);
        USDS.approve(address(PSM), assets);
        PSM.swapExactIn(address(USDS), address(SUSDS), assets, susdsExpected, address(this), _referralCode);

        // Mint wrapper shares
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @notice Internal withdraw: swap sUSDS to USDS and transfer to receiver.
     */
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        // Burn wrapper shares
        _burn(owner_, shares);

        // Calculate sUSDS needed
        uint256 susdsNeeded = PSM.previewSwapExactOut(address(SUSDS), address(USDS), assets);

        // Swap sUSDS → USDS directly to receiver
        SUSDS.approve(address(PSM), susdsNeeded);
        PSM.swapExactOut(address(SUSDS), address(USDS), assets, susdsNeeded, receiver, _referralCode);

        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    /* FEE RELATED */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function setFee(uint24 newFee) external onlyOwner {
        _accrueYield();
        _setFee(newFee);
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function setYieldTreasury(address newYieldTreasury) external override onlyOwner {
        if (newYieldTreasury == address(0)) revert InvalidAddress();
        emit YieldTreasuryUpdated(_yieldTreasury, newYieldTreasury);
        _yieldTreasury = newYieldTreasury;
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function collectFees() external override onlyOwner nonReentrant {
        if (_yieldTreasury == address(0)) revert InvalidAddress();
        _accrueYield();
        uint256 fees = _accumulatedFees;
        if (fees == 0) revert ZeroAmount();
        _accumulatedFees = 0;
        SUSDS.safeTransfer(_yieldTreasury, fees);
        emit FeesCollected(fees);
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     * @dev Sets _lastRate directly to the current rate and accrues yield.
     *      Bypasses the circuit breaker check to unblock operations.
     */
    function syncRate() external override onlyOwner {
        uint256 currentRate = RATE_PROVIDER.getConversionRate();
        _validateRate(currentRate);
        uint256 lastRate = _lastRate;

        // Revert if no sync needed
        if (lastRate == 0 || currentRate == lastRate) revert NoSyncNeeded();

        // Accrue yield without circuit breaker check
        if (currentRate > lastRate) {
            // Rate increased = yield earned
            uint256 totalSusds = SUSDS.balanceOf(address(this));
            uint256 netSusds = totalSusds > _accumulatedFees ? totalSusds - _accumulatedFees : 0;
            if (netSusds > 0) {
                uint256 yieldUsds = netSusds.mulDiv(currentRate - lastRate, RATE_PRECISION);
                uint256 feeUsds = yieldUsds.mulDiv(_fee, MAX_FEE);
                uint256 feeSusds = feeUsds.mulDiv(RATE_PRECISION, currentRate);
                _accumulatedFees += SafeCast.toUint128(feeSusds);
                emit YieldAccrued(yieldUsds, feeSusds, currentRate);
            }
        }
        // For negative yield (slash), no fees to accrue

        _lastRate = currentRate;
        emit RateSynced(lastRate, currentRate, currentRate);
    }

    /// VIEW FUNCTIONS ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function getYieldTreasury() external view override returns (address) {
        return _yieldTreasury;
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function getClaimableFees() external view override returns (uint256) {
        return _getClaimableFees();
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function getLastRate() external view override returns (uint256) {
        return _lastRate;
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function getFee() external view override returns (uint256) {
        return _fee;
    }

    /// INTERNAL FUNCTIONS ///

    /**
     * @notice Internal fee setter.
     */
    function _setFee(uint24 newFee) internal {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        emit FeeUpdated(_fee, newFee);
        _fee = newFee;
    }

    /**
     * @notice Accrues yield based on rate provider rate appreciation.
     * @dev Called before deposit/withdraw to ensure accurate accounting.
     *      Uses net sUSDS (balance minus accumulated fees) for yield calculation.
     *      Includes circuit breaker: reverts if rate changes >5%.
     */
    function _accrueYield() internal {
        uint256 currentRate = RATE_PROVIDER.getConversionRate();
        _validateRate(currentRate);
        uint256 lastRate = _lastRate;

        // Circuit breaker: check rate change bounds (skip on first accrual)
        if (lastRate != 0 && currentRate != lastRate) {
            _checkRateCircuitBreaker(lastRate, currentRate);
        }

        if (currentRate > lastRate) {
            // Rate increased = yield earned
            uint256 totalSusds = SUSDS.balanceOf(address(this));
            // Use net sUSDS (exclude already accumulated fees)
            uint256 netSusds = totalSusds > _accumulatedFees ? totalSusds - _accumulatedFees : 0;
            if (netSusds > 0) {
                // Newly generated yield in USDS terms
                uint256 yieldUsds = netSusds.mulDiv(currentRate - lastRate, RATE_PRECISION);
                // Fee in USDS terms
                uint256 feeUsds = yieldUsds.mulDiv(_fee, MAX_FEE);
                // Fee in sUSDS terms = feeUsds * 1e27 / currentRate
                uint256 feeSusds = feeUsds.mulDiv(RATE_PRECISION, currentRate);
                // Update storage
                _accumulatedFees += SafeCast.toUint128(feeSusds);
                emit YieldAccrued(yieldUsds, feeSusds, currentRate);
            }
            // Always update rate when it increases to prevent stale rate causing retroactive fee accrual
            _lastRate = currentRate;
        } else if (currentRate < lastRate) {
            // Negative yield: update rate (already passed circuit breaker check)
            _lastRate = currentRate;
        }
    }

    /**
     * @notice Internal view function to calculate claimable fees.
     * @dev Returns accumulated fees plus pending fees from unrealized yield.
     */
    function _getClaimableFees() internal view returns (uint256) {
        uint256 currentRate = RATE_PROVIDER.getConversionRate();
        uint256 lastRate = _lastRate;

        // If no positive yield, return only accumulated fees
        if (currentRate <= lastRate) return _accumulatedFees;

        uint256 totalSusds = SUSDS.balanceOf(address(this));
        uint256 netSusds = totalSusds > _accumulatedFees ? totalSusds - _accumulatedFees : 0;
        if (netSusds == 0) return _accumulatedFees;

        // Calculate pending fees from unrealized yield
        uint256 yieldUsds = netSusds.mulDiv(currentRate - lastRate, RATE_PRECISION);
        uint256 feeUsds = yieldUsds.mulDiv(_fee, MAX_FEE);
        uint256 pendingFeeSusds = feeUsds.mulDiv(RATE_PRECISION, currentRate);

        return _accumulatedFees + pendingFeeSusds;
    }

    /* REFERRAL CODE */

    /// GETTER ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function getReferralCode() external view override returns (uint256) {
        return _referralCode;
    }

    /// SETTER ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function setReferralCode(uint256 newReferralCode) external onlyOwner {
        emit ReferralCodeUpdated(_referralCode, newReferralCode);
        _referralCode = newReferralCode;
    }

    /* ALPHIX HOOKS MANAGEMENT */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function addAlphixHook(address hook) external override onlyOwner {
        if (hook == address(0)) revert InvalidAddress();
        if (!_alphixHooks.add(hook)) revert HookAlreadyExists();
        emit AlphixHookAdded(hook);
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function removeAlphixHook(address hook) external override onlyOwner {
        if (!_alphixHooks.remove(hook)) revert HookDoesNotExist();
        emit AlphixHookRemoved(hook);
    }

    /// VIEW FUNCTIONS ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function isAlphixHook(address hook) external view override returns (bool) {
        return _alphixHooks.contains(hook);
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function getAllAlphixHooks() external view override returns (address[] memory) {
        return _alphixHooks.values();
    }

    /// INTERNAL FUNCTIONS ///

    /**
     * @notice Reverts if the caller is not an authorized Alphix Hook or the owner.
     */
    function _checkAlphixHookOrOwner() internal view {
        if (!_isAlphixHookOrOwner(msg.sender)) revert UnauthorizedCaller();
    }

    /**
     * @notice Checks if an address is an authorized Alphix Hook or the owner.
     */
    function _isAlphixHookOrOwner(address account) internal view returns (bool) {
        return _alphixHooks.contains(account) || account == owner();
    }

    /* PAUSABLE */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /* TOKEN RESCUE */

    /**
     * @inheritdoc IAlphix4626WrapperSky
     */
    function rescueTokens(address token, uint256 amount) external override onlyOwner nonReentrant {
        if (token == address(SUSDS)) revert InvalidToken();
        if (_yieldTreasury == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(_yieldTreasury, amount);
        emit TokensRescued(token, amount);
    }

    /* OWNERSHIP */

    /**
     * @dev Disables renouncing ownership.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /* INTERNAL HELPERS */

    /**
     * @dev Validates that the rate is within acceptable bounds.
     * @param rate The rate to validate (27 decimal precision).
     */
    function _validateRate(uint256 rate) internal pure {
        if (rate < MIN_RATE || rate > MAX_RATE) revert InvalidRate();
    }

    /**
     * @dev Validates rate change is within acceptable bounds (5% max).
     * @dev Reverts if rate change exceeds threshold, blocking the transaction.
     * @param lastRate The previous recorded rate.
     * @param currentRate The new rate from the rate provider.
     */
    function _checkRateCircuitBreaker(uint256 lastRate, uint256 currentRate) internal {
        uint256 rateChange;
        if (currentRate > lastRate) {
            rateChange = currentRate - lastRate;
        } else {
            rateChange = lastRate - currentRate;
        }

        uint256 maxAllowedChange = (lastRate * MAX_RATE_CHANGE_BPS) / 10_000;

        if (rateChange > maxAllowedChange) {
            uint256 changeBps = (rateChange * 10_000) / lastRate;
            emit CircuitBreakerTriggered(lastRate, currentRate, changeBps);
            revert ExcessiveRateChange(lastRate, currentRate, changeBps);
        }
    }
}
