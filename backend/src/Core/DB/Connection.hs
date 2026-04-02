module Core.DB.Connection
  ( mkDBEnv,
    runDB,
    withConn,
    ensureSchema,
  )
where

import Control.Monad.IO.Class (MonadIO (liftIO))
import Core.Config (Config (..))
import Core.Environment (DBEnv (..))
import qualified Data.ByteString.Char8 as BS
import Data.Pool (createPool, withResource)
import Database.Beam.Postgres (Pg, runBeamPostgres)
import Database.PostgreSQL.Simple (Connection, close, connectPostgreSQL, execute_)

mkDBEnv :: Config -> IO DBEnv
mkDBEnv cfg = do
  pool <- createPool (connectPostgreSQL (mkConnString cfg)) close 4 30 20
  let db = DBEnv pool
  ensureSchema db
  pure db

runDB :: DBEnv -> Pg a -> IO a
runDB db action = withConn db (\conn -> runBeamPostgres conn action)

withConn :: DBEnv -> (Connection -> IO a) -> IO a
withConn DBEnv {..} = withResource dbPool

mkConnString :: Config -> BS.ByteString
mkConnString Config {..} =
  case databaseUrl of
    Just url -> BS.pack url
    Nothing ->
      BS.pack $
        "host="
          <> postgresHost
          <> " port="
          <> show postgresPort
          <> " user="
          <> postgresUser
          <> " password="
          <> postgresPassword
          <> " dbname="
          <> postgresDatabase

