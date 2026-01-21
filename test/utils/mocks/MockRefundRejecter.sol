// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AlphixETH} from "../../../src/AlphixETH.sol";

/**
 * @title MockRefundRejecter
 * @notice Mock contract that rejects ETH refunds for testing RefundFailed error
 * @dev This contract has no receive() or fallback() function, so any ETH sent to it will revert
 */
contract MockRefundRejecter {
    /**
     * @notice Calls addReHypothecatedLiquidity on the hook with the provided ETH
     * @dev If the hook tries to refund excess ETH, it will fail because this contract rejects ETH
     * @param hook The AlphixETH hook to call
     * @param shares The number of shares to request
     */
    function callAddLiquidity(AlphixETH hook, uint256 shares) external payable {
        hook.addReHypothecatedLiquidity{value: msg.value}(shares);
    }

    // No receive() or fallback() - will reject ETH refunds
}
