ALTER TABLE sessions ADD COLUMN speed_mps REAL CHECK(speed_mps IS NULL OR (speed_mps>=0 AND speed_mps<=100));
ALTER TABLE sessions ADD COLUMN speed_accuracy_mps REAL CHECK(speed_accuracy_mps IS NULL OR (speed_accuracy_mps>=0 AND speed_accuracy_mps<=100));
CREATE TRIGGER end_session_speed AFTER UPDATE OF ended ON sessions WHEN NEW.ended=1 AND (NEW.speed_mps IS NOT NULL OR NEW.speed_accuracy_mps IS NOT NULL) BEGIN UPDATE sessions SET speed_mps=NULL,speed_accuracy_mps=NULL WHERE id=NEW.id; END;
