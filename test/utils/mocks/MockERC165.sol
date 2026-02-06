// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Minimal contract that implements ERC165 but does not support IAlphix interface
 */
contract MockERC165 is IERC165 {
    function supportsInterface(bytes4) external pure override returns (bool) {
        return false;
    }
}
