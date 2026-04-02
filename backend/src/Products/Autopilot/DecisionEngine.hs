{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Decision engine for autopilot releases.
--
-- Provides three decision functions, all gated behind server_config flags:
--
-- 1. Prometheus query checks — reads decision_config from deployment_config,
--  queries Prometheus HTTP API, checks thresholds.
-- 2. AB Decision Engine — calls external AB testing service for Continue/Wait/Abort.
-- 3. Health Score (HS) Decision — calls external health score service,
--  supports pre-monitoring (during rollout) and post-monitoring (after 100%).
--
-- All functions fail OPEN: on any error (HTTP failure, parse failure, missing config),
-- they return Continue/PromOK so releases are never blocked by monitoring infrastructure failures.
module Products.Autopilot.DecisionEngine
  ( -- * Decision Functions
    checkPromQueries,
    getABDecision,
    getHSDecision,
    getCombinedDecision,

    -- * Types
    DecisionResult (..),
    PromCheckResult (..),
  )
where

import Control.Exception (SomeException, try)
import Core.Config (Config (..))
import Core.Environment (DBEnv)
import Data.Aeson (Value (..), eitherDecode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Products.Autopilot.Types.Release (Decision (..), ReleaseTracker (..))
import Shared.Config.Runtime (getConfigBoolForProduct)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Prelude

-- ============================================================================
-- Types
-- ============================================================================

data DecisionResult = DecisionResult
  { -- | Continue, Wait, or Abort
    drDecision :: Decision,
    -- | Human-readable reason
    drReason :: Maybe Text,
    -- | "PROMETHEUS" | "AB_ENGINE" | "HEALTH_SCORE"
    drSource :: Text
  }
  deriving (Show)

data PromCheckResult
  = PromOK
  | PromWarn Text
  | PromAbort Text
  deriving (Show)

-- ============================================================================
-- Prometheus Query Checks
-- ============================================================================

-- | Run Prometheus query checks against the service's decision_config.
--
-- Reads the decision_config JSON from deployment_config, parses query configs,
-- and for each query calls the Prometheus HTTP API to check thresholds.
--
-- Returns PromOK if:
-- - prom_checks_enabled is false (gate)
-- - No decision_config provided
-- - No PROMETHEUS_URL configured
-- - Config is invalid JSON (fail open)
-- - All queries pass thresholds
--
-- Returns PromAbort if any metric exceeds abort_threshold.
-- Returns PromWarn if any metric exceeds warn_threshold (but not abort).
checkPromQueries :: DBEnv -> Config -> ReleaseTracker -> Maybe Text -> IO PromCheckResult
checkPromQueries db cfg tracker mDecisionConfig = do
  enabled <- getConfigBoolForProduct db "prom_checks_enabled" (Just (appGroup tracker)) False
  if not enabled
    then pure PromOK
    else case mDecisionConfig of
      Nothing -> pure PromOK
      Just configJson -> do
        let promUrl = prometheusUrl cfg
        if null promUrl
          then pure PromOK -- No Prometheus URL configured
          else executePromChecks promUrl configJson tracker

-- | Internal: Execute Prometheus checks against all configs in the decision_config JSON.
--
-- The decision_config is a JSON array of config objects, each containing queries
-- and thresholds. We check each config entry and return the worst result
-- (Abort > Warn > OK).
executePromChecks :: String -> Text -> ReleaseTracker -> IO PromCheckResult
executePromChecks promUrl configJson tracker =
  case eitherDecode (LBS.fromStrict (TE.encodeUtf8 configJson)) of
    Left _ -> do
      putStrLn "[DECISION] Failed to parse decision_config JSON, skipping prom checks"
      pure PromOK -- Invalid config, skip (fail open)
    Right configs -> checkAllConfigs promUrl configs tracker

-- | Check all config entries, returning the worst result.
-- Abort > Warn > OK.
checkAllConfigs :: String -> [Value] -> ReleaseTracker -> IO PromCheckResult
checkAllConfigs _ [] _ = pure PromOK
checkAllConfigs url (c : rest) rt = do
  result <- checkSingleConfig url c rt
  case result of
    PromAbort reason -> pure (PromAbort reason)
    PromWarn reason -> do
      restResult <- checkAllConfigs url rest rt
      case restResult of
        PromAbort r -> pure (PromAbort r)
        _ -> pure (PromWarn reason)
    PromOK -> checkAllConfigs url rest rt

-- | Check a single config entry against Prometheus.
--
-- Expected config structure:
-- {
-- "cluster": "...",
-- "config": {
--   "experiments": [{
--     "queries": [{"query": "...", "name": "..."}],
--     "thresholds": {"abort": 100, "warn": 50}
--   }]
-- }
-- }
--
-- Uses try/catch for HTTP failures — returns PromOK on failure (fail open).
checkSingleConfig :: String -> Value -> ReleaseTracker -> IO PromCheckResult
checkSingleConfig url config _rt = do
  result <- try (checkConfigQueries url config) :: IO (Either SomeException PromCheckResult)
  case result of
    Right r -> pure r
    Left e -> do
      putStrLn $ "[DECISION] Prometheus check failed: " <> show e
      pure PromOK -- Fail open

-- | Extract queries from a config entry and check each one.
--
-- Navigates: config.config.experiments[].queries[] and config.config.experiments[].thresholds
checkConfigQueries :: String -> Value -> IO PromCheckResult
checkConfigQueries promUrl (Object configObj) = do
  case KM.lookup (K.fromText "config") configObj of
    Just (Object innerConfig) ->
      case KM.lookup (K.fromText "experiments") innerConfig of
        Just (Array experiments) ->
          checkExperiments promUrl (foldr (:) [] experiments)
        _ -> pure PromOK
    _ -> pure PromOK
checkConfigQueries _ _ = pure PromOK

-- | Check all experiments in a config entry.
checkExperiments :: String -> [Value] -> IO PromCheckResult
checkExperiments _ [] = pure PromOK
checkExperiments promUrl (exp' : rest) = do
  result <- checkExperiment promUrl exp'
  case result of
    PromAbort reason -> pure (PromAbort reason)
    PromWarn reason -> do
      restResult <- checkExperiments promUrl rest
      case restResult of
        PromAbort r -> pure (PromAbort r)
        _ -> pure (PromWarn reason)
    PromOK -> checkExperiments promUrl rest

-- | Check a single experiment: extract queries and thresholds, query Prometheus.
checkExperiment :: String -> Value -> IO PromCheckResult
checkExperiment promUrl (Object expObj) = do
  let queries = case KM.lookup (K.fromText "queries") expObj of
        Just (Array qs) -> foldr (:) [] qs
        _ -> []
      abortThreshold = extractThreshold "abort" expObj
      warnThreshold = extractThreshold "warn" expObj
  checkQueryList promUrl queries abortThreshold warnThreshold
checkExperiment _ _ = pure PromOK

-- | Extract a numeric threshold from the thresholds object.
extractThreshold :: Text -> KM.KeyMap Value -> Maybe Double
extractThreshold key expObj =
  case KM.lookup (K.fromText "thresholds") expObj of
    Just (Object thresholds) ->
      case KM.lookup (K.fromText key) thresholds of
        Just (Number n) -> Just (realToFrac n)
        _ -> Nothing
    _ -> Nothing

-- | Check a list of queries against Prometheus, comparing results to thresholds.
checkQueryList :: String -> [Value] -> Maybe Double -> Maybe Double -> IO PromCheckResult
checkQueryList _ [] _ _ = pure PromOK
checkQueryList promUrl (q : rest) abortTh warnTh = do
  result <- checkSingleQuery promUrl q abortTh warnTh
  case result of
    PromAbort reason -> pure (PromAbort reason)
    PromWarn reason -> do
      restResult <- checkQueryList promUrl rest abortTh warnTh
      case restResult of
        PromAbort r -> pure (PromAbort r)
        _ -> pure (PromWarn reason)
    PromOK -> checkQueryList promUrl rest abortTh warnTh

-- | Query Prometheus for a single metric and compare against thresholds.
checkSingleQuery :: String -> Value -> Maybe Double -> Maybe Double -> IO PromCheckResult
checkSingleQuery promUrl (Object qObj) abortTh warnTh = do
  let mQuery = case KM.lookup (K.fromText "query") qObj of
        Just (String q) -> Just q
        _ -> Nothing
      mName = case KM.lookup (K.fromText "name") qObj of
        Just (String n) -> n
        _ -> "unknown"
  case mQuery of
    Nothing -> pure PromOK
    Just query -> do
      mValue <- queryPrometheus promUrl query
      case mValue of
        Nothing -> pure PromOK -- Query failed, fail open
        Just val -> do
          putStrLn $ "[DECISION] Prom query '" <> T.unpack mName <> "' = " <> show val
          case abortTh of
            Just threshold
              | val > threshold ->
                pure $ PromAbort (mName <> " = " <> T.pack (show val) <> " exceeds abort threshold " <> T.pack (show threshold))
            _ -> case warnTh of
              Just threshold
                | val > threshold ->
                  pure $ PromWarn (mName <> " = " <> T.pack (show val) <> " exceeds warn threshold " <> T.pack (show threshold))
              _ -> pure PromOK
checkSingleQuery _ _ _ _ = pure PromOK

-- | Query Prometheus HTTP API and extract the scalar result value.
--
-- Calls: GET {promUrl}/api/v1/query?query={query}
-- Parses the response JSON to extract the numeric value from the result.
-- Returns Nothing on any failure (fail open).
queryPrometheus :: String -> Text -> IO (Maybe Double)
queryPrometheus promUrl query = do
  let url = promUrl <> "/api/v1/query?query=" <> T.unpack query
      curlArgs =
        [ "-s",
          "--max-time",
          "10",
          url
        ]
  result <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
  case result of
    Left e -> do
      putStrLn $ "[DECISION] Prometheus query failed: " <> show e
      pure Nothing
    Right (ExitSuccess, out, _) ->
      pure (parsePromResponse out)
    Right (ExitFailure code, _, err) -> do
      putStrLn $ "[DECISION] Prometheus query failed (exit " <> show code <> "): " <> err
      pure Nothing

-- | Parse Prometheus query response JSON.
--
-- Expected format:
-- { "status": "success", "data": { "result": [{ "value": [timestamp, "value_string"] }] } }
parsePromResponse :: String -> Maybe Double
parsePromResponse raw =
  case eitherDecode (LBS.fromStrict (TE.encodeUtf8 (T.pack raw))) :: Either String Value of
    Left _ -> Nothing
    Right (Object obj) ->
      case KM.lookup (K.fromText "data") obj of
        Just (Object dataObj) ->
          case KM.lookup (K.fromText "result") dataObj of
            Just (Array results) ->
              case foldr (:) [] results of
                (Object r : _) ->
                  case KM.lookup (K.fromText "value") r of
                    Just (Array vals) ->
                      case foldr (:) [] vals of
                        [_, String valStr] ->
                          case reads (T.unpack valStr) :: [(Double, String)] of
                            ((v, _) : _) -> Just v
                            _ -> Nothing
                        _ -> Nothing
                    _ -> Nothing
                _ -> Nothing
            _ -> Nothing
        _ -> Nothing
    _ -> Nothing

-- ============================================================================
-- AB Decision Engine
-- ============================================================================

-- | Get decision from AB testing engine.
--
-- Calls: GET {AB_ENGINE_URL}/decision/{trackerId}
-- Returns Continue if:
-- - ab_decision_enabled is false (gate)
-- - No AB_ENGINE_URL configured
-- - HTTP call fails (fail open)
--
-- Otherwise returns the decision from the response.
getABDecision :: DBEnv -> Config -> ReleaseTracker -> IO DecisionResult
getABDecision db cfg tracker = do
  enabled <- getConfigBoolForProduct db "ab_decision_enabled" (Just (appGroup tracker)) False
  if not enabled
    then pure (DecisionResult Continue Nothing "AB_ENGINE")
    else do
      let abUrl = abEngineUrl cfg
      if null abUrl
        then pure (DecisionResult Continue Nothing "AB_ENGINE")
        else callABEngine abUrl (releaseId tracker)

-- | Internal: Call AB Engine HTTP API.
--
-- GET {abUrl}/decision/{trackerId}
-- Expects JSON response: {"decision": "Continue|Wait|Abort", "reason": "..."}
callABEngine :: String -> Text -> IO DecisionResult
callABEngine abUrl trackerId = do
  let url = abUrl <> "/decision/" <> T.unpack trackerId
  result <- httpGetJson url
  case result of
    Left e -> do
      putStrLn $ "[DECISION] AB Engine call failed: " <> show e
      pure (DecisionResult Continue (Just "AB Engine unreachable") "AB_ENGINE")
    Right val -> parseDecisionResponse val "AB_ENGINE"

-- ============================================================================
-- Health Score (HS) Decision Engine
-- ============================================================================

-- | Get decision from Health Score engine.
--
-- Calls: GET {AB_HS_URL}/decision/{trackerId} (pre-monitoring)
--  or: GET {AB_HS_URL}/decision/post/{trackerId} (post-monitoring)
--
-- Returns Continue if:
-- - ab_hs_enabled is false (gate)
-- - No AB_HS_URL configured
-- - HTTP call fails (fail open)
--
-- The isPostMonitoring flag selects the endpoint path.
getHSDecision :: DBEnv -> Config -> ReleaseTracker -> Bool -> IO DecisionResult
getHSDecision db cfg tracker isPostMonitoring = do
  enabled <- getConfigBoolForProduct db "ab_hs_enabled" (Just (appGroup tracker)) False
  if not enabled
    then pure (DecisionResult Continue Nothing "HEALTH_SCORE")
    else do
      let hsUrl = abHsUrl cfg
      if null hsUrl
        then pure (DecisionResult Continue Nothing "HEALTH_SCORE")
        else callHSEngine hsUrl (releaseId tracker) isPostMonitoring

-- | Internal: Call HS Engine HTTP API.
--
-- GET {hsUrl}/decision/{trackerId} or GET {hsUrl}/decision/post/{trackerId}
-- Expects JSON response: {"decision": "Continue|Wait|Abort", "reason": "..."}
callHSEngine :: String -> Text -> Bool -> IO DecisionResult
callHSEngine hsUrl trackerId isPostMonitoring = do
  let endpoint = if isPostMonitoring then "/decision/post/" else "/decision/"
      url = hsUrl <> endpoint <> T.unpack trackerId
  result <- httpGetJson url
  case result of
    Left e -> do
      putStrLn $ "[DECISION] HS Engine call failed: " <> show e
      pure (DecisionResult Continue (Just "HS Engine unreachable") "HEALTH_SCORE")
    Right val -> parseDecisionResponse val "HEALTH_SCORE"

-- ============================================================================
-- Combined Decision
-- ============================================================================

-- | Combine AB and HS decisions: Abort wins over Wait wins over Continue.
getCombinedDecision :: DecisionResult -> DecisionResult -> Decision
getCombinedDecision ab hs = case (drDecision ab, drDecision hs) of
  (Abort, _) -> Abort
  (_, Abort) -> Abort
  (Wait, _) -> Wait
  (_, Wait) -> Wait
  _ -> Continue

-- ============================================================================
-- Shared Helpers
-- ============================================================================

-- | Parse a decision response JSON.
--
-- Expected format: {"decision": "Continue|Wait|Abort", "reason": "optional reason"}
-- Falls back to Continue on parse failure (fail open).
parseDecisionResponse :: Value -> Text -> IO DecisionResult
parseDecisionResponse (Object obj) source = do
  let decision = case KM.lookup (K.fromText "decision") obj of
        Just (String "Abort") -> Abort
        Just (String "ABORT") -> Abort
        Just (String "abort") -> Abort
        Just (String "Wait") -> Wait
        Just (String "WAIT") -> Wait
        Just (String "wait") -> Wait
        _ -> Continue
      reason = case KM.lookup (K.fromText "reason") obj of
        Just (String r) | not (T.null r) -> Just r
        _ -> Nothing
  pure (DecisionResult decision reason source)
parseDecisionResponse _ source = do
  putStrLn $ "[DECISION] Could not parse decision response for " <> T.unpack source
  pure (DecisionResult Continue (Just "Invalid response format") source)

-- | HTTP GET returning parsed JSON Value.
--
-- Uses curl with a 10-second timeout, matching the existing pattern in Sync.hs.
-- Returns Left on any failure, Right Value on success.
httpGetJson :: String -> IO (Either String Value)
httpGetJson url = do
  let curlArgs =
        [ "-s",
          "--max-time",
          "10",
          "-H",
          "Accept: application/json",
          url
        ]
  result <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
  case result of
    Left e -> pure (Left (show e))
    Right (ExitSuccess, out, _) ->
      case eitherDecode (LBS.fromStrict (TE.encodeUtf8 (T.pack out))) :: Either String Value of
        Right val -> pure (Right val)
        Left err -> pure (Left ("JSON parse error: " <> err))
    Right (ExitFailure code, _, err) ->
      pure (Left ("curl failed (exit " <> show code <> "): " <> err))
