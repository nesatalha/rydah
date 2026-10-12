CREATE TABLE sessions (id TEXT PRIMARY KEY, write_hash TEXT NOT NULL, read_hash TEXT NOT NULL, source TEXT NOT NULL CHECK(source IN ('device','simulation')), expires_at INTEGER NOT NULL, ended INTEGER NOT NULL DEFAULT 0, seq INTEGER NOT NULL DEFAULT 0, lat REAL, lon REAL, accuracy_m REAL, observed_at INTEGER, received_at INTEGER);
CREATE INDEX sessions_expiry ON sessions(expires_at);
