module Core.Config where

import Control.Exception (IOException, try)
import Data.Text (Text, pack)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Bootstrap configuration loaded once at startup from env vars / .env file.
-- Runtime-tunable configs live in server_config DB table (see RuntimeConfig.hs).
--
-- == Layer policy note (task #24 V4)
--
-- A few fields here (prometheusUrl, abEngineUrl, abHsUrl, syncClusterUrl,
-- syncClusterApiKey, syncReleaseManager) are only read by Products.Autopilot today —
-- specifically by the decision engine and the cross-cluster sync. They live
-- in 'Core.Config' rather than 'Products.Autopilot.Config' because:
--
--  * The types are plain strings — there is no autopilot-specific *type*
--    imported into Core. So this is not a layer dependency edge, just a
--    record with fields that currently have a single consumer.
--  * Moving them to a product-specific bootstrap record would require
--    either making 'AppState' polymorphic in a product-extension slot or
--    introducing a Dynamic-like escape hatch — both of which are much more
--    intrusive than the leak they would fix.
--
-- The field *names* are intentionally generic (prometheusUrl, not
-- nammaApPrometheusUrl) so a second product consuming the same URL tomorrow
-- does not constitute a rename. If the field list grows or a second product
-- needs a *different* value for one of these fields, revisit — that is the
-- trigger to introduce a per-product bootstrap extension.
data Config = Config
  { -- Server
    appState :: String,
    port :: Int,
    envName :: Text,
    -- Kubernetes (infrastructure — any product talking to K8s uses these)
    kubectlBin :: FilePath,
    maxK8sRetries :: Int,
    -- Database
    postgresHost :: String,
    postgresPort :: Int,
    postgresUser :: String,
    postgresPassword :: String,
    postgresDatabase :: String,
    databaseUrl :: Maybe String,
    -- Cross-cluster sync endpoint (secrets). See V4 layer note above.
    syncClusterUrl :: String,
    syncClusterApiKey :: String,
    syncReleaseManager :: String,
    -- Decision engine URLs (metrics + A/B + health score). See V4 layer note.
    prometheusUrl :: String,
    abEngineUrl :: String,
    abHsUrl :: String,
    mcpBaseUrl :: Text,
    cloudProvider :: Text
  }
  deriving (Show)

loadConfig :: IO Config
loadConfig = do
  appState <- envOr "APP_STATE" "SERVER"
  port <- envInt "PORT" 8012
  -- All bootstrap env vars use the @SC_*@ prefix (System Control).
  envName <- pack <$> envOr "SC_ENV" "production"

  kubectlBin <- envOr "SC_KUBECTL_BIN" "kubectl"
  maxK8sRetries <- envInt "SC_MAX_K8S_RETRIES" 3

  postgresHost <- envOr "SC_POSTGRES_HOST" "127.0.0.1"
  postgresPort <- envInt "SC_POSTGRES_PORT" 5432
  postgresUser <- envOr "SC_POSTGRES_USER" "postgres"
  postgresPassword <- envOr "SC_POSTGRES_PASSWORD" "postgres"
  postgresDatabase <- envOr "SC_POSTGRES_DB" "system_control"
  databaseUrl <- lookupSetting "SC_DATABASE_URL"

  syncClusterUrl <- envOr "SYNC_CLUSTER_URL" ""
  syncClusterApiKey <- envOr "SYNC_CLUSTER_API_KEY" ""
  syncReleaseManager <- envOr "SYNC_RELEASE_MANAGER" "sync-service"

  prometheusUrl <- envOr "PROMETHEUS_URL" ""
  abEngineUrl <- envOr "AB_ENGINE_URL" ""
  abHsUrl <- envOr "AB_HS_URL" ""

  mcpBaseUrl <- pack <$> envOr "SC_MCP_BASE_URL" ""

  cloudProvider <- pack <$> envOr "SC_CLOUD_PROVIDER" "GCP"

  pure Config {..}

-- ── Env helpers ────────────────────────────────────────────────────

envOr :: String -> String -> IO String
envOr key fallback = do
  v <- lookupSetting key
  pure (maybe fallback id v)

envInt :: String -> Int -> IO Int
envInt key fallback = do
  v <- lookupSetting key
  pure $ maybe fallback id (v >>= readMaybe)

lookupSetting :: String -> IO (Maybe String)
lookupSetting key = do
  fromEnv <- lookupEnv key
  case fromEnv of
    Just v -> pure (Just v)
    Nothing -> do
      kvs <- loadDotEnv
      pure (lookup key kvs)

loadDotEnv :: IO [(String, String)]
loadDotEnv = do
  exists <- doesFileExist ".env"
  if not exists
    then pure []
    else do
      contentE <- try (readFile ".env") :: IO (Either IOException String)
      case contentE of
        Left _ -> pure []
        Right content -> pure (mapMaybeKV (lines content))
  where
    mapMaybeKV = foldr (\line acc -> maybe acc (: acc) (parseLine line)) []
    parseLine raw =
      let line = trim raw
       in if null line || "#" `prefixOf` line
            then Nothing
            else
              let (k, rest) = break (== '=') line
               in case rest of
                    [] -> Nothing
                    (_ : v) -> Just (trim k, trim v)
    trim = T.unpack . T.strip . T.pack
    prefixOf p s = take (length p) s == p
