[![codecov](https://codecov.io/github/yanisepfl/alphix-atrium/graph/badge.svg?token=JX37PW6PZA)](https://codecov.io/github/yanisepfl/alphix-atrium)

# Alphix: Atrium UHI6

**A Uniswap V4 dynamic-fee hook with upgradeable logic for seamless feature integration.**


## Overview

Alphix implements a flexible Uniswap V4 hook that adjusts LP fees dynamically based on pool ratio signals, with its logic separated into an upgradeable contract to allow safe iteration over time without requiring to redeploy a new hook and pool per feature.
Fee updates are computed from deviations between current and target volume/TVL ratios using EMA smoothing. For security, we apply both global and pool type specific bounds, cooldowns, and side-specific throttling to control sensitivity. As of now we consider three different types of pools: stable, standard and volatile.


## Links


You can find our (WIP) [Work Paper](https://github.com/yanisepfl/alphix-atrium/blob/main/Alphix_Working_Paper.pdf) briefly describing our dynamic fee algorithm. Note that we are currently drafting a Whitepaper that describes our algorithm, simulations and parameters fine tuning in much more depth.

Our [Atrium Demo Video](https://youtu.be/Uy0fGHfMMDY).

Our [Website](https://www.alphix.fi/) (the password to access our app has been shared in the submitted form, in the first answer after the Project link).

Our (WIP) [Documentation](https://alphix.gitbook.io/docs). 

## Partners

Unfortunately, we do not integrate any of the partners (other than Uniswap).

## License

This code is released under the **MIT License**.