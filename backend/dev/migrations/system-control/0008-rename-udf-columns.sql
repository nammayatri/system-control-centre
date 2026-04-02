-- Rename generic udf columns to descriptive names
ALTER TABLE release_tracker RENAME COLUMN udf1 TO sync_enabled;
ALTER TABLE release_tracker RENAME COLUMN udf2 TO env_override_data;
ALTER TABLE release_tracker RENAME COLUMN udf3 TO slack_thread_ts;
