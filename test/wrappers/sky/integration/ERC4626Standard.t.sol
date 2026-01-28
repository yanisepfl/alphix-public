// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC4626Test} from "erc4626-tests/ERC4626.test.sol";

import {Alphix4626WrapperSky} from "../../../../src/wrappers/sky/Alphix4626WrapperSky.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPSM3} from "../mocks/MockPSM3.sol";
import {MockRateProvider} from "../mocks/MockRateProvider.sol";

/**
 * @title ERC4626StandardTest
 * @author Alphix
 * @notice Integration tests using a16z ERC4626 standard property tests.
 * @dev Since the wrapper has access control (only hook/owner can deposit),
 *      we adapt the tests to use authorized callers.
 *
 *      Sky wrapper specifics:
 *      - Asset is USDS (18 decimals)
 *      - Holds sUSDS internally (non-rebasing, yield via rate appreciation)
 *      - Rate provider returns USDS per sUSDS in 27 decimal precision
 *      - PSM3 used for USDS <-> sUSDS swaps
 */
contract ERC4626StandardTest is ERC4626Test {
    MockERC20 internal usds;
    MockERC20 internal susds;
    MockPSM3 internal psm;
    MockRateProvider internal rateProvider;
    Alphix4626WrapperSky internal wrapper;

    address internal alphixHook;
    address internal wrapperOwner;
    address internal treasury;

    uint24 internal constant DEFAULT_FEE = 100_000; // 10%
    uint256 internal constant SEED_LIQUIDITY = 1e18;

    function setUp() public override {
        // Setup hook and owner as authorized users
        alphixHook = makeAddr("alphixHook");
        wrapperOwner = makeAddr("wrapperOwner");
        treasury = makeAddr("treasury");

        // Deploy mock tokens
        usds = new MockERC20("USDS", "USDS", 18);
        susds = new MockERC20("sUSDS", "sUSDS", 18);

        // Deploy mock rate provider
        rateProvider = new MockRateProvider();

        // Deploy mock PSM
        psm = new MockPSM3(address(usds), address(susds), address(rateProvider));

        // Fund PSM with liquidity for swaps
        susds.mint(address(psm), 1_000_000_000e18);
        usds.mint(address(psm), 1_000_000_000e18);

        // Fund owner with asset for seed deposit
        usds.mint(wrapperOwner, SEED_LIQUIDITY);

        // Deploy wrapper
        vm.startPrank(wrapperOwner);
        uint256 nonce = vm.getNonce(wrapperOwner);
        address expectedWrapper = vm.computeCreateAddress(wrapperOwner, nonce);
        usds.approve(expectedWrapper, type(uint256).max);

        wrapper = new Alphix4626WrapperSky(
            address(psm), treasury, "Alphix sUSDS Vault", "alphsUSDS", DEFAULT_FEE, SEED_LIQUIDITY, 0
        );

        // Add alphixHook as authorized hook
        wrapper.addAlphixHook(alphixHook);
        vm.stopPrank();

        // Approve wrapper for hook
        vm.prank(alphixHook);
        usds.approve(address(wrapper), type(uint256).max);

        // Set up a16z test variables
        _underlying_ = address(usds);
        _vault_ = address(wrapper);
        // Allow 0 wei tolerance - exact ERC4626 compliance after swapExactOut fix
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

            // Bound shares to reasonable amounts (18 decimals for Sky)
            uint256 shares = bound(init.share[i], 0, 1_000_000e18);
            if (shares > 0) {
                usds.mint(user, shares);
                vm.prank(user);
                usds.approve(address(wrapper), shares);
                vm.prank(user);
                try wrapper.deposit(shares, user) {} catch {}
            }

            // Assets (for user's balance, not deposited)
            uint256 assets = bound(init.asset[i], 0, 1_000_000e18);
            if (assets > 0) {
                usds.mint(user, assets);
            }
        }

        // Setup yield
        setUpYield(init);
    }

    /**
     * @dev Override setUpYield to simulate yield through rate appreciation.
     *      Sky wrapper: yield comes from sUSDS rate increase, not rebasing.
     */
    function setUpYield(Init memory init) public override {
        if (init.yield >= 0) {
            uint256 gain = uint256(init.yield);
            gain = bound(gain, 0, 100); // Cap yield percentage at 100%
            if (gain > 0) {
                // Simulate yield by increasing the rate
                rateProvider.simulateYield(gain);
            }
        }
        // Note: We don't handle negative yield (slash) in the standard tests
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

    /**
     * @notice Override maxWithdraw test for authorized callers.
     */
    function test_maxWithdraw(Init memory init) public override {
        setUpVault(init);
        address caller = alphixHook;
        address owner_ = alphixHook;
        prop_maxWithdraw(caller, owner_);
    }

    /**
     * @notice Override previewWithdraw test for authorized callers.
     */
    function test_previewWithdraw(Init memory init, uint256 assets) public override {
        setUpVault(init);
        address caller = alphixHook;
        address receiver = alphixHook;
        address owner_ = alphixHook;
        address other = wrapperOwner;
        uint256 maxWith = wrapper.maxWithdraw(owner_);
        assets = bound(assets, 0, maxWith);
        prop_previewWithdraw(caller, receiver, owner_, other, assets);
    }

    /**
     * @notice Override withdraw test for authorized callers.
     */
    function test_withdraw(
        Init memory init,
        uint256 assets,
        uint256 /* allowance */
    )
        public
        override
    {
        setUpVault(init);
        address caller = alphixHook;
        address receiver = alphixHook;
        address owner_ = alphixHook;
        uint256 maxWith = wrapper.maxWithdraw(owner_);
        assets = bound(assets, 0, maxWith);
        // Skip allowance test since we're using caller == owner
        prop_withdraw(caller, receiver, owner_, assets);
    }

    /**
     * @notice Override withdraw_zero_allowance test.
     */
    function test_withdraw_zero_allowance(Init memory init, uint256 assets) public override {
        // Skip - our wrapper requires caller == owner, no allowance mechanism
    }

    /**
     * @notice Override maxRedeem test for authorized callers.
     */
    function test_maxRedeem(Init memory init) public override {
        setUpVault(init);
        address caller = alphixHook;
        address owner_ = alphixHook;
        prop_maxRedeem(caller, owner_);
    }

    /**
     * @notice Override previewRedeem test for authorized callers.
     */
    function test_previewRedeem(Init memory init, uint256 shares) public override {
        setUpVault(init);
        address caller = alphixHook;
        address receiver = alphixHook;
        address owner_ = alphixHook;
        address other = wrapperOwner;
        uint256 maxRed = wrapper.maxRedeem(owner_);
        shares = bound(shares, 0, maxRed);
        prop_previewRedeem(caller, receiver, owner_, other, shares);
    }

    /**
     * @notice Override redeem test for authorized callers.
     */
    function test_redeem(
        Init memory init,
        uint256 shares,
        uint256 /* allowance */
    )
        public
        override
    {
        setUpVault(init);
        address caller = alphixHook;
        address receiver = alphixHook;
        address owner_ = alphixHook;
        uint256 maxRed = wrapper.maxRedeem(owner_);
        shares = bound(shares, 0, maxRed);
        // Skip allowance test since we're using caller == owner
        prop_redeem(caller, receiver, owner_, shares);
    }

    /**
     * @notice Override redeem_zero_allowance test.
     */
    function test_redeem_zero_allowance(Init memory init, uint256 shares) public override {
        // Skip - our wrapper requires caller == owner, no allowance mechanism
    }

    // Skip mint tests since the wrapper doesn't support the mint function
    function test_maxMint(Init memory) public override {}
    function test_previewMint(Init memory, uint256) public override {}
    function test_mint(Init memory, uint256, uint256) public override {}

    /**
     * @notice Override round-trip deposit -> redeem test.
     */
    function test_RT_deposit_redeem(Init memory init, uint256 assets) public override {
        setUpVault(init);
        address caller = alphixHook;
        assets = bound(assets, 0, _max_deposit(caller));
        _approve(_underlying_, caller, _vault_, type(uint256).max);
        prop_RT_deposit_redeem(caller, assets);
    }

    /**
     * @notice Override round-trip deposit -> withdraw test.
     */
    function test_RT_deposit_withdraw(Init memory init, uint256 assets) public override {
        setUpVault(init);
        address caller = alphixHook;
        assets = bound(assets, 0, _max_deposit(caller));
        _approve(_underlying_, caller, _vault_, type(uint256).max);
        prop_RT_deposit_withdraw(caller, assets);
    }

    /**
     * @notice Override round-trip redeem -> deposit test.
     */
    function test_RT_redeem_deposit(Init memory init, uint256 shares) public override {
        setUpVault(init);
        address caller = alphixHook;
        uint256 maxRed = wrapper.maxRedeem(caller);
        shares = bound(shares, 0, maxRed);
        _approve(_underlying_, caller, _vault_, type(uint256).max);
        prop_RT_redeem_deposit(caller, shares);
    }

    // Skip mint-related round-trip tests
    function test_RT_redeem_mint(Init memory, uint256) public override {}
    function test_RT_mint_withdraw(Init memory, uint256) public override {}
    function test_RT_mint_redeem(Init memory, uint256) public override {}

    /**
     * @notice Override round-trip withdraw -> deposit test.
     */
    function test_RT_withdraw_deposit(Init memory init, uint256 assets) public override {
        setUpVault(init);
        address caller = alphixHook;
        uint256 maxWith = wrapper.maxWithdraw(caller);
        assets = bound(assets, 0, maxWith);
        _approve(_underlying_, caller, _vault_, type(uint256).max);
        prop_RT_withdraw_deposit(caller, assets);
    }

    // Skip mint-related round-trip test
    function test_RT_withdraw_mint(Init memory, uint256) public override {}

    /**
     * @dev Override _max_deposit to respect wrapper's access control.
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function _max_deposit(address from) internal view override returns (uint256) {
        if (from != alphixHook && from != wrapperOwner) return 0;
        uint256 balance = usds.balanceOf(from);
        uint256 maxDep = wrapper.maxDeposit(from);
        return balance < maxDep ? balance : maxDep;
    }
}
