# Alphix Core Repository  [![codecov](https://codecov.io/github/yanisepfl/alphix-public/graph/badge.svg?token=JX37PW6PZA)](https://codecov.io/github/yanisepfl/alphix-public)

![Alphix Logo](./branding-materials/logos/type/LogoTypeWhite.png)

> **A Uniswap V4 Dynamic-Fee Hook with upgradeable logic for seamless feature integration**


## Overview 


### Our Vision

Alphix is building the foundation for the next generation of Automated Market Makers (AMMs) and Concentrated Liquidity AMMs (CLMMs) through composable and customizable markets.

Think dynamic fees, liquidity rehypothecation, automated rebalancing, and other market efficiency innovations — all coexisting in a single pool.

### Our Hook

This repository presents Alphix's flagship product: a **Dynamic Fee Hook**.

We have implemented a **Flexible Uniswap V4 Hook** that adjusts LP fees dynamically based on pool ratio signals, with its logic separated into an **upgradeable** contract to allow safe iteration over time without requiring to redeploy a new hook and pool per innovation. 

Fee updates are computed from deviations between current and target volume/TVL ratios using EMA smoothing. For security, we apply both global and pool type specific bounds, cooldowns, and side-specific throttling to control sensitivity.

## Architecture

The system follows a three-layer architecture with clear separation of concerns:

### Core Components

1. **Hook Entrypoint** ([`Alphix.sol`](src/Alphix.sol))
   - Implements Uniswap V4 `IHooks` interface
   - Delegates all callbacks to upgradeable logic contract
   - Manages pool lifecycle (initialization, activation, deactivation)
   - Exposes fee poke functionality and administrative operations
   - Integrates with Registry for automatic tracking

2. **Upgradeable Logic** ([`AlphixLogic.sol`](src/AlphixLogic.sol))
   - Deployed behind ERC1967 proxy with UUPS upgradeability
   - Implements fee computation algorithms and EMA target updates
   - Manages per-pool configuration and state
   - Enforces cooldowns, bounds, and side-specific throttling
   - Tracks active/configured/paused pool status

3. **Math Library** ([`DynamicFee.sol`](src/libraries/DynamicFee.sol))
   - Pure functions for fee calculations
   - EMA computation with configurable lookback periods
   - Fee clamping and out-of-bounds (OOB) detection
   - Streak tracking for consecutive OOB hits

### Supporting Infrastructure

- **Registry** ([`Registry.sol`](src/Registry.sol)): Automatic deployment and pool tracking using AccessManager roles
- **Global Constants** ([`AlphixGlobalConstants.sol`](src/libraries/AlphixGlobalConstants.sol)): System-wide bounds and configuration limits
- **Interfaces** ([`src/interfaces/`](src/interfaces/)): External API definitions for all contracts
- **Base Contracts** ([`BaseDynamicFee.sol`](src/BaseDynamicFee.sol)): OpenZeppelin-based foundation for dynamic fee hooks

## Pool Types & Parameters

Three built-in pool categories with distinct sensitivity profiles:

| PoolType  | Parameter Set                  |
|-----------|--------------------------------|
| STABLE    | Low baseMaxFeeDelta, tight ratioTolerance, short lookbackPeriod |
| STANDARD  | Moderate sensitivity and bounds |
| VOLATILE  | High sensitivity, wider bands   |

Each `PoolTypeParams` includes:

- `minFee` / `maxFee` (uint24)
- `baseMaxFeeDelta` (uint24)  
- `lookbackPeriod` (uint24, expressed in days)  
- `minPeriod` (uint256, expressed in seconds)  
- `ratioTolerance` / `linearSlope` (uint256, 1e18 scaled)  
- `lowerSideFactor` / `upperSideFactor` (uint256, throttling multipliers)

Each of those parameters are bounded by global constants for additional security.

## Security & Upgradability

### Security Patterns

- **OpenZeppelin 5 Upgradeable Contracts**: Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable
- **Access Control**:
  - Hook owner (will be multisig)
  - AccessManager for Registry with role-based permissions (REGISTRAR_ROLE, POKER_ROLE)
  - Two-step ownership transfers to prevent accidental transfers
- **State Protection**:
  - ReentrancyGuard on sensitive operations
  - Pausable for emergency stops
  - Cooldowns to prevent manipulation
- **Upgrade Safety**:
  - UUPS pattern with owner-only authorization
  - Interface compliance checks (`IAlphixLogic` enforcement)
  - State preservation across upgrades

### Economic Security

- **Global Bounds**: System-wide limits on fees, ratios, and parameters
- **Pool Type Bounds**: Category-specific constraints (STABLE, STANDARD, VOLATILE)
- **Cooldown Enforcement**: Time-based rate limiting on fee updates
- **Side-Specific Throttling**: Asymmetric adjustments via upper/lower side factors
- **Streak Multipliers**: Progressive fee adjustments for sustained out-of-bounds conditions

## Testing

The protocol includes comprehensive testing across multiple layers:

- **Unit Tests**: Isolated component validation (libraries, math functions)
- **Integration Tests**: Cross-component interaction verification
- **Full Cycle Tests**: End-to-end lifecycle scenarios including 30-day simulations
- **Invariant Tests**: Property-based stateful fuzzing to ensure critical invariants hold
- **Fuzz Testing**: Randomized input testing with 512 runs per test

All tests are built with Foundry. See [`test/alphix/README.md`](test/alphix/README.md) for detailed documentation.

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git with submodules support

### Setup

```bash
# Clone repository with submodules
git clone --recurse-submodules https://github.com/yanisepfl/alphix-atrium.git
cd alphix-atrium

# Install dependencies
forge install

# Build contracts
forge build
```

### Running Tests

```bash
# Run all tests
forge test

# Run with gas reporting
forge test --gas-report

# Run specific test suite
forge test --match-path "test/alphix/integration/**/*.sol"

# Run with verbosity
forge test -vvv
```

### Deployment

Coming Soon.

### Addresses

Coming Soon.

## Links & Resources

- [Website](https://www.alphix.fi/)
- [Documentation](https://alphix.gitbook.io/docs)
- [Working Paper (WIP)](./Alphix_Working_Paper.pdf)
- [Branding Material](./branding-materials/)

## Partners

More partners to come.

## Acknowledgements

Alphix builds on top of Uniswap V4, leveraging its new **[Hook Feature](#hooks)**. Our implementation follows the official **[Uniswap v4 template](https://github.com/uniswapfoundation/v4-template)**, and closely follows **[OpenZeppelin's Uniswap Hook template](https://github.com/OpenZeppelin/uniswap-hooks)**. This helps us ensure compatibility and best practices.

## License

This code is released under the **MIT License**.