// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/* AAVE IMPORTS */
import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {IPool} from "@aave-v3-core/interfaces/IPool.sol";
import {IAToken} from "@aave-v3-core/interfaces/IAToken.sol";
import {WadRayMath} from "@aave-v3-core/protocol/libraries/math/WadRayMath.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {IncentivizedERC20} from "@aave-v3-core/protocol/tokenization/base/IncentivizedERC20.sol";
import {IRewardsController} from "@aave-v3-periphery/rewards/interfaces/IRewardsController.sol";

/* LOCAL IMPORTS */
import {IAlphix4626WrapperAave} from "./interfaces/IAlphix4626WrapperAave.sol";

/**
 * @title Alphix4626WrapperAave
 * @author Alphix
 * @notice Alphix 4626 Wrapper for Aave V3.
 * @dev This contract is designed from the start to be immutable (non-upgradeable).
 *      It allows Alphix to add a fee on top of the Aave interest rates.
 *
 * ## ERC4626 Deviations
 * This wrapper intentionally deviates from ERC4626 in the following ways:
 * - `mint()` is disabled and reverts with `NotImplemented`. Use `deposit()` instead.
 * - `previewMint()` reverts since mint is disabled.
 * - `deposit()` requires `receiver == msg.sender` (no depositing on behalf of others).
 * - `withdraw()`/`redeem()` require `owner == msg.sender` (no allowance-based withdrawals).
 *
 * ## Trust Model
 * - **Owner**: Has full control over fees (up to 100%), treasury address, hook management,
 *   and pause functionality. Uses Ownable2Step for safe ownership transfers.
 *   `renounceOwnership()` is disabled to prevent accidental loss of admin functions.
 * - **Alphix Hooks**: Authorized contracts that can deposit/withdraw on behalf of users.
 *   Hooks have full access to deposit and withdraw any amount. Only audited, trusted
 *   contracts should be added as hooks. Compromised hooks can drain all funds.
 * - **Users**: Should monitor admin actions (fee changes, treasury updates, hook additions)
 *   as there are no timelocks on these operations.
 */
