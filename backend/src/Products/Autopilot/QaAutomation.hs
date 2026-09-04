{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Trigger the private ny-qa-automation regression suites (NY/MSIL/YS)
against a running test dashboard, either automatically when a release
completes ('dispatchAutoQaRun', wired into 'Products.Autopilot.Notifications.
notifyReleaseCompleted') or manually from the release page
('Products.Autopilot.Actions.QaAutomation.triggerQaRunH', which calls
'triggerQaRun' directly).

Mirrors "Products.Autopilot.Webhooks": same 'Core.Http.Client' usage, same
exactly-once dispatch guard for the automatic path (a release can be
terminalized from more than one place).
-}
module Products.Autopilot.QaAutomation (
    triggerQaRun,
    dispatchAutoQaRun,
    refreshRunStatus,
)
where

import Control.Monad (join, void)
import Control.Monad.Catch (catch, throwM)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, forkFlow)
import Core.Http.Client (
    HttpReq (..),
    HttpResponse (..),
    Method (..),
    defaultReq,
    httpRaw,
 )
import Core.Logging (logErrorG, logInfoG)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value, decode, object, withObject, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (SqlError (..))
import GHC.Int (Int32)
import Products.Autopilot.Queries.QaAutomation
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.Types.QaAutomation
import Products.Autopilot.Types.Release (ReleaseTracker (..))

-- | Exactly-once guard for the *automatic* path (migration 0051's partial
-- unique index) — a release can be terminalized from more than one place
-- (a runner tick and a user-facing handler racing on the same abort), and a
-- duplicate QA run is wasted work, not a harmless duplicate notification.
-- The manual button has no such guard: an operator asking twice gets two runs.
qaAutomationDispatchLabel :: Text
qaAutomationDispatchLabel = "QA_AUTOMATION_DISPATCHED"

requestTimeoutSeconds :: Int32
requestTimeoutSeconds = 15

-- | The base URL to actually fire server-to-server calls against — the
-- in-cluster Service DNS when configured, since 'qcTestDashboardUrl' is
-- fronted externally by Pomerium (an identity-aware proxy expecting a
-- browser/SSO session), which would intercept a plain token-header POST
-- before it ever reached the dashboard's own webhook auth check.
webhookBaseUrl :: QaAutomationConfig -> Text
webhookBaseUrl cfg = fromMaybe (qcTestDashboardUrl cfg) (qcInternalBaseUrl cfg)

-- | Look up config for the tracker's app group and fire the trigger webhook,
-- persisting a run row on success. Never throws — every failure mode (not
-- configured, disabled, unreachable, bad response) comes back as 'Left' so
-- the manual-trigger handler can turn it into a normal error response and
-- the automatic path can just log it.
triggerQaRun :: ReleaseTracker -> Text -> Flow (Either Text QaAutomationRun)
triggerQaRun tracker triggerSource = do
    mCfg <- findConfigForAppGroup (appGroup tracker)
    case mCfg of
        Nothing -> pure (Left "QA automation is not configured for this app group")
        Just cfg
            | not (qcEnabled cfg) -> pure (Left "QA automation is disabled for this app group")
            | otherwise -> do
                let body =
                        object
                            [ "collections" .= qcFlows cfg
                            , "envFile" .= qcEnvFile cfg
                            , "concurrency" .= qcConcurrency cfg
                            ]
                    req =
                        (defaultReq (webhookBaseUrl cfg <> "/api/qa-collections/webhook"))
                            { reqMethod = POST
                            , reqHeaders =
                                [ ("X-QA-Webhook-Token", qcWebhookToken cfg)
                                , ("Content-Type", "application/json")
                                ]
                            , reqBody = Just (Aeson.encode body)
                            , reqTimeout = Seconds (fromIntegral requestTimeoutSeconds)
                            , reqRetries = 0
                            , reqLogTag = "qa-automation"
                            }
                outcome <- liftIO (httpRaw req)
                case outcome of
                    Left err -> do
                        logErrorG $ "[qa-automation] trigger failed for " <> releaseId tracker <> ": " <> T.pack (show err)
                        pure (Left ("could not reach the test dashboard: " <> T.pack (show err)))
                    Right resp
                        | respStatus resp >= 400 ->
                            pure (Left ("test dashboard rejected the trigger: HTTP " <> T.pack (show (respStatus resp))))
                        | otherwise -> case decode (respBody resp) >>= parseMaybe (withObject "response" (.: "runId")) of
                            Nothing -> pure (Left "test dashboard's response did not include a runId")
                            Just runId -> do
                                let dashboardUrl = qcTestDashboardUrl cfg <> "/?qaRunId=" <> runId
                                insertRun runId (releaseId tracker) (appGroup tracker) (Just (newVersion tracker)) triggerSource dashboardUrl
                                mRun <- findRunByRunId runId
                                pure $ maybe (Left "run was triggered but could not be re-read") Right mRun

