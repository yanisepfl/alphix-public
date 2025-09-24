// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* UNISWAP V4 IMPORTS */
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";

/**
 * @title DynamicFeeLib.
 * @notice Pure library for Alphix dynamic fee algorithm and EMA.
 * @dev All math uses 1e18 fixed-point for ratios; fees are uint24.
 */
library DynamicFeeLib {
    using FullMath for uint256;

    uint256 internal constant ONE_WAD = 1e18;
    uint256 internal constant ALPHA_NUMERATOR = 2 * ONE_WAD;

    /**
     * @dev PoolType-dependent parameters.
     * - Bounds are used by clampFee and to validate updates.
     * - Algorithm knobs control fee sensitivity and EMA smoothing.
     * - Side multipliers to throttle by side.
     */
    struct PoolTypeParams {
        // Bounds
        uint24 minFee;
        uint24 maxFee;
        // Algorithm knobs
        uint24 baseMaxFeeDelta; // e.g. 100 = 0.01%
        uint24 lookbackPeriod; // EMA smoothing factor alpha = 1e18 * 2 / (lookbackPeriod + 1)
        uint256 minPeriod; // cooldown in seconds
        uint256 ratioTolerance; // band half-width in 1e18
        uint256 linearSlope; // sensitivity vs relative deviation in 1e18
        uint256 maxCurrentRatio; // maximum allowed current ratio in 1e18
        // Side multipliers
        uint256 upperSideFactor;
        uint256 lowerSideFactor;
    }

    /**
     * @dev Tracks out-of-band dynamics per pool.
     * - consecutiveOOBHits increases within a same-side run and resets in band.
     * - lastOOBWasUpper records side to reset streak on flip.
     */
    struct OOBState {
        bool lastOOBWasUpper;
        uint24 consecutiveOOBHits;
    }

    /**
     * @notice Check whether a current ratio is within a symmetric tolerance band.
     * @param target The target ratio in 1e18.
     * @param tol The tolerance half-width in 1e18.
     * @param current The current ratio in 1e18.
     * @return upper True if above upper bound.
     * @return inBand True if within tolerated bounds.
     */
    function withinBounds(uint256 target, uint256 tol, uint256 current)
        internal
        pure
        returns (bool upper, bool inBand)
    {
        uint256 delta = target.mulDiv(tol, ONE_WAD);
        uint256 lowerBound = target > delta ? target - delta : 0;
        uint256 upperBound = target + delta;
        bool lower = current < lowerBound;
        upper = current > upperBound;
        inBand = !(lower || upper);
    }

    /**
     * @notice Compute a new fee based on current/target ratios and parameters.
     * @dev Implements:
     *  - in-band: clamp current fee to bounds, reset streak.
     *  - out-of-band: update streak/side, compute deviation and linear adjustment rate,
     *    clamp to maxAdjRate, convert to feeDelta proportional to current fee,
     *    throttle by streak, then apply side multiplier and clamp to bounds.
     * @param currentFee The current LP fee from pool.
     * @param currentRatio The current ratio in 1e18.
     * @param targetRatio The target ratio in 1e18.
     * @param globalMaxAdjRate Global cap for adjustmentRate in 1e18.
     * @param p PoolType-dependent parameters (including bounds and factors).
     * @param s Out-of-band state (streak and last side).
     * @return newFee The clamped new LP fee.
     * @return sOut The updated out-of-band state.
     */
    function computeNewFee(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate,
        PoolTypeParams memory p,
        OOBState memory s
    ) internal pure returns (uint24 newFee, OOBState memory sOut) {
        sOut = s;

        (bool isUpper, bool inBand) = withinBounds(targetRatio, p.ratioTolerance, currentRatio);
        if (targetRatio == 0 || inBand) {
            sOut.consecutiveOOBHits = 0;
            return (clampFee(uint256(currentFee), p.minFee, p.maxFee), sOut);
        }

        return _computeOOBFee(currentFee, currentRatio, targetRatio, globalMaxAdjRate, p, sOut, isUpper);
    }

    /**
     * @dev Helper function for out-of-band fee computation to reduce stack depth.
     */
    function _computeOOBFee(
        uint24 currentFee,
        uint256 currentRatio,
        uint256 targetRatio,
        uint256 globalMaxAdjRate,
        PoolTypeParams memory p,
        OOBState memory sOut,
        bool isUpper
    ) private pure returns (uint24 newFee, OOBState memory) {
        // Update streak
        uint24 streak = (isUpper != sOut.lastOOBWasUpper) ? 1 : sOut.consecutiveOOBHits + 1;
        sOut.lastOOBWasUpper = isUpper;
        sOut.consecutiveOOBHits = streak;

        // Compute adjustment
        uint256 deviation = isUpper ? (currentRatio - targetRatio) : (targetRatio - currentRatio);
        uint256 adjustmentRate = deviation.mulDiv(p.linearSlope, targetRatio);
        if (adjustmentRate > globalMaxAdjRate) adjustmentRate = globalMaxAdjRate;

        return _applyFeeAdjustment(currentFee, adjustmentRate, p, streak, isUpper);
    }

    /**
     * @dev Helper function to apply fee adjustment and throttling to reduce stack depth.
     */
    function _applyFeeAdjustment(
        uint24 currentFee,
        uint256 adjustmentRate,
        PoolTypeParams memory p,
        uint24 streak,
        bool isUpper
    ) private pure returns (uint24, OOBState memory sOut) {
        uint256 feeDelta = uint256(currentFee).mulDiv(adjustmentRate, ONE_WAD);

        // throttle by streak
        uint256 maxFeeDelta = uint256(p.baseMaxFeeDelta) * uint256(streak);
        if (feeDelta > maxFeeDelta) feeDelta = maxFeeDelta;

        uint256 feeAcc = uint256(currentFee);

        // throttle by side
        if (isUpper) {
            uint256 deltaUp = feeDelta.mulDiv(p.upperSideFactor, ONE_WAD);
            unchecked {
                feeAcc += deltaUp;
            } // clamped below
        } else {
            uint256 deltaDown = feeDelta.mulDiv(p.lowerSideFactor, ONE_WAD);
            if (deltaDown >= feeAcc) {
                sOut.lastOOBWasUpper = isUpper;
                sOut.consecutiveOOBHits = streak;
                return (p.minFee, sOut);
            } else {
                unchecked {
                    feeAcc -= deltaDown;
                } // clamped below
            }
        }

        sOut.lastOOBWasUpper = isUpper;
        sOut.consecutiveOOBHits = streak;
        return (clampFee(feeAcc, p.minFee, p.maxFee), sOut);
    }

    /**
     * @notice Clamp a fee to pool-type bounds.
     * @param fee The fee to clamp.
     * @param minFee The minimum fee of the pool type.
     * @param maxFee The maximum fee of the pool type.
     * @return The clamped fee.
     */
    function clampFee(uint256 fee, uint24 minFee, uint24 maxFee) internal pure returns (uint24) {
        if (fee < minFee) return minFee;
        if (fee > maxFee) return maxFee;
        return uint24(fee);
    }

    /**
     * @notice Exponential moving average: new = old + alpha*(current - old).
     * @dev alpha = 2 * ONE_WAD / (lookbackPeriod + 1).
     * @param currentRatio The current ratio in 1e18.
     * @param oldTargetRatio The previous target ratio in 1e18.
     * @param lookbackPeriod The lookbackPeriod in days.
     * @return newTargetRatio The updated target ratio in 1e18.
     */
    function ema(uint256 currentRatio, uint256 oldTargetRatio, uint24 lookbackPeriod)
        internal
        pure
        returns (uint256 newTargetRatio)
    {
        uint256 alpha = ALPHA_NUMERATOR / (uint256(lookbackPeriod) + 1);
        if (currentRatio >= oldTargetRatio) {
            uint256 up = (currentRatio - oldTargetRatio).mulDiv(alpha, ONE_WAD);
            return oldTargetRatio + up;
        } else {
            uint256 down = (oldTargetRatio - currentRatio).mulDiv(alpha, ONE_WAD);
            return oldTargetRatio - down;
        }
    }
}
