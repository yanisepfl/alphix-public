# Alphix Full Cycle Testing

This directory contains comprehensive end-to-end integration tests that simulate complete lifecycle scenarios for the Alphix protocol, including multi-day operations, extreme market conditions, and realistic user behavior.

## Overview

Full cycle tests validate the protocol's behavior across extended time periods and complex interaction sequences, ensuring:
1. **Long-term stability** - Protocol functions correctly over days/weeks
2. **Realistic scenarios** - Multi-user interactions with swaps, liquidity, and fee adjustments
3. **Economic correctness** - Fee distributions and LP earnings work as expected
4. **Extreme resilience** - System handles black swan events, liquidity drains, and OOB streaks

## Test Files

### Concrete Tests (`concrete/`)

#### `AlphixFullIntegration.t.sol`
**Purpose**: Validates complete protocol lifecycle with realistic multi-user scenarios

**Key Test Categories**:
- **Pool Lifecycle**: Complete pool setup → operations → fee adjustments

- **Multi-User Interactions**:
  - Swap activity creates volume
  - Diverse LP positions at various ranges
  - Progressive liquidity addition
  - Staged LP exits over time
  - Directional trading pressure

- **Economic Validation**:
  - Dynamic fee accuracy across pool types
  - Fair fee distribution among LPs
  - Time-weighted earnings calculations

- **Extended Scenarios**:
  - 30-day fee evolution with periodic adjustments
  - High volatility market conditions
  - Volume-based ratio calculations

- **Rehypothecation Integration**:
  - JIT liquidity during swaps
  - Fee compounding to yield sources
  - Share value growth over time

### Fuzzed Tests (`fuzzed/`)

#### `AlphixFullIntegrationFuzz.t.sol`
**Purpose**: Fuzz testing of full cycle scenarios with randomized parameters

**Key Fuzzing Areas**:
- **Multi-User Scenarios**: Swap activity, liquidity provision, gradual buildup, directional pressure
- **Economic Validation**: Dynamic fee accuracy, ratio calculations, LP fee distribution
- **Pool Lifecycle**: Complete lifecycle with fee adjustments, volatility scenarios
- **Long-Term Convergence**: EMA convergence to min/max/mid-range fees over weeks/months
- **Parameter Sensitivity**: Linear slope impact, side factor asymmetry, streak accumulation
- **Organic Behavior**: Seasonal patterns, monthly adjustments, stable operation without pokes
- **Extreme Values**: System stability under extreme parameter combinations

#### `AlphixExtremeStatesFuzz.t.sol`
**Purpose**: Validates system resilience under extreme market conditions and edge cases

**Key Fuzzing Areas**:
- **Liquidity Extremes**: Drain-then-flood cycles, zero liquidity recovery, massive injections
- **OOB Streak Behavior**: Consecutive upper/lower hits, alternating streaks, reset verification
- **Black Swan Events**: Full lifecycle crisis → recovery simulation with system stability checks
- **Rehypothecation Edge Cases**: Large deposits/withdrawals, yield source edge cases

## Running Full Cycle Tests

### All Full Cycle Tests
```bash
forge test --match-path "test/alphix/fullCycle/**/*.sol"
```

### Concrete Tests Only
```bash
forge test --match-path "test/alphix/fullCycle/concrete/*.sol"
```

### Fuzzed Tests Only
```bash
forge test --match-path "test/alphix/fullCycle/fuzzed/*.sol"
```

### Specific Test File
```bash
forge test --match-path test/alphix/fullCycle/concrete/AlphixFullIntegration.t.sol
```

### With Gas Reporting
```bash
forge test --match-path "test/alphix/fullCycle/**/*.sol" --gas-report
```

### Verbose Output
```bash
forge test --match-path "test/alphix/fullCycle/**/*.sol" -vvv
```

## Integration with Other Tests

Full cycle tests build upon:
- **Integration tests**: Validate individual components work together
- **Unit tests**: Verify isolated functionality
- **Invariant tests**: Ensure properties hold across all states

Together, these provide comprehensive coverage from unit → integration → full lifecycle validation.
