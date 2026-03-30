-- Add default timestamps + auto-update trigger for release_tracker

ALTER TABLE release_tracker ALTER COLUMN date_created SET DEFAULT now();
ALTER TABLE release_tracker ALTER COLUMN last_updated SET DEFAULT now();

-- Auto-update last_updated on every UPDATE
CREATE OR REPLACE FUNCTION update_last_updated()
RETURNS TRIGGER AS $$
BEGIN
  NEW.last_updated = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS release_tracker_update_timestamp ON release_tracker;
CREATE TRIGGER release_tracker_update_timestamp
  BEFORE UPDATE ON release_tracker
  FOR EACH ROW
  EXECUTE FUNCTION update_last_updated();
