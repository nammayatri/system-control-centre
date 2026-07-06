module Main where

import Control.Concurrent.Async (concurrently_)
import Control.Exception (bracket)
import Core.Config (Config (..), loadConfig)
import Core.DB.Connection (mkDBEnv)
import Core.Environment (AppState (..), runFlow)
import Core.Logging (LoggerConfig (..), loadLoggerConfigFromDhall, logInfoIO, prepareLoggerEnv, releaseLoggerEnv, setGlobalLoggerEnv)
import Core.Server (serverLoop)
import qualified Data.Text as T
import Products.Autopilot.Runner (runnerLoop, runnerPollLoop, runnerStartupRecovery)
import Products.Autopilot.SyncWatcher (syncWatcherPollLoop)

main :: IO ()
main = do
    cfg <- loadConfig
    db <- mkDBEnv cfg
    logCfg <- loadLoggerConfigFromDhall
    bracket (prepareLoggerEnv logCfg) releaseLoggerEnv $ \logEnv -> do
        setGlobalLoggerEnv logEnv
        let st = AppState cfg db logEnv
        logInfoIO logEnv $
            "Starting system-control-centre (mode="
                <> show' (appState cfg)
                <> ", port="
                <> show' (port cfg)
                <> ")"
                <> if logToFile logCfg
                    then ", logFile=" <> T.pack (logFilePath logCfg)
                    else ""
        case appState cfg of
            "RUNNER" -> runnerLoop st
            -- In local/single-process mode keep server + worker together.
            -- #35 FIX 1 — run startup recovery SYNCHRONOUSLY before the HTTP port
            -- is bound. If we forked the poll loop alongside the server like we
            -- used to, rollbackInProgressOnStartup could race with user-initiated
            -- HTTP writes and silently overwrite them. Startup recovery must
            -- complete with the server still closed to new connections.
            "SERVER" -> do
                runnerStartupRecovery st
                -- Store sync runs on-demand (UI ↻ refresh per app, cooldown-gated) — no
                -- background fork here. The review poll lives in the workflow runner
                -- below (ASC-only, no Play edits).
                concurrently_
                    (concurrently_ (serverLoop st) (runnerPollLoop st))
                    (runFlow st syncWatcherPollLoop)
            _ -> serverLoop st
  where
    show' :: (Show a) => a -> T.Text
    show' = T.pack . show
