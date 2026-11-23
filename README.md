# Surco

**A leviathan-free ecosystem built on Pinto and Base.**

Website: [https://surcofi.com](https://surcofi.com) · X: [@chirpfi](https://x.com/chirpfi)

This repository contains the complete, auditable open-source codebase for **Surco** on Base mainnet (`chainId: 8453`):

1. **[`chirp/`](./chirp)** — **Chirp (`CHIRP`)** token and one-sided Pinto Silo book + Uniswap v4 price hook.
2. **[`launcher/`](./launcher)** — **Surco Launcher Factory**, **BurnVault / RedeemVault**, **CollectiveSilo**, **veChirp (`veCHIRP`)** ERC-721 NFT gauge, permissionless daily **keeper**, and **DeFiLlama** TVL adapter.
3. **[`web/`](./web)** — The `surcofi.com` static frontend (Vite + viem + Lightweight Charts).
4. **[`worker/`](./worker)** — The `surcofi.com` Cloudflare Worker API (`/api/chirp`, `/api/launcher/*`, `/api/launcher/ve/*`, `/api/0x/*`, read-only `/api/rpc`, D1 migrations).

All deployed smart contracts have **no owner, no pause, and no upgrade**, and are source-verified (`exact_match`) on both Basescan and Sourcify.

---

## Verified Base Mainnet Contracts (Chain 8453)

### Chirp

| Contract | Address | Explorer & Verification |
|---|---|---|
| **Chirp (`CHIRP`)** | `0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13` | [Basescan](https://basescan.org/address/0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13#code) · [Sourcify](https://repo.sourcify.dev/8453/0x4D2D8C1E1c8239Ca56Db7612C9Efe5d6a1a2ea13) |
| **ChirpHook** (trade entrypoint) | `0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8` | [Basescan](https://basescan.org/address/0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8#code) · [Sourcify](https://repo.sourcify.dev/8453/0x91b48A16f0d78CA7eAe464865F9Bec753Cb72AE8) |
| **ChirpBook** | `0x10b919A89a5ABfecEBd805836DA174F02B023756` | [Basescan](https://basescan.org/address/0x10b919A89a5ABfecEBd805836DA174F02B023756#code) · [Sourcify](https://repo.sourcify.dev/8453/0x10b919A89a5ABfecEBd805836DA174F02B023756) |
| **ChirpPeg** | `0x085db1415D04d6f464a36BEb3cB6CCc429ca75Ec` | [Basescan](https://basescan.org/address/0x085db1415D04d6f464a36BEb3cB6CCc429ca75Ec#code) · [Sourcify](https://repo.sourcify.dev/8453/0x085db1415D04d6f464a36BEb3cB6CCc429ca75Ec) |
| **ChirpFactory** | `0x0D5D9C89b6ff8cDAfe25E7B253Db10114FC6313a` | [Basescan](https://basescan.org/address/0x0D5D9C89b6ff8cDAfe25E7B253Db10114FC6313a#code) · [Sourcify](https://repo.sourcify.dev/8453/0x0D5D9C89b6ff8cDAfe25E7B253Db10114FC6313a) |

### Surco Launcher, Collective Silo & veChirp

| Contract | Address | Explorer & Verification |
|---|---|---|
| **LauncherFactory** | `0xf3A050114d4310beF64660a68332169Eb76D0d70` | [Basescan](https://basescan.org/address/0xf3A050114d4310beF64660a68332169Eb76D0d70#code) · [Sourcify](https://repo.sourcify.dev/8453/0xf3A050114d4310beF64660a68332169Eb76D0d70) |
| **LauncherHook** | `0x9e0DB1E907Da713Ef19E95b0aB539f8ef9ffEAEc` | [Basescan](https://basescan.org/address/0x9e0DB1E907Da713Ef19E95b0aB539f8ef9ffEAEc#code) · [Sourcify](https://repo.sourcify.dev/8453/0x9e0DB1E907Da713Ef19E95b0aB539f8ef9ffEAEc) |
| **VeChirp (`veCHIRP` ERC-721)** | `0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed` | [Basescan](https://basescan.org/address/0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed#code) · [Sourcify](https://repo.sourcify.dev/8453/0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed) |
| **CollectiveSilo** | `0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064` | [Basescan](https://basescan.org/address/0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064#code) · [Sourcify](https://repo.sourcify.dev/8453/0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064) |
| **BurnDeployer** | `0x4A3C9698fF108C936B40D0E92EaFb888661D0539` | [Basescan](https://basescan.org/address/0x4A3C9698fF108C936B40D0E92EaFb888661D0539#code) · [Sourcify](https://repo.sourcify.dev/8453/0x4A3C9698fF108C936B40D0E92EaFb888661D0539) |
| **RedeemDeployer** | `0x7DEA8FC6C53c1CE56701A423169cAA6d97599e14` | [Basescan](https://basescan.org/address/0x7DEA8FC6C53c1CE56701A423169cAA6d97599e14#code) · [Sourcify](https://repo.sourcify.dev/8453/0x7DEA8FC6C53c1CE56701A423169cAA6d97599e14) |

---

## Repository Structure

```text
.
├── chirp/          # Chirp token, one-sided Pinto Silo book, v4 hook & Foundry tests
├── launcher/       # Surco LauncherFactory, Burn/Redeem vaults, CollectiveSilo, VeChirp, keeper & DeFiLlama adapter
├── web/            # surcofi.com frontend (Vite + viem + Lightweight Charts)
└── worker/         # surcofi.com Cloudflare Worker API & D1 SQL migrations
```

---

## Building & Testing Locally

Clone with submodules (`forge-std`, `solmate`, and Uniswap `v4-core` `v4.0.0`):

```bash
git clone --recursive https://github.com/Surco-org/surco.git
cd surco
```

### 1. Chirp Smart Contracts (Foundry)

```bash
cd chirp
forge build
forge test
```

### 2. Launcher, Collective Silo & veChirp Contracts (Foundry)

```bash
cd launcher
forge build
forge test --no-match-path 'test/fork/*'
```

Optional Base mainnet fork tests (requires a Base archive/mainnet RPC):

```bash
forge test --match-path 'test/fork/*' --fork-url "${BASE_RPC_URL:-https://mainnet.base.org}"
```

### 3. Permissionless Keeper (Python 3)

```bash
cd launcher/keeper
python3 -m unittest test_keeper
```

### 4. Frontend (`surcofi.com`)

```bash
cd web
npm ci
npm test
npm run build
```

### 5. Cloudflare Worker API

```bash
cd worker
npm ci
npm run typecheck
npm test
```

---

## Transparency & Disclosures

- **Chirp Referrer:** `ChirpBook.REFERRER` is an immutable constant (`0x0dB14dc82CBB0ce820F65c9796E0bC9E19eF08bf`) passed to Pinto's Field `sow` referral program. Any referral bonus Pods come from Pinto's referral program, never from Chirp's Pinto backing.
- **Launcher Platform Split:** `LauncherFactory` directs 20% of trade fees (in WETH) to the immutable platform treasury address (`0x2D67Fc71e6ed4527E09dD9F8C73f3D7c72219449`), up to 20% to the coin creator, and the remaining 60–80% converts to Pinto in the coin's Silo vault. The `0.0001 ETH` launch fee routes as WETH to `CollectiveSilo`.
- **License:** MIT (see [`LICENSE`](./LICENSE)).
