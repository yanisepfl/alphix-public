# Alphix Integration Testing

This directory contains integration tests that validate how Alphix protocol components work together, including hook callbacks, pool management, access control, JIT liquidity, and rehypothecation.

## Overview

Integration tests ensure that:
1. **Components interact correctly** - Hook ↔ PoolManager work together
2. **Access control is enforced** - Ownership, roles, and permissions
3. **State management works** - Pool configurations, fee updates, pause states
4. **JIT liquidity functions** - BeforeSwap/AfterSwap liquidity provisioning
5. **Rehypothecation works** - ERC-4626 yield source deposits/withdrawals
6. **ETH pools function** - Native ETH handling with WETH wrapping

## Directory Structure

```
integration/
├── concrete/          # Deterministic integration tests
│   ├── AccessAndOwnership.t.sol
│   ├── AlphixETHHookCallsExtended.t.sol
│   ├── DynamicFeeBehavior.t.sol
│   ├── DynamicFeeEMA.t.sol
│   ├── JITTickRangeEdgeCases.t.sol
│   ├── PoolParamsBehaviorChange.t.sol
│   ├── ReHypothecationAdvancedScenarios.t.sol
│   ├── ReHypothecationETHSwaps.t.sol
│   ├── ReHypothecationSwapsAccounting.t.sol
│   └── RoundtripReHypothecation.t.sol
│
└── fuzzed/           # Fuzz-based integration tests
    ├── AlphixDonateHooksFuzz.t.sol
    ├── AlphixETHDeploymentFuzz.t.sol
    ├── AlphixHookCallsFuzz.t.sol
    ├── DynamicFeeBehaviorFuzz.t.sol
    ├── JITSelfHealingFuzz.t.sol
    ├── JITTickRangeFuzz.t.sol
    ├── ReHypothecationDecimalsFuzz.t.sol
    └── ReHypothecationVaryingPricesFuzz.t.sol
```

## Concrete Tests (`concrete/`)

### Access Control & Ownership

#### `AccessAndOwnership.t.sol`
**Purpose**: Validates access control, ownership transfers, and role management

**Key Tests**:
- Initial ownership setup
- Ownable2Step transfers for Hook
- AccessManager role grants/revocations
- Role-based permission enforcement

### Dynamic Fee Behavior

#### `DynamicFeeBehavior.t.sol`
**Purpose**: Validates dynamic fee algorithm behavior

**Key Tests**:
- Fee computation with various ratios
- Fee clamping to bounds
- Cooldown enforcement
- Out-of-bounds streak behavior

#### `DynamicFeeEMA.t.sol`
**Purpose**: Validates EMA (Exponential Moving Average) calculations

**Key Tests**:
- EMA convergence over time
- Lookback period effects
- Target ratio updates

### Pool Parameter Behavior

#### `PoolParamsBehaviorChange.t.sol`
**Purpose**: Validates how pool parameter changes affect fee behavior

**Key Test Categories**:
- **Baseline Behavior**: Original parameters, below/within tolerance
- **Parameter Changes**: Fee bounds, cooldown, lookup periods
- **Sensitivity Testing**: Linear slope, ratio tolerance, side factors
- **Edge Cases**: Extreme parameters, multiple changes

### JIT Liquidity

#### `JITTickRangeEdgeCases.t.sol`
**Purpose**: Validates JIT liquidity tick range edge cases

**Key Tests**:
- Tick range boundary conditions
- Price movement across tick ranges
- Liquidity calculation edge cases

### Rehypothecation

#### `ReHypothecationAdvancedScenarios.t.sol`
**Purpose**: Complex rehypothecation scenarios

**Key Tests**:
- Multi-user deposit/withdrawal sequences
- Share accounting under various conditions
- Yield accrual and distribution

#### `ReHypothecationETHSwaps.t.sol`
**Purpose**: ETH pool rehypothecation with swaps

**Key Tests**:
- ETH wrapping/unwrapping during swaps
- JIT liquidity with native ETH
- Fee capture in ETH pools

#### `ReHypothecationSwapsAccounting.t.sol`
**Purpose**: Validates accounting during swaps with rehypothecation

