ALTER TABLE sessions ADD COLUMN trail TEXT NOT NULL DEFAULT 'off' CHECK(trail IN ('off','15m','30m','session'));
CREATE TABLE session_points (session_id TEXT NOT NULL, seq INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, observed_at INTEGER NOT NULL, PRIMARY KEY(session_id, seq)) WITHOUT ROWID;
CREATE INDEX session_points_time ON session_points(session_id, observed_at);
CREATE TRIGGER end_session_points AFTER UPDATE OF ended ON sessions WHEN NEW.ended=1 BEGIN DELETE FROM session_points WHERE session_id=NEW.id; END;
CREATE TRIGGER delete_session_points AFTER DELETE ON sessions BEGIN DELETE FROM session_points WHERE session_id=OLD.id; END;
