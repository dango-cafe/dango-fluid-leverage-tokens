# Fluid Leverage Tokens

Fully collateralized leverage tokens powered by Aave & Sushiswap. All the leverage tokens aims to leverage at a target leverage ratio.

Following FLTs are live on Polygon!

| **Token**                       | **Collateral** | **Debt** | **Leverage Ratio** |
|---------------------------------|----------------|----------|--------------------|
| [ETH 2x Fluid Leverage Token](https://polygonscan.com/token/0xabcd3c5e8aed3b8d8096f0f33c7aa1cb5d555dfb)     | WETH           | USDC     | 2x                 |
| [BTC 2x Fluid Leverage Token](https://polygonscan.com/token/0x12b6dc6c41460994f0471f0a665bebfc78f3f55c)                                                                                 | WBTC           | USDC     | 2x                 |
| [ETH/BTC 2x Fluid Leverage Token](https://polygonscan.com/token/0x0093660a2f58c0c38ce2ce0f894c86f9011478ea) | WETH           | WBTC     | 2x                 |
| [BTC/ETH 2x Fluid Leverage Token](https://polygonscan.com/token/0x540fbc594c455a8af6d238c16af2511c37cc0e9b) | WBTC           | WETH     | 2x                 |

### Governance / Owner Privileges

* Update mint / burn fees
* Update Aave lending pool / oracle address
* Update Flashloan adapater address
* Update Fee collector address
* Increase deposit limit
* Whitelist / Revoke rebalancers

FLTs need to rebalance every 24 hrs to achieve the target leverage ratio. Only whitelisted rebalancers can call this method

### Contracts

`DangoFluidLeverageToken` - Main contract of FLT system. All the token methods, deposit, withdraw & rebalance methods are inside this contract

`DangoFlashloanAdapter` - This contracts acts as callback for all flashloan methods, hence all trades happen in this contract. Deployed [here](https://polygonscan.com/address/0x0a796b0dc59324233aa2f4ce2e5fb74b81ff2301)