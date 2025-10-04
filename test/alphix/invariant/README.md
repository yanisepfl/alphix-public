# Alphix Invariant Testing

This directory contains stateful invariant tests for the Alphix protocol, implementing comprehensive property-based testing to ensure critical invariants hold across all possible state transitions.

## Overview

Invariant tests are a powerful form of property-based testing that:
1. **Randomly call functions** in your contracts with fuzzed inputs
2. **Check invariants** after each call to ensure they still hold
3. **Explore state space** more thoroughly than traditional tests

## Files

### `AlphixInvariants.t.sol`
Main test contract defining critical invariants that must always hold:

#### Invariant 1: Fee Bounds
- `invariant_feesWithinGlobalBounds()` - All fees stay within MIN_FEE and MAX_LP_FEE
- `invariant_feesWithinPoolTypeBounds()` - All fees respect pool-type specific bounds

#### Invariant 2: Target Ratio Bounds
- `invariant_targetRatioNeverExceedsCap()` - Target ratios never exceed MAX_CURRENT_RATIO (1e24)
- `invariant_targetRatioNonZeroForConfiguredPools()` - Configured pools have non-zero target ratios

#### Invariant 3: Pool State Consistency
- `invariant_trackedPoolsAreValid()` - All tracked pools are properly initialized
- `invariant_configuredPoolsHaveValidParams()` - Configuration parameters are valid

#### Invariant 4: Pool Type Consistency
- `invariant_poolTypesAreValid()` - Pool types are within enum bounds (0-2)

#### Invariant 5: Fee Behavior
- `invariant_feeNeverBelowReasonableMinimum()` - Fees never drop below pool-type minimums
- `invariant_ghostVariablesConsistent()` - Ghost variable tracking remains consistent

#### Invariant 6: Volume and Liquidity
- `invariant_swapVolumeReasonable()` - Swap volume aligns with call counts
- `invariant_netLiquidityNonNegative()` - Net liquidity (added - removed) ≥ 0

#### Invariant 7: State Machine Safety
- `invariant_pauseStateConsistent()` - Pause state is always accessible and valid
- `invariant_poolManagerFeeConsistency()` - Hook fees match pool manager's reported fees

#### Invariant 8: Mathematical Properties
- `invariant_allActiveFeesValid()` - All active pool fees are within MAX_LP_FEE
- `invariant_initialTargetRatiosValid()` - Initial target ratios are valid and capped
- `invariant_poolConfigurationsConsistent()` - Pool configs remain consistent after setup

#### Invariant 9: Economic Security
- `invariant_feesAlwaysBoundedDespiteManipulation()` - Fees bounded even under MEV attacks
- `invariant_cooldownPreventsSameBlockManipulation()` - Cooldown prevents rapid manipulation

#### Invariant 10: Edge Cases & Safety
- `invariant_zeroTargetHandledSafely()` - Zero targets never cause division by zero
- `invariant_extremeRatiosHandledSafely()` - Extreme ratios don't cause overflow
- `invariant_timeWarpsSafe()` - Time warps don't break timestamp logic

#### Invariant 11: Streak & OOB Behavior
- `invariant_pokeTrackingConsistent()` - Poke operations track changes correctly
- `invariant_sideFactorsCreateAsymmetry()` - Side factors create asymmetric adjustments

#### Invariant 12: Upgrade Safety
- `invariant_logicAddressValid()` - Logic contract address is always valid
- `invariant_hookPermissionsImmutable()` - Hook permissions remain stable

### `handlers/AlphixInvariantHandler.sol`
Handler contract that guides the fuzzer through valid state transitions with **swap and liquidity operations**:

**Handler Functions:**
- `poke()` - Fuzzed ratio-based fee updates with cooldown handling
- `swap()` - **Real swap operations** using `IUniswapV4Router04.swapExactTokensForTokens()`
- `addLiquidity()` - **Real liquidity addition** using `IPositionManager.mint()` via EasyPosm library
- `removeLiquidity()` - **Real liquidity removal** using `IPositionManager.burn()` via EasyPosm library
- `warpTime()` - Time manipulation for cooldown testing (1 hour to 30 days)
- `configureNewPool()` - Pool configuration testing
- `pauseContract()` / `unpauseContract()` - Pause state testing

**Position Tracking:**
- `userPositions[poolId][user]` - Mapping of token IDs for each user per pool
- Tracks NFT positions for proper liquidity removal

**Ghost Variables (Statistical Tracking):**
- `ghost_sumOfFees` - Tracks cumulative fees across all pokes
- `ghost_sumOfTargetRatios` - Tracks cumulative target ratios
- `ghost_maxFeeObserved` - Maximum fee ever observed
- `ghost_minFeeObserved` - Minimum fee ever observed
- `ghost_totalSwapVolume` - Total volume from all swaps
- `ghost_totalLiquidityAdded` - Total liquidity added across all operations
- `ghost_totalLiquidityRemoved` - Total liquidity removed across all operations

## Running Invariant Tests

### Basic Run
```bash
forge test --match-path test/alphix/invariant/AlphixInvariants.t.sol
```

### With Increased Runs (more thorough)
```bash
forge test --match-path test/alphix/invariant/AlphixInvariants.t.sol --fuzz-runs 1000
```

### With Verbosity
```bash
forge test --match-path test/alphix/invariant/AlphixInvariants.t.sol -vvv
```

### Configuration
Invariant test settings in `foundry.toml`:
```toml
[invariant]
runs = 512              # Number of sequences to run
depth = 50              # Number of calls per sequence (512 × 50 = 25,600 calls/invariant)
fail_on_revert = false  # Don't fail on reverts (expected fuzzer behavior)
```
