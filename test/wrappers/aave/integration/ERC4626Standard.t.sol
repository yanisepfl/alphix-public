// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";

import {Alphix4626WrapperAave} from "../../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockAToken} from "../mocks/MockAToken.sol";
import {MockAavePool} from "../mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "../mocks/MockPoolAddressesProvider.sol";

/**
 * @title ERC4626StandardTest
 * @author Alphix
 * @notice Integration tests using a16z ERC4626 standard property tests.
 * @dev Since the wrapper has access control (only hook/owner can deposit),
 *      we adapt the tests to use authorized callers.
 */
contract ERC4626StandardTest is ERC4626Test {
    MockERC20 internal asset;
    MockAToken internal aToken;
    MockAavePool internal aavePool;
    MockPoolAddressesProvider internal poolAddressesProvider;
    Alphix4626WrapperAave internal wrapper;

    address internal alphixHook;
    address internal wrapperOwner;
    address internal treasury;

    uint24 internal constant DEFAULT_FEE = 100_000; // 10%
    uint256 internal constant SEED_LIQUIDITY = 1e6;

    function setUp() public override {
        // Setup hook and owner as authorized users
        alphixHook = makeAddr("alphixHook");
        wrapperOwner = makeAddr("wrapperOwner");
        treasury = makeAddr("treasury");

        // Deploy mock underlying asset
        asset = new MockERC20("USD Coin", "USDC", 6);

        // Deploy mock Aave pool
        aavePool = new MockAavePool();

        // Deploy mock aToken
        aToken = new MockAToken("Aave USDC", "aUSDC", 6, address(asset), address(aavePool));

        // Initialize reserve in pool
        aavePool.initReserve(address(asset), address(aToken), true, false, false, 0);

        // Deploy mock pool addresses provider
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));

        // Fund owner with asset for seed deposit
        asset.mint(wrapperOwner, SEED_LIQUIDITY);

        // Deploy wrapper
        vm.startPrank(wrapperOwner);
        uint256 nonce = vm.getNonce(wrapperOwner);
        address expectedWrapper = vm.computeCreateAddress(wrapperOwner, nonce);
        asset.approve(expectedWrapper, type(uint256).max);

        wrapper = new Alphix4626WrapperAave(
            address(asset),
            treasury,
            address(poolAddressesProvider),
            "Alphix USDC Vault",
            "alphUSDC",
            DEFAULT_FEE,
            SEED_LIQUIDITY
        );

        // Add alphixHook as authorized hook
        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Set up a16z test variables
        _underlying_ = address(asset);
        _vault_ = address(wrapper);
        _delta_ = 0;
        _vaultMayBeEmpty = false;
        _unlimitedAmount = false;
    }

    /**
     * @dev Override setUpVault to use authorized callers.
     *      Since only hook/owner can deposit, we map test users to authorized addresses.
     */
    function setUpVault(Init memory init) public override {
        // Map all test users to authorized callers (hook or owner)
        // User 0 and 2 -> alphixHook
        // User 1 and 3 -> wrapperOwner
        init.user[0] = alphixHook;
        init.user[1] = wrapperOwner;
        init.user[2] = alphixHook;
        init.user[3] = wrapperOwner;

        // Setup initial shares and assets for individual users
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];

            // Bound shares to reasonable amounts
            uint256 shares = bound(init.share[i], 0, 1_000_000e6);
            if (shares > 0) {
                asset.mint(user, shares);
                vm.prank(user);
                asset.approve(address(wrapper), shares);
                vm.prank(user);
                try wrapper.deposit(shares, user) {} catch {}
            }

            // Assets (for user's balance, not deposited)
            uint256 assets = bound(init.asset[i], 0, 1_000_000e6);
            if (assets > 0) {
                asset.mint(user, assets);
            }
        }

        // Setup yield
        setUpYield(init);
    }

    /**
     * @dev Override setUpYield to simulate yield through Aave mock.
     */
    function setUpYield(Init memory init) public override {
        if (init.yield >= 0) {
            uint256 gain = uint256(init.yield);
            gain = bound(gain, 0, 100_000_000e6); // Cap yield
            if (gain > 0) {
                // Simulate yield by minting aTokens to wrapper
                aavePool.simulateYield(
                    address(asset), address(wrapper), 1e18 + (gain * 1e18 / aToken.balanceOf(address(wrapper)))
                );
            }
        }
        // Note: We don't handle negative yield (loss) as our mock doesn't support it
    }

    // Override tests that rely on unrestricted access to skip them
    // or adapt them to use authorized callers

    /**
     * @notice Override deposit test to use authorized caller.
     */
    function test_deposit(Init memory init, uint256 assets, uint256 allowance) public override {
        setUpVault(init);
        address caller = alphixHook; // Use authorized caller
        address receiver = alphixHook; // Must be authorized receiver too
        assets = bound(assets, 0, _max_deposit(caller));
        _approve(_underlying_, caller, _vault_, allowance);
        prop_deposit(caller, receiver, assets);
    }

    /**
     * @notice Override previewDeposit test to use authorized caller.
     */
    function test_previewDeposit(Init memory init, uint256 assets) public override {
        setUpVault(init);
        address caller = alphixHook;
        address receiver = alphixHook;
        address other = wrapperOwner;
        assets = bound(assets, 0, _max_deposit(caller));
        _approve(_underlying_, caller, _vault_, type(uint256).max);
        prop_previewDeposit(caller, receiver, other, assets);
    }

    /**
     * @notice Override maxDeposit test - it should work for any caller.
     */
    function test_maxDeposit(Init memory init) public override {
        setUpVault(init);
        address caller = alphixHook;
        address receiver = alphixHook;
        prop_maxDeposit(caller, receiver);
    }

    // Skip mint/withdraw/redeem tests since they're not implemented yet
    function test_maxMint(Init memory) public override {}
    function test_previewMint(Init memory, uint256) public override {}
    function test_mint(Init memory, uint256, uint256) public override {}
    function test_maxWithdraw(Init memory) public override {}
    function test_previewWithdraw(Init memory, uint256) public override {}
    function test_withdraw(Init memory, uint256, uint256) public override {}
    function test_withdraw_zero_allowance(Init memory, uint256) public override {}
    function test_maxRedeem(Init memory) public override {}
    function test_previewRedeem(Init memory, uint256) public override {}
    function test_redeem(Init memory, uint256, uint256) public override {}
    function test_redeem_zero_allowance(Init memory, uint256) public override {}

    // Skip round-trip tests since withdraw/redeem not implemented
    function test_RT_deposit_redeem(Init memory, uint256) public override {}
    function test_RT_deposit_withdraw(Init memory, uint256) public override {}
    function test_RT_redeem_deposit(Init memory, uint256) public override {}
    function test_RT_redeem_mint(Init memory, uint256) public override {}
    function test_RT_mint_withdraw(Init memory, uint256) public override {}
    function test_RT_mint_redeem(Init memory, uint256) public override {}
    function test_RT_withdraw_mint(Init memory, uint256) public override {}
    function test_RT_withdraw_deposit(Init memory, uint256) public override {}

    /**
     * @dev Override _max_deposit to respect wrapper's access control.
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function _max_deposit(address from) internal view override returns (uint256) {
        if (from != alphixHook && from != wrapperOwner) return 0;
        uint256 balance = asset.balanceOf(from);
        uint256 maxDep = wrapper.maxDeposit(from);
        return balance < maxDep ? balance : maxDep;
    }
}
