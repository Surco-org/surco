# Surco Launcher Keeper

Permissionless upkeep script (`keeper.py`) for Surco Launcher vaults and `CollectiveSilo` on Base.

Anyone can run this keeper. On each run it:
1. Discovers newly launched vaults from `LauncherFactory` `Launched` logs.
2. Calls `seed()` on any vault (or `CollectiveSilo`) holding unbooked Pinto.
3. Calls `convert()` when a vault's accumulated WETH fees reach at least `0.0005 WETH`.
4. When Pinto is above peg, calls `buyback()` (`BurnVault`), `claim()` (`RedeemVault`), and `plant()` + `distribute()` (`CollectiveSilo`).

## Dependencies

- Python 3.10+ standard library
- `eth_account` (imported lazily only when signing live transactions; not required for `DRY_RUN=1` or unit tests)

## Configuration

Set environment variables (e.g. via an `.env` file with `chmod 600`):

- `FACTORY` — `LauncherFactory` address (`0xf3A050114d4310beF64660a68332169Eb76D0d70`)
- `FACTORY_BLOCK` — deployment block (`60614593`)
- `COLLECTIVE_SILO` — `CollectiveSilo` address (`0x1e050aDAC1011bcCeEf66FA485331fAaFA9Ad064`)
- `VE_CHIRP` — `VeChirp` address (`0x7b817Bd8773b5CaAE267e9cc43FEdbceF148F0ed`)
- `RPC_URL` — Base JSON-RPC endpoint supporting `eth_getLogs` (defaults to `https://base-rpc.publicnode.com`)
- `STATE` — path to JSON cursor/state file (defaults to `./state.json`)
- `PRIVATE_KEY` — EOA private key used to pay gas (only required when `DRY_RUN` is not set)
- `DRY_RUN=1` — simulate discovery and action planning without signing or sending transactions
- `TELEGRAM_CHAT_ID` + `$CREDENTIALS_DIRECTORY/telegram_token` — optional alert delivery on crash, repeated vault failure, or low ETH balance

See `launcher-keeper.service.example` and `launcher-keeper.timer` for a sample `systemd` deployment.

## Tests

```bash
python3 -m unittest test_keeper
```
