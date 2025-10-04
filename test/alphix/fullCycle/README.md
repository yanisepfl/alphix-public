# Alphix Full Cycle Testing

This directory contains comprehensive end-to-end integration tests that simulate complete lifecycle scenarios for the Alphix protocol, including multi-day operations, upgrades, and realistic user interactions.

## Overview

Full cycle tests validate the protocol's behavior across extended time periods and complex interaction sequences, ensuring:
1. **Long-term stability** - Protocol functions correctly over days/weeks
2. **Upgrade compatibility** - UUPS upgrades preserve state and functionality
3. **Realistic scenarios** - Multi-user interactions with swaps, liquidity, and fee adjustments
4. **Economic correctness** - Fee distributions and LP earnings work as expected

## Test Files

### Concrete Tests (`concrete/`)

#### `AlphixFullIntegration.t.sol`
**Purpose**: Validates complete protocol lifecycle with realistic multi-user scenarios

**Key Test Categories**:
- **Pool Lifecycle**: Complete pool setup → operations → fee adjustments
- **Multi-User Interactions**:
  - `test_multiUser_swap_activity_creates_volume()` - Swap volume accumulation
  - `test_multiUser_liquidity_provision_various_ranges()` - Diverse LP positions
  - `test_multiUser_gradual_liquidity_buildup()` - Progressive liquidity addition
  - `test_multiUser_liquidity_removal_over_time()` - Staged LP exits
  - `test_multiUser_directional_trading_pressure()` - Directional swap patterns

- **Economic Validation**:
  - `test_traders_pay_correct_dynamic_fees()` - Fee calculation accuracy (STABLE/STANDARD/VOLATILE)
  - `test_equal_LPs_equal_timeline_earn_equal_fees()` - Fair fee distribution
  - `test_complex_LP_fee_distribution_different_timelines()` - Time-weighted earnings

- **Extended Scenarios**:
  - `test_periodic_fee_adjustments_over_month()` - 30-day fee evolution (all pool types)
  - `test_comprehensive_30day_full_cycle_all_interactions()` - Complete 30-day simulation
  - `test_high_volatility_scenario_with_dynamic_fees()` - Extreme market conditions
  - `test_realistic_ratio_calculation_from_volumes()` - Volume-based ratio accuracy

**Gas Benchmarks**: ~800k - 6.2M gas per test (realistic full scenarios)

#### `AlphixUpgradeability.t.sol`
**Purpose**: Validates UUPS upgrade safety and state preservation

**Key Test Categories**:
- **Basic Upgrades**:
  - `test_basic_upgrade_to_new_implementation()` - Simple upgrade flow (all pool types)
  - `test_upgrade_with_initialization_data()` - Upgrade with reinitializer

- **State Preservation**:
  - `test_upgrade_preserves_pool_configurations()` - Pool configs unchanged
  - `test_upgrade_preserves_pool_type_parameters()` - Pool type params intact
  - `test_upgrade_maintains_fee_state()` - Fee state consistency
  - `test_upgrade_with_active_pool_state()` - Active pool operations during upgrade

- **Upgrade Validation**:
  - `test_upgrade_rejects_invalid_implementation()` - Interface compliance check
  - `test_upgrade_access_control_enforced()` - Only owner can upgrade
  - `test_upgrade_reverts_for_unauthorized()` - Non-owner rejection

- **Post-Upgrade Operations**:
  - `test_pool_operations_work_after_upgrade()` - Swaps/liquidity work (all pool types)
  - `test_new_pool_initialization_after_upgrade()` - New pool creation
  - `test_fee_poke_works_after_upgrade()` - Fee updates functional
  - `test_multiple_sequential_upgrades()` - Repeated upgrades safe

**Gas Benchmarks**: ~650k - 13.9M gas per test (upgrade operations)

### Fuzzed Tests (`fuzzed/`)

#### `AlphixFullIntegrationFuzz.t.sol`
**Purpose**: Fuzz testing of full cycle scenarios with randomized parameters

**Key Fuzzing Areas**:
- Multi-user swap and liquidity scenarios with random amounts
- Time-based operations with fuzzed delays
- Fee adjustments with randomized ratios
- Pool type variations

**Runs**: 512 iterations per test with bounded inputs

#### `AlphixUpgradeabilityFuzz.t.sol`
**Purpose**: Fuzz testing of upgrade scenarios

**Key Fuzzing Areas**:
- Upgrade with random active pool states
- State preservation with fuzzed configurations
- Post-upgrade operations with random parameters

**Runs**: 512 iterations per test

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
