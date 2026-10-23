{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- | Drives approved group runs. Each tick, for every RUNNING group, work out
which step(s) are next ('planAdvance') and approve those steps' trackers. The
normal runner then executes them — this loop never touches Kubernetes.

Safe to run in more than one process: a step is claimed with a WAITING ->
STARTED compare-and-swap before it is approved.
-}
module Products.Autopilot.ReleaseGroup.Coordinator (
    releaseGroupLoop,
    advanceRun,
)
where

import Control.Exception qualified as E
import Control.Monad (forM, forM_, forever, void, when)
import Control.Monad.Catch qualified as MC
import Core.Environment (Flow, logError, logInfo, logWarning)
import Core.Types.Time (threadDelaySec)
import Data.Aeson (object, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Products.Autopilot.Actions.Release (approveReleaseCore)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTrackerForCloud, insertReleaseEvent)
import Products.Autopilot.ReleaseGroup.Store
import Products.Autopilot.ReleaseGroup.Types
import Products.Autopilot.RuntimeConfig (getReleaseWatchDelay)
import Products.Autopilot.Types qualified as NT
import Products.Autopilot.Types.API (ApproveReleaseReq (..))

-- | Forever loop; a failing tick is logged and the loop carries on.
releaseGroupLoop :: Flow ()
releaseGroupLoop = forever $ do
    result <- MC.try @_ @E.SomeException $ do
        runs <- activeRuns
        forM_ runs $ \r -> do
            one <- MC.try @_ @E.SomeException (advanceRun r)
            case one of
                Left e -> logError $ "[RELEASE_GROUP] " <> r.runId <> " tick failed (continuing): " <> T.pack (show e)
                Right () -> pure ()
        getReleaseWatchDelay >>= threadDelaySec
    case result of
        Left e -> logError $ "[RELEASE_GROUP] Poll iteration failed (continuing): " <> T.pack (show e)
        Right () -> pure ()

advanceRun :: GroupRun -> Flow ()
advanceRun run = do
    views <- forM run.steps $ \s -> do
        o <- outcomeOf s
        pure (StepView s.stageIdx s.stepIdx s.stageMode o)
    case planAdvance views of
        Wait -> pure ()
        CompleteRun -> do
            ok <- transitionRun run.runId [Running] Completed ""
            when ok $ logInfo $ "[RELEASE_GROUP] " <> run.runId <> " completed"
        HaltRun why -> halt run why
        StartSteps ks -> forM_ ks $ \(si, pi') ->
            forM_ [s | s <- run.steps, s.stageIdx == si, s.stepIdx == pi'] (startStep run)

halt :: GroupRun -> Text -> Flow ()
halt run why = do
    ok <- transitionRun run.runId [Running] Halted why
    when ok $ logWarning $ "[RELEASE_GROUP] " <> run.runId <> " halted: " <> why

label :: RunStep -> Text
label s = s.appGroup <> "/" <> s.service

outcomeOf :: RunStep -> Flow Outcome
outcomeOf s = case s.state of
    Skipped -> pure Done
    Waiting -> pure NotStarted
    Started -> do
        m <- findReleaseTrackerForCloud s.releaseId
        pure $ case m of
            Nothing -> Unknown
            Just (t, _) -> case classifyStatus (T.pack (show (NT.status t))) of
                Failed st -> Failed (label s <> " is " <> st)
                other -> other

startStep :: GroupRun -> RunStep -> Flow ()
startStep run s = do
    claimed <- claimStep run.runId s.stageIdx s.stepIdx
    when claimed $ do
        let approver = fromMaybe run.createdBy run.approvedBy
        r <- MC.try @_ @E.SomeException $ do
            m <- findReleaseTrackerForCloud s.releaseId
            case m of
                Nothing -> MC.throwM (userError ("release " <> T.unpack s.releaseId <> " not found"))
                Just (t, mts) -> void $ approveReleaseCore s.releaseId (ApproveReleaseReq approver Nothing) t mts
        case r of
            Right () -> do
                insertReleaseEvent s.releaseId "BUSINESS" "GROUP_STEP_STARTED" $
                    object ["runId" .= run.runId, "stage" .= s.stageName]
                logInfo $ "[RELEASE_GROUP] " <> run.runId <> " started " <> label s
            Left e -> do
                -- Hand the step back so Resume can retry it, and stop the group.
                setStepState run.runId s.stageIdx s.stepIdx Waiting
                halt run ("Could not start " <> label s <> ": " <> T.pack (show e))
