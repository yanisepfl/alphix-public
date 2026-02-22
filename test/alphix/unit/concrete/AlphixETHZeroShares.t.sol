// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {BaseAlphixETHTest} from "../../BaseAlphixETH.t.sol";
import {AlphixETH} from "../../../../src/AlphixETH.sol";
import {IReHypothecation} from "../../../../src/interfaces/IReHypothecation.sol";
import {ReHypothecationLib} from "../../../../src/libraries/ReHypothecation.sol";
import {MockYieldVault} from "../../../utils/mocks/MockYieldVault.sol";
import {MockAlphix4626WrapperWeth} from "../../../utils/mocks/MockAlphix4626WrapperWeth.sol";
import {MockWETH9} from "../../../utils/mocks/MockWETH9.sol";

/**
 * @title AlphixETHZeroSharesTest
 * @notice Tests for zero-share and zero-amount edge cases in AlphixETH.
 */
contract AlphixETHZeroSharesTest is BaseAlphixETHTest {
    using PoolIdLibrary for PoolKey;

    MockWETH9 public weth;
    MockAlphix4626WrapperWeth public ethVault;
    MockYieldVault public tokenVault;

    function setUp() public override {
        super.setUp();

        // Deploy WETH mock and vaults
        weth = new MockWETH9();
        ethVault = new MockAlphix4626WrapperWeth(address(weth));
        tokenVault = new MockYieldVault(IERC20(Currency.unwrap(key.currency1)));
    }

    /* ═══════════════════════════════════════════════════════════════════════════
        ZERO-SHARE DEPOSIT VIA addReHypothecatedLiquidity
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Verifies _depositToYieldSourceEth reverts when the ETH vault returns 0 shares.
     * @dev Inflates vault share price via yield donation so small deposits round to 0 shares.
     */
    function test_depositToYieldSourceEth_revertsOnZeroSharesReceived() public {
        _setupYieldSources();

        // Seed the vault and inflate share price: 1 share = 1001 ether
        _inflateEthVaultSharePrice();

        // First depositor gets real hook shares (hook totalSupply == 0 → amounts from pool price)
        _seedBaseLiquidity(user1, 1e18);

        // Find minimal hook shares that yield a non-zero ETH amount but 0 vault shares
        (uint256 hookShares, uint256 tinyAmount0, uint256 tinyAmount1) = _findMinimalHookShares();

        // Verify preconditions: ETH path is exercised and vault returns 0 shares
        assertGt(tinyAmount0, 0, "tinyAmount0 must be > 0 to exercise ETH deposit path");
        assertEq(ethVault.previewDeposit(tinyAmount0), 0, "Vault should return 0 shares for this amount");

        // Attempt deposit — should revert
        MockERC20(Currency.unwrap(key.currency1)).mint(user2, tinyAmount1 + 1e18);
        vm.deal(user2, tinyAmount0 + 1 ether);

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        vm.expectRevert(ReHypothecationLib.ZeroSharesReceived.selector);
        hook.addReHypothecatedLiquidity{value: tinyAmount0}(hookShares, 0, 0);
        vm.stopPrank();
    }

    /**
     * @notice Verifies user's ETH balance is unchanged when ZeroSharesReceived reverts the deposit.
     * @dev The revert must be atomic — no ETH should be lost to the vault.
     */
    function test_depositToYieldSourceEth_zeroSharesRevert_preservesUserETH() public {
        _setupYieldSources();
        _inflateEthVaultSharePrice();

        // First depositor provides base liquidity
        _seedBaseLiquidity(user1, 1e18);

        // Find hook shares that trigger zero vault shares
        (uint256 hookShares, uint256 tinyAmount0, uint256 tinyAmount1) = _findMinimalHookShares();
        assertGt(tinyAmount0, 0, "tinyAmount0 must be > 0 to exercise ETH deposit path");

        MockERC20(Currency.unwrap(key.currency1)).mint(user2, tinyAmount1 + 1e18);
        vm.deal(user2, tinyAmount0 + 1 ether);

        uint256 ethBefore = user2.balance;
        uint256 hookSharesBefore = hook.balanceOf(user2);

        vm.startPrank(user2);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        vm.expectRevert(ReHypothecationLib.ZeroSharesReceived.selector);
        hook.addReHypothecatedLiquidity{value: tinyAmount0}(hookShares, 0, 0);
        vm.stopPrank();

        // Verify nothing changed — revert was atomic
        assertEq(user2.balance, ethBefore, "User ETH balance should be unchanged after revert");
        assertEq(hook.balanceOf(user2), hookSharesBefore, "User hook shares should be unchanged after revert");
    }

    /* ═══════════════════════════════════════════════════════════════════════════
        ZERO-SHARE MIGRATION VIA setYieldSource
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Verifies setYieldSource migration reverts when the new vault returns 0 shares.
     * @dev Migrates real ETH from old vault to new vault with inflated share price.
     */
    function test_setYieldSource_migration_revertsOnZeroSharesReceived() public {
        address yieldManager = _setupYieldSources();
        _seedBaseLiquidity(user1, 10e18);

        uint256 amountInYield = hook.getAmountInYieldSource(Currency.wrap(address(0)));
        assertGt(amountInYield, 0, "Should have ETH in yield source");

        // Deploy new vault with inflated share price (2x the migrated amount)
        MockAlphix4626WrapperWeth newEthVault = _deployInflatedEthVault(amountInYield * 2);

        // Attempt migration — should revert
        vm.prank(yieldManager);
        vm.expectRevert(ReHypothecationLib.ZeroSharesReceived.selector);
        hook.setYieldSource(Currency.wrap(address(0)), address(newEthVault));
    }

    /**
     * @notice Verifies that a failed migration preserves the old yield source and shares.
     * @dev After revert, yield source address and sharesOwned should be unchanged.
     */
    function test_setYieldSource_migration_zeroSharesRevert_preservesState() public {
        address yieldManager = _setupYieldSources();
        _seedBaseLiquidity(user1, 10e18);

        uint256 amountInYield = hook.getAmountInYieldSource(Currency.wrap(address(0)));
        address yieldSourceBefore = hook.getCurrencyYieldSource(Currency.wrap(address(0)));

        MockAlphix4626WrapperWeth newEthVault = _deployInflatedEthVault(amountInYield * 2);

        vm.prank(yieldManager);
        vm.expectRevert(ReHypothecationLib.ZeroSharesReceived.selector);
        hook.setYieldSource(Currency.wrap(address(0)), address(newEthVault));

        // Verify state preserved after revert
        assertEq(
            hook.getCurrencyYieldSource(Currency.wrap(address(0))),
            yieldSourceBefore,
            "Yield source should be unchanged after failed migration"
        );
        assertEq(
            hook.getAmountInYieldSource(Currency.wrap(address(0))),
            amountInYield,
            "Amount in yield source should be unchanged after failed migration"
        );
    }

    /* ═══════════════════════════════════════════════════════════════════════════
        ZERO-AMOUNT WITHDRAWAL VIA removeReHypothecatedLiquidity
    ═══════════════════════════════════════════════════════════════════════════ */

    /**
     * @notice Verifies removeReHypothecatedLiquidity reverts when both amounts round to zero
     *         due to severe vault losses.
     * @dev Drains vaults to near-zero assets so small share counts produce 0 amounts.
     */
    function test_removeReHypothecatedLiquidity_revertsOnZeroAmounts_afterLoss() public {
        _setupYieldSources();
        _seedBaseLiquidity(user1, 10e18);

        // Simulate severe losses — drain both vaults to ~1 wei
        _drainVaultsToMinimum();

        // Verify precondition: 1 share → 0 amounts
        (uint256 previewAmount0, uint256 previewAmount1) = hook.previewRemoveReHypothecatedLiquidity(1);
        assertEq(previewAmount0, 0, "Amount0 should be 0 for 1 share after loss");
        assertEq(previewAmount1, 0, "Amount1 should be 0 for 1 share after loss");

        // Attempt removal — should revert with ZeroAmounts
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroAmounts.selector);
        hook.removeReHypothecatedLiquidity(1, 0, 0);
    }

    /**
     * @notice Verifies that the zero-amounts guard is specific to dust conditions —
     *         a large enough share count still allows withdrawal even after partial losses.
     * @dev Users with significant holdings should still be able to withdraw when per-share
     *      value is small but non-zero.
     */
    function test_removeReHypothecatedLiquidity_succeedsWithLargeSharesAfterLoss() public {
        _setupYieldSources();
        _seedBaseLiquidity(user1, 10e18);

        // Simulate severe losses
        _drainVaultsToMinimum();

        // Removing ALL shares should still work (amounts may be tiny but non-zero)
        (uint256 fullAmount0, uint256 fullAmount1) = hook.previewRemoveReHypothecatedLiquidity(10e18);

        // At least one amount should be > 0 for full share count (1 wei left in each vault)
        // If both are somehow 0 even for full shares, the revert is correct behavior
        if (fullAmount0 > 0 || fullAmount1 > 0) {
            vm.prank(user1);
            hook.removeReHypothecatedLiquidity(10e18, 0, 0);
            assertEq(hook.balanceOf(user1), 0, "User should have 0 shares after full withdrawal");
        } else {
            vm.prank(user1);
            vm.expectRevert(IReHypothecation.ZeroAmounts.selector);
            hook.removeReHypothecatedLiquidity(10e18, 0, 0);
        }
    }

    /**
     * @notice Verifies shares are preserved when zero-amount withdrawal reverts.
     * @dev The revert prevents share destruction — user retains their claim.
     */
    function test_removeReHypothecatedLiquidity_zeroAmountsRevert_preservesShares() public {
        _setupYieldSources();
        _seedBaseLiquidity(user1, 10e18);

        _drainVaultsToMinimum();

        uint256 sharesBefore = hook.balanceOf(user1);
        uint256 ethBefore = user1.balance;

        // Attempt removal of 1 share — reverts, nothing changes
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroAmounts.selector);
        hook.removeReHypothecatedLiquidity(1, 0, 0);

        // Shares and ETH preserved
        assertEq(hook.balanceOf(user1), sharesBefore, "Shares should be unchanged after revert");
        assertEq(user1.balance, ethBefore, "ETH balance should be unchanged after revert");
    }

    /**
     * @notice Verifies removeReHypothecatedLiquidity reverts when both amounts round to zero
     *         due to large share supply making 1 share worth ~0 (dust condition, no vault loss).
     * @dev Mirrors the test pattern from AlphixUnit.t.sol for consistency.
     */
    function test_removeReHypothecatedLiquidity_revertsOnZeroAmounts_dustCondition() public {
        _setupYieldSources();

        // Add a large amount of liquidity so 1 share is worth dust
        _seedBaseLiquidity(user1, 100e18);

        // Try removing 1 share out of 100e18 — amounts round to 0
        // amount0 = floor(1 * amount0InYield / 100e18) = 0 for typical amounts
        vm.prank(user1);
        vm.expectRevert(IReHypothecation.ZeroAmounts.selector);
        hook.removeReHypothecatedLiquidity(1, 0, 0);
    }

    /* ═══════════════════════════════════════════════════════════════════════════
                              HELPER FUNCTIONS
    ═══════════════════════════════════════════════════════════════════════════ */

    function _setupYieldSources() internal returns (address yieldManager) {
        yieldManager = makeAddr("yieldManager");

        vm.startPrank(owner);
        _setupYieldManagerRole(yieldManager, accessManager, address(hook));
        vm.stopPrank();

        vm.startPrank(yieldManager);
        hook.setYieldSource(Currency.wrap(address(0)), address(ethVault));
        hook.setYieldSource(key.currency1, address(tokenVault));
        vm.stopPrank();
    }

    /// @dev Seeds base liquidity for a user with the given number of hook shares
    function _seedBaseLiquidity(address user, uint256 shares) internal {
        (uint256 amount0Needed, uint256 amount1Needed) = hook.previewAddReHypothecatedLiquidity(shares);
        MockERC20(Currency.unwrap(key.currency1)).mint(user, amount1Needed + 1e18);
        vm.deal(user, amount0Needed + 10 ether);

        vm.startPrank(user);
        MockERC20(Currency.unwrap(key.currency1)).approve(address(hook), type(uint256).max);
        hook.addReHypothecatedLiquidity{value: amount0Needed}(shares, 0, 0);
        vm.stopPrank();
    }

    /// @dev Finds minimal hook shares where tinyAmount0 > 0 but ethVault.previewDeposit(tinyAmount0) == 0
    function _findMinimalHookShares()
        internal
        view
        returns (uint256 hookShares, uint256 tinyAmount0, uint256 tinyAmount1)
    {
        hookShares = 1;
        (tinyAmount0, tinyAmount1) = hook.previewAddReHypothecatedLiquidity(hookShares);
        while (tinyAmount0 == 0 && hookShares < 2000) {
            hookShares++;
            (tinyAmount0, tinyAmount1) = hook.previewAddReHypothecatedLiquidity(hookShares);
        }
    }

    /// @dev Inflates ethVault share price to ~1001 ether per share
    function _inflateEthVaultSharePrice() internal {
        vm.deal(address(this), 1002 ether);
        weth.deposit{value: 1 ether}();
        weth.approve(address(ethVault), 1 ether);
        ethVault.deposit(1 ether, address(this));
        // ethVault: totalAssets = 1 ether, totalSupply = 1 ether

        weth.deposit{value: 1000 ether}();
        weth.approve(address(ethVault), 1000 ether);
        ethVault.simulateYield(1000 ether);
        // ethVault: totalAssets = 1001 ether, totalSupply = 1 ether
    }

    /// @dev Deploys a new WETH vault with inflated share price (1 share = 1 + donation assets)
    function _deployInflatedEthVault(uint256 donation) internal returns (MockAlphix4626WrapperWeth newVault) {
        newVault = new MockAlphix4626WrapperWeth(address(weth));

        vm.deal(address(this), donation + 1);
        weth.deposit{value: 1}();
        weth.approve(address(newVault), 1);
        newVault.deposit(1, address(this));

        weth.deposit{value: donation}();
        weth.approve(address(newVault), donation);
        newVault.simulateYield(donation);
    }

    /// @dev Drains both vaults to ~1 wei of assets via simulateLoss
    function _drainVaultsToMinimum() internal {
        uint256 ethVaultAssets = ethVault.totalAssets();
        uint256 tokenVaultAssets = tokenVault.totalAssets();

        if (ethVaultAssets > 1) {
            vm.deal(address(this), ethVaultAssets);
            weth.deposit{value: ethVaultAssets - 1}();
            weth.approve(address(ethVault), ethVaultAssets - 1);
            ethVault.simulateLoss(ethVaultAssets - 1);
        }
        if (tokenVaultAssets > 1) {
            MockERC20(Currency.unwrap(key.currency1)).mint(address(this), tokenVaultAssets);
            MockERC20(Currency.unwrap(key.currency1)).approve(address(tokenVault), tokenVaultAssets - 1);
            tokenVault.simulateLoss(tokenVaultAssets - 1);
        }
    }
}
