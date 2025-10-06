// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";

contract DeployMockERC20Script is Script {
    /////////////////////////////////////
    // ---     .env Parameters     --- //
    /////////////////////////////////////

    // misc variables
    struct DeployData {
        string deploymentNetwork;
    }

    address private token0Addr;
    uint8 private decimals0;
    MockERC20Token private token0;

    address private deployer;
    address private satoshui;

    function run() public {
        DeployData memory data;
        // get deployment network from .env
        data.deploymentNetwork = vm.envString("DEPLOYMENT_NETWORK");
        if (bytes(data.deploymentNetwork).length == 0) {
            revert("DEPLOYMENT_NETWORK is not set in .env file");
        }

        string memory envVar;

        // get deployer address from .env
        envVar = string.concat("DEPLOYER_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        deployer = vm.envAddress(envVar);

        // get satoshui address from .env
        envVar = string.concat("SATOSHUI_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        satoshui = vm.envAddress(envVar);

        // get token4 decimals from .env
        envVar = string.concat("TOKEN4_DECIMALS_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        decimals0 = uint8(vm.envUint(envVar));
        if (decimals0 < 6 || decimals0 > 18) {
            revert("TOKEN4_DECIMALS must be between 6 and 18");
        }

        vm.startBroadcast();
        token0 = new MockERC20Token("Alphix Testnet DAI", "aDAI", decimals0, deployer);
        token0.mint(deployer, 1_000_000 * 10 ** decimals0); // 1M token0 sent to deployer and satoshui
        token0.mint(satoshui, 1_000_000 * 10 ** decimals0);
        token0Addr = address(token0);
        console.log("Token0 Address: ", token0Addr);
        vm.stopBroadcast();
    }
}
