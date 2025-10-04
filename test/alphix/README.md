# Alphix Protocol Test Suite

Comprehensive test suite for the Alphix protocol - a Uniswap V4 Hook with upgradeable logic.

## Overview

The Alphix test suite provides multi-layered validation from unit tests to full lifecycle scenarios, ensuring protocol correctness, security, and economic soundness.

### Test Results

All tests should be passing.

## Directory Structure

```
test/alphix/
├── integration/          # Component integration tests
│   ├── concrete/        # Deterministic integration tests
│   │   ├── AccessAndOwnership.t.sol
│   │   ├── AlphixDeployment.t.sol
│   │   ├── AlphixHookCalls.t.sol
│   │   ├── AlphixLogicDeployment.t.sol
│   │   ├── AlphixLogicHookCalls.t.sol
│   │   ├── AlphixLogicPoolManagement.t.sol
│   │   ├── AlphixPoolManagement.t.sol
│   │   ├── PoolTypeParamsBehaviorChange.t.sol
│   │   └── RegistryDeployment.t.sol
│   └── fuzzed/          # Fuzz-based integration tests
│       ├── AccessAndOwnershipFuzz.t.sol
│       ├── AlphixHookCallsFuzz.t.sol
│       ├── AlphixLogicHookCallsFuzz.t.sol
│       ├── AlphixLogicPoolManagementFuzz.t.sol
│       ├── AlphixPokeFuzz.t.sol
│       └── PoolTypeParamsBehaviorChangeFuzz.t.sol
│
├── fullCycle/           # End-to-end lifecycle tests
│   ├── concrete/
│   │   ├── AlphixFullIntegration.t.sol      # 30-day scenarios
│   │   └── AlphixUpgradeability.t.sol       # UUPS upgrades
│   └── fuzzed/
│       ├── AlphixFullIntegrationFuzz.t.sol
│       └── AlphixUpgradeabilityFuzz.t.sol
│
├── invariant/           # Stateful property testing
│   ├── AlphixInvariants.t.sol
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
- Hook ↔ Logic communication secure
- Hook ↔ PoolManager integration correct
- Access control enforced (Ownable2Step, AccessManaged, Roles)
- State transitions valid (pause, active/inactive)
- UUPS upgrades authorized properly
- Parameter changes affect behavior correctly

**Run Command**:
```bash
forge test --match-path "test/alphix/integration/**/*.sol"
```

**See**: [integration/README.md](integration/README.md) for detailed documentation

### 3. Full Cycle Tests

**Purpose**: Validate complete protocol lifecycle and upgrades

**Key Scenarios**:
- 30-day full cycle with swaps, liquidity, fee adjustments
- Multi-user coordinated and adversarial behaviors
- Upgrade preserves state and functionality
- Fee earnings proportional to liquidity × time
- High volatility and extreme market conditions

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
- Logic contract address always valid

**Run Command**:
```bash
forge test --match-path test/alphix/invariant/AlphixInvariants.t.sol
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
forge test --match-path test/alphix/invariant/AlphixInvariants.t.sol
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
