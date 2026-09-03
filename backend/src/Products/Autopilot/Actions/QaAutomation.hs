{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Manual QA-automation trigger + results for the release page's "QA
Automation" tab. The automatic trigger (on release COMPLETED) lives in
'Products.Autopilot.Notifications.notifyReleaseCompleted' via
'Products.Autopilot.QaAutomation.dispatchAutoQaRun' — this module is only the
operator-facing surface.
-}
module Products.Autopilot.Actions.QaAutomation (
    triggerQaRunH,
    listQaRunsH,
    refreshQaRunH,
)
where

import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), requireDeploymentPermission)
import Core.Environment (Flow)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Products.Autopilot.QaAutomation (refreshRunStatus, triggerQaRun)
import Products.Autopilot.Queries.QaAutomation (findRunByRunId, findRunsForRelease)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTrackerForCloud)
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.QaAutomation (QaAutomationRun, TriggerQaRunResponse (..), qrReleaseId, qrRunId, qrTestDashboardUrl)
import Products.Autopilot.Types.Release (ReleaseTracker (..))

-- | Fires the configured flows for this release's app group and tags the run
-- with the release's version. 400s (not 500s) for "not configured" /
-- "disabled" / "dashboard unreachable" — these are expected, actionable
-- outcomes, not server errors.
triggerQaRunH :: AuthedPerson -> Text -> Flow TriggerQaRunResponse
triggerQaRunH ap rid = do
    mTracker <- findReleaseTrackerForCloud rid
    case mTracker of
        Nothing -> throwM $ NotFound "Release not found"
        Just (tracker, _) -> do
            requireDeploymentPermission (Proxy :: Proxy 'AP_QA_TRIGGER) ap (appGroup tracker)
            result <- triggerQaRun tracker "MANUAL"
            case result of
                Left err -> throwM $ BadRequest err
                Right run ->
                    pure
                        TriggerQaRunResponse
                            { tqrRunId = qrRunId run
                            , tqrTestDashboardUrl = maybe "" id (qrTestDashboardUrl run)
                            }

-- | View-only — anyone who can see the release can see its QA runs.
listQaRunsH :: AuthedPerson -> Text -> Flow [QaAutomationRun]
listQaRunsH ap rid = do
    mTracker <- findReleaseTrackerForCloud rid
    case mTracker of
        Nothing -> throwM $ NotFound "Release not found"
        Just (tracker, _) -> do
            requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_VIEW) ap (appGroup tracker)
            findRunsForRelease rid

-- | Poll the test dashboard for one run's latest status/detail. Gated the
-- same as triggering — a refresh reaches out over the network too — via the
-- run's own releaseId (not the runId itself, which isn't a release).
refreshQaRunH :: AuthedPerson -> Text -> Flow (Maybe QaAutomationRun)
refreshQaRunH ap runId = do
    mExisting <- findRunByRunId runId
    case mExisting of
        Nothing -> pure Nothing
        Just existing -> do
            mTracker <- findReleaseTrackerForCloud (qrReleaseId existing)
            case mTracker of
                Nothing -> throwM $ NotFound "Release not found"
                Just (tracker, _) -> do
                    requireDeploymentPermission (Proxy :: Proxy 'AP_QA_TRIGGER) ap (appGroup tracker)
                    refreshRunStatus runId
