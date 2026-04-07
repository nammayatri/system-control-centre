{- | File + console logging via fast-logger, inspired by NammaYatri's IOLogging.

Usage in IO code:

@
logInfoIO  logEnv "Server started on port 8012"
logErrorIO logEnv ("Failed to connect: " <> errMsg)
@

Usage in Flow (reads LoggerEnv from AppState):

@
logInfo  "Processing release"
logError ("K8s call failed: " <> err)
@
-}
module Core.Logging (
    LogLevel (..),
    LoggerConfig (..),
    LoggerEnv (..),
    prepareLoggerEnv,
    releaseLoggerEnv,
    loadLoggerConfigFromDhall,
    logOutput,
    -- IO-level helpers (require LoggerEnv)
    logInfoIO,
    logErrorIO,
    logWarningIO,
    logDebugIO,
    -- Global helpers (use the process-wide LoggerEnv set by Main)
    setGlobalLoggerEnv,
    logInfoG,
    logErrorG,
    logWarningG,
    logDebugG,
)
where

import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON (..), withObject, withText, (.:))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import GHC.Generics (Generic)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger
import System.Process (readProcess)

-- ── Types ─────────────────────────────────────────────────────────

data LogLevel = DEBUG | INFO | WARNING | ERROR
    deriving (Show, Read, Eq, Ord)

instance FromJSON LogLevel where
    parseJSON = withText "LogLevel" $ \t -> case T.toUpper t of
        "DEBUG" -> pure DEBUG
        "INFO" -> pure INFO
        "WARNING" -> pure WARNING
        "ERROR" -> pure ERROR
        _ -> fail $ "Unknown LogLevel: " <> T.unpack t

data LoggerConfig = LoggerConfig
    { logLevel :: LogLevel
    , logToFile :: Bool
    , logFilePath :: FilePath
    , logToConsole :: Bool
    }
    deriving (Generic)

instance FromJSON LoggerConfig

data Logger = Logger
    { printLogFunc :: FastLogger
    , cleanUpFunc :: IO ()
    }

data LoggerEnv = LoggerEnv
    { level :: LogLevel
    , fileLogger :: Maybe Logger
    , consoleLogger :: Maybe Logger
    }

-- ── Dhall loader ──────────────────────────────────────────────────

{- | Load LoggerConfig from the dhall config file.
Uses @dhall-to-json@ CLI (available in the nix shell) to convert dhall
to JSON, then extracts the @loggerCfg@ block with aeson.

Config path resolution (mirrors NammaYatri convention):
  1. @SC_CONFIG_PATH@ env var
  2. Default: @./dhall-configs/system-control.dhall@
-}
loadLoggerConfigFromDhall :: IO LoggerConfig
loadLoggerConfigFromDhall = do
    cfgPath <- maybe defaultPath id <$> lookupEnv "SC_CONFIG_PATH"
    jsonStr <- readProcess "dhall-to-json" ["--file", cfgPath] ""
    let jsonBS = LBS.fromStrict $ TE.encodeUtf8 $ T.pack jsonStr
    case A.eitherDecode jsonBS of
        Left err -> fail $ "Failed to parse dhall config: " <> err
        Right wrapper -> pure (loggerCfg (wrapper :: DhallWrapper))
  where
    defaultPath = "./dhall-configs/system-control.dhall"

-- | Minimal wrapper to extract just the loggerCfg block from the full dhall JSON.
newtype DhallWrapper = DhallWrapper {loggerCfg :: LoggerConfig}

instance FromJSON DhallWrapper where
    parseJSON = withObject "DhallConfig" $ \o ->
        DhallWrapper <$> o .: "loggerCfg"

-- ── Lifecycle ─────────────────────────────────────────────────────

prepareLoggerEnv :: LoggerConfig -> IO LoggerEnv
prepareLoggerEnv cfg = do
    fileLogger <-
        if logToFile cfg
            then Just <$> mkLogger (LogFileNoRotate (logFilePath cfg) defaultBufSize)
            else pure Nothing
    consoleLogger <-
        if logToConsole cfg
            then Just <$> mkLogger (LogStdout defaultBufSize)
            else pure Nothing
    pure
        LoggerEnv
            { level = logLevel cfg
            , fileLogger = fileLogger
            , consoleLogger = consoleLogger
            }
  where
    mkLogger logType = do
        (pf, cu) <- newFastLogger logType
        pure Logger{printLogFunc = pf, cleanUpFunc = cu}

releaseLoggerEnv :: LoggerEnv -> IO ()
releaseLoggerEnv env = do
    maybe (pure ()) cleanUpFunc (fileLogger env)
    maybe (pure ()) cleanUpFunc (consoleLogger env)

-- ── Log output ────────────────────────────────────────────────────

logOutput :: (MonadIO m) => LoggerEnv -> LogLevel -> Text -> m ()
logOutput env lvl msg = when (lvl >= level env) $
    liftIO $ do
        now <- getCurrentTime
        let formatted = formatLogLine now lvl msg
        maybe (pure ()) (\l -> printLogFunc l formatted) (fileLogger env)
        maybe (pure ()) (\l -> printLogFunc l formatted) (consoleLogger env)

formatLogLine :: UTCTime -> LogLevel -> Text -> LogStr
formatLogLine now lvl msg =
    toLogStr $
        TE.encodeUtf8 $
            timestamp <> " [" <> T.pack (show lvl) <> "] " <> msg <> "\n"
  where
    timestamp = T.pack $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" now

-- ── IO-level convenience ──────────────────────────────────────────

logInfoIO :: LoggerEnv -> Text -> IO ()
logInfoIO env = logOutput env INFO

logErrorIO :: LoggerEnv -> Text -> IO ()
logErrorIO env = logOutput env ERROR

logWarningIO :: LoggerEnv -> Text -> IO ()
logWarningIO env = logOutput env WARNING

logDebugIO :: LoggerEnv -> Text -> IO ()
logDebugIO env = logOutput env DEBUG

-- ── Global logger ─────────────────────────────────────────────────
--
-- A process-wide LoggerEnv set once at startup by Main. Used by call
-- sites that don't have a LoggerEnv in scope (e.g. plain IO helpers
-- buried inside K8s/Notifications/DecisionEngine modules) so their
-- output still lands in the structured log file rather than only on
-- stdout via 'putStrLn'.
--
-- Until 'setGlobalLoggerEnv' is called, the helpers fall back to
-- 'putStrLn' so logs from very early startup are not silently dropped.

{-# NOINLINE globalLoggerRef #-}
globalLoggerRef :: IORef (Maybe LoggerEnv)
globalLoggerRef = unsafePerformIO (newIORef Nothing)

-- | Install the process-wide LoggerEnv. Call once from Main after
-- 'prepareLoggerEnv'.
setGlobalLoggerEnv :: LoggerEnv -> IO ()
setGlobalLoggerEnv env = writeIORef globalLoggerRef (Just env)

logG :: LogLevel -> Text -> IO ()
logG lvl msg = do
    mEnv <- readIORef globalLoggerRef
    case mEnv of
        Just env -> logOutput env lvl msg
        Nothing -> putStrLn ("[" <> show lvl <> "] " <> T.unpack msg)

logInfoG :: Text -> IO ()
logInfoG = logG INFO

logErrorG :: Text -> IO ()
logErrorG = logG ERROR

logWarningG :: Text -> IO ()
logWarningG = logG WARNING

logDebugG :: Text -> IO ()
logDebugG = logG DEBUG
