-- Chirp page feed (src/worker/chirp.ts). `live` holds the one served body; `points` every reading.
CREATE TABLE live (k TEXT PRIMARY KEY, t INTEGER NOT NULL, body TEXT NOT NULL);
CREATE TABLE points (t INTEGER PRIMARY KEY, pinto REAL NOT NULL, chirp REAL NOT NULL);
INSERT INTO live (k, t, body) VALUES ('chirp', 0, '{}');
