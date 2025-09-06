// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/**
 * @title IAlphixLogic.
 * @notice Interface for the Alphix Hook logic.
 * @dev Defines the external API for the upgradeable Hook logic.
 */
interface IAlphixLogic {
    /* ERRORS */

    error InvalidLogicContract();
    error InvalidCaller();

    /* CORE FUNCTIONS */

    /**
     * @notice Getter for the fee of a given pool.
     * @param key The key of the pool to retrieve the fee of.
     * @return The fee of the given pool.
     */
    function getFee(PoolKey calldata key) external view returns (uint24);
    function getFee() external view returns (uint24);

    /* HOOK ENTRY POINTS */

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96) external returns (bytes4);
    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        returns (bytes4);
}
