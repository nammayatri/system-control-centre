module Main where

import Control.Concurrent.Async (concurrently_)
import Core.Config (appState, loadConfig)
import Core.DB.Connection (mkDBEnv)
import Core.Environment (AppState (..))
import Core.Server (serverLoop)
import Products.Autopilot.Runner (runnerLoop)

main :: IO ()
main = do
  cfg <- loadConfig
  db <- mkDBEnv cfg
  let st = AppState cfg db
  case appState cfg of
    "RUNNER" -> runnerLoop st
    -- In local/single-process mode keep server + worker together.
    "SERVER" -> concurrently_ (serverLoop st) (runnerLoop st)
    _ -> serverLoop st
