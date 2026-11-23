# Security Policy

## Immutability & Trust Model

All Surco smart contracts deployed on Base mainnet (`chainId: 8453`) are **immutable**:

- **No owner or admin keys** — there is no `owner()`, no `Ownable`, no multisig upgrade key, and no timelock controller.
- **No pause switches** — trading, redemptions, veChirp locks/withdrawals, and upkeep functions cannot be paused or frozen.
- **No proxies or upgrades** — contract bytecode cannot be modified after deployment.
- **Permissionless upkeep** — `seed()`, `convert()`, `buyback()`, `claim()`, `plant()`, `distribute()`, `sow()`, and `harvest()` can be called by anyone.
- **Exact source verification** — every deployed contract is verified as an exact match on both [Basescan](https://basescan.org/) and [Sourcify](https://sourcify.dev/).

## Known Upstream Dependencies & Risks

- **Pinto Protocol:** All protocol backing is deposited into Pinto's Silo on Base (`0xD1A0D188E861ed9d15773a2F3574a2e94134bA8f`). Pinto is governed by its own multisig and upgrade process (see [Pinto Upgradability](https://docs.pinto.money/appendix/upgradability)). While Pinto trades below $1, Silo deposits earn zero new Pinto yield.
- **Uniswap v4 & Basin Wells:** Launcher pools use Uniswap v4 `PoolManager` (`0x498581fF718922c3f8e6A244956aF099B2652b2b`), and WETH→Pinto fee conversions route through Uniswap v3 WETH/cbETH and the Pinto cbETH Basin Well with TWAP/EMA price guards.
- **Permissionless Coin Launches:** Anyone can deploy a coin through `LauncherFactory`. On-chain deployment or listing on `surcofi.com` is automatic and not an endorsement of any third-party token.

## Reporting a Vulnerability

If you discover a security issue in the contracts, keeper, frontend, or worker API:

1. **Do not** open a public GitHub issue for an unpatched web, API, or keeper vulnerability.
2. Report privately via [GitHub Security Advisories](https://github.com/Surco-org/surco/security/advisories/new).
3. Include reproduction steps, affected contract or endpoint, and impact assessment.