-- | Called from 'Products.Autopilot.Notifications.notifyReleaseCompleted' —
-- fire-and-forget, exactly like 'Products.Autopilot.Webhooks.
-- dispatchTerminalWebhooks': a QA-trigger problem must never block or fail
-- release completion.
dispatchAutoQaRun :: ReleaseTracker -> Flow ()
dispatchAutoQaRun tracker = void $ forkFlow $ do
    mCfg <- findConfigForAppGroup (appGroup tracker)
    case mCfg of
        Nothing -> pure ()
        Just cfg | not (qcEnabled cfg) || not (qcOnSuccess cfg) -> pure ()
        Just _ -> do
            claimed <- claimAutoDispatch (releaseId tracker)
            if not claimed
                then logInfoG $ "[qa-automation] " <> releaseId tracker <> " already dispatched, skipping"
                else do
                    result <- triggerQaRun tracker "AUTO"
                    case result of
                        Left err -> logErrorG $ "[qa-automation] auto-trigger failed for " <> releaseId tracker <> ": " <> err
                        Right run -> logInfoG $ "[qa-automation] auto-triggered " <> qrRunId run <> " for " <> releaseId tracker

-- | The claim is taken /before/ delivery, so this is at-most-once: a crash
-- between the claim and the HTTP call drops the auto-trigger permanently.
-- Deliberate, same rationale as 'Products.Autopilot.Webhooks.claimDispatch'.
claimAutoDispatch :: Text -> Flow Bool
claimAutoDispatch rid =
    (True <$ insertReleaseEvent rid "BUSINESS" qaAutomationDispatchLabel (object []))
        `catch` \e -> if sqlState e == "23505" then pure False else throwM (e :: SqlError)

{- | Poll the test dashboard for a run's current state and cache the result.
Called on-demand (results tab open / explicit refresh), not from a
background loop. Never throws — an unreachable dashboard or an unexpected
response just leaves the cached row as it was.
-}
refreshRunStatus :: Text -> Flow (Maybe QaAutomationRun)
refreshRunStatus runId = do
    mRun <- findRunByRunId runId
    case mRun of
        Nothing -> pure Nothing
        Just run -> do
            mCfg <- findConfigForAppGroup (qrAppGroup run)
            case mCfg of
                Nothing -> pure (Just run)
                Just cfg -> do
                    let req =
                            (defaultReq (webhookBaseUrl cfg <> "/api/qa-collections/runs/" <> runId))
                                { reqTimeout = Seconds (fromIntegral requestTimeoutSeconds)
                                , reqRetries = 0
                                , reqLogTag = "qa-automation"
                                }
                    outcome <- liftIO (httpRaw req)
                    case outcome of
                        Left _ -> pure (Just run)
                        Right resp
                            | respStatus resp >= 400 -> pure (Just run)
                            | otherwise -> case decode (respBody resp) :: Maybe Value of
                                Nothing -> pure (Just run)
                                Just v -> do
                                    let mStatus = parseMaybe (withObject "detail" (.: "status")) v
                                        newStatus = maybe (qrStatus run) mapDashboardStatus mStatus
                                        passed = join (parseMaybe (withObject "detail" (.:? "passed")) v)
                                        failed = join (parseMaybe (withObject "detail" (.:? "failed")) v)
                                    updateRunResult runId newStatus passed failed (Just v)
                                    findRunByRunId runId

-- | The dashboard reports lowercase statuses ("running"/"passed"/"failed"/
-- "stopped"); this codebase's own enums are upper-case (COMPLETED, ABORTED,
-- WEBHOOK_SENT, ...) — keep qa_automation_run.status consistent with that.
mapDashboardStatus :: Text -> Text
mapDashboardStatus = T.toUpper
