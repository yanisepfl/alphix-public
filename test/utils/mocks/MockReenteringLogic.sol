// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

/* OZ IMPORTS */
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/* LOCAL IMPORTS */
import {BaseDynamicFee} from "../../../src/BaseDynamicFee.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";

/**
 * @dev Minimal logic that supports IAlphixLogic and tries to re-enter hook.poke from getFee
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
     * @dev Signature matches IAlphixLogic.computeFeeAndTargetRatio, but implementation attempts a re-entrancy
     */
    function computeFeeAndTargetRatio(PoolKey calldata key, uint256 currentRatio)
        external
        returns (uint24, uint256, uint256, DynamicFeeLib.OobState memory)
    {
        // Attempt to re-enter poke
        BaseDynamicFee(HOOK).poke(key, currentRatio);
        return (3000, 0, 0, DynamicFeeLib.OobState(false, 0));
    }
}
