// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {MockFaucet} from "../mocks/MockFaucet.sol";
import {MockERC20Token} from "../mocks/MockERC20.sol";

contract DeployMockFaucetScript is Script {
    /////////////////////////////////////
    // ---     .env Parameters     --- //
    /////////////////////////////////////

    // misc variables
    struct DeployData {
        string deploymentNetwork;
    }

    MockFaucet private faucet;
    address private token0Addr;
    MockERC20Token private token0;
    address private token1Addr;
    MockERC20Token private token1;
    address private token2Addr;
    MockERC20Token private token2;
    address private token3Addr;
    MockERC20Token private token3;
    address private token4Addr;
    MockERC20Token private token4;

    function run() public {
        DeployData memory data;
        // get deployment network from .env
        data.deploymentNetwork = vm.envString("DEPLOYMENT_NETWORK");
        if (bytes(data.deploymentNetwork).length == 0) {
            revert("DEPLOYMENT_NETWORK is not set in .env file");
        }

        string memory envVar;

        // get token0 address from .env
        envVar = string.concat("TOKEN0_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        token0Addr = vm.envAddress(envVar);
        token0 = MockERC20Token(token0Addr);

        // get token1 address from .env
        envVar = string.concat("TOKEN1_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        token1Addr = vm.envAddress(envVar);
        token1 = MockERC20Token(token1Addr);

        // get token2 address from .env
        envVar = string.concat("TOKEN2_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        token2Addr = vm.envAddress(envVar);
        token2 = MockERC20Token(token2Addr);

        // get token3 address from .env
        envVar = string.concat("TOKEN3_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        token3Addr = vm.envAddress(envVar);
        token3 = MockERC20Token(token3Addr);

        // get token4 address from .env
        envVar = string.concat("TOKEN4_", data.deploymentNetwork);
        if (bytes(vm.envString(envVar)).length == 0) {
            revert(string.concat(envVar, " is not set in .env file"));
        }
        token4Addr = vm.envAddress(envVar);
        token4 = MockERC20Token(token4Addr);

        /// DEPLOYING FAUCET ///
        vm.startBroadcast();

        faucet = new MockFaucet(token0, token1, token2, token3, token4);
        console.log("Faucet Address:", address(faucet));

        // Set the faucet address for each token (batched for gas efficiency)
        token0.setFaucet(address(faucet));
        token1.setFaucet(address(faucet));
        token2.setFaucet(address(faucet));
        token3.setFaucet(address(faucet));
        token4.setFaucet(address(faucet));

        /// USING FAUCET ///
        faucet.faucet();

        vm.stopBroadcast();
    }
}
