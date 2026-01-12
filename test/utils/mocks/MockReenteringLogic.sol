// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../src/BaseDynamicFee.sol";

/**
 * @dev Minimal logic that supports IAlphixLogic and tries to re-enter hook.poke from poke
 */
contract MockReenteringLogic is IERC165 {
    address public immutable HOOK;

    constructor(address _hook) {
        HOOK = _hook;
    }

    /**
     * @dev Pretend to support IAlphixLogic for ERC165 checks if any
     */
    function supportsInterface(bytes4) external pure override returns (bool) {
        return true;
    }

    /**
     * @dev Signature matches IAlphixLogic.poke, but implementation attempts a re-entrancy
     */
    function poke(uint256 currentRatio) external returns (uint24, uint24, uint256, uint256) {
        // Attempt to re-enter poke - single pool architecture now stores key
        BaseDynamicFee(HOOK).poke(currentRatio);
        return (3000, 3000, 0, 0);
    }
}
