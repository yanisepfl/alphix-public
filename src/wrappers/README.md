# Alphix 4626 Wrappers

ERC-4626 vault wrappers that allow Alphix Hooks to rehypothecate liquidity into various DeFi protocols, earning additional yield on top of swap fees while enabling Alphix to collect a performance fee.

## Overview

This repository contains protocol-specific ERC-4626 vault implementations. Each wrapper:

- Deposits user funds into a yield-generating DeFi protocol
- Exposes a standard ERC-4626 interface for deposits/withdrawals
- Collects a configurable fee on generated yield
- Restricts access to authorized Alphix Hooks and the contract owner

## Supported Protocols

| Protocol | Wrapper | Asset | Chain | Description |
|----------|---------|-------|-------|-------------|
| **Aave V3** | `Alphix4626WrapperAave` | Any ERC-20 | Any with Aave V3 | Deposits into Aave V3 lending pools |
| **Aave V3** | `Alphix4626WrapperWethAave` | WETH/ETH | Any with Aave V3 | Extends Aave wrapper with native ETH support |
| **Sky (Spark)** | `Alphix4626WrapperSky` | USDS | Base | Deposits into sUSDS via Spark PSM, includes circuit breaker |

## Architecture

```text
┌─────────────────────────────────────────────────────────────────┐
│                        Alphix Hook                              │
│              (Authorized depositor/withdrawer)                  │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Alphix4626Wrapper                            │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  ERC-4626 Interface                                     │   │
│  │  - deposit(assets, receiver) → shares                   │   │
│  │  - withdraw(assets, receiver, owner) → shares           │   │
│  │  - redeem(shares, receiver, owner) → assets             │   │
│  └─────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Fee Mechanism                                          │   │
│  │  - Tracks yield via rate/balance changes                │   │
│  │  - Deducts fee percentage from yield                    │   │
│  │  - Owner calls collectFees() → treasury                 │   │
│  └─────────────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Access Control                                         │   │
│  │  - Ownable2Step (owner)                                 │   │
│  │  - Authorized Alphix Hooks (depositors)                 │   │
│  │  - Pausable                                             │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Underlying Protocol                          │
│           (Aave V3, Spark PSM, future protocols...)            │
└─────────────────────────────────────────────────────────────────┘
```

## ERC-4626 Deviations

All wrappers intentionally deviate from the ERC-4626 standard:

| Function | Deviation | Reason |
|----------|-----------|--------|
| `mint()` | Disabled, reverts with `NotImplemented` | Simplifies accounting; use `deposit()` instead |
| `previewMint()` | Reverts | Mint is disabled |
| `deposit()` | Requires `receiver == msg.sender` | Prevents unauthorized deposits on behalf of others |
| `withdraw()`/`redeem()` | Requires `owner == msg.sender` | No allowance-based withdrawals; only owner can withdraw |

## Trust Model

### Owner (Ownable2Step)

The owner has full administrative control:

- Set fee rate (0-100%)
- Set/change yield treasury address
- Add/remove authorized Alphix Hooks
- Pause/unpause the contract
- Rescue stuck tokens (excluding protocol tokens)
- Claim Aave rewards (Aave wrappers only)
- Sync rate after circuit breaker triggers (Sky wrapper only)

**Note:** `renounceOwnership()` is disabled to prevent accidental loss of admin functions.

### Alphix Hooks

Authorized contracts that can deposit and withdraw. Only audited, trusted contracts should be added as hooks.

**Warning:** Compromised hooks can drain all funds. Exercise extreme caution when adding hooks.

### Users

Should monitor admin actions (fee changes, treasury updates, hook additions) as there are no timelocks on these operations.

## Installation

```bash
# Clone the repository
git clone https://github.com/alphix/alphix-4626-wrappers.git
cd alphix-4626-wrappers

# Install dependencies
forge install

# Copy environment file
cp .env.example .env
# Edit .env with your configuration
```

## Building

```bash
# Build all contracts
forge build

# Build with optimizer (for deployment)
forge build --profile ci
```

## Testing

The test suite includes unit tests, fuzz tests, integration tests, and invariant tests.

```bash
# Run all tests
forge test

# Run with verbose output
forge test -vvv

# Run specific test file
forge test --match-path test/aave/unit/concrete/Deposit.t.sol

# Run specific test function
forge test --match-test test_deposit_success
```

### Test Coverage

