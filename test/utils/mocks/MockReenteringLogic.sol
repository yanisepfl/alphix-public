// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/* OZ IMPORTS */
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {BaseDynamicFee} from "@openzeppelin/uniswap-hooks/src/fee/BaseDynamicFee.sol";

/**
 * @dev Minimal logic that supports IAlphixLogic and tries to re-enter hook.poke from getFee
 */
contract MockReenteringLogic is IERC165 {
    address public immutable hook;

    constructor(address _hook) {
        hook = _hook;
    }

    /**
     * @dev Pretend to support IAlphixLogic for ERC165 checks if any
     */
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    /**
     * @dev Signature matches IAlphixLogic.getFee, but implementation attempts a re-entrancy
     */
    function getFee(PoolKey calldata key) external returns (uint24) {
        // Attempt to re-enter poke
        BaseDynamicFee(hook).poke(key);
        return 3000;
    }
}
