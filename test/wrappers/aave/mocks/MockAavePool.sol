// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DataTypes} from "@aave-v3-core/protocol/libraries/types/DataTypes.sol";
import {MockAToken} from "./MockAToken.sol";

/**
 * @title MockAavePool
 * @author Alphix
 * @notice Mock Aave V3 Pool for testing purposes.
 * @dev Yield Simulation Design:
 *      To mock yield accrual, we increase the vault's aToken asset balance.
 *      But, this will lead to scenarios where there are more aTokens to redeem
 *      than there are underlying assets in this mock pool.
 *      As such, avoid using the deal cheatcode in Foundry and instead
 *      implement utility functions which retain 1:1 asset:aToken parity.
 */
contract MockAavePool {
    using SafeERC20 for IERC20;

    /// @notice Scale for yield calculations (1e18 = 1.0x)
    uint256 internal constant SCALE = 1e18;

    /// @notice RAY constant for Aave math
    uint256 internal constant RAY = 1e27;

    /// @notice Mapping from underlying asset to aToken
    mapping(address => MockAToken) internal _reserves;

    /// @notice Reserve configuration map (shared for simplicity in tests)
    uint256 public reserveConfigMap;

    /**
     * @notice Sets up a mock reserve for an asset.
     * @param asset The underlying asset address.
     * @param aToken The aToken contract.
     */
    function mockReserve(address asset, MockAToken aToken) external {
        _reserves[asset] = aToken;
    }

    /**
     * @notice Sets the reserve configuration map for testing.
     * @param _reserveConfigMap The configuration bitmap.
     */
    function setReserveConfigMap(uint256 _reserveConfigMap) external {
        reserveConfigMap = _reserveConfigMap;
    }

    /**
     * @notice Initializes a reserve with specific configuration flags.
     * @param asset The underlying asset address.
     * @param aToken The aToken address.
     * @param active Whether the reserve is active.
     * @param frozen Whether the reserve is frozen.
     * @param paused Whether the reserve is paused.
     * @param supplyCap The supply cap (in whole tokens, 0 = no cap).
     */
    function initReserve(address asset, address aToken, bool active, bool frozen, bool paused, uint256 supplyCap)
        external
    {
        _reserves[asset] = MockAToken(aToken);

        // Build configuration bitmap
        uint256 config = 0;

        // Active flag at bit 56
        if (active) {
            config |= (1 << 56);
        }

        // Frozen flag at bit 57
        if (frozen) {
            config |= (1 << 57);
        }

        // Paused flag at bit 60
        if (paused) {
            config |= (1 << 60);
        }

        // Supply cap at bits 116-151 (36 bits)
        config |= (supplyCap << 116);

        reserveConfigMap = config;
    }

    /**
     * @notice Returns the reserve data for an asset.
     * @param asset The underlying asset address.
     * @return The reserve data struct.
     */
    function getReserveData(address asset) external view returns (DataTypes.ReserveData memory) {
        return DataTypes.ReserveData({
            configuration: DataTypes.ReserveConfigurationMap({data: reserveConfigMap}),
            // forge-lint: disable-next-line(unsafe-typecast)
            liquidityIndex: uint128(RAY), // RAY (1e27) fits in uint128
            currentLiquidityRate: 0,
            // forge-lint: disable-next-line(unsafe-typecast)
            variableBorrowIndex: uint128(RAY), // RAY (1e27) fits in uint128
            currentVariableBorrowRate: 0,
            currentStableBorrowRate: 0,
            lastUpdateTimestamp: 0,
            id: 0,
            aTokenAddress: address(_reserves[asset]),
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            accruedToTreasury: 0,
            unbacked: 0,
            isolationModeTotalDebt: 0
        });
    }

    /**
     * @notice Supplies assets to the pool.
     * @param _asset The underlying asset address.
     * @param _amount The amount to supply.
     * @param _onBehalfOf The address that will receive the aTokens.
     */
    function supply(address _asset, uint256 _amount, address _onBehalfOf, uint16) external {
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);
        _reserves[_asset].mint(address(this), _onBehalfOf, _amount, 0);
        IERC20(_asset).safeTransfer(address(_reserves[_asset]), _amount);
    }

    /**
     * @notice Withdraws assets from the pool.
     * @param _asset The underlying asset address.
     * @param _amount The amount to withdraw.
     * @param _receiver The address that will receive the underlying.
     * @return The actual amount withdrawn.
     */
    function withdraw(address _asset, uint256 _amount, address _receiver) external returns (uint256) {
        _reserves[_asset].burn(msg.sender, _receiver, _amount, 0);
        return _amount;
    }

    /**
     * @notice Simulates yield accrual by minting new aTokens.
     * @param _asset The underlying asset address.
     * @param _recipient The recipient of the yield.
     * @param _yield The yield multiplier (SCALE = 1e18 = 1.0x, 1.1e18 = 1.1x = 10% yield).
     * @dev Mints recipient new tokens based on current aToken balance to simulate yield.
     */
    function simulateYield(address _asset, address _recipient, uint256 _yield) external {
        uint256 balanceBefore = _reserves[_asset].balanceOf(_recipient);
        uint256 balanceAfter = (balanceBefore * _yield) / SCALE;

        if (balanceAfter > balanceBefore) {
            _reserves[_asset].mint(address(this), _recipient, balanceAfter - balanceBefore, 0);
        }
    }

    /**
     * @notice Sets the reserve configuration.
     * @param active Whether the reserve is active.
     * @param frozen Whether the reserve is frozen.
     * @param paused Whether the reserve is paused.
     * @param supplyCap The supply cap.
     */
    function setReserveConfig(bool active, bool frozen, bool paused, uint256 supplyCap) external {
        uint256 config = 0;
        if (active) config |= (1 << 56);
        if (frozen) config |= (1 << 57);
        if (paused) config |= (1 << 60);
        config |= (supplyCap << 116);

        reserveConfigMap = config;
    }
}
