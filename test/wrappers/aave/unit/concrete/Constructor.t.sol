// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseAlphix4626WrapperAave} from "../../BaseAlphix4626WrapperAave.t.sol";
import {Alphix4626WrapperAave} from "../../../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockAToken} from "../../mocks/MockAToken.sol";

/**
 * @title ConstructorTest
 * @author Alphix
 * @notice Unit tests for the Alphix4626WrapperAave constructor.
 */
contract ConstructorTest is BaseAlphix4626WrapperAave {
    /**
     * @notice Tests that the constructor sets all immutables correctly.
     */
    function test_constructor_setsImmutables() public view {
        assertEq(address(wrapper.ASSET()), address(asset), "Asset mismatch");
        assertEq(address(wrapper.POOL_ADDRESSES_PROVIDER()), address(poolAddressesProvider), "Provider mismatch");
        assertEq(address(wrapper.AAVE_POOL()), address(aavePool), "Pool mismatch");
        assertEq(address(wrapper.ATOKEN()), address(aToken), "AToken mismatch");
    }

    /**
     * @notice Tests that the constructor sets the owner correctly.
     */
    function test_constructor_setsOwner() public view {
        assertEq(wrapper.owner(), owner, "Owner mismatch");
    }

    /**
     * @notice Tests that the constructor sets ERC20 metadata correctly.
     */
    function test_constructor_setsERC20Metadata() public view {
        assertEq(wrapper.name(), "Alphix USDC Vault", "Name mismatch");
        assertEq(wrapper.symbol(), "alphUSDC", "Symbol mismatch");
        assertEq(wrapper.decimals(), DEFAULT_DECIMALS, "Decimals mismatch");
    }

    /**
     * @notice Tests that the constructor performs the seed deposit.
     */
    function test_constructor_performsSeedDeposit() public view {
        // Owner should have received seed liquidity worth of shares
        assertEq(wrapper.balanceOf(owner), DEFAULT_SEED_LIQUIDITY, "Seed shares mismatch");
        assertEq(wrapper.totalSupply(), DEFAULT_SEED_LIQUIDITY, "Total supply mismatch");
    }

    /**
     * @notice Tests that the constructor sets the initial fee.
     */
    function test_constructor_setsInitialFee() public {
        // Create wrapper with different fee to verify
        MockERC20 newAsset = new MockERC20("Test", "TST", 6);
        MockAToken newAToken = new MockAToken("aTest", "aTST", 6, address(newAsset), address(aavePool));
        aavePool.initReserve(address(newAsset), address(newAToken), true, false, false, 0);

        uint24 customFee = 50_000; // 5%
        uint256 seedAmount = 1e6;
        newAsset.mint(owner, seedAmount);

        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        newAsset.approve(expectedWrapper, type(uint256).max);

        // Expect FeeUpdated event with initial fee
        vm.expectEmit(true, true, true, true);
        emit FeeUpdated(0, customFee);

        new Alphix4626WrapperAave(
            address(newAsset), treasury, address(poolAddressesProvider), "Test Vault", "tVAULT", customFee, seedAmount
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that the constructor reverts with zero asset address.
     */
    function test_constructor_revertsWithZeroAsset() public {
        vm.startPrank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.InvalidAddress.selector);
        new Alphix4626WrapperAave(
            address(0), treasury, address(poolAddressesProvider), "Test", "TST", DEFAULT_FEE, DEFAULT_SEED_LIQUIDITY
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that the constructor reverts with zero provider address.
     */
    function test_constructor_revertsWithZeroProvider() public {
        vm.startPrank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.InvalidAddress.selector);
        new Alphix4626WrapperAave(
            address(asset), treasury, address(0), "Test", "TST", DEFAULT_FEE, DEFAULT_SEED_LIQUIDITY
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that the constructor reverts with zero seed liquidity.
     */
    function test_constructor_revertsWithZeroSeedLiquidity() public {
        MockERC20 newAsset = new MockERC20("Test", "TST", 6);
        MockAToken newAToken = new MockAToken("aTest", "aTST", 6, address(newAsset), address(aavePool));
        aavePool.initReserve(address(newAsset), address(newAToken), true, false, false, 0);

        vm.startPrank(owner);
        vm.expectRevert(IAlphix4626WrapperAave.ZeroSeedLiquidity.selector);
        new Alphix4626WrapperAave(
            address(newAsset), treasury, address(poolAddressesProvider), "Test", "TST", DEFAULT_FEE, 0
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that the constructor reverts with fee exceeding max.
     */
    function test_constructor_revertsWithFeeTooHigh() public {
        MockERC20 newAsset = new MockERC20("Test", "TST", 6);
        MockAToken newAToken = new MockAToken("aTest", "aTST", 6, address(newAsset), address(aavePool));
        aavePool.initReserve(address(newAsset), address(newAToken), true, false, false, 0);
        newAsset.mint(owner, DEFAULT_SEED_LIQUIDITY);

        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        newAsset.approve(expectedWrapper, type(uint256).max);

        vm.expectRevert(IAlphix4626WrapperAave.FeeTooHigh.selector);
        new Alphix4626WrapperAave(
            address(newAsset),
            treasury,
            address(poolAddressesProvider),
            "Test",
            "TST",
            MAX_FEE + 1, // Exceeds max
            DEFAULT_SEED_LIQUIDITY
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that the constructor reverts with unsupported asset (no aToken).
     */
    function test_constructor_revertsWithUnsupportedAsset() public {
        // Create asset without initializing in Aave
        MockERC20 unsupportedAsset = new MockERC20("Unsupported", "UNS", 6);
        unsupportedAsset.mint(owner, DEFAULT_SEED_LIQUIDITY);

        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        unsupportedAsset.approve(expectedWrapper, type(uint256).max);

        vm.expectRevert(IAlphix4626WrapperAave.UnsupportedAsset.selector);
        new Alphix4626WrapperAave(
            address(unsupportedAsset),
            treasury,
            address(poolAddressesProvider),
            "Test",
            "TST",
            DEFAULT_FEE,
            DEFAULT_SEED_LIQUIDITY
        );
        vm.stopPrank();
    }

    /**
     * @notice Tests that the constructor sets max allowance to Aave pool.
     */
    function test_constructor_setsMaxAllowance() public view {
        uint256 allowance = asset.allowance(address(wrapper), address(aavePool));
        assertEq(allowance, type(uint256).max, "Allowance not set to max");
    }

    /**
     * @notice Tests that the constructor reverts if seed liquidity exceeds supply cap.
     */
    function test_constructor_revertsIfSeedLiquidityExceedsMax() public {
        // Create new asset and aToken
        MockERC20 newAsset = new MockERC20("Test", "TST", 6);
        MockAToken newAToken = new MockAToken("aTest", "aTST", 6, address(newAsset), address(aavePool));

        // Initialize with a very low supply cap (1 token = 1e6 units for 6 decimals)
        // Supply cap is in whole tokens, so supplyCap=1 means max 1e6 units
        aavePool.initReserve(address(newAsset), address(newAToken), true, false, false, 1);

        // Try to create wrapper with seed liquidity exceeding the cap
        uint256 seedAmount = 2e6; // 2 tokens, exceeds cap of 1 token
        newAsset.mint(owner, seedAmount);

        vm.startPrank(owner);
        uint256 nonce = vm.getNonce(owner);
        address expectedWrapper = vm.computeCreateAddress(owner, nonce);
        newAsset.approve(expectedWrapper, type(uint256).max);

        vm.expectRevert(IAlphix4626WrapperAave.DepositExceedsMax.selector);
        new Alphix4626WrapperAave(
            address(newAsset), treasury, address(poolAddressesProvider), "Test Vault", "tVAULT", DEFAULT_FEE, seedAmount
        );
        vm.stopPrank();
    }
}
