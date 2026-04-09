-- | File + console logging via fast-logger.
module Core.Logging (
    LogLevel (..),
    LoggerConfig (..),
    LoggerEnv (..),
    prepareLoggerEnv,
    releaseLoggerEnv,
    loadLoggerConfigFromDhall,
    logOutput,
    logInfoIO,
    logErrorIO,
    logWarningIO,
    logDebugIO,
    setGlobalLoggerEnv,
    logInfoG,
    logErrorG,
    logWarningG,
    logDebugG,
    withLogTag,
)
where

import qualified Control.Concurrent as Conc
import Control.Exception (bracket_)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON (..), withObject, withText, (.:))
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import GHC.Generics (Generic)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Log.FastLogger
import System.Process (readProcess)

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

{- | Load LoggerConfig from dhall (via @dhall-to-json@). Path from
@SC_CONFIG_PATH@ env var or @./dhall-configs/system-control.dhall@.
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

newtype DhallWrapper = DhallWrapper {loggerCfg :: LoggerConfig}

instance FromJSON DhallWrapper where
    parseJSON = withObject "DhallConfig" $ \o ->
        DhallWrapper <$> o .: "loggerCfg"

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

logInfoIO :: LoggerEnv -> Text -> IO ()
logInfoIO env = logOutput env INFO

logErrorIO :: LoggerEnv -> Text -> IO ()
logErrorIO env = logOutput env ERROR

logWarningIO :: LoggerEnv -> Text -> IO ()
logWarningIO env = logOutput env WARNING

logDebugIO :: LoggerEnv -> Text -> IO ()
logDebugIO env = logOutput env DEBUG

-- Process-wide LoggerEnv set once at startup for call sites without a
-- LoggerEnv in scope. Falls back to 'putStrLn' until installed so
-- early-startup logs are not silently dropped.

{-# NOINLINE globalLoggerRef #-}
globalLoggerRef :: IORef (Maybe LoggerEnv)
globalLoggerRef = unsafePerformIO (newIORef Nothing)

-- | Per-thread tag stack, cleaned up on exit by 'withLogTag''s 'bracket_'.
{-# NOINLINE tagStackRef #-}
tagStackRef :: IORef (Map.Map Conc.ThreadId [Text])
tagStackRef = unsafePerformIO (newIORef Map.empty)

-- | Install the process-wide LoggerEnv. Call once from Main.
setGlobalLoggerEnv :: LoggerEnv -> IO ()
setGlobalLoggerEnv env = writeIORef globalLoggerRef (Just env)

{- | Run an action with a tag pushed onto the current thread's log
stack. Automatically popped on exit (even on exceptions).
-}
withLogTag :: (MonadIO m) => Text -> IO a -> m a
withLogTag tag action = liftIO $ do
    tid <- Conc.myThreadId
    bracket_ (push tid) (pop tid) action
  where
    push tid = atomicModifyIORef' tagStackRef $ \m ->
        (Map.insertWith (++) tid [tag] m, ())
    pop tid = atomicModifyIORef' tagStackRef $ \m ->
        case Map.lookup tid m of
            Just (_ : rest) | not (null rest) -> (Map.insert tid rest m, ())
            _ -> (Map.delete tid m, ())

-- | Format the current thread's tag stack as @"[tag1][tag2] "@.
currentTagPrefix :: IO Text
currentTagPrefix = do
    tid <- Conc.myThreadId
    m <- readIORef tagStackRef
    case Map.lookup tid m of
        Nothing -> pure ""
        Just [] -> pure ""
        Just tags -> pure (T.concat (map (\t -> "[" <> t <> "]") (reverse tags)) <> " ")

logG :: LogLevel -> Text -> IO ()
logG lvl msg = do
    prefix <- currentTagPrefix
    let full = prefix <> msg
    mEnv <- readIORef globalLoggerRef
    case mEnv of
        Just env -> logOutput env lvl full
        Nothing -> putStrLn ("[" <> show lvl <> "] " <> T.unpack full)

logInfoG :: (MonadIO m) => Text -> m ()
logInfoG = liftIO . logG INFO

logErrorG :: (MonadIO m) => Text -> m ()
logErrorG = liftIO . logG ERROR

logWarningG :: (MonadIO m) => Text -> m ()
logWarningG = liftIO . logG WARNING

logDebugG :: (MonadIO m) => Text -> m ()
logDebugG = liftIO . logG DEBUG
