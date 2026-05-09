# **Synthora Vault** 

**Real-World Assets. Perpetual Power.**

*Automated Leveraged Trading Vault for AAPL, TSLA, NVDA, Gold & More*

---

## Overview

**Synthora Vault** is a next-generation on-chain **automated trading vault** that enables users to get leveraged exposure to **Real World Assets (RWA)** through synthetic perpetual futures.

Users deposit USDC and the vault intelligently opens, manages, and optimizes leveraged long/short positions on traditional assets like Apple, Tesla, Nvidia, S&P 500, Gold, etc., using high-precision oracles (Pyth + Chainlink).

Built with battle-tested GMX V2 style mechanics + advanced risk management, Synthora brings **24/7 institutional-grade trading** to DeFi with full self-custody.

---

## Core Concept

Traditional stock trading has limitations:
- Restricted trading hours
- High barriers for non-US users
- Limited leverage
- Complex account setup

**Synthora solves this** by creating **synthetic perpetual futures** on real-world assets, allowing:
- Up to **20x leverage**
- 24/7 trading
- Dynamic risk management
- Funding rate arbitrage opportunities

The vault acts as an **autonomous trading agent** that executes professional strategies on behalf of depositors.

---

## How It Works

### User Flow

1. **Connect Wallet** → Deposit USDC (or supported stablecoins)
2. **Receive Vault Shares** (ERC4626 compliant)
3. **Choose Strategy**:
   - Directional Long/Short
   - Multi-Asset Basket
   - Funding Rate Arbitrage (market-neutral)
4. **Vault Executes** → Opens leveraged perp position using oracle prices
5. **Active Management** → Keeper bots monitor & optimize positions
6. **Withdraw Anytime** → Redeem shares with realized PnL

---

## Key Features

### Trading Capabilities
- **Synthetic RWA Perps**: AAPL, TSLA, NVDA, GOOGL, AMZN, SPX, Gold, Crude Oil, etc.
- **Dynamic Leverage** — Automatically adjusts based on volatility, equity, and position size
- **Funding Rate Arbitrage** — Earn yield from funding imbalances
- **Multi-Collateral Support** (USDC primary)
- **Real-time Risk Management** — Liquidation protection & auto-rebalancing

### Technical Excellence
- **UUPS Upgradeable** architecture
- **Role-based Access Control** (Admin, Strategist, Keeper)
- **Gas Optimized** + Storage Packing
- **Frontend-friendly** extensive view functions
- **Keeper Automation** via Chainlink + custom bots
- **Comprehensive Events** for The Graph indexing

---

## Smart Contract Architecture

- **Main Contract**: `SynthoraVault.sol`
- **Pattern**: UUPS Proxy + ERC4626 Vault
- **Oracles**: Pyth Network (primary) + Chainlink (fallback)
- **Blockchain**: Arbitrum (primary) / Base
- **Security**: ReentrancyGuard, Custom Errors, Slippage Protection, Pausable
- **Testing**: Unit + Fuzz + Invariant + Fork tests

---

## Roles & Permissions

| Role              | Responsibilities                          | Access Level     |
|-------------------|-------------------------------------------|------------------|
| **Admin**         | Fees, Parameters, Upgrades, Emergency     | Highest          |
| **Strategist**    | Strategy creation & tuning                | High             |
| **Keeper**        | Automation, Rebalancing, Liquidation Mgmt | Operational      |
| **User**          | Deposit & Withdraw                        | Standard         |

---

## Risk Disclaimer

**Important**: Leveraged trading carries substantial risk of loss. Users can lose entire capital due to liquidation, funding rates, or oracle deviations. This is a high-risk DeFi product. DYOR and only invest what you can afford to lose.

---

## Tech Stack

- **Language**: Solidity ^0.8.28
- **Framework**: Foundry
- **Frontend**: Next.js + Wagmi + Tailwind CSS
- **Oracles**: Pyth + Chainlink
- **Indexing**: The Graph
- **Automation**: Chainlink Keepers

---

## Quick Start

```bash
# Clone the repo
git clone https://github.com/vishal-tiwari9/Synthora-Vault.git

# Install dependencies
forge install

# Run tests
forge test -vvv

# Deploy on Arbitrum Sepolia
forge script script/DeploySynthoraVault.s.sol \
  --rpc-url arbitrum-sepolia \
  --broadcast --verify
