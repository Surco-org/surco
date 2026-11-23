-- Price chart rollups (chirp.ts pointWrites / handleChirpHistory): the latest reading per 5-minute (g=300) and
-- per hour (g=3600) bucket, so 24h/7d/all read a few hundred rows instead of every 10s reading.
CREATE TABLE rollup (g INTEGER NOT NULL, b INTEGER NOT NULL, t INTEGER NOT NULL, pinto REAL NOT NULL, chirp REAL NOT NULL, PRIMARY KEY (g, b));
CREATE INDEX rollup_t ON rollup (g, t);
-- Backfill (SQLite: bare columns come from the MAX(t) row).
INSERT INTO rollup SELECT 300, t / 300, MAX(t), pinto, chirp FROM points GROUP BY t / 300;
INSERT INTO rollup SELECT 3600, t / 3600, MAX(t), pinto, chirp FROM points GROUP BY t / 3600;