contract Alphix4626WrapperAave is ERC4626, IAlphix4626WrapperAave, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /* STORAGE */

    /// Constants ///

    /**
     * @notice The fee is represented in hundredths of a bip, so the max is 100%.
     */
    uint24 private constant MAX_FEE = 1_000_000;

    /**
     * @notice The referral code to use when depositing into Aave V3.
     * @dev Internal to allow child contracts (e.g., WETH wrapper) to use it.
     */
    uint16 internal constant REFERRAL_CODE = 0;

    /**
     * @notice Bit position of the supply cap in Aave V3 reserve configuration map.
     */
    uint256 private constant AAVE_SUPPLY_CAP_BIT_POSITION = 116;

    /*
     * @notice Aave V3 reserve configuration masks.
     */
    uint256 private constant AAVE_ACTIVE_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFF;
    uint256 private constant AAVE_FROZEN_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFDFFFFFFFFFFFFFF;
    uint256 private constant AAVE_PAUSED_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFFFFFFFFF;
    uint256 private constant AAVE_SUPPLY_CAP_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFF000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    /// Immutables ///

    /**
     * @notice The pool addresses provider for Aave V3.
     */
    IPoolAddressesProvider public immutable POOL_ADDRESSES_PROVIDER;

    /**
     * @notice The Aave V3 pool.
     */
    IPool public immutable AAVE_POOL;

    /**
     * @notice The Aave V3 aToken.
     */
    IAToken public immutable ATOKEN;

    /**
     * @notice The asset of the wrapper (cached for gas efficiency).
     */
    IERC20 public immutable ASSET;

    /// Variables ///

    /**
     * @notice Set of authorized Alphix Hook addresses.
     * @dev Uses EnumerableSet for O(1) add/remove/contains operations.
     */
    EnumerableSet.AddressSet private _alphixHooks;

    /**
     * @notice Total aToken balance in the wrapper, including fees.
     * @dev Internal to allow child contracts (e.g., WETH wrapper) to update after ETH operations.
     */
    uint128 internal _lastWrapperBalance;

    /**
     * @notice Fees accrued in the wrapper since last update.
     * @dev Internal to allow child contracts to access for fee calculations.
     */
    uint128 internal _accumulatedFees;

    /**
     * @notice The fee (in hundredths of a bip) to be charged on yield.
     * @dev Internal to allow child contracts to access for fee calculations.
     */
    uint24 internal _fee;

    /**
     * @notice The address where fees are sent when collected.
     * @dev Internal to allow child contracts to access for validation.
     */
    address internal _yieldTreasury;

    /* MODIFIERS */

    /**
     * @notice Modifier to restrict access to only registered Alphix Hooks or the owner.
     */
    modifier onlyAlphixHookOrOwner() {
        _checkAlphixHookOrOwner();
        _;
    }

    /* CONSTRUCTOR */

    /**
     * @notice Constructs the 4626 Wrapper.
     * @param asset_ The asset which can be supplied and withdrawn (e.g., USDC).
     * @param yieldTreasury_ The address where fees are sent when collected.
     * @param poolAddressesProvider_ The Aave V3 Pool Addresses Provider.
     * @param shareName The name of the share of the 4626 Wrapper.
     * @param shareSymbol The symbol of the share of the 4626 Wrapper.
     * @param initialFee The initial fee (in hundredths of a bip).
     * @param seedLiquidity The seed amount of asset to deposit to prevent frontrunning attacks.
     * @dev The owner is set to the deployer address. Alphix Hooks must be added post-deployment.
     */
    constructor(
        address asset_,
        address yieldTreasury_,
        address poolAddressesProvider_,
        string memory shareName,
        string memory shareSymbol,
        uint24 initialFee,
        uint256 seedLiquidity
    ) ERC4626(IERC20(asset_)) ERC20(shareName, shareSymbol) Ownable(msg.sender) {
        if (asset_ == address(0) || poolAddressesProvider_ == address(0) || yieldTreasury_ == address(0)) {
            revert InvalidAddress();
        }
        if (seedLiquidity == 0) revert ZeroSeedLiquidity();

        ASSET = IERC20(asset_);
        POOL_ADDRESSES_PROVIDER = IPoolAddressesProvider(poolAddressesProvider_);
        AAVE_POOL = IPool(POOL_ADDRESSES_PROVIDER.getPool());

        address aTokenAddress = AAVE_POOL.getReserveData(asset_).aTokenAddress;
        if (aTokenAddress == address(0)) revert UnsupportedAsset();
        ATOKEN = IAToken(aTokenAddress);

        _setFee(initialFee);
        _yieldTreasury = yieldTreasury_;

        IERC20(asset_).forceApprove(address(AAVE_POOL), type(uint256).max);

        if (seedLiquidity > maxDeposit(msg.sender)) revert DepositExceedsMax();
        _accrueYield();
        // Seed deposit at 1:1 ratio (since totalSupply == 0) to prevent frontrunning attacks
        _deposit(msg.sender, msg.sender, seedLiquidity, seedLiquidity);
    }

    /* ERC4626 */

    /// MAIN FUNCTIONS ///

    /**
     * @inheritdoc ERC4626
     * @notice Only registered Alphix Hooks or the owner can deposit into the wrapper.
     * @dev The receiver must be the caller (receiver == msg.sender).
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
        if (assets > maxDeposit(msg.sender)) revert DepositExceedsMax();
        _accrueYield();
        shares = _convertToShares(assets, Math.Rounding.Floor);
        if (shares == 0) revert ZeroShares();
        _deposit(msg.sender, msg.sender, assets, shares);
    }

    /**
     * @inheritdoc ERC4626
     * @notice Not implemented - reverts if called. Use {deposit} instead.
     */
    function mint(uint256, address) public pure override returns (uint256) {
        revert NotImplemented();
    }

    /**
     * @inheritdoc ERC4626
     * @notice Only registered Alphix Hooks or the owner can withdraw from the wrapper.
     * @dev The caller must be the owner of the shares (owner_ == msg.sender).
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
     * @notice Only registered Alphix Hooks or the owner can redeem from the wrapper.
     * @dev The caller must be the owner of the shares (owner_ == msg.sender).
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
     * @notice Only authorized Alphix Hooks or the owner can deposit into the wrapper.
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (!_isAlphixHookOrOwner(receiver)) return 0;
        return _maxAssetsSuppliableToAave();
    }

    /**
     * @inheritdoc ERC4626
     * @notice Returns 0 since mint is not implemented.
     */
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /**
     * @inheritdoc ERC4626
     * @notice Only authorized Alphix Hooks or the owner can withdraw from the wrapper.
     */
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (!_isAlphixHookOrOwner(owner_)) return 0;
        uint256 maxWithdrawable = _maxAssetsWithdrawableFromAave();
        return maxWithdrawable == 0 ? 0 : maxWithdrawable.min(_convertToAssets(balanceOf(owner_), Math.Rounding.Floor));
    }

    /**
     * @inheritdoc ERC4626
     * @notice Only authorized Alphix Hooks or the owner can redeem from the wrapper.
     */
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (!_isAlphixHookOrOwner(owner_)) return 0;
        uint256 maxWithdrawable = _maxAssetsWithdrawableFromAave();
        return maxWithdrawable == 0 ? 0 : _convertToShares(maxWithdrawable, Math.Rounding.Floor).min(balanceOf(owner_));
    }

    /**
     * @inheritdoc ERC4626
     * @notice Not implemented - reverts if called since mint is disabled.
     */
    function previewMint(uint256) public pure override returns (uint256) {
        revert NotImplemented();
    }

    /**
     * @inheritdoc ERC4626
     * @notice The total assets owned by the wrapper and held in Aave's pool, net of fees.
     */
    function totalAssets() public view override returns (uint256) {
        return ATOKEN.balanceOf(address(this)) - _getClaimableFees();
    }

    /// INTERNAL FUNCTIONS ///

    /**
     * @inheritdoc ERC4626
     * @dev Supplies assets to Aave and mints shares to the receiver.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        ASSET.safeTransferFrom(caller, address(this), assets);
        AAVE_POOL.supply(address(ASSET), assets, address(this), REFERRAL_CODE);
        _lastWrapperBalance = uint128(ATOKEN.balanceOf(address(this)));
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /**
     * @inheritdoc ERC4626
     * @dev Burns shares and withdraws assets from Aave and sends them to the receiver.
     * @notice Assumes caller is owner as enforced in {withdraw} and {redeem}.
     */
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        _burn(owner_, shares);
        AAVE_POOL.withdraw(address(ASSET), assets, receiver);
        _lastWrapperBalance = uint128(ATOKEN.balanceOf(address(this)));
        emit Withdraw(caller, receiver, owner_, assets, shares);
    }

    /* FEE RELATED */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function setFee(uint24 newFee) public override onlyOwner {
        _accrueYield();
        _setFee(newFee);
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function setYieldTreasury(address newYieldTreasury) public override onlyOwner {
        if (newYieldTreasury == address(0)) revert InvalidAddress();
        emit YieldTreasuryUpdated(_yieldTreasury, newYieldTreasury);
        _yieldTreasury = newYieldTreasury;
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function collectFees() public override onlyOwner nonReentrant {
        if (_yieldTreasury == address(0)) revert InvalidAddress();
        _accrueYield();
        uint256 feesCollected = _accumulatedFees;
        if (feesCollected == 0) revert ZeroAmount();
        _accumulatedFees = 0;
        IERC20(address(ATOKEN)).safeTransfer(_yieldTreasury, feesCollected);
        _lastWrapperBalance = uint128(ATOKEN.balanceOf(address(this)));
        emit FeesCollected(feesCollected, _lastWrapperBalance);
    }

    /// VIEW FUNCTIONS ///

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function getYieldTreasury() public view override returns (address) {
        return _yieldTreasury;
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function getClaimableFees() public view override returns (uint256) {
        return _getClaimableFees();
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function getLastWrapperBalance() public view override returns (uint256) {
        return _lastWrapperBalance;
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function getFee() public view override returns (uint256) {
        return _fee;
    }

    /// INTERNAL FUNCTIONS ///

    /**
     * @notice Sets the fee rate.
     * @param newFee The new fee in hundredths of a bip.
     * @dev Reverts if the new fee exceeds MAX_FEE.
     */
    function _setFee(uint24 newFee) internal {
        if (newFee > MAX_FEE) revert FeeTooHigh();
        emit FeeUpdated(_fee, newFee);
        _fee = newFee;
    }

    /**
     * @notice Accrues yield and updates accumulated fees.
     * @dev Called before any state-changing operation that depends on accurate fee accounting.
     *      Emits {YieldAccrued} if new yield was generated since last accrual.
     *      Emits {NegativeYield} if balance decreased (e.g., slashing), reducing fees to cover loss.
     *
     *      Fee calculation splits yield between fee-owned and user-owned portions:
     *      - Yield on fee-owned aTokens: 100% goes to fees (treasury's yield)
     *      - Yield on user-owned aTokens: _fee% goes to fees
     */
    function _accrueYield() internal {
        uint256 newWrapperBalance = ATOKEN.balanceOf(address(this));
        uint256 lastBalance = _lastWrapperBalance;
        if (newWrapperBalance > lastBalance) {
            // Positive yield: accrue fees
            uint256 totalYield = newWrapperBalance - lastBalance;
            uint256 newFeesEarned;

            if (lastBalance > 0) {
                // Yield on fee-owned aTokens goes 100% to fees
                // Cap feePortionYield to totalYield to prevent underflow (safety against edge cases)
                uint256 feePortionYield = totalYield.mulDiv(_accumulatedFees, lastBalance).min(totalYield);
                // Yield on user-owned aTokens: only _fee% goes to fees
                uint256 userPortionYield = totalYield - feePortionYield;
                uint256 feeOnUserYield = userPortionYield.mulDiv(_fee, MAX_FEE);
                newFeesEarned = feePortionYield + feeOnUserYield;
            } else {
                // No previous balance (edge case after seed), apply standard fee
                newFeesEarned = totalYield.mulDiv(_fee, MAX_FEE);
            }

            // forge-lint: disable-next-line(unsafe-typecast)
            _accumulatedFees += uint128(newFeesEarned);
            // forge-lint: disable-next-line(unsafe-typecast)
            _lastWrapperBalance = uint128(newWrapperBalance);
            emit YieldAccrued(totalYield, newFeesEarned, newWrapperBalance);
        } else if (newWrapperBalance < lastBalance) {
            // Negative yield: reduce fees proportionally to the loss
            uint256 loss = lastBalance - newWrapperBalance;
            uint256 feeLoss = uint256(_accumulatedFees).mulDiv(loss, lastBalance);
            // forge-lint: disable-next-line(unsafe-typecast)
            _accumulatedFees -= uint128(feeLoss);
            // forge-lint: disable-next-line(unsafe-typecast)
            _lastWrapperBalance = uint128(newWrapperBalance);
            emit NegativeYield(loss, feeLoss, newWrapperBalance);
        }
        // If equal, no action needed
    }

    /* ALPHIX HOOKS MANAGEMENT */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function addAlphixHook(address hook) external override onlyOwner {
        if (hook == address(0)) revert InvalidAddress();
        if (!_alphixHooks.add(hook)) revert HookAlreadyExists();
        emit AlphixHookAdded(hook);
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function removeAlphixHook(address hook) external override onlyOwner {
        if (!_alphixHooks.remove(hook)) revert HookDoesNotExist();
        emit AlphixHookRemoved(hook);
    }

    /// VIEW FUNCTIONS ///

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function isAlphixHook(address hook) external view override returns (bool) {
        return _alphixHooks.contains(hook);
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function getAllAlphixHooks() external view override returns (address[] memory) {
        return _alphixHooks.values();
    }

    /* PAUSABLE */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function pause() external override onlyOwner {
        _pause();
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function unpause() external override onlyOwner {
        _unpause();
    }

    /* REWARDS */

    /// ONLY OWNER ///

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function claimRewards() external override onlyOwner {
        if (_yieldTreasury == address(0)) revert InvalidAddress();
        address rewardsController = address(IncentivizedERC20(address(ATOKEN)).getIncentivesController());
        if (rewardsController == address(0)) revert NoRewardsController();
        address[] memory assets = new address[](1);
        assets[0] = address(ATOKEN);
        (address[] memory rewardsList, uint256[] memory claimedAmounts) =
            IRewardsController(rewardsController).claimAllRewards(assets, _yieldTreasury);
        emit RewardsClaimed(rewardsList, claimedAmounts);
    }

    /**
     * @inheritdoc IAlphix4626WrapperAave
     */
    function rescueTokens(address token, uint256 amount) external override onlyOwner {
        if (token == address(ATOKEN)) revert InvalidToken();
        if (_yieldTreasury == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(_yieldTreasury, amount);
        emit TokensRescued(token, amount);
    }

    /* OWNERSHIP OVERRIDE */

    /**
     * @notice Disabled to prevent accidental loss of admin functions.
     * @dev Ownership can only be transferred via two-step process, not renounced.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /* HELPERS */

    /// INTERNAL VIEW FUNCTIONS ///

    /**
     * @notice Calculates the current claimable fees without modifying state.
     * @return The total claimable fees including pending yield-based fees.
     * @dev Accounts for negative yield by reducing fees accordingly.
     *      Mirrors _accrueYield logic: fee-owned yield goes 100% to fees, user-owned yield has _fee% taken.
     */
    function _getClaimableFees() internal view returns (uint256) {
        uint256 newWrapperBalance = ATOKEN.balanceOf(address(this));
        uint256 lastBalance = _lastWrapperBalance;
        if (newWrapperBalance > lastBalance) {
            // Positive yield: add pending fees
            uint256 totalYield = newWrapperBalance - lastBalance;
            uint256 newFeesEarned;

            if (lastBalance > 0) {
                // Yield on fee-owned aTokens goes 100% to fees
                // Cap feePortionYield to totalYield to prevent underflow (safety against edge cases)
                uint256 feePortionYield = totalYield.mulDiv(_accumulatedFees, lastBalance).min(totalYield);
                // Yield on user-owned aTokens: only _fee% goes to fees
                uint256 userPortionYield = totalYield - feePortionYield;
                uint256 feeOnUserYield = userPortionYield.mulDiv(_fee, MAX_FEE);
                newFeesEarned = feePortionYield + feeOnUserYield;
            } else {
                newFeesEarned = totalYield.mulDiv(_fee, MAX_FEE);
            }

            return _accumulatedFees + newFeesEarned;
        } else if (newWrapperBalance < lastBalance) {
            // Negative yield: reduce fees proportionally to the loss
            uint256 loss = lastBalance - newWrapperBalance;
            uint256 feeLoss = uint256(_accumulatedFees).mulDiv(loss, lastBalance);
            return _accumulatedFees - feeLoss;
        }
        return _accumulatedFees;
    }

    /**
     * @notice Calculates the maximum assets that can be supplied to Aave.
     * @return The maximum suppliable amount, or type(uint256).max if no cap.
     * @dev Checks Aave reserve status (active, not frozen, not paused) and supply cap.
     */
    function _maxAssetsSuppliableToAave() internal view returns (uint256) {
        DataTypes.ReserveData memory reserveData = AAVE_POOL.getReserveData(address(ASSET));
        uint256 reserveConfigMap = reserveData.configuration.data;
        uint256 supplyCap = (reserveConfigMap & ~AAVE_SUPPLY_CAP_MASK) >> AAVE_SUPPLY_CAP_BIT_POSITION;
        if (
            (reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) || (reserveConfigMap & ~AAVE_FROZEN_MASK != 0)
                || (reserveConfigMap & ~AAVE_PAUSED_MASK != 0)
        ) {
            // reserve is inactive, frozen or paused
            return 0;
        } else if (supplyCap == 0) {
            // no supply cap
            return type(uint256).max;
        } else {
            // supply cap - current supply
            uint256 currentSupply = WadRayMath.rayMul(
                (ATOKEN.scaledTotalSupply() + uint256(reserveData.accruedToTreasury)), reserveData.liquidityIndex
            );
            uint256 supplyCapScaled = supplyCap * 10 ** decimals();
            return supplyCapScaled > currentSupply ? supplyCapScaled - currentSupply : 0;
        }
    }

    /**
     * @notice Calculates the maximum assets that can be withdrawn from Aave.
     * @return The maximum withdrawable amount based on aToken balance and reserve status.
     * @dev Checks Aave reserve status (active, not paused) before returning balance.
     */
    function _maxAssetsWithdrawableFromAave() internal view returns (uint256) {
        DataTypes.ReserveData memory reserveData = AAVE_POOL.getReserveData(address(ASSET));
        uint256 reserveConfigMap = reserveData.configuration.data;
        if ((reserveConfigMap & ~AAVE_ACTIVE_MASK == 0) || (reserveConfigMap & ~AAVE_PAUSED_MASK != 0)) {
            // reserve is inactive or paused
            return 0;
        } else {
            return ASSET.balanceOf(address(ATOKEN));
        }
    }

    /**
     * @dev Checks if the caller is either an authorized Alphix Hook or the owner.
     */
    function _checkAlphixHookOrOwner() internal view {
        if (!_isAlphixHookOrOwner(msg.sender)) revert UnauthorizedCaller();
    }

    /**
     * @dev Returns true if the address is an authorized Alphix Hook or the owner.
     * @param account The address to check.
     * @return True if authorized, false otherwise.
     */
    function _isAlphixHookOrOwner(address account) internal view returns (bool) {
        return _alphixHooks.contains(account) || account == owner();
    }
}
