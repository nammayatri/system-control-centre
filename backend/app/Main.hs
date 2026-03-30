module Main where

import Control.Concurrent.Async (concurrently_)
import NammaAP.Core.Config (appState, loadConfig)
import NammaAP.Core.DB.Connection (mkDBEnv)
import NammaAP.Products.Autopilot.Runner (runnerLoop)
import NammaAP.Core.Server (serverLoop)
import NammaAP.Core.Environment (AppState (..))

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