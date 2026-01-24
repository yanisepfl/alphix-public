# Alphix Invariant Testing

This directory contains stateful invariant tests for the Alphix protocol, implementing comprehensive property-based testing to ensure critical invariants hold across all possible state transitions.

## Overview

Invariant tests are a powerful form of property-based testing that:
1. **Randomly call functions** in your contracts with fuzzed inputs
2. **Check invariants** after each call to ensure they still hold
3. **Explore state space** more thoroughly than traditional tests

## Files

### `AlphixInvariants.t.sol`
Main test contract defining critical invariants for the dynamic fee system:

#### Invariant 1: Fee Bounds
- `invariant_feesWithinGlobalBounds()` - All fees stay within MIN_FEE and MAX_LP_FEE
- `invariant_feesWithinPoolTypeBounds()` - All fees respect pool-type specific bounds

#### Invariant 2: Target Ratio Bounds
- `invariant_targetRatioNeverExceedsCap()` - Target ratios never exceed MAX_CURRENT_RATIO (1e24)
- `invariant_targetRatioNonZeroForConfiguredPools()` - Configured pools have non-zero target ratios

#### Invariant 3: Pool State Consistency
- `invariant_trackedPoolsAreValid()` - All tracked pools are properly initialized
- `invariant_configuredPoolsHaveValidParams()` - Configuration parameters are valid

#### Invariant 4: Fee Behavior
- `invariant_feeNeverBelowReasonableMinimum()` - Fees never drop below pool-type minimums
- `invariant_ghostVariablesConsistent()` - Ghost variable tracking remains consistent

#### Invariant 5: Volume and Liquidity
- `invariant_swapVolumeReasonable()` - Swap volume aligns with call counts
- `invariant_netLiquidityNonNegative()` - Net liquidity (added - removed) ≥ 0

#### Invariant 6: State Machine Safety
- `invariant_pauseStateConsistent()` - Pause state is always accessible and valid
- `invariant_poolManagerFeeConsistency()` - Hook fees match pool manager's reported fees

#### Invariant 7: Mathematical Properties
- `invariant_allActiveFeesValid()` - All active pool fees are within MAX_LP_FEE
- `invariant_initialTargetRatiosValid()` - Initial target ratios are valid and capped
- `invariant_poolConfigurationsConsistent()` - Pool configs remain consistent after setup

#### Invariant 8: Economic Security
- `invariant_feesAlwaysBoundedDespiteManipulation()` - Fees bounded even under MEV attacks
- `invariant_cooldownPreventsSameBlockManipulation()` - Cooldown prevents rapid manipulation

#### Invariant 9: Edge Cases & Safety
- `invariant_zeroTargetHandledSafely()` - Zero targets never cause division by zero
- `invariant_extremeRatiosHandledSafely()` - Extreme ratios don't cause overflow
- `invariant_timeWarpsSafe()` - Time warps don't break timestamp logic

#### Invariant 10: Streak & OOB Behavior
- `invariant_pokeTrackingConsistent()` - Poke operations track changes correctly
- `invariant_sideFactorsCreateAsymmetry()` - Side factors create asymmetric adjustments

### `ReHypothecationInvariants.t.sol`
Invariant tests for the rehypothecation system:

#### Share Accounting Invariants
- Total shares minted equals sum of user balances
- Share value never decreases unexpectedly (no value extraction)
- Protocol-favorable rounding (up for deposits, down for withdrawals)

#### Yield Source Invariants
- Vault shares owned match expected from deposits
- Withdrawal amounts never exceed available
- No assets stranded in intermediate states

#### JIT Liquidity Invariants
- Position is empty before/after swap (transient only)
- Delta resolution always balanced
- No dust accumulation in hook

### `DustShareTest.t.sol`
Focused tests on dust and rounding edge cases:

- Minimal share amounts don't break accounting
- First depositor attack prevention
- Rounding doesn't accumulate over time
- Zero-value edge cases handled

### `handlers/AlphixInvariantHandler.sol`
Handler contract that guides the fuzzer through valid state transitions:

**Handler Functions:**
- `poke()` - Fuzzed ratio-based fee updates with cooldown handling
- `swap()` - Real swap operations
- `addLiquidity()` - Real liquidity addition
- `removeLiquidity()` - Real liquidity removal
- `warpTime()` - Time manipulation for cooldown testing (1 hour to 30 days)
- `configureNewPool()` - Pool configuration testing
- `pauseContract()` / `unpauseContract()` - Pause state testing

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
forge test --match-path "test/alphix/invariant/*.t.sol"
```

### With Increased Runs (more thorough)
```bash
forge test --match-path "test/alphix/invariant/*.t.sol" --fuzz-runs 1000
```

### With Verbosity
```bash
forge test --match-path "test/alphix/invariant/*.t.sol" -vvv
```

### Specific Test File
```bash
# Dynamic fee invariants
forge test --match-path test/alphix/invariant/AlphixInvariants.t.sol

# Rehypothecation invariants
forge test --match-path test/alphix/invariant/ReHypothecationInvariants.t.sol

# Dust/rounding tests
forge test --match-path test/alphix/invariant/DustShareTest.t.sol
```

### Configuration
Invariant test settings in `foundry.toml`:
```toml
[invariant]
runs = 512              # Number of sequences to run
depth = 50              # Number of calls per sequence (512 × 50 = 25,600 calls/invariant)
fail_on_revert = false  # Don't fail on reverts (expected fuzzer behavior)
```
