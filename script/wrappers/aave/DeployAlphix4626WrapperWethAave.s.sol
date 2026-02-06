// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Alphix4626WrapperWethAave} from "../../../src/wrappers/aave/Alphix4626WrapperWethAave.sol";
import {IWETH} from "@aave-v3-core/misc/interfaces/IWETH.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployAlphix4626WrapperWethAave
 * @author Alphix
 * @notice Deployment script for Alphix4626WrapperWethAave (WETH-specific with ETH support).
 *
 * @dev Usage:
 *
 * 1. Set environment variables:
 *    export PRIVATE_KEY=0x...
 *    export RPC_URL=https://...
 *
 * 2. Configure deployment parameters below or via environment:
 *    export WETH_ADDRESS=0x...            # WETH contract address
 *    export YIELD_TREASURY=0x...          # Fee recipient address
 *    export POOL_ADDRESSES_PROVIDER=0x... # Aave V3 PoolAddressesProvider
 *    export SHARE_NAME="Alphix WETH"
 *    export SHARE_SYMBOL="alphWETH"
 *    export INITIAL_FEE=100000            # 10% in hundredths of bip
 *    export SEED_LIQUIDITY=1000000000000000000  # 1 WETH (18 decimals)
 *
 * 3. Run deployment:
 *    forge script script/aave/DeployAlphix4626WrapperWethAave.s.sol:DeployAlphix4626WrapperWethAave \
 *      --rpc-url $RPC_URL \
 *      --broadcast \
 *      --verify
 *
 * 4. Post-deployment:
 *    - Add Alphix Hooks via addAlphixHook()
 *    - Transfer ownership if needed via transferOwnership()
 *
 * @dev Network-specific WETH addresses:
 *    Mainnet:  0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
 *    Arbitrum: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1
 *    Optimism: 0x4200000000000000000000000000000000000006
 *    Polygon:  0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619 (WETH, not native MATIC)
 *    Base:     0x4200000000000000000000000000000000000006
 */
contract DeployAlphix4626WrapperWethAave is Script {
    /* DEPLOYMENT PARAMETERS */

    // Aave V3 PoolAddressesProvider addresses by network
    // Mainnet: 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e
    // Arbitrum: 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Optimism: 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Polygon: 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Base: 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D

    /// @notice The WETH contract address
    address public weth;

    /// @notice The address where yield fees are sent
    address public yieldTreasury;

    /// @notice The Aave V3 PoolAddressesProvider
    address public poolAddressesProvider;

    /// @notice The name for the vault share token
    string public shareName;

    /// @notice The symbol for the vault share token
    string public shareSymbol;

    /// @notice Initial fee in hundredths of a bip (100_000 = 10%)
    uint24 public initialFee;

    /// @notice Seed liquidity amount in wei (1e18 = 1 WETH)
    uint256 public seedLiquidity;

    /* DEPLOYMENT */

    function run() external returns (Alphix4626WrapperWethAave wrapper) {
        // Load configuration from environment or use defaults
        _loadConfig();

        // Validate configuration
        _validateConfig();

        // Get deployer
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Alphix4626WrapperWethAave Deployment ===");
        console.log("Deployer:", deployer);
        console.log("WETH:", weth);
        console.log("Yield Treasury:", yieldTreasury);
        console.log("Pool Addresses Provider:", poolAddressesProvider);
        console.log("Share Name:", shareName);
        console.log("Share Symbol:", shareSymbol);
        console.log("Initial Fee (hundredths of bip):", initialFee);
        console.log("Seed Liquidity (wei):", seedLiquidity);

        vm.startBroadcast(deployerPrivateKey);

        // Check if deployer has enough WETH, if not wrap ETH
        uint256 wethBalance = IERC20(weth).balanceOf(deployer);
        bool needsWrap = wethBalance < seedLiquidity;
        if (needsWrap) {
            uint256 ethNeeded = seedLiquidity - wethBalance;
            require(deployer.balance >= ethNeeded, "Insufficient ETH to wrap for seed liquidity");
            console.log("Wrapping ETH to WETH, amount (wei):", ethNeeded);
            IWETH(weth).deposit{value: ethNeeded}();
        }

        // Compute expected wrapper address for approval
        // Note: +1 for approve tx, +1 more if we wrapped ETH
        uint64 deployNonce = vm.getNonce(deployer) + 1;
        address expectedWrapper = _computeCreateAddress(deployer, deployNonce);

        // Approve seed liquidity before deployment
        IERC20(weth).approve(expectedWrapper, seedLiquidity);

        // Deploy wrapper
        wrapper = new Alphix4626WrapperWethAave(
            weth, yieldTreasury, poolAddressesProvider, shareName, shareSymbol, initialFee, seedLiquidity
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Wrapper deployed at:", address(wrapper));
        console.log("WETH:", address(wrapper.WETH()));
        console.log("aToken:", address(wrapper.ATOKEN()));
        console.log("Owner:", wrapper.owner());
        console.log("Total Assets:", wrapper.totalAssets());
        console.log("Total Supply:", wrapper.totalSupply());

        // Verify deployment
        _verifyDeployment(wrapper, deployer);
    }

    /* CONFIGURATION */

    function _loadConfig() internal {
        // Try environment variables first, then use defaults for local testing
        weth = vm.envOr("WETH_ADDRESS", address(0));
        yieldTreasury = vm.envOr("YIELD_TREASURY", address(0));
        poolAddressesProvider = vm.envOr("POOL_ADDRESSES_PROVIDER", address(0));
        shareName = vm.envOr("SHARE_NAME", string("Alphix WETH Vault"));
        shareSymbol = vm.envOr("SHARE_SYMBOL", string("alphWETH"));
        initialFee = uint24(vm.envOr("INITIAL_FEE", uint256(100_000))); // Default 10%
        seedLiquidity = vm.envOr("SEED_LIQUIDITY", uint256(1 ether)); // Default 1 WETH
    }

    function _validateConfig() internal view {
        require(weth != address(0), "WETH_ADDRESS not set");
        require(yieldTreasury != address(0), "YIELD_TREASURY not set");
        require(poolAddressesProvider != address(0), "POOL_ADDRESSES_PROVIDER not set");
        require(seedLiquidity > 0, "SEED_LIQUIDITY must be > 0");
        require(initialFee <= 1_000_000, "INITIAL_FEE too high (max 1_000_000)");
    }

    function _verifyDeployment(Alphix4626WrapperWethAave wrapper, address deployer) internal view {
        require(address(wrapper.WETH()) == weth, "WETH mismatch");
        require(address(wrapper.ASSET()) == weth, "Asset mismatch");
        require(wrapper.owner() == deployer, "Owner mismatch");
        require(wrapper.getFee() == initialFee, "Fee mismatch");
        // Allow 1 wei difference due to Aave aToken rounding
        uint256 totalAssets = wrapper.totalAssets();
        require(totalAssets >= seedLiquidity - 1 && totalAssets <= seedLiquidity + 1, "Seed liquidity mismatch");
        console.log("Deployment verification passed!");
    }

    /* HELPERS */

    /// @notice Compute CREATE address for approval before deployment
    function _computeCreateAddress(address deployer, uint64 nonce) internal pure returns (address) {
        bytes memory data;
        if (nonce == 0x00) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            data = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce));
        } else if (nonce <= 0xff) {
            data = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce));
        } else if (nonce <= 0xffff) {
            data = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce));
        } else if (nonce <= 0xffffff) {
            data = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), uint24(nonce));
        } else {
            data = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), uint32(nonce));
        }
        return address(uint160(uint256(keccak256(data))));
    }
}