```bash
# Quick coverage (recommended for development)
FOUNDRY_FUZZ_RUNS=16 FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=32 \
  forge coverage --no-match-coverage "lib/|script/"

# Full coverage (takes longer due to invariant tests)
forge coverage --no-match-coverage "lib/|script/"

# Generate LCOV report
forge coverage --report lcov --no-match-coverage "lib/|script/"
```

### Test Structure

```text
test/
├── <protocol>/
│   ├── Base<Protocol>.t.sol       # Shared test setup
│   ├── mocks/                     # Mock contracts
│   ├── unit/
│   │   ├── concrete/              # Concrete unit tests
│   │   └── fuzzed/                # Fuzz unit tests
│   ├── integration/
│   │   ├── concrete/              # Concrete integration tests
│   │   └── fuzzed/                # Fuzz integration tests
│   └── invariant/                 # Invariant tests
│       └── handlers/              # Invariant test handlers
```

## Deployment

Deployment scripts are located in `script/<protocol>/`.

```bash
# Deploy Aave wrapper (example)
forge script script/aave/DeployAlphix4626WrapperAave.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

Refer to individual deployment scripts for required environment variables and configuration.

## Adding a New Protocol

To add support for a new DeFi protocol:

1. **Create the wrapper contract** in `src/<protocol>/`:
   - Inherit from `ERC4626`, `Ownable2Step`, `ReentrancyGuard`, `Pausable`
   - Implement protocol-specific deposit/withdraw logic
   - Implement fee tracking based on yield mechanism (rate changes, balance growth, etc.)
   - Follow the ERC-4626 deviations documented above

2. **Create the interface** in `src/<protocol>/interfaces/`:
   - Define custom errors, events, and protocol-specific functions

3. **Create test infrastructure** in `test/<protocol>/`:
   - `Base<Protocol>.t.sol` - Shared setup with mock contracts
   - `mocks/` - Protocol-specific mocks
   - Unit, integration, and invariant tests

4. **Create deployment script** in `script/<protocol>/`

### Template Structure

```text
src/<protocol>/
├── Alphix4626Wrapper<Protocol>.sol
└── interfaces/
    └── IAlphix4626Wrapper<Protocol>.sol

test/<protocol>/
├── Base<Protocol>.t.sol
├── mocks/
│   └── Mock<ExternalContract>.sol
├── unit/
│   ├── concrete/
│   └── fuzzed/
├── integration/
│   ├── concrete/
│   └── fuzzed/
└── invariant/
    └── handlers/

script/<protocol>/
└── Deploy<Protocol>.s.sol
```

## Protocol-Specific Features

### Sky Wrapper: Circuit Breaker

The Sky wrapper includes a circuit breaker mechanism that protects against oracle manipulation or unexpected rate changes:

- **Threshold**: Reverts if the sUSDS/USDS rate changes by more than **1%** since the last accrual
- **Trigger**: Any operation that accrues yield (deposit, withdraw, redeem, setFee, collectFees) will revert with `ExcessiveRateChange` if the threshold is exceeded
- **Recovery**: Owner calls `syncRate()` to update the stored rate to current, bypassing the circuit breaker while still accruing yield/fees

```solidity
// When circuit breaker blocks operations due to large rate jump:
wrapper.syncRate();  // Owner-only, syncs rate in a single call

// After sync, normal operations resume
wrapper.deposit(amount, receiver);
```

**When does the circuit breaker trigger?**
- Oracle manipulation attempts
- Legitimate large rate changes (rare but possible)
- Extended periods without any wrapper interaction

## Security Considerations

- **No Timelocks**: Admin functions execute immediately. Monitor owner actions.
- **Hook Trust**: Only add thoroughly audited hooks. Compromised hooks = total loss.
- **Fee Range**: Fees can be set from 0% to 100%. High fees impact user returns.
- **Protocol Risk**: Wrapper inherits risks from underlying protocols (smart contract bugs, oracle failures, etc.).
- **Pausability**: Owner can pause deposits/withdrawals at any time.
- **Circuit Breaker (Sky)**: Large rate changes (>1%) block operations until owner calls `syncRate()`.

## License

BUSL-1.1 (Business Source License 1.1)

See [LICENSE](LICENSE) for details. The license converts to MIT on December 25, 2028.

## Dependencies

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) - ERC-4626, access control, security utilities
- [Aave V3 Core](https://github.com/aave/aave-v3-core) - Aave V3 interfaces and libraries
- [Aave V3 Periphery](https://github.com/aave/aave-v3-periphery) - Aave V3 rewards interfaces
- [Forge Std](https://github.com/foundry-rs/forge-std) - Foundry testing utilities
