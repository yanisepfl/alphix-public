# Alphix Protocol Test Suite

Comprehensive test suite for the Alphix protocol - a Uniswap V4 Dynamic Fee Hook with JIT Liquidity Rehypothecation.

## Overview

The Alphix test suite provides multi-layered validation from unit tests to full lifecycle scenarios, ensuring protocol correctness, security, and economic soundness.

### Test Results

All tests should be passing.

## Directory Structure

```text
test/alphix/
├── integration/          # Component integration tests
│   ├── concrete/        # Deterministic integration tests
│   │   ├── AccessAndOwnership.t.sol
│   │   ├── AlphixETHHookCallsExtended.t.sol
│   │   ├── DynamicFeeBehavior.t.sol
│   │   ├── DynamicFeeEMA.t.sol
│   │   ├── JITTickRangeEdgeCases.t.sol
│   │   ├── PoolParamsBehaviorChange.t.sol
│   │   ├── ReHypothecationAdvancedScenarios.t.sol
│   │   ├── ReHypothecationETHSwaps.t.sol
│   │   ├── ReHypothecationSwapsAccounting.t.sol
│   │   └── RoundtripReHypothecation.t.sol
│   └── fuzzed/          # Fuzz-based integration tests
│       ├── AlphixDonateHooksFuzz.t.sol
│       ├── AlphixETHDeploymentFuzz.t.sol
│       ├── AlphixHookCallsFuzz.t.sol
│       ├── DynamicFeeBehaviorFuzz.t.sol
│       ├── JITSelfHealingFuzz.t.sol
│       ├── JITTickRangeFuzz.t.sol
│       ├── ReHypothecationDecimalsFuzz.t.sol
│       └── ReHypothecationVaryingPricesFuzz.t.sol
│
├── fullCycle/           # End-to-end lifecycle tests
│   ├── concrete/
│   │   └── AlphixFullIntegration.t.sol      # Multi-day scenarios
│   └── fuzzed/
│       ├── AlphixExtremeStatesFuzz.t.sol
│       └── AlphixFullIntegrationFuzz.t.sol
│
├── invariant/           # Stateful property testing
│   ├── AlphixInvariants.t.sol
│   ├── DustShareTest.t.sol
│   ├── ReHypothecationInvariants.t.sol
│   ├── handlers/
│   │   └── AlphixInvariantHandler.sol       # Fuzzer handler
│   └── README.md                            # Detailed invariant docs
│
├── libraries/           # Library unit tests
│   ├── concrete/
│   │   └── DynamicFee.t.sol                 # Pure math functions
│   └── fuzzed/
│       └── DynamicFeeFuzz.t.sol             # Math property tests
│
├── openZeppelin/        # OZ base contract tests
│   └── concrete/
│       └── BaseDynamicFee.t.sol             # Dynamic fee base
│
├── BaseAlphix.t.sol     # Base test contract (shared setup)
└── README.md            # This file
```

## Test Layers

### 1. Unit Tests

**Purpose**: Validate isolated components and pure functions

**Key Validations**:
- Fee clamping always respects bounds
- EMA calculations are monotonic and bounded
- Streak multipliers amplify correctly
- Side factors create asymmetric adjustments
- Edge cases (zero values, max values) handled safely

**Run Command**:
```bash
forge test --match-path "test/alphix/libraries/**/*.sol"
forge test --match-path "test/alphix/openZeppelin/**/*.sol"
```

### 2. Integration Tests

**Purpose**: Validate how components work together

**Key Validations**:
- Hook ↔ PoolManager integration correct
- Access control enforced (Ownable2Step, AccessManaged, Roles)
- State transitions valid (pause, active/inactive)
- Parameter changes affect behavior correctly
- JIT liquidity provisioning works correctly
- Rehypothecation deposits/withdrawals from yield sources
- ETH pool handling with WETH wrapping

**Run Command**:
```bash
forge test --match-path "test/alphix/integration/**/*.sol"
```

**See**: [integration/README.md](integration/README.md) for detailed documentation

### 3. Full Cycle Tests

**Purpose**: Validate complete protocol lifecycle

**Key Scenarios**:
- 30-day full cycle with swaps, liquidity, fee adjustments
- Multi-user coordinated and adversarial behaviors
- Fee earnings proportional to liquidity × time
- High volatility and extreme market conditions
- Extreme states (liquidity drain, black swan events)

**Run Command**:
```bash
forge test --match-path "test/alphix/fullCycle/**/*.sol"
```

**See**: [fullCycle/README.md](fullCycle/README.md) for detailed documentation

### 4. Invariant Tests

**Purpose**: Stateful property-based testing with fuzzer-guided exploration

**Test Configuration**:
- 512 runs × 50 depth = 25,600 calls per invariant
- Handler with swaps and liquidity operations

**Key Validations**:
- Fees always within bounds despite any state
- No MEV attack can manipulate fees beyond limits
- Cooldowns prevent same-block manipulation
- Zero values never cause division by zero
- Extreme ratios don't cause overflow
- Rehypothecation share accounting remains consistent
- Dust/rounding issues don't accumulate

**Run Command**:
```bash
forge test --match-path "test/alphix/invariant/*.t.sol"
```

**See**: [invariant/README.md](invariant/README.md) for detailed documentation

## Quick Start

### Run All Tests
```bash
forge test
```

### Run With Summary
```bash
forge test --summary
```

### Run Specific Layer
```bash
# Unit tests only
forge test --match-path "test/alphix/libraries/**/*.sol"

# Integration tests only
forge test --match-path "test/alphix/integration/**/*.sol"

# Full cycle tests only
forge test --match-path "test/alphix/fullCycle/**/*.sol"

# Invariant tests only
forge test --match-path "test/alphix/invariant/*.t.sol"
```

### Run With Gas Reporting
```bash
forge test --gas-report
```

### Run With Coverage
```bash
forge coverage --report lcov
```

### Verbose Output
```bash
forge test -vvv  # Very verbose (shows traces)
forge test -vv   # Verbose (shows revert reasons)
```

## Test Configuration

### Foundry Configuration (`foundry.toml`)

```toml
[fuzz]
runs = 512              # Fuzz test iterations

[invariant]
runs = 512              # Invariant sequences
depth = 50              # Calls per sequence
fail_on_revert = false  # Expected fuzzer behavior
```

## Continuous Integration

Tests run automatically on:
- Pull requests
- Commits to main branch
- Release tags

CI configuration includes:
- Full test suite execution
- Coverage reporting
- Gas snapshot comparison
- Linting checks

## Resources

- [Foundry Book](https://book.getfoundry.sh/) - Foundry documentation
- [Invariant Testing Guide](https://book.getfoundry.sh/forge/invariant-testing) - Stateful fuzzing
- [Uniswap V4 Docs](https://docs.uniswap.org/contracts/v4/overview) - Hook system
- [OpenZeppelin Docs](https://docs.openzeppelin.com/) - Security patterns
