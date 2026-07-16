ALTER TABLE deployment_config ADD COLUMN IF NOT EXISTS hpa_min_replicas INT;
ALTER TABLE deployment_config ADD COLUMN IF NOT EXISTS hpa_max_replicas INT;
