// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IAlphixLogic {
    /* ERRORS */
    error InvalidLogicContract();

    /* FUNCTIONS */
    /**
     * @notice Getter for the fee of a given pool.
     * @param key The key of the pool to retrieve the fee of.
     * @return The fee of the given pool.
     */
    function getFee(PoolKey calldata key) external view returns (uint24);
    function getFee() external view returns (uint24);
}
