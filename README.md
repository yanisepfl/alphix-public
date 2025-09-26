# Alphix Core Repository  [![codecov](https://codecov.io/github/yanisepfl/alphix-atrium/graph/badge.svg?token=JX37PW6PZA)](https://codecov.io/github/yanisepfl/alphix-atrium)

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

The system consists of a Uniswap V4 hook that delegates all callbacks to an upgradeable logic contract, plus a pure math library and interfaces for coordination and registration.
Administrative functions are managed by the hook owner, while per-pool state and algorithms reside in the logic contract deployed behind an ERC1967 proxy with UUPS authorization.

The repository is organized into three main layers:
- **Hook entrypoint ([Alphix](src/Alphix.sol)):** Alphix forwards all before/after initialize, add/remove liquidity, and swap callbacks to the logic and exposes admin operations, including fee pokes and pool lifecycle management.
- **Upgradeable logic ([AlphixLogic](src/AlphixLogic.sol)):** AlphixLogic implements fee computation, EMA target updates, cooldown checks, per-pool configuration, and active/configured/paused pool status tracking.
- **Dynamic Fee Library ([DynamicFeeLib](src/libraries/DynamicFee.sol)):** DynamicFeeLib provides pure math helper functions for fee deltas, clamping, OOB tracking, and EMA.

We also created a [Registry](src/Registry.sol) that automatically stores our deployed contracts and pools using AccessManager roles. Finally, we added [Interfaces](src/interfaces/) to define the external API for our contracts.

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

- Utilizes **OpenZeppelin Upgradable** patterns: Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, and ERC165 support. 
- The owner address will be a **multisig**.
- **Registry** uses AccessManager for granular role control over registrations.
- **Upgradeable logic** through UUPS: `authorizeUpgrade` restricts to owner and enforces `IAlphixLogic` interface compliance.

## Links & Resources

- [Working Paper (WIP)](./Alphix_Working_Paper.pdf)
- [Website](https://www.alphix.fi/)
- [Documentation (WIP)](https://alphix.gitbook.io/docs)
- [Branding Material](./branding-materials/)

## Partners

More partners to come.

## Acknowledgements

Alphix builds on top of Uniswap V4, leveraging its new **[Hook Feature](#hooks)**. Our implementation follows the official **[Uniswap v4 template](https://github.com/uniswapfoundation/v4-template)**, and closely follows **[OpenZeppelin's Uniswap Hook template](https://github.com/OpenZeppelin/uniswap-hooks)**. This helps us ensure compatibility and best practices.

## License

This code is released under the **MIT License**.