ensureSchema :: DBEnv -> IO ()
ensureSchema db = withConn db $ \conn -> do
  -- ========================================================================
  -- deployment_config (NEW — replaces product_config + release_config)
  -- ========================================================================
  _ <-
    execute_
      conn
      "CREATE TABLE IF NOT EXISTS deployment_config (\
      \id serial primary key, \
      \app_group text not null, \
      \service text null, \
      \cluster text null, \
      \namespace text null, \
      \vs_name text null, \
      \product_acronym text null, \
      \product_type text null, \
      \sync_cluster text null, \
      \need_infra_approval boolean null, \
      \vs_locked_by text null, \
      \vs_lock_timestamp timestamptz null, \
      \service_host text null, \
      \service_type text null, \
      \rollout_strategy text null, \
      \revert_strategy text null, \
      \decision_config text null, \
      \slack_channel text null)"
  -- Unique constraint: (app_group, COALESCE(service, ''))
  _ <-
    execute_
      conn
      "DO $$ BEGIN \
      \IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'uq_deployment_config') THEN \
      \CREATE UNIQUE INDEX IF NOT EXISTS uq_deployment_config ON deployment_config (app_group, COALESCE(service, '')); \
      \END IF; END $$"
  -- Rename product -> app_group if needed (for existing DBs)
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='deployment_config' AND column_name='product') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='deployment_config' AND column_name='app_group') THEN ALTER TABLE deployment_config RENAME COLUMN product TO app_group; END IF; END $$"

  -- ========================================================================
  -- Migrate data from old tables (if they exist) into deployment_config
  -- ========================================================================
  -- Migrate product_config -> deployment_config (product-level rows, DISTINCT ON handles dups)
  _ <-
    execute_
      conn
      "DO $$ BEGIN \
      \IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='product_config') THEN \
      \INSERT INTO deployment_config (app_group, product_type, product_acronym, repo_name, release_branch, need_infra_approval, \
      \cluster, namespace, vs_name, sync_cluster) \
      \SELECT DISTINCT ON (p.product) p.product, p.product_type, p.product_acronym, p.repo_name, p.release_branch, p.need_infra_approval, \
      \COALESCE((p.target_config::json->>'cluster')::text, ''), \
      \COALESCE((p.target_config::json->>'namespace')::text, ''), \
      \COALESCE((p.target_config::json->>'vsName')::text, ''), \
      \(p.target_config::json->>'syncCluster')::text \
      \FROM product_config p \
      \WHERE NOT EXISTS (SELECT 1 FROM deployment_config d WHERE d.app_group = p.product AND d.service IS NULL) \
      \ORDER BY p.product, p.id; \
      \END IF; END $$"

  -- Migrate release_config -> deployment_config (service-level rows)
  _ <-
    execute_
      conn
      "DO $$ BEGIN \
      \IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name='release_config') THEN \
      \INSERT INTO deployment_config (app_group, service, service_type, emails, rollout_strategy, revert_strategy, \
      \decision_config, slack_channel, bitbucket_path, service_host, service_acronym) \
      \SELECT r.product, r.service, r.service_type, r.emails, r.rollout_strategy, r.revert_strategy, \
      \r.decision_config, r.slack_webhook_urls, r.bitbucket_path, \
      \COALESCE((r.target_config::json->>'serviceHost')::text, ''), \
      \r.service_acronym \
      \FROM release_config r \
      \WHERE NOT EXISTS (SELECT 1 FROM deployment_config d WHERE d.app_group = r.product AND d.service = r.service); \
      \END IF; END $$"

  -- ========================================================================
  -- Old tables (kept for backward compat — not used by new code)
  -- Old tables removed (migrated to deployment_config + release_tracker):
  -- product_config → deployment_config WHERE service IS NULL
  -- release_config → deployment_config WHERE service IS NOT NULL
  -- vs_edit_tracker → release_tracker WHERE category = 'VSEdit'

  -- ========================================================================
  -- server_config
  -- ========================================================================
  _ <- execute_ conn "CREATE TABLE IF NOT EXISTS server_config (id integer GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY, type varchar(255) not null default '', name varchar(255) not null, value text not null default '', last_updated timestamp without time zone not null default CURRENT_TIMESTAMP, enabled int not null default 1)"
  _ <- execute_ conn "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'server_config_name_unique') THEN CREATE UNIQUE INDEX IF NOT EXISTS server_config_name_product_unique ON server_config (name, COALESCE(product, '')); END IF; END $$"
  _ <- execute_ conn "ALTER TABLE server_config ADD COLUMN IF NOT EXISTS product text null"

  -- ========================================================================
  -- release_tracker
  -- ========================================================================
  _ <- execute_ conn "CREATE TABLE IF NOT EXISTS release_tracker (id text primary key, status text not null, description text null, new_version text not null, old_version text not null, app_group text not null, service text not null, mode text null, date_created timestamptz not null, last_updated timestamptz not null, start_time timestamptz null, end_time timestamptz null, release_manager text not null, approved_by text null, env text not null, priority int not null, rollout_strategy text null, rollout_history text null, schedule_time timestamptz null, release_tag text not null, change_log text null, release_context text null, info text null, sync_enabled text null, env_override_data text null, slack_thread_ts text null, is_approved boolean null, is_infra_approved boolean null, metadata text null, category text null, release_wf_status text null, global_id text null, new_service boolean null, cronjob_suspend boolean null, ab_hs_status text null default 'Uninitiated')"
  -- Migrate legacy column names if they exist
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='tracker_type') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='category') THEN ALTER TABLE release_tracker RENAME COLUMN tracker_type TO category; END IF; END $$"
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='workflow_status') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='release_wf_status') THEN ALTER TABLE release_tracker RENAME COLUMN workflow_status TO release_wf_status; END IF; END $$"
  _ <- execute_ conn "ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS approved_by text null"
  _ <- execute_ conn "ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS global_id text null"
  _ <- execute_ conn "ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS new_service boolean null"
  _ <- execute_ conn "ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS cronjob_suspend boolean null"
  _ <- execute_ conn "ALTER TABLE release_tracker ADD COLUMN IF NOT EXISTS ab_hs_status text null default 'Uninitiated'"
  -- Drop obsolete columns (events, is_art_recorder)
  _ <- execute_ conn "ALTER TABLE release_tracker DROP COLUMN IF EXISTS events"
  _ <- execute_ conn "ALTER TABLE release_tracker DROP COLUMN IF EXISTS is_art_recorder"
  -- Rename product -> app_group if needed
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='product') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='app_group') THEN ALTER TABLE release_tracker RENAME COLUMN product TO app_group; END IF; END $$"
  -- Rename udf1/udf2/udf3 -> sync_enabled/env_override_data/slack_thread_ts if needed
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='udf1') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='sync_enabled') THEN ALTER TABLE release_tracker RENAME COLUMN udf1 TO sync_enabled; END IF; END $$"
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='udf2') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='env_override_data') THEN ALTER TABLE release_tracker RENAME COLUMN udf2 TO env_override_data; END IF; END $$"
  _ <- execute_ conn "DO $$ BEGIN IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='udf3') AND NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='release_tracker' AND column_name='slack_thread_ts') THEN ALTER TABLE release_tracker RENAME COLUMN udf3 TO slack_thread_ts; END IF; END $$"

  -- ========================================================================
  -- release_events
  -- ========================================================================
  _ <- execute_ conn "CREATE TABLE IF NOT EXISTS release_events (re_id serial primary key, re_release_id text not null, re_category text not null, re_label text not null, re_payload jsonb not null, re_created_at timestamptz not null)"
  pure ()
