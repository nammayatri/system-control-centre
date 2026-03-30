module Core.Config where

import Control.Exception (IOException, try)
import Data.List (break)
import Data.Text (Text, pack)
import qualified Data.Text as T
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

{- | Bootstrap configuration loaded once at startup from env vars / .env file.
Runtime-tunable configs live in server_config DB table (see RuntimeConfig.hs).
-}
data Config = Config
    { -- Server
      appState :: String
    , port :: Int
    , envName :: Text
    , -- Kubernetes
      kubectlBin :: FilePath
    , defaultNamespace :: Text
    , maxK8sRetries :: Int
    , -- Database
      postgresHost :: String
    , postgresPort :: Int
    , postgresUser :: String
    , postgresPassword :: String
    , postgresDatabase :: String
    , databaseUrl :: Maybe String
    , -- Cluster sync (secrets)
      syncClusterUrl :: String
    , syncClusterBaseAuth :: String
    }
    deriving (Show)

loadConfig :: IO Config
loadConfig = do
    appState <- envOr "APP_STATE" "SERVER"
    port <- envInt "PORT" 8012
    envName <- pack <$> envOr "NammaAP_ENV" "production"

    kubectlBin <- envOr "NammaAP_KUBECTL_BIN" "kubectl"
    defaultNamespace <- pack <$> envOr "NammaAP_DEFAULT_NAMESPACE" "default"
    maxK8sRetries <- envInt "NammaAP_MAX_K8S_RETRIES" 3

    postgresHost <- envOr "NammaAP_POSTGRES_HOST" "127.0.0.1"
    postgresPort <- envInt "NammaAP_POSTGRES_PORT" 5432
    postgresUser <- envOr "NammaAP_POSTGRES_USER" "postgres"
    postgresPassword <- envOr "NammaAP_POSTGRES_PASSWORD" "postgres"
    postgresDatabase <- envOr "NammaAP_POSTGRES_DB" "namma_ap"
    databaseUrl <- lookupSetting "NammaAP_DATABASE_URL"

    syncClusterUrl <- envOr "SYNC_CLUSTER_URL" ""
    syncClusterBaseAuth <- envOr "SYNC_CLUSTER_BASE_AUTH" ""

    pure Config{..}

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
