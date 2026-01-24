# Alphix Core Repository  [![codecov](https://codecov.io/github/yanisepfl/alphix-public/graph/badge.svg?token=JX37PW6PZA)](https://codecov.io/github/yanisepfl/alphix-public) [![Olympix Security](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/yanisepfl/924b52d1b46ddf65b8b1606edea89322/raw)](https://github.com/yanisepfl/alphix-public/actions/workflows/ci.yml)

![Alphix Logo](./branding-materials/logos/type/LogoTypeWhite.png)

> **A Uniswap V4 Dynamic-Fee Hook with JIT Liquidity Rehypothecation**


## Overview


### Our Vision

Alphix is building the foundation for the next generation of Automated Market Makers (AMMs) and Concentrated Liquidity AMMs (CLMMs) through composable markets.

Think dynamic fees and liquidity rehypothecation coexisting in a single pool.

### Our Hook

This repository presents Alphix's flagship product: a **Dynamic Fee Hook with JIT Liquidity Rehypothecation**.

We have implemented a **Uniswap V4 Hook** that:

1. **Adjusts LP fees dynamically** based on pool ratio signals using EMA smoothing
2. **Rehypothecates idle liquidity** through ERC-4626 yield vaults using Just-In-Time (JIT) liquidity provisioning
3. **Issues ERC20 LP shares** representing pro-rata ownership of rehypothecated positions

Fee updates are computed from deviations between current and target volume/TVL ratios. For security, we apply global bounds, cooldowns, and side-specific throttling to control sensitivity.

## Architecture

The system follows a **single-pool-per-hook design** with separation of concerns:

### Core Components

1. **Alphix Hook** ([`Alphix.sol`](src/Alphix.sol))
   - Uniswap V4 Hook with dynamic fee support
   - ERC20 LP shares for rehypothecated liquidity positions
   - JIT liquidity provisioning via `beforeSwap`/`afterSwap` hooks
   - Per-currency ERC-4626 yield source integration
   - Access-controlled via OpenZeppelin AccessManager
   - Each instance serves exactly **one pool**

2. **AlphixETH Hook** ([`AlphixETH.sol`](src/AlphixETH.sol))
   - Extends Alphix for pools with native ETH as currency0
   - Uses `IAlphix4626WrapperWeth` for ETH yield sources
   - Handles ETH deposits/withdrawals for JIT liquidity
   - Supports wrapped ETH yield vaults (e.g., Aave aWETH)

3. **DynamicFee Library** ([`DynamicFee.sol`](src/libraries/DynamicFee.sol))
   - Pure functions for fee calculations
   - EMA computation with configurable lookback periods
   - Fee clamping and out-of-bounds (OOB) detection
   - Streak tracking for consecutive OOB hits

4. **ReHypothecation Library** ([`ReHypothecation.sol`](src/libraries/ReHypothecation.sol))
   - ERC-4626 yield source interactions
   - JIT liquidity amount calculations
   - Tick range validation and liquidity math

### Supporting Infrastructure

- **BaseDynamicFee** ([`BaseDynamicFee.sol`](src/BaseDynamicFee.sol)): OpenZeppelin-based foundation for dynamic fee hooks
- **Global Constants** ([`AlphixGlobalConstants.sol`](src/libraries/AlphixGlobalConstants.sol)): System-wide bounds and configuration limits
- **Interfaces** ([`src/interfaces/`](src/interfaces/)): External API definitions
  - `IAlphix`: Main hook interface
  - `IReHypothecation`: Rehypothecation functions
  - `IAlphix4626WrapperWeth`: ETH yield source interface

## Key Features

### Dynamic Fees

Each pool is configured with parameters including:

- `minFee` / `maxFee` (uint24) - Fee bounds
- `baseMaxFeeDelta` (uint24) - Maximum fee adjustment per update
- `lookbackPeriod` (uint24) - EMA smoothing period in days
- `minPeriod` (uint256) - Cooldown between fee updates
- `ratioTolerance` / `linearSlope` (uint256, 1e18 scaled)
- `lowerSideFactor` / `upperSideFactor` (uint256) - Asymmetric throttling multipliers

### JIT Liquidity Rehypothecation

- Idle liquidity is deposited into ERC-4626 yield vaults
- Before swaps: liquidity is pulled from vaults and added to the pool
- After swaps: liquidity is removed and returned to vaults
- Users receive ERC20 shares representing their pro-rata ownership
- Supports both ERC20 and native ETH pools

### Access Control Roles

| Role | ID | Permissions |
|------|-----|-------------|
| ADMIN_ROLE | 0 | Full access, ownership |
| FEE_POKER_ROLE | 1 | Call `poke()` to update fees |
| YIELD_MANAGER_ROLE | 2 | Configure yield sources |

## Security

### Security Patterns

- **OpenZeppelin 5 Contracts**: Ownable2Step, AccessManaged, ReentrancyGuardTransient, Pausable
- **Access Control**:
  - Hook owner (will be multisig)
  - AccessManager for granular role-based permissions
  - Two-step ownership transfers to prevent accidental transfers
- **State Protection**:
  - Transient reentrancy guard on sensitive operations
  - Pausable for emergency stops
  - Cooldowns to prevent fee manipulation

### Economic Security

- **Global Bounds**: System-wide limits on fees, ratios, and parameters
- **Pool Parameter Bounds**: Configurable constraints per pool
- **Cooldown Enforcement**: Time-based rate limiting on fee updates
- **Side-Specific Throttling**: Asymmetric adjustments via upper/lower side factors
- **Streak Multipliers**: Progressive fee adjustments for sustained out-of-bounds conditions

### Governance & Operations

The Alphix team manages the following aspects of the protocol:

- **Fee Dynamization**: Fee algorithm parameters and pool configurations
- **Yield Sources**: ERC-4626 vault configurations and tick ranges
- **Treasury**: Yield tax collection and distribution

All administrative operations are executed through a **multisig wallet**. The protocol is **pausable** for emergency response.

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
git clone --recurse-submodules https://github.com/yanisepfl/alphix-public.git
cd alphix-public

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

### Running Slither Static Analysis

To run Slither analysis on the Alphix codebase:

```bash
./run_slither.sh
```

Or manually:

```bash
slither . --filter-paths "lib/|test/|script/" --json slither-report.json
```

## Deployment

Located in `script/alphix/`.

### Deployment Order

| Script | Purpose |
|--------|---------|
| `00_DeployAccessManager.s.sol` | Deploy OpenZeppelin AccessManager |
| `01_DeployAlphix.s.sol` | Deploy Alphix hook (ERC20/ERC20 pools) |
| `01_DeployAlphixETH.s.sol` | Deploy AlphixETH hook (ETH/ERC20 pools) |
| `02_ConfigureRoles.s.sol` | Configure AccessManager roles |
| `02b_SetFeePoker.s.sol` | Grant FEE_POKER_ROLE to an address |
| `02c_SetYieldManager.s.sol` | Grant YIELD_MANAGER_ROLE to an address |
| `03_CreatePool.s.sol` | Create Uniswap V4 pool with initial liquidity |
| `04_ConfigureReHypothecation.s.sol` | Set yield sources for currencies |
| `05_AddLiquidity.s.sol` | Add normal V4 liquidity |
| `05b_AddRHLiquidity.s.sol` | Add rehypothecated liquidity |
| `05c_RemoveRHLiquidity.s.sol` | Remove rehypothecated liquidity |
| `06_Swap.s.sol` | Execute swaps (testnet - PoolSwapTest) |
| `06b_SwapUniversalRouter.s.sol` | Execute swaps (mainnet - Universal Router) |
| `07_PokeFee.s.sol` | Update dynamic fee |
| `08_TransferOwnership.s.sol` | Transfer to multisig |
| `08b_AcceptOwnership.s.sol` | Accept ownership transfer |

### Running Scripts

```bash
# 1. Set up environment
cp .env.example .env
# Edit .env with your configuration
source .env

# 2. Deploy AccessManager
forge script script/alphix/00_DeployAccessManager.s.sol --rpc-url $RPC_URL --broadcast --verify

# 3. Deploy Hook (choose one based on pool type)
# For ERC20/ERC20 pools:
forge script script/alphix/01_DeployAlphix.s.sol --rpc-url $RPC_URL --broadcast --verify
# For ETH/ERC20 pools:
forge script script/alphix/01_DeployAlphixETH.s.sol --rpc-url $RPC_URL --broadcast --verify

# 4. Configure roles and unpause
forge script script/alphix/02_ConfigureRoles.s.sol --rpc-url $RPC_URL --broadcast

# 5. Create pool with initial liquidity
forge script script/alphix/03_CreatePool.s.sol --rpc-url $RPC_URL --broadcast

# 6. (Optional) Configure rehypothecation
forge script script/alphix/04_ConfigureReHypothecation.s.sol --rpc-url $RPC_URL --broadcast
forge script script/alphix/05_AddRHLiquidity.s.sol --rpc-url $RPC_URL --broadcast

# 7. Test swaps and dynamic fees
# Testnet (PoolSwapTest):
forge script script/alphix/06_Swap.s.sol --rpc-url $RPC_URL --broadcast
# Mainnet (Universal Router):
forge script script/alphix/06b_SwapUniversalRouter.s.sol --rpc-url $RPC_URL --broadcast

# 8. Update dynamic fee
forge script script/alphix/07_PokeFee.s.sol --rpc-url $RPC_URL --broadcast

# 9. Transfer ownership to multisig
forge script script/alphix/08_TransferOwnership.s.sol --rpc-url $RPC_URL --broadcast
# New owner accepts:
forge script script/alphix/08b_AcceptOwnership.s.sol --rpc-url $RPC_URL --broadcast
```

### Testnet Utilities

Mock contracts for testing are available in `script/alphix/testnet/`:

- `TestnetDeployMockERC20.s.sol` - Deploy mock ERC20 tokens
- `TestnetDeployMockYieldVault.s.sol` - Deploy mock ERC-4626 vault
- `TestnetMockYieldVaultETH.sol` - Mock ETH yield vault implementing `IAlphix4626WrapperWeth`

### Deployed Addresses

#### Base Sepolia (Testnet)

Coming Soon!

#### Mainnet

Coming Soon!

## Links & Resources

- [Website](https://www.alphix.fi/)
- [Documentation](https://alphix.gitbook.io/docs)
- [Working Paper (WIP)](./Alphix_Working_Paper.pdf)
- [Branding Material](./branding-materials/)

## Partners

- Base: Base Batch 001 & IncuBase.
- Uniswap Foundation: Buildathon Season.
- More partners to come!

## Acknowledgements

Alphix builds on top of Uniswap V4, leveraging its new **Hook Feature**. Our implementation follows the official **[Uniswap v4 template](https://github.com/uniswapfoundation/v4-template)**, and closely follows **[OpenZeppelin's Uniswap Hook template](https://github.com/OpenZeppelin/uniswap-hooks)**. This helps us ensure compatibility and best practices.

## License

This project is licensed under the **Business Source License 1.1 (BUSL-1.1)**.

- **Change Date:** December 25, 2028
- **Change License:** MIT

After the Change Date, the code will be available under the MIT License. See [LICENSE](./LICENSE) for full terms.
