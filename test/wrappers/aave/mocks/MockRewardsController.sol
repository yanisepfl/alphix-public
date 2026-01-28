// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockRewardsController
 * @author Alphix
 * @notice Mock Aave RewardsController for testing purposes.
 */
contract MockRewardsController {
    using SafeERC20 for IERC20;

    // Mapping from user -> asset -> reward token -> claimable amount
    mapping(address => mapping(address => mapping(address => uint256))) public claimableRewards;

    // Reward tokens configured
    address[] public rewardTokens;

    /**
     * @notice Adds a reward token to the list.
     * @param rewardToken The reward token address.
     */
    function addRewardToken(address rewardToken) external {
        rewardTokens.push(rewardToken);
    }

    /**
     * @notice Sets claimable rewards for a user.
     * @param user The user address.
     * @param asset The asset address (e.g., aToken).
     * @param rewardToken The reward token address.
     * @param amount The claimable amount.
     */
    function setClaimableRewards(address user, address asset, address rewardToken, uint256 amount) external {
        claimableRewards[user][asset][rewardToken] = amount;
    }

    /**
     * @notice Claims all rewards for a user.
     * @param assets The list of assets to claim rewards for.
     * @param to The recipient of the rewards.
     * @return rewardsList The list of reward token addresses.
     * @return claimedAmounts The amounts claimed for each reward token.
     */
    function claimAllRewards(address[] calldata assets, address to)
        external
        returns (address[] memory rewardsList, uint256[] memory claimedAmounts)
    {
        rewardsList = new address[](rewardTokens.length);
        claimedAmounts = new uint256[](rewardTokens.length);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            rewardsList[i] = rewardTokens[i];
            uint256 totalClaimed = 0;

            for (uint256 j = 0; j < assets.length; j++) {
                uint256 claimable = claimableRewards[msg.sender][assets[j]][rewardTokens[i]];
                if (claimable > 0) {
                    claimableRewards[msg.sender][assets[j]][rewardTokens[i]] = 0;
                    totalClaimed += claimable;
                }
            }

            claimedAmounts[i] = totalClaimed;

            if (totalClaimed > 0) {
                // Transfer reward tokens to recipient
                IERC20(rewardTokens[i]).safeTransfer(to, totalClaimed);
            }
        }
    }

    /**
     * @notice Returns all reward tokens.
     * @return The list of reward token addresses.
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }
}
