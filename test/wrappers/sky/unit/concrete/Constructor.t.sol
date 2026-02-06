// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperSky} from "../../BaseAlphix4626WrapperSky.t.sol";
import {Alphix4626WrapperSky} from "../../../../../src/wrappers/sky/Alphix4626WrapperSky.sol";
import {IAlphix4626WrapperSky} from "../../../../../src/wrappers/sky/interfaces/IAlphix4626WrapperSky.sol";
import {MockPSM3} from "../../mocks/MockPSM3.sol";
import {MockRateProvider} from "../../mocks/MockRateProvider.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

/**
 * @title ConstructorTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperSky constructor.
 */
contract ConstructorTest is BaseAlphix4626WrapperSky {
    /* IMMUTABLES INITIALIZATION */

    /**
     * @notice Test that PSM is set correctly.
     */
    function test_constructor_setsPSM() public view {
        assertEq(address(wrapper.PSM()), address(psm), "PSM not set correctly");
    }

    /**
     * @notice Test that rate provider is set correctly.
     */
    function test_constructor_setsRateProvider() public view {
        assertEq(address(wrapper.RATE_PROVIDER()), address(rateProvider), "Rate provider not set correctly");
    }

    /**
     * @notice Test that USDS is set correctly.
     */
    function test_constructor_setsUSDS() public view {
        assertEq(address(wrapper.USDS()), address(usds), "USDS not set correctly");
    }

    /**
     * @notice Test that sUSDS is set correctly.
     */
    function test_constructor_setsSUSDS() public view {
        assertEq(address(wrapper.SUSDS()), address(susds), "sUSDS not set correctly");
    }

    /**
     * @notice Test that asset returns USDS.
     */
    function test_constructor_assetIsUSDS() public view {
        assertEq(wrapper.asset(), address(usds), "Asset should be USDS");
    }

    /* STATE INITIALIZATION */

    /**
     * @notice Test that initial fee is set correctly.
     */
    function test_constructor_setsInitialFee() public view {
        assertEq(wrapper.getFee(), DEFAULT_FEE, "Initial fee not set correctly");
    }

    /**
     * @notice Test that yield treasury is set correctly.
     */
    function test_constructor_setsYieldTreasury() public view {
        assertEq(wrapper.getYieldTreasury(), treasury, "Yield treasury not set correctly");
    }

    /**
     * @notice Test that owner is set correctly.
     */
    function test_constructor_setsOwner() public view {
        assertEq(wrapper.owner(), owner, "Owner not set correctly");
    }

    /**
     * @notice Test that initial rate is recorded.
     */
    function test_constructor_recordsInitialRate() public view {
        assertEq(wrapper.getLastRate(), INITIAL_RATE, "Initial rate not recorded");
    }

    /**
     * @notice Test that referral code is set correctly.
     */
    function test_constructor_setsReferralCode() public view {
        assertEq(wrapper.getReferralCode(), 0, "Referral code should be 0");
    }

    /* SEED LIQUIDITY */

    /**
     * @notice Test that seed liquidity is deposited and swapped to sUSDS.
     */
    function test_constructor_depositsSeedLiquidity() public view {
        // Wrapper should hold sUSDS (after swap)
        uint256 susdsBalance = susds.balanceOf(address(wrapper));
        assertGt(susdsBalance, 0, "Wrapper should hold sUSDS");

        // At 1:1 rate, should be approximately equal
        assertApproxEqAbs(susdsBalance, DEFAULT_SEED_LIQUIDITY, 1, "sUSDS balance should match seed liquidity");
    }

    /**
     * @notice Test that seed liquidity mints shares to deployer.
     */
    function test_constructor_mintsSharesToDeployer() public view {
        uint256 ownerShares = wrapper.balanceOf(owner);
        assertEq(ownerShares, DEFAULT_SEED_LIQUIDITY, "Owner should receive seed shares");
    }

    /**
     * @notice Test that total supply equals seed liquidity.
     */
    function test_constructor_totalSupplyMatchesSeed() public view {
        assertEq(wrapper.totalSupply(), DEFAULT_SEED_LIQUIDITY, "Total supply should match seed");
    }

    /* ERC20 METADATA */

    /**
     * @notice Test that name is set correctly.
     */
    function test_constructor_setsName() public view {
        assertEq(wrapper.name(), "Alphix sUSDS Vault", "Name not set correctly");
    }

    /**
     * @notice Test that symbol is set correctly.
     */
    function test_constructor_setsSymbol() public view {
        assertEq(wrapper.symbol(), "alphsUSDS", "Symbol not set correctly");
    }

    /**
     * @notice Test that decimals matches USDS (18).
     */
    function test_constructor_decimalsMatch() public view {
        assertEq(wrapper.decimals(), DEFAULT_DECIMALS, "Decimals should be 18");
    }

    /* REVERT CONDITIONS */

    /**
     * @notice Test that constructor reverts with zero PSM address.
     * @dev When PSM is zero address, calling usds() on it fails with call to non-contract.
     */
    function test_constructor_revertsIfZeroPSM() public {
        usds.mint(owner, DEFAULT_SEED_LIQUIDITY);
        vm.startPrank(owner);

        // When PSM is zero address, calling usds() on it fails
        vm.expectRevert();
        new Alphix4626WrapperSky(address(0), treasury, "Test", "TEST", DEFAULT_FEE, DEFAULT_SEED_LIQUIDITY, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test that constructor reverts with zero treasury address.
     */
    function test_constructor_revertsIfZeroTreasury() public {
        usds.mint(owner, DEFAULT_SEED_LIQUIDITY);
        vm.startPrank(owner);

        vm.expectRevert(IAlphix4626WrapperSky.InvalidAddress.selector);
        new Alphix4626WrapperSky(address(psm), address(0), "Test", "TEST", DEFAULT_FEE, DEFAULT_SEED_LIQUIDITY, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test that constructor reverts with zero seed liquidity.
     */
    function test_constructor_revertsIfZeroSeedLiquidity() public {
        vm.startPrank(owner);

        vm.expectRevert(IAlphix4626WrapperSky.InsufficientSeedLiquidity.selector);
        new Alphix4626WrapperSky(address(psm), treasury, "Test", "TEST", DEFAULT_FEE, 0, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test that constructor reverts with insufficient seed liquidity (below minimum).
     */
    function test_constructor_revertsIfInsufficientSeedLiquidity() public {
        vm.startPrank(owner);

        // MIN_SEED_LIQUIDITY is 1e15, try with 1e14
        vm.expectRevert(IAlphix4626WrapperSky.InsufficientSeedLiquidity.selector);
        new Alphix4626WrapperSky(address(psm), treasury, "Test", "TEST", DEFAULT_FEE, 1e14, 0);
        vm.stopPrank();
    }

    /**
     * @notice Test that constructor reverts if fee is too high.
     */
    function test_constructor_revertsIfFeeTooHigh() public {
        usds.mint(owner, DEFAULT_SEED_LIQUIDITY);
        vm.startPrank(owner);

        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        usds.approve(expectedWrapper, type(uint256).max);

        vm.expectRevert(IAlphix4626WrapperSky.FeeTooHigh.selector);
        new Alphix4626WrapperSky(address(psm), treasury, "Test", "TEST", MAX_FEE + 1, DEFAULT_SEED_LIQUIDITY, 0);
        vm.stopPrank();
    }

    /* CUSTOM REFERRAL CODE */

    /**
     * @notice Test constructor with custom referral code.
     */
    function test_constructor_withCustomReferralCode() public {
        uint256 customReferralCode = 12345;

        // Deploy new mock tokens and PSM
        MockERC20 newUsds = new MockERC20("USDS", "USDS", 18);
        MockERC20 newSusds = new MockERC20("sUSDS", "sUSDS", 18);
        MockRateProvider newRateProvider = new MockRateProvider();
        MockPSM3 newPsm = new MockPSM3(address(newUsds), address(newSusds), address(newRateProvider));
        newSusds.mint(address(newPsm), 1_000_000_000e18);
        newUsds.mint(owner, DEFAULT_SEED_LIQUIDITY);

        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        newUsds.approve(expectedWrapper, type(uint256).max);

        Alphix4626WrapperSky newWrapper = new Alphix4626WrapperSky(
            address(newPsm), treasury, "Test", "TEST", DEFAULT_FEE, DEFAULT_SEED_LIQUIDITY, customReferralCode
        );
        vm.stopPrank();

        assertEq(newWrapper.getReferralCode(), customReferralCode, "Referral code should be set");
    }
}
