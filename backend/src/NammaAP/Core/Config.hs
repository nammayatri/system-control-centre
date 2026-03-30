module NammaAP.Core.Config where

import Control.Exception (IOException, try)
import Data.List (break)
import Data.Text (Text, pack)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Bootstrap configuration loaded once at startup from env vars / .env file.
-- Runtime-tunable configs live in server_config DB table (see RuntimeConfig.hs).
data Config = Config
  { -- Server
    appState :: String
  , port :: Int
  , envName :: Text
  , maintenanceMode :: Bool

    -- Kubernetes
  , kubectlBin :: FilePath
  , defaultNamespace :: Text
  , maxK8sRetries :: Int

    -- Runner
  , runnerPollSeconds :: Int
  , isMultiReleasePerProduct :: Bool

    -- Deployment defaults (overridable via server_config)
  , defaultCooloffSeconds :: Int
  , deleteOldDeploymentOnComplete :: Bool
  , oldDeploymentCleanupDelaySeconds :: Int

    -- AB decision defaults (overridable via server_config)
  , abDecisionEnabled :: Bool
  , abAbortOnFailure :: Bool
  , abCollectMetricsDelaySeconds :: Int
  , abHost :: Maybe String
  , abTrackerCreatePath :: String
  , abDeciderPathPrefix :: String
  , abApiKey :: Maybe String
  , abRequestTimeoutSeconds :: Int

    -- AB HS defaults (overridable via server_config)
  , abHsDecisionEnabled :: Bool
  , abHsHost :: Maybe String
  , abHsDecisionPathPrefix :: String

    -- HPA defaults (overridable via server_config)
  , hpaEnabledProducts :: [Text]
  , hpaMaxReplicasBuffer :: Int

    -- Database
  , postgresHost :: String
  , postgresPort :: Int
  , postgresUser :: String
  , postgresPassword :: String
  , postgresDatabase :: String
  , databaseUrl :: Maybe String

    -- Notification
  , approverEmails :: [Text]
  , alertWebhookCommand :: Maybe String

  , syncClusterUrl :: String
  , syncClusterBaseAuth :: String
  } deriving (Show)

loadConfig :: IO Config
loadConfig = do
  appState <- envOr "APP_STATE" "SERVER"
  port <- envInt "PORT" 8012
  envName <- pack <$> envOr "NammaAP_ENV" "production"
  maintenanceMode <- envBool "NammaAP_MAINTENANCE_MODE" False

  kubectlBin <- envOr "NammaAP_KUBECTL_BIN" "kubectl"
  defaultNamespace <- pack <$> envOr "NammaAP_DEFAULT_NAMESPACE" "default"
  maxK8sRetries <- envInt "NammaAP_MAX_K8S_RETRIES" 3

  runnerPollSeconds <- envInt "NammaAP_RUNNER_POLL_SECONDS" 20
  isMultiReleasePerProduct <- envBool "NammaAP_IS_MULTI_RELEASE_PER_PRODUCT" False

  defaultCooloffSeconds <- envInt "NammaAP_STAGGER_COOLOFF_SECONDS" 120
  deleteOldDeploymentOnComplete <- envBool "NammaAP_DELETE_OLD_DEPLOYMENT_ON_COMPLETE" True
  oldDeploymentCleanupDelaySeconds <- envInt "NammaAP_OLD_DEPLOYMENT_CLEANUP_DELAY_SECONDS" 0

  abDecisionEnabled <- envBool "NammaAP_AB_DECISION_ENABLED" False
  abAbortOnFailure <- envBool "NammaAP_ABORT_ON_AB_FAILURE" True
  abCollectMetricsDelaySeconds <- envInt "NammaAP_AB_COLLECT_METRICS_DELAY_SECONDS" 30
  abHost <- lookupSetting "NammaAP_AB_HOST"
  abTrackerCreatePath <- envOr "NammaAP_AB_TRACKER_CREATE_PATH" "/tracker/"
  abDeciderPathPrefix <- envOr "NammaAP_AB_DECIDER_PATH_PREFIX" "/decider/"
  abApiKey <- lookupSetting "NammaAP_AB_API_KEY"
  abRequestTimeoutSeconds <- envInt "NammaAP_AB_REQUEST_TIMEOUT_SECONDS" 10

  abHsDecisionEnabled <- envBool "NammaAP_AB_HS_DECISION_ENABLED" False
  abHsHost <- lookupSetting "NammaAP_AB_HS_HOST"
  abHsDecisionPathPrefix <- envOr "NammaAP_AB_HS_DECISION_PATH_PREFIX" "/get/ab/decision/"

  hpaEnabledProducts <- splitCsv . pack <$> envOr "NammaAP_SCALING_WITH_HPA_ENABLED" ""
  hpaMaxReplicasBuffer <- envInt "NammaAP_HPA_MAX_REPLICAS_BUFFER" 1

  postgresHost <- envOr "NammaAP_POSTGRES_HOST" "127.0.0.1"
  postgresPort <- envInt "NammaAP_POSTGRES_PORT" 5432
  postgresUser <- envOr "NammaAP_POSTGRES_USER" "postgres"
  postgresPassword <- envOr "NammaAP_POSTGRES_PASSWORD" "postgres"
  postgresDatabase <- envOr "NammaAP_POSTGRES_DB" "namma_ap"
  databaseUrl <- lookupSetting "NammaAP_DATABASE_URL"

  approverEmails <- splitCsv . pack <$> envOr "NammaAP_APPROVER_EMAILS" ""
  alertWebhookCommand <- lookupSetting "NammaAP_ALERT_WEBHOOK_CMD"

  syncClusterUrl <- envOr "SYNC_CLUSTER_URL" ""
  syncClusterBaseAuth <- envOr "SYNC_CLUSTER_BASE_AUTH" ""

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

envBool :: String -> Bool -> IO Bool
envBool key fallback = do
  v <- lookupSetting key
  pure $ maybe fallback id (v >>= readMaybe)

splitCsv :: Text -> [Text]
splitCsv = filter (not . T.null) . T.splitOn ","

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
