// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Alphix4626WrapperSky} from "../../../src/wrappers/sky/Alphix4626WrapperSky.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPSM3} from "../../../src/wrappers/sky/interfaces/IPSM3.sol";

/**
 * @title DeployAlphix4626WrapperSky
 * @author Alphix
 * @notice Deployment script for Alphix4626WrapperSky (USDS/sUSDS vault via Spark PSM).
 *
 * @dev Usage:
 *
 * 1. Set environment variables:
 *    export PRIVATE_KEY=0x...
 *    export RPC_URL=https://...
 *
 * 2. Configure deployment parameters below or via environment:
 *    export SKY_PSM_ADDRESS=0x...            # Spark PSM3 address
 *    export YIELD_TREASURY=0x...             # Fee recipient address
 *    export SKY_SHARE_NAME="Alphix sUSDS"
 *    export SKY_SHARE_SYMBOL="alphsUSDS"
 *    export INITIAL_FEE=100000               # 10% in hundredths of bip
 *    export SKY_SEED_LIQUIDITY=1000000000000000000  # 1 USDS (18 decimals)
 *    export SKY_REFERRAL_CODE=0              # PSM referral code (optional)
 *
 * 3. Run deployment:
 *    forge script script/sky/DeployAlphix4626WrapperSky.s.sol:DeployAlphix4626WrapperSky \
 *      --rpc-url $RPC_URL \
 *      --broadcast \
 *      --verify
 *
 * 4. Post-deployment:
 *    - Add Alphix Hooks via addAlphixHook()
 *    - Transfer ownership if needed via transferOwnership()
 *
 * @dev Network-specific PSM addresses:
 *    Base: 0x1601843c5E9bC251A3272907010AFa41Fa18347E
 */
contract DeployAlphix4626WrapperSky is Script {
    /* DEPLOYMENT PARAMETERS */

    /// @notice The Spark PSM3 address
    address public psm;

    /// @notice The address where yield fees are sent
    address public yieldTreasury;

    /// @notice The name for the vault share token
    string public shareName;

    /// @notice The symbol for the vault share token
    string public shareSymbol;

    /// @notice Initial fee in hundredths of a bip (100_000 = 10%)
    uint24 public initialFee;

    /// @notice Seed liquidity amount in USDS (18 decimals)
    uint256 public seedLiquidity;

    /// @notice Referral code for PSM swaps (can be 0)
    uint256 public referralCode;

    /* DEPLOYMENT */

    function run() external returns (Alphix4626WrapperSky wrapper) {
        // Load configuration from environment or use defaults
        _loadConfig();

        // Validate configuration
        _validateConfig();

        // Get deployer
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get USDS address from PSM
        address usds = IPSM3(psm).usds();

        console.log("=== Alphix4626WrapperSky Deployment ===");
        console.log("Deployer:", deployer);
        console.log("PSM:", psm);
        console.log("USDS:", usds);
        console.log("Yield Treasury:", yieldTreasury);
        console.log("Share Name:", shareName);
        console.log("Share Symbol:", shareSymbol);
        console.log("Initial Fee (hundredths of bip):", initialFee);
        console.log("Seed Liquidity (wei):", seedLiquidity);
        console.log("Referral Code:", referralCode);

        vm.startBroadcast(deployerPrivateKey);

        // Approve seed liquidity before deployment
        // The constructor will transferFrom the deployer
        // Note: +1 because the approve tx itself consumes a nonce
        IERC20(usds).approve(_computeCreateAddress(deployer, vm.getNonce(deployer) + 1), seedLiquidity);

        // Deploy wrapper
        wrapper = new Alphix4626WrapperSky(
            psm, yieldTreasury, shareName, shareSymbol, initialFee, seedLiquidity, referralCode
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Wrapper deployed at:", address(wrapper));
        console.log("PSM:", address(wrapper.PSM()));
        console.log("USDS:", address(wrapper.USDS()));
        console.log("sUSDS:", address(wrapper.SUSDS()));
        console.log("Rate Provider:", address(wrapper.RATE_PROVIDER()));
        console.log("Owner:", wrapper.owner());
        console.log("Total Assets:", wrapper.totalAssets());
        console.log("Total Supply:", wrapper.totalSupply());

        // Verify deployment
        _verifyDeployment(wrapper, deployer);
    }

    /* CONFIGURATION */

    function _loadConfig() internal {
        // Try environment variables first, then use defaults for local testing
        psm = vm.envOr("SKY_PSM_ADDRESS", address(0));
        yieldTreasury = vm.envOr("YIELD_TREASURY", address(0));
        shareName = vm.envOr("SKY_SHARE_NAME", string("Alphix sUSDS Vault"));
        shareSymbol = vm.envOr("SKY_SHARE_SYMBOL", string("alphsUSDS"));
        initialFee = uint24(vm.envOr("INITIAL_FEE", uint256(100_000))); // Default 10%
        seedLiquidity = vm.envOr("SKY_SEED_LIQUIDITY", uint256(1 ether)); // Default 1 USDS
        referralCode = vm.envOr("SKY_REFERRAL_CODE", uint256(0));
    }

    function _validateConfig() internal view {
        require(psm != address(0), "SKY_PSM_ADDRESS not set");
        require(yieldTreasury != address(0), "YIELD_TREASURY not set");
        require(seedLiquidity > 0, "SKY_SEED_LIQUIDITY must be > 0");
        require(initialFee <= 1_000_000, "INITIAL_FEE too high (max 1_000_000)");
    }

    function _verifyDeployment(Alphix4626WrapperSky wrapper, address deployer) internal view {
        require(address(wrapper.PSM()) == psm, "PSM mismatch");
        require(wrapper.owner() == deployer, "Owner mismatch");
        require(wrapper.getFee() == initialFee, "Fee mismatch");
        require(wrapper.totalSupply() == seedLiquidity, "Seed liquidity mismatch");
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
