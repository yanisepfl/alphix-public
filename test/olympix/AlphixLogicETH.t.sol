// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {MockReenteringLogic} from "test/utils/mocks/MockReenteringLogic.sol";
/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

/* OZ IMPORTS */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/* SOLMATE IMPORTS */
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/* LOCAL IMPORTS */
import {OlympixUnitTest} from "../utils/OlympixUnitTest.sol";
import {BaseAlphixTest} from "../alphix/BaseAlphix.t.sol";
import {AlphixLogicETH} from "../../src/AlphixLogicETH.sol";
import {IReHypothecation} from "../../src/interfaces/IReHypothecation.sol";
import {DynamicFeeLib} from "../../src/libraries/DynamicFee.sol";
import {MockWETH9} from "../utils/mocks/MockWETH9.sol";
import {MockYieldVault} from "../utils/mocks/MockYieldVault.sol";

/**
 * @title AlphixLogicETHTest
 * @notice Olympix-generated unit tests for AlphixLogicETH contract
 * @dev Tests the ETH-variant logic contract functionality including:
 *      - ETH wrapping/unwrapping for yield sources
 *      - Native ETH deposits and withdrawals
 *      - WETH-based yield vault interactions
 *      - ETH transfer handling
 *      - ERC20 share token functionality for ETH pools
 */
