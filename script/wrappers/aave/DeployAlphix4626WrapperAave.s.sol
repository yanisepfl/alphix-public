// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Alphix4626WrapperAave} from "../../../src/wrappers/aave/Alphix4626WrapperAave.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployAlphix4626WrapperAave
 * @author Alphix
 * @notice Deployment script for Alphix4626WrapperAave (generic ERC20 assets).
 *
 * @dev Usage:
 *
 * 1. Set environment variables:
 *    export PRIVATE_KEY=0x...
 *    export RPC_URL=https://...
 *
 * 2. Configure deployment parameters below or via environment:
 *    export ASSET_ADDRESS=0x...           # The underlying asset (e.g., USDC)
 *    export YIELD_TREASURY=0x...          # Fee recipient address
 *    export POOL_ADDRESSES_PROVIDER=0x... # Aave V3 PoolAddressesProvider
 *    export SHARE_NAME="Alphix USDC"
 *    export SHARE_SYMBOL="alphUSDC"
 *    export INITIAL_FEE=100000            # 10% in hundredths of bip
 *    export SEED_LIQUIDITY=1000000        # 1 USDC (6 decimals)
 *
 * 3. Run deployment:
 *    forge script script/wrappers/aave/DeployAlphix4626WrapperAave.s.sol:DeployAlphix4626WrapperAave \
 *      --rpc-url $RPC_URL \
 *      --broadcast \
 *      --verify
 *
 * 4. Post-deployment:
 *    - Add Alphix Hooks via addAlphixHook()
 *    - Transfer ownership if needed via transferOwnership()
 */
contract DeployAlphix4626WrapperAave is Script {
    /* DEPLOYMENT PARAMETERS */

    // Aave V3 PoolAddressesProvider addresses by network
    // Mainnet: 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e
    // Arbitrum: 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Optimism: 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Polygon: 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb
    // Base: 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D

    /// @notice The underlying asset address (e.g., USDC, USDT, DAI)
    address public asset;

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

    /// @notice Seed liquidity amount (in asset decimals)
    uint256 public seedLiquidity;

    /* DEPLOYMENT */

    function run() external returns (Alphix4626WrapperAave wrapper) {
        // Load configuration from environment or use defaults
        _loadConfig();

        // Validate configuration
        _validateConfig();

        // Get deployer
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Alphix4626WrapperAave Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Asset:", asset);
        console.log("Yield Treasury:", yieldTreasury);
        console.log("Pool Addresses Provider:", poolAddressesProvider);
        console.log("Share Name:", shareName);
        console.log("Share Symbol:", shareSymbol);
        console.log("Initial Fee (hundredths of bip):", initialFee);
        console.log("Seed Liquidity:", seedLiquidity);

        vm.startBroadcast(deployerPrivateKey);

        // Approve seed liquidity before deployment
        // The constructor will transferFrom the deployer
        // Note: +1 because the approve tx itself consumes a nonce
        IERC20(asset).approve(vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1), seedLiquidity);

        // Deploy wrapper
        wrapper = new Alphix4626WrapperAave(
            asset, yieldTreasury, poolAddressesProvider, shareName, shareSymbol, initialFee, seedLiquidity
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Wrapper deployed at:", address(wrapper));
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
        asset = vm.envOr("ASSET_ADDRESS", address(0));
        yieldTreasury = vm.envOr("YIELD_TREASURY", address(0));
        poolAddressesProvider = vm.envOr("POOL_ADDRESSES_PROVIDER", address(0));
        shareName = vm.envOr("SHARE_NAME", string("Alphix Vault"));
        shareSymbol = vm.envOr("SHARE_SYMBOL", string("alphVAULT"));
        seedLiquidity = vm.envOr("SEED_LIQUIDITY", uint256(0));

        // Read fee as uint256 first; validated and cast in _validateConfig
        uint256 rawFee = vm.envOr("INITIAL_FEE", uint256(100_000)); // Default 10%
        require(rawFee <= 1_000_000, "INITIAL_FEE too high (max 1_000_000)");
        initialFee = uint24(rawFee);
    }

    function _validateConfig() internal view {
        require(asset != address(0), "ASSET_ADDRESS not set");
        require(yieldTreasury != address(0), "YIELD_TREASURY not set");
        require(poolAddressesProvider != address(0), "POOL_ADDRESSES_PROVIDER not set");
        require(seedLiquidity > 0, "SEED_LIQUIDITY must be > 0");
        require(bytes(shareName).length > 0, "SHARE_NAME must not be empty");
        require(bytes(shareSymbol).length > 0, "SHARE_SYMBOL must not be empty");
    }

    function _verifyDeployment(Alphix4626WrapperAave wrapper, address deployer) internal view {
        require(address(wrapper.ASSET()) == asset, "Asset mismatch");
        require(wrapper.owner() == deployer, "Owner mismatch");
        require(wrapper.getFee() == initialFee, "Fee mismatch");
        // Allow 1 wei difference due to Aave aToken rounding
        uint256 totalAssets = wrapper.totalAssets();
        require(totalAssets >= seedLiquidity - 1 && totalAssets <= seedLiquidity + 1, "Seed liquidity mismatch");
        console.log("Deployment verification passed!");
    }
}
