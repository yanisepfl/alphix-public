# Alphix Integration Testing

This directory contains integration tests that validate how Alphix protocol components work together, including hook callbacks, pool management, access control, and cross-contract interactions.

## Overview

Integration tests ensure that:
1. **Components interact correctly** - Hook ↔ Logic ↔ PoolManager work together
2. **Access control is enforced** - Ownership, roles, and permissions
3. **State management works** - Pool configurations, fee updates, pause states
4. **External integrations function** - Uniswap V4, OpenZeppelin contracts

## Directory Structure

```
integration/
├── concrete/          # Deterministic integration tests
│   ├── AccessAndOwnership.t.sol
│   ├── AlphixDeployment.t.sol
│   ├── AlphixHookCalls.t.sol
│   ├── AlphixLogicDeployment.t.sol
│   ├── AlphixLogicHookCalls.t.sol
│   ├── AlphixLogicPoolManagement.t.sol
│   ├── AlphixPoolManagement.t.sol
│   ├── PoolTypeParamsBehaviorChange.t.sol
│   └── RegistryDeployment.t.sol
│
└── fuzzed/           # Fuzz-based integration tests
    ├── AccessAndOwnershipFuzz.t.sol
    ├── AlphixHookCallsFuzz.t.sol
    ├── AlphixLogicHookCallsFuzz.t.sol
    ├── AlphixLogicPoolManagementFuzz.t.sol
    ├── AlphixPokeFuzz.t.sol
    └── PoolTypeParamsBehaviorChangeFuzz.t.sol
```

## Concrete Tests (`concrete/`)

### Access Control & Ownership

#### `AccessAndOwnership.t.sol`
**Purpose**: Validates access control, ownership transfers, and role management

**Key Tests**:
- `test_default_owners()` - Initial ownership setup
- `test_hook_two_step_ownership_transfer()` - Ownable2Step for Hook
- `test_logic_two_step_ownership_transfer_and_admin_ops()` - Logic ownership + admin ops
- `test_access_manager_roles_and_revocation()` - AccessManager role grants/revocations
- `test_only_hook_can_call_logic_endpoints_despite_ownership_changes()` - Hook-only access preserved

**Fuzz Companion**: `AccessAndOwnershipFuzz.t.sol`
- Ownership transfers to random addresses
- Role grants with various delays
- Unauthorized access attempts
- Pool registration with fuzzed parameters

### Deployment & Initialization

#### `AlphixDeployment.t.sol`
**Purpose**: Validates Hook deployment, initialization, and configuration

**Key Tests**:
- Constructor validation (zero address checks, invalid params)
- Initialization (logic setup, pause/unpause)
- Logic contract management (`setLogic`, upgrade validation)
- Registry integration
- Malicious logic rejection

#### `AlphixLogicDeployment.t.sol`
**Purpose**: Validates Logic contract deployment and UUPS upgrade authorization

**Key Tests**:
- Constructor and initializer protection
- Pool type parameter getters
- Pause/unpause functionality
- Upgrade authorization (owner-only, interface validation)
- Mock logic upgrades (with/without reinitializer)

### Hook Callbacks

#### `AlphixHookCalls.t.sol`
**Purpose**: Validates Hook's integration with Uniswap V4 callbacks

**Key Tests**:
- `test_afterInitialize_dynamic_fee_required()` - Dynamic fee enforcement
- `test_owner_can_initialize_new_pool_on_hook()` - Pool initialization
- User operations (add/remove liquidity, swaps)
- Pause/deactivate state enforcement

**Fuzz Companion**: `AlphixHookCallsFuzz.t.sol`

#### `AlphixLogicHookCalls.t.sol`
**Purpose**: Validates Logic's hook callback implementations

**Key Tests**:
- `beforeInitialize` / `afterInitialize` - Pool setup
- `beforeSwap` / `afterSwap` - Swap callbacks
- `beforeAddLiquidity` / `afterAddLiquidity` - Liquidity callbacks
- `beforeRemoveLiquidity` / `afterRemoveLiquidity` - Removal callbacks
- Non-hook caller rejection
- Pause state enforcement

**Fuzz Companion**: `AlphixLogicHookCallsFuzz.t.sol`

### Pool Management

