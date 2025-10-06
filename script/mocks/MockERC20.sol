// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract MockERC20Token is MockERC20 {
    address private owner;
    address private faucet;

    constructor(string memory _name, string memory _symbol, uint8 _decimals, address _owner)
        MockERC20(_name, _symbol, _decimals)
    {
        owner = _owner;
    }

    function setFaucet(address _faucet) external {
        require(msg.sender == owner, "Invalid caller");
        faucet = _faucet;
    }

    function mint(address to, uint256 value) public override {
        require(msg.sender == owner || msg.sender == faucet, "Invalid caller");
        _mint(to, value);
    }

    function burn(address from, uint256 value) public override {
        require(msg.sender == owner || msg.sender == faucet, "Invalid caller");
        _burn(from, value);
    }
}
