# Surco Launcher, Collective Silo & veChirp (Contracts)

Permissionless token launcher on Base (`chainId: 8453`) whose Uniswap v4 hook trade fees convert into Pinto deposited in Pinto's Silo, paired with a shared `CollectiveSilo` and `VeChirp` ERC-721 vote-escrow gauge.

**Immutable on Base mainnet:** no owner, no pause, no proxy, no upgrade.

## Contracts (`src/`)

- **`LauncherHook`** — Shared Uniswap v4 hook: collects swap fees in WETH to each coin's vault (with a 10-minute decaying anti-sniper toll from 80% down to the coin's base fee), permanently locks full-range liquidity, and maintains a per-pool tick EMA.
- **`LauncherFactory`** — Permissionless `launch()` entrypoint: deploys a `LaunchToken` (1B fixed supply, 18 decimals) + either a `BurnVault` or `RedeemVault`, initializes a COIN/WETH Uniswap v4 pool at a 10 WETH starting FDV, locks 100% of supply, executes an optional creator first buy, and routes the `0.0001 ETH` launch fee as WETH to `CollectiveSilo`.
- **`BurnDeployer` / `RedeemDeployer`** — Helper deployers for `BurnVault` and `RedeemVault`.
- **`VaultBase`** — `split()` pays platform + creator WETH shares; `convert()` routes WETH → cbETH → Pinto into Pinto's Silo (0.5% keeper tip) with TWAP/EMA guards; `seed()` books voluntarily transferred Pinto directly into Silo backing.
- **`BurnVault`** — When Pinto is above peg, `buyback(maxPinto)` spends planted Silo yield to buy the coin through its v4 pool and burn it.
- **`RedeemVault`** — Holders `redeem()` coins for their proportional share of Silo Pinto backing (1% fee stays in the vault); `claim()` plants earned Silo yield; `merge()` consolidates Silo stems.
- **`VeChirp`** — Minimal `solmate` ERC-721 vote-escrow gauge for `CHIRP`: 2–365 UTC day linear decay + Permanent Max-Lock toggle, `today + 1` activation (no flash-staking), one directed coin per NFT, zero external dependency on withdrawal.
- **`CollectiveSilo`** — Shared Pinto Silo funded by launch fees and voluntary Pinto seeds; distributes planted Silo yield across factory-launched coins proportional to daily `veCHIRP` gauge weights.
- **`LaunchToken`, `FeeMath`, `PriceGuard`, `PintoRoute`, `Constants`** — Supporting token, fee curve, oracle/EMA guards, swap routing, and canonical Base protocol constants.

## Live Base Mainnet Addresses

| Contract | Address |
|---|---|
| `LauncherFactory` | `0xf3A050114d4310beF64660a68332169Eb76D0d70` |
| `LauncherHook` | `0x9e0DB1E907Da713Ef19E95b0aB539f8ef9ffEAEc` |
| `VeChirp` | `0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed` |
| `CollectiveSilo` | `0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064` |
| `BurnDeployer` | `0x4A3C9698fF108C936B40D0E92EaFb888661D0539` |
| `RedeemDeployer` | `0x7DEA8FC6C53c1CE56701A423169cAA6d97599e14` |

## Testing & Simulation

```bash
# Unit, fuzz, and invariant tests (offline)
forge test --no-match-path 'test/fork/*'

# Base mainnet fork tests (pinned block 60,050,000)
forge test --match-path 'test/fork/*' --fork-url "${BASE_RPC_URL:-https://mainnet.base.org}"

# Simulate full stack deployment (never pass --broadcast unless deploying a new instance)
LAUNCHER_SAFE=0x000000000000000000000000000000000000dEaD forge script script/Deploy.s.sol --fork-url "${BASE_RPC_URL:-https://mainnet.base.org}"
```

## Gas Benchmarks (Base Fork)

| Call | Approximate Gas |
|---|---|
| `launch` (with 1 ETH first buy) | ~3.95M |
| Universal Router exact-in swap | ~122k |
| `convert` (split + v3 + well + Silo deposit) | ~1.30–1.38M |
| `seed` (real Silo deposit, cold) | ~574–869k |
| `redeem` (single stem) | ~288–295k |
| `buyback` (`abovePeg()` + `plant()` + route + burn) | ~1.35–1.39M |
| `merge` (3 stems, warm) | ~369k |

## Keeper Notes

1. Buffer gas estimates for `convert`/`buyback` by ~1.3× (`eth_estimateGas * 1.3`).
2. Treat `Slippage` / `TickDrift` reverts from `convert()` as transient retries with backoff; `NothingPending` is a normal no-op.
3. Direct Basin Well `swapFrom` calls require at least a 400k gas limit so the well's reentrancy sentry does not run out of gas.
4. `convert()` auto-merges when a vault exceeds 3 Silo stems (`MERGE_GAS = 1M`); size gas via `eth_estimateGas` or allow ~2.5M gas.