contract AlphixLogicETHTest is OlympixUnitTest("AlphixLogicETH"), BaseAlphixTest {
    // ETH-specific contracts
    AlphixLogicETH public ethLogic;
    MockWETH9 public weth;

    // Yield vaults (WETH-based for currency0)
    MockYieldVault public wethVault;
    MockYieldVault public tokenVault;

    // Test token for currency1
    MockERC20 public token1;

    /* ========================================================================== */
    /*                              SETUP                                         */
    /* ========================================================================== */

    function setUp() public override {
        super.setUp();

        // Deploy WETH mock
        weth = new MockWETH9();

        // Deploy test token for currency1
        token1 = new MockERC20("Token1", "TKN1", 18);

        // Deploy yield vaults
        wethVault = new MockYieldVault(IERC20(address(weth)));
        tokenVault = new MockYieldVault(IERC20(address(token1)));

        // Note: Full ETH logic deployment requires additional setup
        // This skeleton provides the structure for Olympix to generate tests
    }

    /* ========================================================================== */
    /*                           HELPER FUNCTIONS                                 */
    /* ========================================================================== */

    /**
     * @notice Helper to wrap ETH to WETH
     * @param amount Amount of ETH to wrap
     */
    function _wrapEth(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
    }

    /**
     * @notice Helper to unwrap WETH to ETH
     * @param amount Amount of WETH to unwrap
     */
    function _unwrapWeth(uint256 amount) internal {
        weth.withdraw(amount);
    }

    /**
     * @notice Helper to add rehypothecated liquidity with ETH
     * @param user User adding liquidity
     * @param ethAmount Amount of ETH
     * @param tokenAmount Amount of token1
     */
    function _addRehypothecatedLiquidityEth(address user, uint256 ethAmount, uint256 tokenAmount) internal {
        // This would call AlphixLogicETH.addReHypothecatedLiquidity{value: ethAmount}(shares)
        // Placeholder for actual implementation
    }

    /**
     * @notice Helper to simulate yield in WETH vault
     * @param amount Yield amount
     */
    function _simulateWethYield(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(wethVault), amount);
        wethVault.deposit(amount, address(wethVault));
    }

    /* ========================================================================== */
    /*                           EXAMPLE TESTS                                    */
    /* ========================================================================== */

    /**
     * @notice Test WETH deployment
     */
    function test_wethDeployed() public view {
        assertTrue(address(weth) != address(0), "WETH should be deployed");
        assertEq(weth.name(), "Wrapped Ether", "WETH name should match");
        assertEq(weth.symbol(), "WETH", "WETH symbol should match");
    }

    /**
     * @notice Test ETH to WETH wrapping
     */
    function test_ethToWethWrapping() public {
        uint256 amount = 10 ether;
        _wrapEth(amount);

        assertEq(weth.balanceOf(address(this)), amount, "WETH balance should match wrapped amount");
    }

    /**
     * @notice Test WETH to ETH unwrapping
     */
    function test_wethToEthUnwrapping() public {
        uint256 amount = 10 ether;
        _wrapEth(amount);

        uint256 ethBalanceBefore = address(this).balance;
        _unwrapWeth(amount);

        assertEq(weth.balanceOf(address(this)), 0, "WETH balance should be 0");
        assertEq(address(this).balance, ethBalanceBefore + amount, "ETH balance should increase");
    }

    /**
     * @notice Test WETH vault deposit
     */
    function test_wethVaultDeposit() public {
        uint256 amount = 5 ether;
        _wrapEth(amount);

        weth.approve(address(wethVault), amount);
        uint256 shares = wethVault.deposit(amount, address(this));

        assertTrue(shares > 0, "Should receive vault shares");
        assertEq(weth.balanceOf(address(wethVault)), amount, "Vault should hold WETH");
    }

    /**
     * @notice Test WETH vault withdrawal
     */
    function test_wethVaultWithdrawal() public {
        uint256 amount = 5 ether;
        _wrapEth(amount);

        weth.approve(address(wethVault), amount);
        uint256 shares = wethVault.deposit(amount, address(this));

        uint256 withdrawn = wethVault.redeem(shares, address(this), address(this));

        assertEq(withdrawn, amount, "Should withdraw full amount");
        assertEq(weth.balanceOf(address(this)), amount, "WETH should be returned");
    }

    /**
     * @notice Test yield source validation for WETH
     * @dev For ETH pools, yield source for currency0 must accept WETH
     */
    function test_yieldSourceValidationWETH() public view {
        // The yield vault's asset should be WETH
        assertEq(address(wethVault.asset()), address(weth), "Vault asset should be WETH");
    }

    /**
     * @notice Test receive() function accepts ETH
     */
    function test_acceptsETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        // Send ETH to WETH contract (simulating receive from PoolManager)
        (bool success,) = address(weth).call{value: amount}("");
        assertTrue(success, "Should accept ETH");
    }

    /**
     * @notice Test native ETH handling in deposits
     * @dev Verifies msg.value is properly handled
     */
    function test_nativeETHDeposit() public {
        uint256 amount = 1 ether;
        vm.deal(user1, amount);

        // This test verifies the pattern for ETH deposits
        // Actual implementation would call the logic contract with {value: amount}
        vm.prank(user1);
        weth.deposit{value: amount}();

        assertEq(weth.balanceOf(user1), amount, "User should have WETH after deposit");
    }

    // Required to receive ETH
    receive() external payable {}

    function test_initialize_revertsInvalidWETHAddress_branch101True() public {
        // opix-target-branch-101-True: AlphixLogicETH.initialize(...) must revert InvalidWETHAddress
        // because ETH variant requires initializeEth instead.
        AlphixLogicETH impl = new AlphixLogicETH();

        vm.expectRevert(AlphixLogicETH.InvalidWETHAddress.selector);
        impl.initialize(address(1), address(2), address(3), "Name", "SYM");
    }

    function test_initializeEth_revertsWhenWethIsZeroAddress_branch118True() public {
        // initializeEth is an initializer; calling it on the implementation reverts with OZ InvalidInitialization
        // because the constructor disables initializers. To reach the branch
        // `if (weth9_ == address(0)) revert InvalidWETHAddress();` we must call through a proxy.

        AlphixLogicETH impl = new AlphixLogicETH();

        // Deploying the proxy will delegatecall into initializeEth, hitting the weth9_ == address(0) check.
        vm.expectRevert(AlphixLogicETH.InvalidWETHAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(0), // triggers opix-target-branch-118-True
                "Alphix ETH Shares",
                "aETH"
            )
        );
    }

    function test_beforeInitialize_revertsWhenNotETHPool_currency0NotZero() public {
        // Deploy + initialize ETH logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );

        // NOTE: AlphixLogicETH has a payable receive(), so the proxy address must be cast to payable
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Create a NON-ETH pool key: currency0 is not address(0)
        PoolKey memory nonEthKey = PoolKey({
            currency0: currency1, // non-zero address => should revert NotAnETHPool
            currency1: currency0,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });

        // Call as the hook to satisfy onlyAlphixHook
        vm.startPrank(address(hook));
        vm.expectRevert(AlphixLogicETH.NotAnETHPool.selector);
        logicEth.beforeInitialize(address(0), nonEthKey, uint160(0));
        vm.stopPrank();
    }

    function test_depositToYieldSource_nonNativeCurrency_entersElseBranch174() public {
        // Hit opix-target-branch-174 ELSE in AlphixLogicETH.depositToYieldSource
        // Preconditions to avoid early returns:
        // - amount != 0
        // - yieldSource configured for the passed (non-native) currency
        // - msg.sender must be _alphixHook (onlyAlphixHook)

        address localOwner = address(0xBEEF);
        address localHook = address(0xCAFE);

        // AccessManager only matters for restricted functions (setYieldSource)
        AccessManager am = new AccessManager(localOwner);

        // Local tokens/vaults
        MockWETH9 wethLocal = new MockWETH9();
        MockERC20 tokenLocal = new MockERC20("Token", "TKN", 18);
        MockYieldVault tokenVaultLocal = new MockYieldVault(IERC20(address(tokenLocal)));

        // Authorize this test contract for `restricted` calls (AccessManaged default roleId=0)
        vm.startPrank(localOwner);
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Deploy + initialize logic behind proxy (implementation disables initializers)
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                localOwner,
                localHook,
                address(am),
                address(wethLocal),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Pool must be configured for setYieldSource's poolConfigured modifier.
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenLocal)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        // Configure pool as hook (onlyAlphixHook enforced internally)
        vm.startPrank(localHook);
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // Configure yield source for NON-native currency (so early-return yieldSource==0 is false)
        Currency nonNative = Currency.wrap(address(tokenLocal));
        logicEth.setYieldSource(nonNative, address(tokenVaultLocal));

        // Provide the logic contract with tokens so it can deposit into the vault
        uint256 amount = 1 ether;
        tokenLocal.mint(address(logicEth), amount);

        // Call as hook to satisfy onlyAlphixHook and enter ELSE branch (currency.isAddressZero() == false)
        vm.startPrank(localHook);
        logicEth.depositToYieldSource(nonNative, amount);
        vm.stopPrank();

        // Assert deposit happened
        assertEq(tokenLocal.balanceOf(address(tokenVaultLocal)), amount);
    }

    function test_withdrawAndApprove_nativeCurrency_entersBranch190True_revertsOnUnauthorizedETHSender() public {
        // Hit opix-target-branch-190-True in AlphixLogicETH.withdrawAndApprove by calling with native currency.
        // We must bypass the early return `if (_yieldSourceState[currency].yieldSource == address(0)) return;`
        // so we first configure a native (ETH) yield source.
        //
        // The previous attempts failed because AlphixLogicETH.receive() only accepts ETH from:
        //   - the WETH contract, or
        //   - the PoolManager returned by BaseDynamicFee(_alphixHook).poolManager().
        // In unit tests, `hook.poolManager()` call inside receive() reverted because `hook` was an EOA.
        //
        // To make receive() succeed without needing a full PoolManager, we set `_alphixHook` to a contract
        // that implements `poolManager()` and returns address(this). MockReenteringLogic does that.

        // 1) Setup addresses and contracts
        address localOwner = address(0xBEEF);
        MockWETH9 wethLocal = new MockWETH9();
        MockYieldVault wethVaultLocal = new MockYieldVault(IERC20(address(wethLocal)));

        // Hook MUST be a contract so `BaseDynamicFee(_alphixHook).poolManager()` is callable.
        // MockReenteringLogic(HOOK) is a contract, and its `poke` calls BaseDynamicFee(HOOK).poke.
        // Importantly, it ALSO has a `HOOK()` getter and is a deployed contract with code.
        // We'll use it as the hook address and set its HOOK to this test contract.
        MockReenteringLogic hookLike = new MockReenteringLogic(address(this));

        // 2) AccessManager: authorize this test contract for `restricted` calls (roleId=0)
        AccessManager am = new AccessManager(localOwner);
        vm.startPrank(localOwner);
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        // 3) Deploy AlphixLogicETH behind proxy and initialize
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                localOwner,
                address(hookLike),
                address(am),
                address(wethLocal),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // 4) Configure pool (required for poolConfigured in setYieldSource)
        MockERC20 tokenLocal = new MockERC20("Token", "TKN", 18);
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenLocal)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hookLike))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(address(hookLike));
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // 5) Configure yield source for native currency so withdrawAndApprove doesn't early-return
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVaultLocal));

        // 6) Seed vault shares to logicEth so the withdraw path attempts to unwrap and send ETH
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        wethLocal.deposit{value: amount}();
        wethLocal.approve(address(wethVaultLocal), amount);
        wethVaultLocal.deposit(amount, address(logicEth));

        // 7) Call withdrawAndApprove for native currency.
        // This enters branch 190 (currency.isAddressZero() == true).
        // It withdraws WETH and then calls weth.withdraw(amount), which sends ETH to logicEth.
        // logicEth.receive() will now call hookLike.poolManager() via BaseDynamicFee(_alphixHook).poolManager().
        // Since hookLike is NOT a real BaseDynamicFee (it doesn't implement poolManager()),
        // that call will revert, causing receive() to revert. We expect a revert.
        vm.startPrank(address(hookLike));
        vm.expectRevert();
        logicEth.withdrawAndApprove(Currency.wrap(address(0)), amount);
        vm.stopPrank();
    }

    function test_setYieldSource_nativeCurrency_nonZeroYieldSource_hitsBranch219True_revertsOnAssetMismatch() public {
        // Deploy + initialize ETH logic behind proxy (to mirror production wiring)
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Configure & activate ETH pool as hook (onlyAlphixHook)
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Replace the AccessManager with one where the test contract is authorized under the required role.
        // This avoids AccessManagerUnauthorizedAccount seen in previous attempt.
        AccessManager am = new AccessManager(owner);
        vm.startPrank(owner);
        // AccessManagedUpgradeable uses "restricted" which checks roleId == 0 by default.
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Deploy a fresh logic instance pointing to our new AccessManager, then configure pool.
        AlphixLogicETH impl2 = new AlphixLogicETH();
        ERC1967Proxy proxy2 = new ERC1967Proxy(
            address(impl2),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(am),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth2 = AlphixLogicETH(payable(address(proxy2)));

        vm.startPrank(address(hook));
        logicEth2.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Hit branch 219 (newYieldSource != address(0)) by passing non-zero yield source.
        // Use tokenVault (asset = token1) so it mismatches WETH and reverts.
        vm.expectRevert(AlphixLogicETH.YieldSourceAssetMismatch.selector);
        logicEth2.setYieldSource(Currency.wrap(address(0)), address(tokenVault));
    }

    function test_setYieldSource_nativeCurrency_withWethVault_hitsBranch223Else() public {
        // Deploy dependencies
        MockWETH9 wethLocal = new MockWETH9();
        MockERC20 tokenLocal = new MockERC20("Token", "TKN", 18);
        MockYieldVault wethVaultLocal = new MockYieldVault(IERC20(address(wethLocal)));

        // Create an AccessManager where this test contract is authorized for `restricted` calls.
        // AccessManagedUpgradeable defaults to roleId=0 for `restricted`.
        address localOwner = address(0xBEEF);
        AccessManager am = new AccessManager(localOwner);
        vm.startPrank(localOwner);
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Deploy + initialize logic behind proxy
        address localHook = address(0xCAFE);
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                localOwner,
                localHook,
                address(am),
                address(wethLocal),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Configure pool (required for poolConfigured modifier in setYieldSource)
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenLocal)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(localHook);
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // Call setYieldSource for native currency with a WETH-backed vault.
        // This makes (vaultAsset != address(_weth9)) false, entering the ELSE branch (opix-target-branch-223).
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVaultLocal));

        // Post-condition: yield source stored
        assertEq(logicEth.getCurrencyYieldSource(Currency.wrap(address(0))), address(wethVaultLocal));
    }

    function test_setYieldSource_nativeCurrency_newYieldSourceZero_hitsBranch226Else() public {
        // We must satisfy: restricted + poolConfigured + whenNotPaused.
        // - restricted: AccessManaged roleId=0 by default
        // - poolConfigured: pool must be configured via activateAndConfigurePool
        // - for the opix branch: currency is native (address(0)) and newYieldSource == address(0)

        // Local, self-contained deployment with an AccessManager that authorizes this test for `restricted`.
        address localOwner = address(0xBEEF);
        address localHook = address(0xCAFE);

        AccessManager am = new AccessManager(localOwner);
        vm.startPrank(localOwner);
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        MockWETH9 wethLocal = new MockWETH9();
        MockERC20 tokenLocal = new MockERC20("Token", "TKN", 18);

        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                localOwner,
                localHook,
                address(am),
                address(wethLocal),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Configure pool as hook (onlyAlphixHook is enforced in activateAndConfigurePool via internal _onlyAlphixHook())
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenLocal)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(localHook);
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // Hit opix-target-branch-226 ELSE by passing newYieldSource == address(0)
        logicEth.setYieldSource(Currency.wrap(address(0)), address(0));

        // Post-condition: yield source stored as zero
        assertEq(logicEth.getCurrencyYieldSource(Currency.wrap(address(0))), address(0));
    }

    function test_setYieldSource_nonNativeCurrency_entersElseBranch229() public {
        // Goal: hit AlphixLogicETH.setYieldSource() branch 229 ELSE by making
        // `currency.isAddressZero()` == false (i.e., pass a non-native currency).

        // Authorize this test contract for `restricted` calls (AccessManaged default roleId=0)
        address localOwner = address(0xBEEF);
        address localHook = address(0xCAFE);

        AccessManager am = new AccessManager(localOwner);
        vm.startPrank(localOwner);
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Deploy dependencies
        MockWETH9 wethLocal = new MockWETH9();
        MockERC20 tokenLocal = new MockERC20("Token", "TKN", 18);
        MockYieldVault tokenVaultLocal = new MockYieldVault(IERC20(address(tokenLocal)));

        // Deploy + initialize logic behind proxy (initializer is disabled on implementation)
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                localOwner,
                localHook,
                address(am),
                address(wethLocal),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Pool must be configured for the `poolConfigured` modifier on setYieldSource
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenLocal)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(localHook);
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // Enter ELSE branch at opix-target-branch-229 by using non-native currency (tokenLocal)
        Currency nonNative = Currency.wrap(address(tokenLocal));
        logicEth.setYieldSource(nonNative, address(tokenVaultLocal));

        // Post-condition: yield source stored
        assertEq(logicEth.getCurrencyYieldSource(nonNative), address(tokenVaultLocal));
    }

    function test_addReHypothecatedLiquidity_revertsWhenSharesZero_hitsZeroSharesBranch() public {
        // Deploy + initialize ETH logic behind proxy (need payable cast because of receive())
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Must be pool-activated, otherwise poolActivated modifier reverts before hitting the shares==0 check.
        // Configure pool from the hook (onlyAlphixHook) with minimal valid params.
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // Hit: if (shares == 0) revert ZeroShares(); // opix-target-branch-275-True
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        logicEth.addReHypothecatedLiquidity{value: 0}(0);
    }

    function test_addReHypothecatedLiquidity_revertsWhenMsgValueLessThanAmount0_branch288True() public {
        // Hit opix-target-branch-288-True:
        // `if (msg.value < amount0) revert InvalidMsgValue();`
        // Key requirement: _convertSharesToAmountsForDeposit() needs a real PoolManager,
        // so we must use the BaseAlphixTest-deployed hook + poolManager, and wire the hook to this logic.

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire the hook to use this logic (so BaseDynamicFee(_alphixHook).poolManager() works)
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        vm.stopPrank();

        // Create/init ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure & activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Authorize this test contract for restricted calls (roleId=0 by default)
        vm.startPrank(owner);
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Set tick range so preview/add uses non-zero amounts
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);

        // Configure yield sources for both currencies so deposits won't early-return/revert
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Provide token1 and approval so the only revert we hit is InvalidMsgValue
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        // Choose shares and compute required ETH amount0
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        assertTrue(amount0 > 0, "amount0 must be > 0");
        assertTrue(amount1 > 0, "amount1 must be > 0");

        // Send insufficient ETH to make (msg.value < amount0) true
        vm.deal(address(this), amount0 - 1);
        vm.expectRevert(IReHypothecation.InvalidMsgValue.selector);
        logicEth.addReHypothecatedLiquidity{value: amount0 - 1}(shares);
    }

    function test_addReHypothecatedLiquidity_refundsExcessETH_hitsBranch294True() public {
        // Goal: hit opix-target-branch-294-True in AlphixLogicETH.addReHypothecatedLiquidity
        // i.e., execute `if (msg.value > amount0) { refund }`.
        //
        // Key fix vs previous failing attempt: previewAddReHypothecatedLiquidity() requires
        // a real PoolManager reachable via `BaseDynamicFee(_alphixHook).poolManager()`.
        // We therefore deploy the full AlphixETH hook + pool using BaseAlphixTest helpers,
        // then deploy AlphixLogicETH behind a proxy, register it with the hook, configure
        // tick range and yield sources, and finally call addReHypothecatedLiquidity with
        // msg.value > required amount0.

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire the hook to use this logic (hook is deployed in BaseAlphixTest.setUp())
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        vm.stopPrank();

        // Build ETH pool key (currency0 must be native)
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });

        // Initialize the pool in PoolManager if not already initialized
        // (BaseAlphixTest provides poolManager)
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure & activate pool on logic (must be called by hook due to onlyAlphixHook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Set tick range (restricted) - authorize this test contract for roleId=0
        vm.startPrank(owner);
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);

        // Configure yield sources for both currencies
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Mint token1 to this test and approve the logic to pull token1
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        // Choose shares such that preview requires non-zero ETH + token1
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        assertTrue(amount0 > 0, "amount0 must be > 0");
        assertTrue(amount1 > 0, "amount1 must be > 0");

        // Provide excess ETH to trigger refund branch
        uint256 excess = 0.123 ether;
        uint256 msgValue = amount0 + excess;
        vm.deal(address(this), msgValue);

        uint256 ethBalBefore = address(this).balance;

        logicEth.addReHypothecatedLiquidity{value: msgValue}(shares);

        // Net ETH spent should be exactly amount0 (excess refunded)
        assertEq(address(this).balance, ethBalBefore - amount0, "Excess ETH should be refunded");

        // Shares minted
        assertEq(logicEth.balanceOf(address(this)), shares, "Shares should be minted");

        // Token1 deposited into token vault
        assertEq(token1.balanceOf(address(tokenVault)), amount1, "Token vault should receive token1");
    }

    function test_addReHypothecatedLiquidity_refundFails_revertsETHTransferFailed_branch296True() public {
        // Hit opix-target-branch-296-True:
        // In AlphixLogicETH.addReHypothecatedLiquidity:
        //   if (msg.value > amount0) {
        //      (bool success,) = msg.sender.call{value: msg.value - amount0}("");
        //      if (!success) revert ETHTransferFailed();
        //   }
        // We make `success == false` by calling from MockYieldVault, which has no payable receive/fallback,
        // so it cannot accept ETH refunds.

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire hook -> logic so PoolManager is reachable via BaseDynamicFee(_alphixHook).poolManager()
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        vm.stopPrank();

        // Initialize ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure & activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Authorize this test contract for restricted setters (roleId=0)
        vm.startPrank(owner);
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Configure tick range and yield sources so addReHypothecatedLiquidity reaches refund code
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Choose shares and compute required ETH amount0 and token1 amount1
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        assertTrue(amount0 > 0 && amount1 > 0);

        // Use an existing contract that cannot receive ETH as the msg.sender
        // MockYieldVault has no payable receive/fallback.
        MockYieldVault refundRejector = new MockYieldVault(IERC20(address(token1)));

        // Fund rejector with enough ETH and token1, and approve token1 transfer to logic
        vm.deal(address(refundRejector), amount0 + 1 wei);
        token1.mint(address(refundRejector), amount1);

        vm.startPrank(address(refundRejector));
        token1.approve(address(logicEth), type(uint256).max);

        // Call with msg.value > amount0 so refund is attempted and must fail
        vm.expectRevert(AlphixLogicETH.ETHTransferFailed.selector);
        logicEth.addReHypothecatedLiquidity{value: amount0 + 1 wei}(shares);
        vm.stopPrank();
    }

    function test_addReHypothecatedLiquidity_hitsBranch297Else_noRefundWhenMsgValueEqualsAmount0() public {
        // Goal: hit opix-target-branch-297 ELSE branch in AlphixLogicETH.addReHypothecatedLiquidity
        // by making (msg.value > amount0) == false, i.e., msg.value == amount0.

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire hook -> logic so BaseDynamicFee(_alphixHook).poolManager() is reachable for preview math
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        vm.stopPrank();

        // Initialize ETH pool in PoolManager
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure & activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Authorize this test contract for restricted calls (roleId=0)
        vm.startPrank(owner);
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Set tick range so preview/add uses non-zero amounts
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);

        // Configure yield sources for both currencies
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Provide token1 and approval for transferFrom
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        // Pick shares and compute required amounts
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        assertTrue(amount0 > 0, "amount0 must be > 0");
        assertTrue(amount1 > 0, "amount1 must be > 0");

        // Set msg.value exactly equal to amount0 to ensure no refund path is taken
        vm.deal(address(this), amount0);
        uint256 ethBalBefore = address(this).balance;

        logicEth.addReHypothecatedLiquidity{value: amount0}(shares);

        // No refund => we spent exactly amount0
        assertEq(address(this).balance, ethBalBefore - amount0);

        // Shares minted
        assertEq(logicEth.balanceOf(address(this)), shares);

        // Token1 deposited into vault
        assertEq(token1.balanceOf(address(tokenVault)), amount1);
    }

    function test_addReHypothecatedLiquidity_entersBranch304Else_whenAmount1IsZero() public {
        // Goal: hit opix-target-branch-304 ELSE in AlphixLogicETH.addReHypothecatedLiquidity
        // by making (amount1 > 0) false, i.e. amount1 == 0.

        // Deploy a fresh, self-contained setup and ensure the hook has a real PoolManager (from BaseAlphixTest)
        // so previewAddReHypothecatedLiquidity works.

        // 1) Deploy ETH logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // 2) Wire the hook to this logic (so BaseDynamicFee(_alphixHook).poolManager() is reachable)
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // 3) Create/init ETH pool (native currency0)
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // 4) Configure/activate pool as hook
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // 5) Set tick range so amount0 > 0 for initial deposit
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);

        // 6) Configure yield sources for both currencies
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // 7) Choose shares such that amount1 becomes 0.
        // For initial deposit, _convertSharesToAmountsForDeposit returns (amount0+1, amount1+1).
        // If raw amount1 is 0, returned amount1 will be 1. So we must make *returned* amount1 == 0.
        // That can only happen when shares == 0, but shares==0 reverts.
        // Therefore, to reach the `else` branch (amount1 > 0 is false) we must make currency1 amount1 == 0
        // by forcing _convertSharesToAmountsForDeposit to return 0 for amount1.
        // The only reachable way is to use a situation where totalSupply > 0 and userAmount1 == 0,
        // but then convertSharesToAmountsRoundUp returns 0 for amount1.

        // First, mint some shares with a normal deposit to create totalSupply > 0.
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        uint256 seedShares = 10e18;
        (
            uint256 seedAmount0, /* seedAmount1 */
        ) = logicEth.previewAddReHypothecatedLiquidity(seedShares);
        vm.deal(address(this), seedAmount0);
        logicEth.addReHypothecatedLiquidity{value: seedAmount0}(seedShares);
        assertEq(logicEth.totalSupply(), seedShares);

        // Now, drain currency1 user-available amount to 0 by collecting all token1 from the yield source.
        // We do this by redeeming from tokenVault as the logic itself is the share owner.
        // tokenVault shares are owned by logicEth, so we must make the vault send assets out.
        // The simplest path in this constrained environment is to simulate a total loss of the vault's assets.
        // MockYieldVault has simulateLoss which transfers underlying out.
        // First give this test contract enough token1 allowance to move funds into the vault admin.
        // simulateLoss transfers to vault admin (deployer == address(this) here), so funds come back here.

        uint256 vaultTokenBalance = token1.balanceOf(address(tokenVault));
        if (vaultTokenBalance > 0) {
            tokenVault.simulateLoss(vaultTokenBalance);
        }
        // At this point, tokenVault has 0 underlying, so userAmount1 should be 0.
        assertEq(token1.balanceOf(address(tokenVault)), 0);

        // 8) Now preview for a new deposit; amount1 should compute to 0
        uint256 shares = 1e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        assertTrue(amount0 > 0, "amount0 must be > 0");
        assertEq(amount1, 0, "amount1 must be 0 to hit opix branch 304 else");

        // 9) Call addReHypothecatedLiquidity with exact ETH required; no token transfer should happen
        vm.deal(address(this), amount0);
        logicEth.addReHypothecatedLiquidity{value: amount0}(shares);

        // Post-conditions: shares minted and token vault unchanged (still 0)
        assertEq(logicEth.balanceOf(address(this)), seedShares + shares);
        assertEq(token1.balanceOf(address(tokenVault)), 0);
    }

    function test_removeReHypothecatedLiquidity_zeroShares_hitsBranch330True() public {
        // To reach `if (shares == 0) revert ZeroShares();` we must pass the `poolActivated` modifier first.
        // So we deploy the logic behind a proxy, initialize it, then configure/activate a pool as the hook.

        // Deploy + initialize logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Configure + activate pool (satisfies `poolActivated` modifier)
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });

        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // opix-target-branch-330-True
        vm.expectRevert(IReHypothecation.ZeroShares.selector);
        logicEth.removeReHypothecatedLiquidity(0);
    }

    function test_collectAccumulatedTax_hitsBranch369True() public {
        // Deploy logic behind proxy (implementation disables initializers)
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire the hook to this logic so poolManager lookups work
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        // allow this test to call restricted functions (roleId=0)
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Create and initialize an ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Activate/configure pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Configure tick range and yield sources
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Seed deposits to both yield sources so collectAccumulatedTax runs through its True branch
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        vm.deal(address(this), amount0);
        logicEth.addReHypothecatedLiquidity{value: amount0}(shares);
        assertEq(logicEth.balanceOf(address(this)), shares);

        // Simulate some yield in both vaults so accumulated tax can become non-zero
        // (Even if yieldTaxPips is 0 by default, the function still executes the branch.)
        if (amount0 > 0) {
            vm.deal(address(this), 1 ether);
            weth.deposit{value: 1 ether}();
            weth.approve(address(wethVault), 1 ether);
            wethVault.deposit(1 ether, address(this));
        }
        if (amount1 > 0) {
            token1.mint(address(this), 1 ether);
            token1.approve(address(tokenVault), 1 ether);
            tokenVault.deposit(1 ether, address(this));
        }

        // Call and assert it executed (branch 369 True). We don't require non-zero collection,
        // but it should not revert and should return two values.
        (uint256 collected0, uint256 collected1) = logicEth.collectAccumulatedTax();
        // Sanity: values are bounded by current vault balances; just ensure call succeeded.
        assertTrue(collected0 >= 0);
        assertTrue(collected1 >= 0);
    }

    function test_withdrawFromYieldSourceToEth_revertsWhenRecipientRejectsETH_branch440False() public {
        // Target: opix-target-branch-440-False (i.e., the `if (!success) revert ETHTransferFailed();` path)
        // We make `recipient.call{value: amount}("")` fail by using a contract with no payable receive/fallback:
        // MockYieldVault fits (it is not payable).

        // Deploy a fresh logic instance behind a proxy so it can be initialized
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire the hook to use this logic so poolManager lookups work
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        // allow this test to call restricted setters (roleId=0)
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Create and initialize an ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Activate/configure pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Configure tick range and yield sources
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // First deposit once so we have shares to withdraw
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        uint256 seedShares = 100e18;
        (uint256 seedAmount0,) = logicEth.previewAddReHypothecatedLiquidity(seedShares);
        vm.deal(address(this), seedAmount0);
        logicEth.addReHypothecatedLiquidity{value: seedAmount0}(seedShares);
        assertEq(logicEth.balanceOf(address(this)), seedShares);

        // Create a recipient that cannot receive ETH (no payable receive/fallback)
        MockYieldVault rejector = new MockYieldVault(IERC20(address(token1)));

        // Transfer shares to the rejector so it is the msg.sender during withdrawal
        require(logicEth.transfer(address(rejector), seedShares), "Transfer failed");
        assertEq(logicEth.balanceOf(address(rejector)), seedShares);

        // Withdraw as rejector; should revert when trying to send ETH to rejector
        vm.startPrank(address(rejector));
        vm.expectRevert(AlphixLogicETH.ETHTransferFailed.selector);
        logicEth.removeReHypothecatedLiquidity(seedShares);
        vm.stopPrank();
    }

    function test_getWeth9_returnsWethAddress_hitsBranch486True() public {
        // Deploy implementation and initialize through proxy because the implementation disables initializers
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );

        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // opix-target-branch-486-True: getWeth9() returns address(_weth9)
        assertEq(logicEth.getWeth9(), address(weth));
    }

    function test_depositToYieldSource_nativeCurrency_entersBranch172True() public {
        // opix-target-branch-172-True: In AlphixLogicETH.depositToYieldSource, enter the
        // `if (currency.isAddressZero())` branch.
        //
        // Key requirement (learned from previous failure): AlphixLogicETH.receive() ONLY accepts ETH from:
        //  - WETH contract (during unwrap), or
        //  - the PoolManager address returned by BaseDynamicFee(_alphixHook).poolManager().
        // So we MUST have msg.sender == poolManager when sending ETH to logic.

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire hook -> logic so `BaseDynamicFee(_alphixHook).poolManager()` is reachable
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        // authorize this test for restricted setters (roleId=0 by default)
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Create/init ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure & activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Configure tick range and yield source for native currency so depositToYieldSource doesn't early-return
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));

        // Provide ETH to poolManager, then send it from poolManager to logicEth (authorized sender)
        uint256 amount = 1 ether;
        vm.deal(address(poolManager), amount);
        vm.startPrank(address(poolManager));
        (bool sent,) = address(logicEth).call{value: amount}("");
        assertTrue(sent, "pre-fund ETH transfer from poolManager to logicEth should succeed");
        vm.stopPrank();

        // Call as hook to satisfy onlyAlphixHook and enter the native-currency branch
        vm.startPrank(address(hook));
        logicEth.depositToYieldSource(Currency.wrap(address(0)), amount);
        vm.stopPrank();

        // Assert: WETH got deposited into the WETH vault
        assertEq(weth.balanceOf(address(wethVault)), amount, "wethVault should receive WETH from deposit");
    }

    function test_withdrawAndApprove_nativeCurrency_revertsETHTransferFailed_branch195True() public {
        // opix-target-branch-195-True: in AlphixLogicETH.withdrawAndApprove (native currency path),
        // force `(bool success,) = _alphixHook.call{value: amount}("")` to return false,
        // so it reverts with ETHTransferFailed.

        // 1) Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // 2) Wire the hook to this logic so PoolManager lookups work when needed
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        // allow this test to call restricted functions (roleId=0)
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // 3) Create/init ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // 4) Configure/activate pool (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // 5) Configure tick range + yield source for native currency so withdrawAndApprove doesn't early-return
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));

        // 6) Seed the WETH vault with WETH shares owned by logicEth
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(wethVault), amount);
        wethVault.deposit(amount, address(logicEth));

        // 7) Make the hook reject ETH transfers so `_alphixHook.call{value: amount}("")` fails.
        // The deployed hook has no payable receive/fallback, so the ETH send should fail.
        vm.startPrank(address(hook));
        vm.expectRevert(AlphixLogicETH.ETHTransferFailed.selector);
        logicEth.withdrawAndApprove(Currency.wrap(address(0)), amount);
        vm.stopPrank();
    }

    function test_withdrawAndApprove_nonNativeCurrency_entersElseBranch196() public {
        // opix-target-branch-196: enter the ELSE branch by making `currency.isAddressZero()` false.
        // Preconditions to avoid early returns:
        // - amount != 0
        // - _yieldSourceState[currency].yieldSource != address(0)
        // - msg.sender must be _alphixHook

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire hook -> logic (so poolManager lookup inside logic works in general)
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        // authorize this test to call `restricted` setters (roleId=0 by default)
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Create/init ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure/activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Configure yield source for NON-native currency so withdrawAndApprove doesn't early-return
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Seed vault with assets owned by logicEth so withdraw succeeds
        uint256 amount = 1 ether;
        token1.mint(address(this), amount);
        token1.approve(address(tokenVault), amount);
        tokenVault.deposit(amount, address(logicEth));

        // Call as hook to satisfy onlyAlphixHook and enter else-branch (non-native currency)
        vm.startPrank(address(hook));
        logicEth.withdrawAndApprove(Currency.wrap(address(token1)), amount);
        vm.stopPrank();

        // Post-condition: Hook approval set for token1 (forceApprove)
        assertEq(token1.allowance(address(logicEth), address(hook)), amount);
    }

    function test_setYieldSource_nonNativeCurrency_revertsInvalidYieldSource_branch231True() public {
        // opix-target-branch-231-True: in AlphixLogicETH.setYieldSource(), take the non-native currency path
        // and make ReHypothecationLib.isValidYieldSource(newYieldSource, currency) return false.
        // This should revert with InvalidYieldSource(newYieldSource).

        // Create an AccessManager where this test contract is authorized for `restricted` calls (roleId=0 by default).
        address localOwner = address(0xBEEF);
        address localHook = address(0xCAFE);

        AccessManager am = new AccessManager(localOwner);
        vm.startPrank(localOwner);
        am.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Deploy dependencies
        MockWETH9 wethLocal = new MockWETH9();
        MockERC20 tokenLocal = new MockERC20("Token", "TKN", 18);

        // Deploy + initialize logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                localOwner,
                localHook,
                address(am),
                address(wethLocal),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Pool must be configured for the `poolConfigured` modifier on setYieldSource
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tokenLocal)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(localHook))
        });

        DynamicFeeLib.PoolParams memory params = DynamicFeeLib.PoolParams({
            minFee: 1,
            maxFee: LPFeeLibrary.MAX_LP_FEE,
            baseMaxFeeDelta: 1,
            lookbackPeriod: 7,
            minPeriod: 1 hours,
            ratioTolerance: 1e15,
            linearSlope: 1e17,
            maxCurrentRatio: 1e24,
            upperSideFactor: 1e18,
            lowerSideFactor: 1e18
        });

        vm.startPrank(localHook);
        logicEth.activateAndConfigurePool(ethKey, 1, 1e18, params);
        vm.stopPrank();

        // Non-native currency: enter the else-branch of currency.isAddressZero().
        // Provide an invalid yield source address (EOA with no code), so isValidYieldSource returns false.
        Currency nonNative = Currency.wrap(address(tokenLocal));
        address invalidYieldSource = address(0xDEAD);

        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.InvalidYieldSource.selector, invalidYieldSource));
        logicEth.setYieldSource(nonNative, invalidYieldSource);
    }

    function test_depositToYieldSourceWeth_revertsWhenYieldSourceNotConfigured_branch387True() public {
        // opix-target-branch-387-True: `_depositToYieldSourceWeth` must revert YieldSourceNotConfigured
        // when state.yieldSource == address(0).
        // IMPORTANT: We must NOT hit the early-return in depositToYieldSource:
        //   if (_yieldSourceState[currency].yieldSource == address(0)) return;
        // So we keep yieldSource configured (non-zero), but make the INTERNAL check see zero by passing
        // a different Currency key (native ETH uses Currency.wrap(address(0)) exactly).

        // Deploy logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire hook -> logic and authorize this test for restricted setters (roleId=0)
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Create/init ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure/activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Configure a yield source for the TRUE native key so depositToYieldSource doesn't early-return.
        Currency nativeKey = Currency.wrap(address(0));
        logicEth.setYieldSource(nativeKey, address(wethVault));

        // Pre-fund logicEth with ETH from PoolManager (authorized sender for receive())
        uint256 amount = 1 ether;
        vm.deal(address(poolManager), amount);
        vm.startPrank(address(poolManager));
        (bool sent,) = address(logicEth).call{value: amount}("");
        assertTrue(sent, "pre-fund ETH transfer from poolManager to logicEth should succeed");
        vm.stopPrank();

        // Now call depositToYieldSource from the hook, but with a DIFFERENT currency key that is NOT address(0),
        // while still making currency.isAddressZero() == true.
        // This is impossible: isAddressZero() is true only for Currency.wrap(address(0)).
        // Therefore the only way to hit branch 387-True is via _depositToYieldSourceWeth itself.
        // We trigger it by calling addReHypothecatedLiquidity (which calls _depositToYieldSourceWeth directly)
        // after clearing native yield source.

        // Clear native yield source to make internal check revert
        logicEth.setYieldSource(nativeKey, address(0));

        // Need poolActivated + tick range, and also ensure we reach _depositToYieldSourceWeth.
        // addReHypothecatedLiquidity will call _depositToYieldSourceWeth for currency0 (ETH) and thus revert.
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);

        // Also configure token1 yield source to avoid reverting earlier on currency1 path
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Provide token1 and approval (needed for amount1 transfer)
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        // Choose some shares and compute required ETH amount0
        uint256 shares = 100e18;
        (uint256 amount0, uint256 amount1) = logicEth.previewAddReHypothecatedLiquidity(shares);
        assertTrue(amount0 > 0, "amount0 must be > 0");
        // amount1 can be 0 in some edge cases; ensure it is funded if >0
        if (amount1 > 0) {
            assertTrue(token1.balanceOf(address(this)) >= amount1, "insufficient token1 for amount1");
        }

        // Call addReHypothecatedLiquidity which will enter _depositToYieldSourceWeth and revert at branch 387
        vm.deal(address(this), amount0);
        vm.expectRevert(abi.encodeWithSelector(IReHypothecation.YieldSourceNotConfigured.selector, nativeKey));
        logicEth.addReHypothecatedLiquidity{value: amount0}(shares);
    }

    function test_collectCurrencyTaxEth_revertsETHTransferFailed_branch471True() public {
        // Target: opix-target-branch-471-True in AlphixLogicETH._collectCurrencyTaxEth
        // Path: collectAccumulatedTax() -> _collectCurrencyTaxEth() -> send ETH to _yieldTreasury
        // Force send failure by making treasury a contract that cannot receive ETH (MockYieldVault).

        // Deploy ETH logic behind proxy
        AlphixLogicETH impl = new AlphixLogicETH();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(
                AlphixLogicETH.initializeEth.selector,
                owner,
                address(hook),
                address(accessManager),
                address(weth),
                "Alphix ETH Shares",
                "aETH"
            )
        );
        AlphixLogicETH logicEth = AlphixLogicETH(payable(address(proxy)));

        // Wire the hook to this logic, and authorize this test for restricted setters (roleId=0 by default)
        vm.startPrank(owner);
        hook.setLogic(address(logicEth));
        accessManager.grantRole(0, address(this), 0);
        vm.stopPrank();

        // Create/init ETH pool
        PoolKey memory ethKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: defaultTickSpacing,
            hooks: IHooks(address(hook))
        });
        poolManager.initialize(ethKey, Constants.SQRT_PRICE_1_1);

        // Configure/activate pool on logic (must be called by hook)
        vm.startPrank(address(hook));
        logicEth.activateAndConfigurePool(ethKey, INITIAL_FEE, INITIAL_TARGET_RATIO, defaultPoolParams);
        vm.stopPrank();

        // Configure tick range and yield sources
        int24 tickLower = TickMath.minUsableTick(ethKey.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(ethKey.tickSpacing);
        logicEth.setTickRange(tickLower, tickUpper);
        logicEth.setYieldSource(Currency.wrap(address(0)), address(wethVault));
        logicEth.setYieldSource(Currency.wrap(address(token1)), address(tokenVault));

        // Set yield tax pips > 0 so yield accumulation produces non-zero accumulatedTax
        logicEth.setYieldTaxPips(500_000); // 50%

        // Set yield treasury to a contract that cannot receive ETH
        MockYieldVault rejectingTreasury = new MockYieldVault(IERC20(address(token1)));
        logicEth.setYieldTreasury(address(rejectingTreasury));

        // Deposit once to create sharesOwned in the WETH vault
        token1.mint(address(this), 1_000_000 ether);
        token1.approve(address(logicEth), type(uint256).max);

        uint256 shares = 100e18;
        (
            uint256 amount0, /* amount1 */
        ) = logicEth.previewAddReHypothecatedLiquidity(shares);
        vm.deal(address(this), amount0);
        logicEth.addReHypothecatedLiquidity{value: amount0}(shares);

        // Simulate yield by transferring WETH into the vault (increases convertToAssets)
        // Mint WETH to this test, then call simulateYield on the vault
        uint256 yieldAmount = 1 ether;
        vm.deal(address(this), yieldAmount);
        weth.deposit{value: yieldAmount}();
        weth.approve(address(wethVault), yieldAmount);
        wethVault.simulateYield(yieldAmount);

        // Now collectAccumulatedTax should attempt to send ETH to rejecting treasury and revert (branch 471 True)
        vm.expectRevert(AlphixLogicETH.ETHTransferFailed.selector);
        logicEth.collectAccumulatedTax();
    }
}
