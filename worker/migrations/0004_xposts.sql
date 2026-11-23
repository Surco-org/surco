-- Peg watch (src/worker/pegwatch.ts): one row per post to @chirpfi on X, written BEFORE the send, so a second cron
-- run can never post the same key twice. status: pending | dry | sent | failed. day = UTC YYYY-MM-DD (daily cap).
CREATE TABLE xposts (key TEXT PRIMARY KEY, t INTEGER NOT NULL, day TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL);
CREATE INDEX xposts_day ON xposts (day);
-- Peg watch's own state: {"block","log"} = last event considered, "side" = last peg side. {} = not seeded yet.
INSERT INTO live (k, t, body) VALUES ('xwatch', 0, '{}');