**Key Tests**:
- Fee compounding to yield sources
- Delta resolution after swaps
- Principal vs fee separation

#### `RoundtripReHypothecation.t.sol`
**Purpose**: End-to-end deposit → swap → withdraw flows

**Key Tests**:
- Complete user journey
- No value leakage
- Correct share minting/burning

### ETH Pool Integration

#### `AlphixETHHookCallsExtended.t.sol`
**Purpose**: Extended tests for AlphixETH hook

**Key Tests**:
- Native ETH handling in hook callbacks
- WETH wrapper integration
- ETH refund handling

## Fuzzed Tests (`fuzzed/`)

### Hook & Deployment

#### `AlphixHookCallsFuzz.t.sol`
**Purpose**: Fuzz testing of hook callbacks with random parameters

#### `AlphixETHDeploymentFuzz.t.sol`
**Purpose**: Fuzz testing of AlphixETH deployment and initialization

#### `AlphixDonateHooksFuzz.t.sol`
**Purpose**: Fuzz testing of donate hook functionality

### Dynamic Fee

#### `DynamicFeeBehaviorFuzz.t.sol`
**Purpose**: Fuzz testing of fee behavior with random ratios and parameters

### JIT Liquidity

#### `JITTickRangeFuzz.t.sol`
**Purpose**: Fuzz testing of JIT tick range calculations

#### `JITSelfHealingFuzz.t.sol`
**Purpose**: Fuzz testing of JIT self-healing after failed operations

### Rehypothecation

#### `ReHypothecationDecimalsFuzz.t.sol`
**Purpose**: Fuzz testing with various token decimal combinations

#### `ReHypothecationVaryingPricesFuzz.t.sol`
**Purpose**: Fuzz testing with varying prices and yield rates

## Running Integration Tests

### All Integration Tests
```bash
forge test --match-path "test/alphix/integration/**/*.sol"
```

### Concrete Only
```bash
forge test --match-path "test/alphix/integration/concrete/*.sol"
```

### Fuzzed Only
```bash
forge test --match-path "test/alphix/integration/fuzzed/*.sol"
```

### Specific Test Suite
```bash
# Rehypothecation tests
forge test --match-path "test/alphix/integration/concrete/ReHypothecation*.sol"

# Dynamic fee tests
forge test --match-path "test/alphix/integration/concrete/DynamicFee*.sol"

# Access control
forge test --match-path test/alphix/integration/concrete/AccessAndOwnership.t.sol
```

### With Verbosity
```bash
forge test --match-path "test/alphix/integration/**/*.sol" -vvv
```

## Key Integration Points Tested

### 1. **Hook ↔ PoolManager Integration**
- Hook callbacks invoked correctly
- Fee updates propagated to PoolManager
- Pool state consistency

### 2. **JIT Liquidity Flow**
- BeforeSwap: Add liquidity from yield sources
- Swap: Execute using JIT liquidity
- AfterSwap: Remove liquidity, deposit fees to yield sources

### 3. **Rehypothecation Integration**
- ERC-4626 vault deposits/withdrawals
- Share minting/burning
- Fee compounding

### 4. **Access Control Integration**
- Ownable2Step for ownership transfers
- AccessManaged for role-based permissions
- Role-based permissions (Poker, YieldManager)

### 5. **OpenZeppelin Patterns**
- Pausable functionality
- ReentrancyGuardTransient protection
- SafeERC20 usage

## Test Results

All tests should be passing.

## Coverage Areas

- **Access Control**: Ownership, roles, and permissions enforced
- **Hook Callbacks**: All Uniswap V4 hooks implemented correctly
- **Pool Management**: Configuration, activation, parameter updates
- **Fee Computation**: Dynamic fees calculated correctly with pool parameters
- **JIT Liquidity**: Correct liquidity provisioning during swaps
- **Rehypothecation**: ERC-4626 integration, share accounting
- **ETH Handling**: Native ETH wrapping/unwrapping
- **State Management**: Pause, cooldowns, tick ranges

These integration tests provide the middle layer of testing between unit tests (isolated components) and full cycle tests (end-to-end scenarios).