#### `AlphixPoolManagement.t.sol`
**Purpose**: Validates Hook's pool management operations

**Key Tests**:
- Pool initialization (owner-only, validation)
- Pool activation/deactivation
- Fee pokes (cooldown, zero ratio, reentrancy)
- Global max adjustment rate
- Pool type bounds
- Poker role management

#### `AlphixLogicPoolManagement.t.sol`
**Purpose**: Validates Logic's pool management implementation

**Key Tests**:
- `activateAndConfigurePool` - Combined activation + configuration
- `activatePool` / `deactivatePool` - State transitions
- `computeFeeAndTargetRatio` - Fee computation with ratio clamping
- `finalizeAfterFeeUpdate` - EMA updates, cooldown enforcement
- `setPoolTypeParams` - Parameter updates with validation

**Fuzz Companions**:
- `AlphixLogicPoolManagementFuzz.t.sol`
- `AlphixPokeFuzz.t.sol`

### Parameter Behavior

#### `PoolTypeParamsBehaviorChange.t.sol`
**Purpose**: Validates how pool type parameter changes affect fee behavior

**Key Test Categories**:
- **Baseline Behavior**: Original parameters, below/within tolerance
- **Parameter Changes**: Fee bounds, cooldown, lookup periods
- **Sensitivity Testing**: Linear slope, ratio tolerance, side factors
- **Edge Cases**: Extreme parameters, multiple changes, cooldown bypass prevention

**Fuzz Companion**: `PoolTypeParamsBehaviorChangeFuzz.t.sol`
- Extreme ratios with safe calculations
- Boundary conditions for all parameters
- Lookback period convergence
- Fee adjustment sensitivity

### Registry

#### `RegistryDeployment.t.sol`
**Purpose**: Validates Registry contract for automatic deployment tracking

**Key Tests**:
- Constructor and initialization
- Contract registration (authorized only, overwrites, zero address)
- Pool registration (duplicates, unauthorized)
- Getters (`getContract`, `getPoolInfo`, `listPools`)
- Multi-contract type registration

## Fuzzed Tests (`fuzzed/`)

All concrete test suites have fuzz companions that:
- Run 512 iterations with randomized inputs
- Test boundary conditions and edge cases
- Validate behavior across random state transitions
- Ensure robustness against unexpected inputs

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
# Hook callbacks
forge test --match-path test/alphix/integration/concrete/AlphixHookCalls.t.sol

# Pool management
forge test --match-path test/alphix/integration/concrete/AlphixPoolManagement.t.sol

# Access control
forge test --match-path test/alphix/integration/concrete/AccessAndOwnership.t.sol
```

### With Verbosity
```bash
forge test --match-path "test/alphix/integration/**/*.sol" -vvv
```

## Key Integration Points Tested

### 1. **Hook ↔ Logic Communication**
- Hook delegates all logic to Logic contract
- Logic validates Hook is caller
- State synchronization between contracts

### 2. **Hook ↔ PoolManager Integration**
- Hook callbacks invoked correctly
- Fee updates propagated to PoolManager
- Pool state consistency

### 3. **Access Control Integration**
- Ownable2Step for ownership transfers
- AccessManaged for Hook/Logic communication
- Role-based permissions (Poker, Registrar)

### 4. **Registry Integration**
- Automatic deployment tracking
- Pool registration on initialization
- Contract lookup functionality

### 5. **OpenZeppelin Patterns**
- UUPS upgradeability
- Pausable functionality
- ReentrancyGuard protection

## Test Results

All tests should be passing.

## Coverage Areas

- **Deployment & Initialization**: All contracts deploy and initialize correctly
- **Access Control**: Ownership, roles, and permissions enforced
- **Hook Callbacks**: All Uniswap V4 hooks implemented correctly
- **Pool Management**: Configuration, activation, deactivation, parameter updates
- **Fee Computation**: Dynamic fees calculated correctly with pool type parameters
- **State Management**: Pause, active/inactive, cooldowns
- **Upgrade Safety**: UUPS upgrades with proper authorization
- **Registry Tracking**: Automatic deployment and pool registration

These integration tests provide the middle layer of testing between unit tests (isolated components) and full cycle tests (end-to-end scenarios).
