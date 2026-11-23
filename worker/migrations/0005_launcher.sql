-- Pinto Launcher site indexer tables (surcofi.com /coins, /coin, /creator).
-- Every table is scoped by `factory` so switching from the TEST factory to the real factory starts cleanly.
-- Raw uint256 amounts are stored as decimal strings; float/real columns are for ORDER BY / charting only.

CREATE TABLE launcher_state (
  factory TEXT PRIMARY KEY,
  cursor_block INTEGER NOT NULL,
  last_refresh_ms INTEGER NOT NULL DEFAULT 0,
  weth_usd REAL NOT NULL DEFAULT 0,
  pinto_usd REAL NOT NULL DEFAULT 0
);

CREATE TABLE launcher_coins (
  factory TEXT NOT NULL,
  coin TEXT NOT NULL,
  vault TEXT NOT NULL,
  pool_id TEXT NOT NULL,
  launcher TEXT NOT NULL,
  creator_payout TEXT NOT NULL,
  mode INTEGER NOT NULL,
  fee_bps INTEGER NOT NULL,
  creator_bps INTEGER NOT NULL,
  name TEXT NOT NULL DEFAULT '',
  symbol TEXT NOT NULL DEFAULT '',
  image_uri TEXT NOT NULL DEFAULT '',
  coin_is_token0 INTEGER NOT NULL DEFAULT 0,
  launched_block INTEGER NOT NULL,
  launched_at INTEGER NOT NULL,
  first_buy_weth TEXT NOT NULL DEFAULT '0',
  hidden INTEGER NOT NULL DEFAULT 0,
  hidden_reason TEXT,
  price_weth REAL NOT NULL DEFAULT 0,
  silo_pinto TEXT NOT NULL DEFAULT '0',
  silo_pinto_num REAL NOT NULL DEFAULT 0,
  yield_pinto TEXT NOT NULL DEFAULT '0',
  pending_weth TEXT NOT NULL DEFAULT '0',
  unsplit_weth TEXT NOT NULL DEFAULT '0',
  total_supply TEXT NOT NULL DEFAULT '1000000000000000000000000000',
  vol_24h_weth REAL NOT NULL DEFAULT 0,
  vol_all_weth REAL NOT NULL DEFAULT 0,
  trades_24h INTEGER NOT NULL DEFAULT 0,
  trades_all INTEGER NOT NULL DEFAULT 0,
  last_swap_at INTEGER NOT NULL DEFAULT 0,
  creator_paid_weth TEXT NOT NULL DEFAULT '0',
  PRIMARY KEY (factory, coin)
);

CREATE INDEX launcher_coins_vault ON launcher_coins (factory, vault);
CREATE INDEX launcher_coins_pool ON launcher_coins (factory, pool_id);
CREATE INDEX launcher_coins_creator ON launcher_coins (factory, creator_payout);
CREATE INDEX launcher_coins_launcher ON launcher_coins (factory, launcher);
CREATE INDEX launcher_coins_sort ON launcher_coins (factory, hidden, vol_24h_weth DESC, last_swap_at DESC);

CREATE TABLE launcher_swaps (
  factory TEXT NOT NULL,
  pool_id TEXT NOT NULL,
  block INTEGER NOT NULL,
  log_idx INTEGER NOT NULL,
  tx TEXT NOT NULL,
  t INTEGER NOT NULL,
  is_buy INTEGER NOT NULL,
  weth_wei TEXT NOT NULL,
  coin_wei TEXT NOT NULL,
  weth_num REAL NOT NULL,
  sqrt_price_x96 TEXT NOT NULL,
  tick INTEGER NOT NULL,
  price_weth REAL NOT NULL,
  PRIMARY KEY (factory, pool_id, block, log_idx)
);

CREATE INDEX launcher_swaps_t ON launcher_swaps (factory, pool_id, t DESC);
CREATE INDEX launcher_swaps_time ON launcher_swaps (factory, t DESC);

CREATE TABLE launcher_vault_events (
  factory TEXT NOT NULL,
  vault TEXT NOT NULL,
  block INTEGER NOT NULL,
  log_idx INTEGER NOT NULL,
  tx TEXT NOT NULL,
  t INTEGER NOT NULL,
  kind TEXT NOT NULL,
  actor TEXT,
  amount_a TEXT NOT NULL DEFAULT '0',
  amount_b TEXT NOT NULL DEFAULT '0',
  tip TEXT NOT NULL DEFAULT '0',
  PRIMARY KEY (factory, vault, block, log_idx)
);

CREATE INDEX launcher_vault_events_t ON launcher_vault_events (factory, vault, t DESC);

-- Atomic idempotency guard: if two refresh callers read the same cursor, the second hits this PK and rolls back.
CREATE TABLE launcher_ranges (
  factory TEXT NOT NULL,
  from_block INTEGER NOT NULL,
  to_block INTEGER NOT NULL,
  PRIMARY KEY (factory, from_block)
);
