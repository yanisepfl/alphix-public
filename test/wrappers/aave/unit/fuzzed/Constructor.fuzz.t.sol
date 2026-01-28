// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Alphix4626WrapperAave} from "../../../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {IAlphix4626WrapperAave} from "../../../../../src/wrappers/aave/interfaces/IAlphix4626WrapperAave.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockAToken} from "../../mocks/MockAToken.sol";
import {MockAavePool} from "../../mocks/MockAavePool.sol";
import {MockPoolAddressesProvider} from "../../mocks/MockPoolAddressesProvider.sol";

/**
 * @title ConstructorFuzzTest
 * @author Alphix
 * @notice Fuzz tests for the Alphix4626WrapperAave constructor.
 */
contract ConstructorFuzzTest is Test {
    MockERC20 internal asset;
    MockAToken internal aToken;
    MockAavePool internal aavePool;
    MockPoolAddressesProvider internal poolAddressesProvider;

    address internal alphixHook;
    address internal deployer;
    address internal treasury;

    uint24 internal constant MAX_FEE = 1_000_000;

    function setUp() public {
        alphixHook = makeAddr("alphixHook");
        deployer = makeAddr("deployer");
        treasury = makeAddr("treasury");

        asset = new MockERC20("Test", "TEST", 6);
        aavePool = new MockAavePool();
        aToken = new MockAToken("aTest", "aTEST", 6, address(asset), address(aavePool));
        aavePool.initReserve(address(asset), address(aToken), true, false, false, 0);
        poolAddressesProvider = new MockPoolAddressesProvider(address(aavePool));
    }

    /**
     * @notice Fuzz test constructor with valid fees.
     * @param initialFee The initial fee.
     */
    function testFuzz_constructor_validFee(uint24 initialFee) public {
        initialFee = uint24(bound(initialFee, 0, MAX_FEE));
        uint256 seedLiquidity = 1e6;

        asset.mint(deployer, seedLiquidity);

        vm.startPrank(deployer);
        uint256 nonce = vm.getNonce(deployer);
        address expectedWrapper = vm.computeCreateAddress(deployer, nonce);
        asset.approve(expectedWrapper, type(uint256).max);

        Alphix4626WrapperAave wrapper = new Alphix4626WrapperAave(
            address(asset), treasury, address(poolAddressesProvider), "Test Vault", "tVAULT", initialFee, seedLiquidity
        );
        vm.stopPrank();

        assertEq(wrapper.getFee(), initialFee, "Fee should match");
    }

    /**
     * @notice Fuzz test constructor reverts with fee above max.
     * @param initialFee The initial fee.
     */
    function testFuzz_constructor_feeTooHigh_reverts(uint24 initialFee) public {
        initialFee = uint24(bound(initialFee, MAX_FEE + 1, type(uint24).max));
        uint256 seedLiquidity = 1e6;

        asset.mint(deployer, seedLiquidity);

        vm.startPrank(deployer);
        uint256 nonce = vm.getNonce(deployer);
        address expectedWrapper = vm.computeCreateAddress(deployer, nonce);
        asset.approve(expectedWrapper, type(uint256).max);

        vm.expectRevert(IAlphix4626WrapperAave.FeeTooHigh.selector);
        new Alphix4626WrapperAave(
            address(asset), treasury, address(poolAddressesProvider), "Test Vault", "tVAULT", initialFee, seedLiquidity
        );
        vm.stopPrank();
    }

    /**
     * @notice Fuzz test constructor with valid seed liquidity.
     * @param seedLiquidity The seed liquidity.
     */
    function testFuzz_constructor_validSeedLiquidity(uint256 seedLiquidity) public {
        seedLiquidity = bound(seedLiquidity, 1, 1_000_000_000e6);
        uint24 initialFee = 100_000;

        asset.mint(deployer, seedLiquidity);

        vm.startPrank(deployer);
        uint256 nonce = vm.getNonce(deployer);
        address expectedWrapper = vm.computeCreateAddress(deployer, nonce);
        asset.approve(expectedWrapper, type(uint256).max);

        Alphix4626WrapperAave wrapper = new Alphix4626WrapperAave(
            address(asset), treasury, address(poolAddressesProvider), "Test Vault", "tVAULT", initialFee, seedLiquidity
        );
        vm.stopPrank();

        assertEq(wrapper.totalSupply(), seedLiquidity, "Total supply should equal seed");
        assertEq(wrapper.totalAssets(), seedLiquidity, "Total assets should equal seed");
    }

    /**
     * @notice Fuzz test constructor with various decimals.
     * @param decimals The asset decimals.
     */
    function testFuzz_constructor_variousDecimals(uint8 decimals) public {
        decimals = uint8(bound(decimals, 0, 18));

        MockERC20 newAsset = new MockERC20("Test", "TEST", decimals);
        MockAToken newAToken = new MockAToken("aTest", "aTEST", decimals, address(newAsset), address(aavePool));
        aavePool.initReserve(address(newAsset), address(newAToken), true, false, false, 0);

        uint256 seedLiquidity = 10 ** decimals; // 1 token
        uint24 initialFee = 100_000;

        newAsset.mint(deployer, seedLiquidity);

        vm.startPrank(deployer);
        uint256 nonce = vm.getNonce(deployer);
        address expectedWrapper = vm.computeCreateAddress(deployer, nonce);
        newAsset.approve(expectedWrapper, type(uint256).max);

        Alphix4626WrapperAave wrapper = new Alphix4626WrapperAave(
            address(newAsset),
            treasury,
            address(poolAddressesProvider),
            "Test Vault",
            "tVAULT",
            initialFee,
            seedLiquidity
        );
        vm.stopPrank();

        assertEq(wrapper.decimals(), decimals, "Decimals should match asset");
    }
}
