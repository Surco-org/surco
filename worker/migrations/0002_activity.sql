-- Chirp app page (/chirp): every book event and every Chirp holder, indexed by src/worker/chirp-index.ts.
-- Amounts are raw uint256 decimal strings (they do not fit SQLite integers); holders.sort = bal / 1e18, for ORDER BY only.
CREATE TABLE events (block INTEGER NOT NULL, log INTEGER NOT NULL, tx TEXT NOT NULL, t INTEGER NOT NULL,
  kind TEXT NOT NULL, who TEXT, pinto TEXT NOT NULL, chirp TEXT NOT NULL, extra TEXT, PRIMARY KEY (block, log));
CREATE INDEX events_t ON events (t);
CREATE TABLE holders (addr TEXT PRIMARY KEY, bal TEXT NOT NULL, sort REAL NOT NULL);
CREATE INDEX holders_sort ON holders (sort DESC);
-- One row per applied log range. A second indexer that read the same cursor (a refresh that outlived the 10s claim)
-- hits this primary key, and D1 rolls its whole batch back, so holder balances are never applied twice.
CREATE TABLE ranges (from_block INTEGER PRIMARY KEY, to_block INTEGER NOT NULL);
-- Indexing starts at launch; the worker catches up from here in 200k-block steps. body = {"readMs": last log read}.
INSERT INTO live (k, t, body) VALUES ('cursor', 58889182, '{}');
