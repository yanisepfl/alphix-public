// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IAlphixLogic {
    function getFee(PoolKey calldata key) external view returns (uint24);
}
