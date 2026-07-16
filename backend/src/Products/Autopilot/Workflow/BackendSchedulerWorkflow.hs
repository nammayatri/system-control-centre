{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Backend scheduler workflow (K8s pod-count based deployment)
--
-- This module implements the workflow for deploying backend schedulers to Kubernetes.
-- Unlike BackendServiceWorkflow, schedulers use pod-count based rollout:
-- - NO VirtualService manipulation (schedulers don't have VS)
-- - NO DestinationRule manipulation
-- - Scale old to 0, then scale new up progressively
-- - Pod count at each step: max(podsRolloutRatio * rollout%, totalPods)
module Products.Autopilot.Workflow.BackendSchedulerWorkflow
  ( backendSchedulerSpec,
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import Core.Environment (getConfig, logError, logInfo, logWarning)
import Core.Types.Time (threadDelaySec)
import Core.Workflow.Spec (WorkflowSpec (..))
import Core.Workflow.Stage (Stage)
import Data.Aeson (object, toJSON, (.=))
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Products.Autopilot.K8s.Deployment
  ( buildCloneDeploymentCommand,
    buildConfigMapApplyCommand,
    buildScaleDeploymentCommand,
    buildScaleNamedDeploymentCommand,
    deploymentExists,
    getDeploymentReplicaStatus,
    getRunningSchedulerVersion,
  )
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd, shellQuote)
import Products.Autopilot.K8s.HPA (buildCloneHpaCommand, buildDeleteHpaCommand, getHpaMinMax, hpaExists)
import Products.Autopilot.Notifications
  ( notifyPodsScaledDown,
    notifyReleaseCompleted,
    notifyReleaseProgress,
  )
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker, insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (isScaleDownPodsOnCompletion)
-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release
  ( ReleaseStatus (..),
    ReleaseTracker (appGroup, releaseId, rolloutHistory, rolloutStrategy, status),
    RolloutHistory (..),
    RolloutStep (..),
  )
import Products.Autopilot.Types.Target
  ( BackendServiceWFStatus (..),
    K8sDeploymentState (..),
    TargetState (..),
    emptyK8sState,
  )
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers
  ( captureDeploymentSnapshot,
    getRT,
    persistWorkflowState,
    updateRT,
    withK8sContext,
  )
import Products.Autopilot.Workflow.StageHelpers (mkLegacyStateFlowStage)
import Products.Autopilot.Workflow.Types
  ( ReleaseState (..),
    StateFlow,
  )
import Prelude

-- ============================================================================
-- Workflow Spec — the only entry point
-- ============================================================================

-- | Backend scheduler workflow expressed as a 'WorkflowSpec' value.
--
-- Every workflow is a __value__ (a record holding a list of stages + lifecycle
-- hooks), not a function. The same canonical six-step lifecycle (skip-check →
-- acquire-locks → pre-check → exec → validate → advance-and-persist) runs
-- every stage through the engine in 'Core.Workflow.Engine'. The shape is
-- identical to what infra-switch's 'StageInterface' was designed for, just
-- with @s@ as a type parameter so any future SCC product can plug in.
--
-- Each stage uses the existing legacy 'StateFlow' function bodies via
-- 'mkLegacyStateFlowStage' — we are __preserving__ the existing semantics,
-- not rewriting them. Future PRs can incrementally split each @stageExec@
-- into @stagePreCheck@ + @stageExec@ + per-stage @stageOnError@ as desired.
backendSchedulerSpec :: WorkflowSpec ReleaseState
backendSchedulerSpec =
  WorkflowSpec
    { wsName = "BackendScheduler",
      wsStages =
        [ schedulerStageInit,
          schedulerStagePrepare,
          schedulerStageDeploy,
          schedulerStageMonitor,
          schedulerStageFinalize,
          schedulerStageDone
        ],
      -- Workflow-level rollback is handled by the runner's
      -- restoreVsTrafficOnFailure (called from Runner.hs:445), so the
      -- spec-level rollback is a no-op. Future work: move the runner's
      -- rollback into wsRollback so the engine handles it uniformly.
      wsRollback = \_err -> pure (),
      wsPersist = persistWorkflowState
    }

schedulerStageInit,
  schedulerStagePrepare,
  schedulerStageDeploy,
  schedulerStageMonitor,
  schedulerStageFinalize,
  schedulerStageDone ::
    Stage ReleaseState
schedulerStageInit = mkLegacyStateFlowStage "init" INIT validatePreconditions
schedulerStagePrepare = mkLegacyStateFlowStage "prepare" PREPARING prepareK8sResources
schedulerStageDeploy = mkLegacyStateFlowStage "deploy" DEPLOYING podCountRollout
schedulerStageMonitor = mkLegacyStateFlowStage "monitor" MONITORING monitorHealth
schedulerStageFinalize = mkLegacyStateFlowStage "finalize" FINALIZING cleanupOldVersion
schedulerStageDone = mkLegacyStateFlowStage "done" DONE notifyComplete

-- ============================================================================
-- Helpers: Config / Context / K8s IO
-- ============================================================================

-- | Get bootstrap config from the Flow (ReaderT) environment
getCfg :: StateFlow Config
getCfg = lift getConfig

-- | StateFlow-level logging (lifts from Flow)
logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

logErrorS :: T.Text -> StateFlow ()
logErrorS = lift . logError

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = withK8sContext

-- | Run an IO action that returns Either K8sError, lifting into StateFlow
runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
  result <- liftIO action
  case result of
    Right a -> pure a
    Left (K8sError err) -> liftIO $ throwIO $ WorkflowError "k8s" err

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
  rt <- getRT
  cfg <- getCfg
  logInfoS $ "Validating preconditions for scheduler " <> appGroup rt

  -- Initialise or update K8s deployment state
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) ->
      modify $ \s -> s {targetState = Just (K8sState (k8s {categoryWorkflowStatus = BSInit}))}
    _ -> do
      let k8sState = emptyK8sState {categoryWorkflowStatus = BSInit}
      modify $ \s -> s {targetState = Just (K8sState k8sState)}

  ctx <- getK8sCtx

  -- Check cluster reachable by verifying namespace exists
  logInfoS "  Checking cluster reachability"
  _ <-
    runK8sIO $
      runCmd
        ( unwords
            [ kubectlBin cfg,
              "-n",
              T.unpack (namespace ctx),
              "get namespace",
              T.unpack (namespace ctx)
            ]
        )

  -- Verify old deployment exists (for non-new schedulers)
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
  oldExists <- liftIO $ deploymentExists cfg (namespace ctx) oldDepName
  when (not oldExists && not (T.null (oldVersion ctx)) && oldVersion ctx /= "new") $
    logWarningS $
      "  Old deployment not found: " <> oldDepName

  logInfoS "  Cluster reachable, namespace exists"
  logInfoS "Preconditions validated for scheduler"

-- | Prepare K8s resources: ConfigMap, clone deployment with 1 pod for verification
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  logInfoS $ "PREPARING K8s resources for scheduler " <> appGroup rt

  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
      knownOldVersion =
        not (T.null (oldVersion ctx))
          && oldVersion ctx /= "unknown"
          && oldVersion ctx /= "new"
  if knownOldVersion
    then captureDeploymentSnapshot cfg (releaseId rt) (namespace ctx) oldDepName "DEPLOYMENT_BEFORE"
    else logInfoS $ "  Skipping BEFORE snapshot — old version is '" <> oldVersion ctx <> "'"

  -- 1. Apply ConfigMap
  updateK8sStatus BSApplyConfigMap
  logInfoS "  Applying ConfigMap"
  _ <- runK8sIO $ executeWithRetry cfg (buildConfigMapApplyCommand cfg ctx)
  updateK8sField (\k8s -> k8s {configMapApplied = True})

  -- 2. Clone deployment (or reuse existing) + ensure at least 1 replica
  --    for the readiness verification below.
  --
  -- Bug fix: previously, when the target deployment already existed
  -- (resume, revert, restart paths), this branch skipped BOTH the clone
  -- AND the scale-to-1 call. The next step 'waitForSchedulerPodReady'
  -- then looped while @desired > 0@ was false and timed out after 5 min
  -- on a deployment that was left at replicas=0 by a prior release's
  -- scale-down. Now we always ensure @replicas >= 1@ before the
  -- readiness check — the scale call is idempotent, so it's cheap even
  -- when the deployment is already running.
  --
  -- If oldVersion is "unknown" the running version could not be detected
  -- (e.g. no labelled deployment found). Check whether the old deployment
  -- actually exists before attempting the clone; fail early with a clear
  -- message instead of letting jq/kubectl emit a confusing NotFound error.
  updateK8sStatus BSCreateDeployment
  newDepExists <- liftIO $ deploymentExists cfg (namespace ctx) (deploymentName ctx)
  -- When the new deployment already exists AND the old source deployment is still
  -- present, it means a previous release attempt left a stale deployment —
  -- potentially with the wrong image (e.g. from the pre-fix jq bug). Delete it
  -- and re-clone so the image is always correct.
  -- When the old source is gone (cleaned up after a previous successful release),
  -- the existing new deployment is canonical — just scale it.
  effectivelyNeedsClone <-
    if newDepExists
      then do
        logInfoS "  Deployment already exists — ensuring replicas >= 1"
        _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx 1)
        pure False
      else pure True
  resolvedSrcCtx <-
    if not effectivelyNeedsClone
      then pure ctx
      else do
        oldDepExists <- liftIO $ deploymentExists cfg (namespace ctx) oldDepName
        srcCtx <-
          if oldDepExists
            then pure ctx
            else do
              discovered <- liftIO $ getRunningSchedulerVersion cfg (namespace ctx) (serviceName ctx)
              case discovered of
                Right (Just liveVer) -> do
                  let liveDepName = serviceName ctx <> "-" <> liveVer
                  liveExists <- liftIO $ deploymentExists cfg (namespace ctx) liveDepName
                  if liveExists
                    then do
                      logInfoS $
                        "  Stored old version '"
                          <> oldVersion ctx
                          <> "' not found; using live version '"
                          <> liveVer
                          <> "'"
                      pure ctx {oldVersion = liveVer}
                    else
                      liftIO $
                        throwIO $
                          WorkflowError "prepare" $
                            "Old deployment '"
                              <> oldDepName
                              <> "' not found and live discovery yielded '"
                              <> liveDepName
                              <> "' which also does not exist in namespace '"
                              <> namespace ctx
                              <> "'."
                _ ->
                  liftIO $
                    throwIO $
                      WorkflowError "prepare" $
                        "Old deployment '"
                          <> oldDepName
                          <> "' not found in namespace '"
                          <> namespace ctx
                          <> "'. "
                          <> "Could not detect the running version automatically — "
                          <> "please specify old_version explicitly when creating the release."
        logInfoS $ "  Cloning deployment to " <> deploymentName ctx <> " with 1 pod for verification"
        logInfoS $
          "  [clone] container="
            <> containerName ctx
            <> " dockerImage="
            <> maybe "(none)" id (dockerImage ctx)
            <> " oldVersion="
            <> oldVersion srcCtx
            <> " newVersion="
            <> newVersion ctx
        _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentCommand cfg srcCtx 1)
        _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx 1)
        -- Verify the cloned deployment has the expected image.
        -- This catches jq/container-name mismatches immediately as a visible event.
        let verifyCmd =
              unwords
                [ kubectlBin cfg,
                  "-n",
                  shellQuote (namespace ctx),
                  "get deploy",
                  shellQuote (deploymentName ctx),
                  "-o",
                  "jsonpath={range .spec.template.spec.containers[*]}{.name}={.image}{\"\\n\"}{end}"
                ]
        rt' <- getRT
        verifyResult <- liftIO $ runCmd verifyCmd
        case verifyResult of
          Right (K8sResult out) -> do
            logInfoS $ "  [clone] container images after apply:\n" <> out
            insertReleaseEvent
              (releaseId rt')
              "BUSINESS"
              "CLONE_IMAGE_VERIFY"
              (object ["containers" .= out, "expected_version" .= newVersion ctx])
            let expectedTag = newVersion ctx
            when (not (T.isInfixOf expectedTag out)) $
              logErrorS $
                "  [clone] WARNING: new version '"
                  <> expectedTag
                  <> "' not found in deployed images. Image may be wrong."
          Left (K8sError err) ->
            logWarningS $ "  [clone] Could not verify image: " <> err
        pure srcCtx
  updateK8sField (\k8s -> k8s {deploymentCreated = True})

  -- 3. HPA: preserve existing / clone from old (no template branch).
  --
  -- Schedulers (queue workers, cron-driven workers) don't typically have an
  -- HPA — autoscaling on CPU is meaningless for a queue consumer. But
  -- some schedulers DO have one (e.g. KEDA-managed custom-metrics HPA on
  -- queue depth). When that's the case we mirror BackendService's flow:
  -- preserve the operator-configured min/max/metrics/behavior verbatim and
  -- only mutate the HPA at this prepare stage. Progressive pod-count
  -- rollout caps at the live HPA's maxReplicas but never patches it.
  -- No Branch 3 (template create) — schedulers without an old HPA simply
  -- run without one.
  let newHpaName = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
      oldHpaName = serviceName ctx <> "-" <> oldVersion resolvedSrcCtx <> "-hpa"
  newHpaFound <- liftIO $ hpaExists cfg (namespace ctx) newHpaName
  if newHpaFound
    then do
      logInfoS $ "  HPA " <> newHpaName <> " already exists, preserving (no patch)"
      insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_PRESERVED" (toJSON newHpaName)
    else do
      oldHpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
      when oldHpaFound $ do
        logInfoS $ "  Cloning HPA from " <> oldHpaName <> " (preserving min/max/metrics/behavior)"
        cloneResult <- liftIO $ runCmd (buildCloneHpaCommand cfg (namespace ctx) (serviceName ctx) (oldVersion ctx) (newVersion ctx) oldHpaName)
        case cloneResult of
          Right _ -> do
            logInfoS "  HPA cloned successfully"
            insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_CLONED" (toJSON newHpaName)
          Left (K8sError err) -> logErrorS $ "  [HPA] Clone failed (non-fatal): " <> err

  -- Bug fix B10: replace the previous fixed `threadDelaySec 10` (which
  -- waited a fixed 10 seconds and then logged a warning if pods were not
  -- ready) with a real readiness poll. We poll up to 30 times at 10s
  -- intervals (~5 min total, matching BackendServiceWorkflow's
  -- `pod_readiness_max_attempts` / `pod_readiness_poll_seconds` defaults)
  -- and bail loudly if the pod never reaches ready≥1.
  logInfoS "  Waiting for verification pod readiness (max 30 polls × 10s)"
  waitForSchedulerPodReady cfg ctx 30 10
  checkDeploymentHealth cfg ctx

  logInfoS "K8s resources prepared for scheduler"

-- | Pod-count based rollout for schedulers/queue workers.
--
-- Order matters: ramp the NEW deployment FIRST, then scale the OLD to 0
-- once the new is fully ramped. The previous order (scale old → 0 first,
-- then ramp new) caused a window where there were ZERO active workers,
-- which for queue/cron-driven schedulers means queue depth grows or
-- cron runs are missed during the window.
--
-- Two distinct workers (old + new) running in parallel during the ramp
-- is NOT a problem for queue workers — they simply share the queue load.
-- Once the rollout completes, the old goes to 0 and only the new pulls.
podCountRollout :: StateFlow ()
podCountRollout = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  logInfoS $ "Starting pod-count rollout for scheduler " <> appGroup rt

  updateK8sStatus BSProgressiveRollout

  -- Step 1: Scale NEW deployment up progressively through rollout steps.
  -- The OLD deployment keeps running until the new is fully ramped, so
  -- there is never a moment with zero workers.
  let steps = rolloutStrategy rt
  if null steps
    then do
      -- No rollout strategy defined, scale to 1 pod minimum.
      logInfoS "  No rollout strategy, scaling new deployment to 1 pod"
      stepStartTime <- liftIO getCurrentTime
      scaleNewSchedulerCappedAtHpa cfg ctx 1
      stepEndTime <- liftIO getCurrentTime
      updateK8sField (\k8s -> k8s {trafficPercentage = 100})
      -- Append rollout history entry — schedulers previously did
      -- NOT write history, leaving the UI history panel empty and
      -- breaking restart-from-checkpoint detection.
      let entry = mkSchedHistory 100 0 1 stepStartTime stepEndTime
      updateRT $ \r -> r {rolloutHistory = rolloutHistory r <> [entry]}
      currentRT <- getRT
      lift $ notifyReleaseProgress currentRT 100
    else do
      forM_ steps $ \step -> do
        -- Bug fix: re-read the tracker from DB at the top of each
        -- stage so PAUSED / ABORTING / USER_ABORTED signals issued
        -- by the user via /update are picked up between stages.
        -- Previously the forM_ loop ran to completion regardless of
        -- mid-rollout status changes — an operator's PAUSE during
        -- cooloff would be silently ignored and the release would
        -- finish anyway.
        bailIfNotInProgress (releaseId rt) (rolloutPercent step)

        let targetPods = max 1 (podCount step)
        logInfoS $
          "  Scaling new deployment to "
            <> T.pack (show targetPods)
            <> " pods (stage "
            <> T.pack (show (rolloutPercent step))
            <> "% of rollout)"
        stepStartTime <- liftIO getCurrentTime
        scaleNewSchedulerCappedAtHpa cfg ctx targetPods
        updateK8sField (\k8s -> k8s {trafficPercentage = rolloutPercent step})

        -- Notify Slack of progress (fires before cooloff so the
        -- channel sees the ramp immediately).
        latestRT <- getRT
        lift $ notifyReleaseProgress latestRT (rolloutPercent step)

        -- Cooloff between steps. @cooloffMinutes@ is minutes;
        -- multiply by 60 before passing to the seconds-based delay.
        -- Bug fix: previously called @threadDelaySec (cooloffMinutes step)@
        -- which treated a 90-minute cooloff as 90 seconds, silently
        -- collapsing multi-stage rollouts to finish in well under a
        -- minute. BackendServiceWorkflow already does the @* 60@.
        when (cooloffMinutes step > 0 && rolloutPercent step < 100) $ do
          logInfoS $
            "  Cooloff: "
              <> T.pack (show (cooloffMinutes step))
              <> " minutes ("
              <> T.pack (show (cooloffMinutes step * 60))
              <> " seconds)"
          liftIO $ threadDelaySec (cooloffMinutes step * 60)

        -- Health check between steps
        when (rolloutPercent step < 100) $
          checkDeploymentHealth cfg ctx

        -- Append rollout history entry AFTER cooloff + health check
        -- so the @completedAt@ timestamp reflects the stage's real
        -- wall-clock duration (scale + cooloff + health), not just
        -- the ~0.3s scale call.
        stepEndTime <- liftIO getCurrentTime
        let entry = mkSchedHistory (rolloutPercent step) (cooloffMinutes step) targetPods stepStartTime stepEndTime
        updateRT $ \r -> r {rolloutHistory = rolloutHistory r <> [entry]}

  -- Step 2: New is fully ramped — NOW scale OLD to 0.
  -- Bug fix: previously this happened BEFORE step 1, leaving a window with
  -- zero active workers. Schedulers/queue workers can't tolerate that gap.
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
  logInfoS $ "  New deployment fully ramped, scaling down old deployment: " <> oldDepName
  _ <- runK8sIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) oldDepName 0)
  updateK8sField (\k8s -> k8s {oldDeploymentScaledDown = True})

  -- Notify Slack of old pods scaled down (now correct: fires AFTER new is up)
  finalRT <- getRT
  lift $ notifyPodsScaledDown finalRT (oldVersion ctx)

  logInfoS "Pod-count rollout complete"

-- | Re-read the tracker from DB and bail out of the rollout loop if the
-- user issued a PAUSE, ABORT, or DISCARD between stages. Throws a
-- 'WorkflowError' that the engine maps to 'DomainError', letting the
-- workflow stop cleanly without completing the remaining stages.
--
-- This is the scheduler equivalent of BackendService's per-iteration fresh
-- tracker re-read. Without it, the 'forM_ steps' loop ignores mid-rollout
-- status changes and the release runs to completion even after the
-- operator hit PAUSE.
bailIfNotInProgress :: T.Text -> Int -> StateFlow ()
bailIfNotInProgress rid stageRolloutPct = do
  fresh <- lift $ findReleaseTracker rid
  case fresh of
    Just (freshRT, _) -> case status freshRT of
      INPROGRESS -> pure ()
      PAUSED -> do
        logInfoS $
          "  [stage "
            <> T.pack (show stageRolloutPct)
            <> "%] Release is PAUSED — bailing out, runner will resume on next tick"
        liftIO $ throwIO $ WorkflowError "scheduler-rollout" "paused by user"
      ABORTING -> do
        logInfoS $
          "  [stage "
            <> T.pack (show stageRolloutPct)
            <> "%] Release is ABORTING — bailing out"
        liftIO $ throwIO $ WorkflowError "scheduler-rollout" "aborting by user"
      USER_ABORTED -> do
        logInfoS $
          "  [stage "
            <> T.pack (show stageRolloutPct)
            <> "%] Release already USER_ABORTED — bailing out"
        liftIO $ throwIO $ WorkflowError "scheduler-rollout" "user aborted"
      ABORTED -> liftIO $ throwIO $ WorkflowError "scheduler-rollout" "aborted"
      DISCARDED -> liftIO $ throwIO $ WorkflowError "scheduler-rollout" "discarded"
      other ->
        logWarningS $
          "  [stage "
            <> T.pack (show stageRolloutPct)
            <> "%] Unexpected tracker status "
            <> T.pack (show other)
            <> " — continuing"
    Nothing -> pure () -- tracker gone from DB, let the next op surface it

-- | Build a 'RolloutHistory' entry for a single scheduler stage.
-- Schedulers don't have a decision engine, so the @historyDecision@ /
-- @historyDecisionReason@ / @historyDecisionHs@ / @historyDecisionHsReason@
-- fields are 'Nothing'. Manual override is also unused for schedulers.
mkSchedHistory :: Int -> Int -> Int -> UTCTime -> UTCTime -> RolloutHistory
mkSchedHistory rollPct cooloff pods startedAt completedAt =
  RolloutHistory
    { historyRolloutPercent = rollPct,
      historyCooloffMinutes = cooloff,
      historyPodsCount = pods,
      historyDecision = Nothing,
      historyDecisionReason = Nothing,
      historyStartedAt = startedAt,
      historyCompletedAt = Just completedAt,
      historyManualOverride = False,
      historyDecisionHs = Nothing,
      historyDecisionHsReason = Nothing
    }

-- | Scale the new scheduler deployment to @targetPods@ replicas, capped at
-- the live HPA's @maxReplicas@ if an HPA exists for this version.
--
-- If @safeTarget > liveMax@ (operator configured a tighter HPA than the rollout
-- strategy demands), we scale to @liveMax@ and emit a 'ROLLOUT_CAPPED_BY_HPA'
-- event so the operator can decide whether to bump the HPA or reduce
-- 'podCount'. The HPA itself is NOT mutated by the rollout — its bounds are
-- sacred. See the prepare stage for the only place schedulers touch HPAs.
scaleNewSchedulerCappedAtHpa :: Config -> K8sReleaseContext -> Int -> StateFlow ()
scaleNewSchedulerCappedAtHpa cfg ctx targetPods = do
  let newHpa = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
      ns = namespace ctx
  rt <- getRT
  (_liveMin, liveMax) <- liftIO $ getHpaMinMax cfg ns newHpa
  let cappedTarget
        | liveMax > 0 = min targetPods liveMax
        | otherwise = targetPods -- no HPA, or read failure
      wasCapped = liveMax > 0 && targetPods > liveMax
  when wasCapped $ do
    logWarningS $
      "  [pods] Scheduler target "
        <> T.pack (show targetPods)
        <> " exceeds HPA "
        <> newHpa
        <> " maxReplicas="
        <> T.pack (show liveMax)
        <> " — capping at "
        <> T.pack (show liveMax)
    insertReleaseEvent
      (releaseId rt)
      "BUSINESS"
      "ROLLOUT_CAPPED_BY_HPA"
      ( object
          [ "hpa" .= newHpa,
            "safeTarget" .= targetPods,
            "hpaMaxReplicas" .= liveMax,
            "cappedTo" .= liveMax
          ]
      )
  _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx cappedTarget)
  pure ()

-- | Check deployment health via replica status
checkDeploymentHealth :: Config -> K8sReleaseContext -> StateFlow ()
checkDeploymentHealth cfg ctx = do
  (ready, available, desired) <-
    runK8sIO $
      getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
  logInfoS $
    "    Health: ready="
      <> T.pack (show ready)
      <> " available="
      <> T.pack (show available)
      <> " desired="
      <> T.pack (show desired)
  when (ready < desired) $
    logWarningS "    WARNING: Not all replicas ready yet"

-- | Poll deployment replica status until ready≥desired or timeout.
--
-- This is a minimal scheduler-local readiness check that replaces the previous
-- fixed `threadDelaySec 10` (bug B10). It polls 'getDeploymentReplicaStatus' at
-- fixed intervals and throws 'WorkflowError' if the deployment never reaches
-- the ready state. The full pod-health checking (CrashLoopBackOff, ImagePull
-- failure, restart count) lives in 'BackendServiceWorkflow.waitForPodsReady'
-- and will be extracted to a shared module in the foundation phase.
--
-- @maxAttempts@ × @pollSeconds@ = total wait budget. Defaults to 30 × 10 = 5min.
waitForSchedulerPodReady :: Config -> K8sReleaseContext -> Int -> Int -> StateFlow ()
waitForSchedulerPodReady cfg ctx maxAttempts pollSeconds = do
  rt <- getRT
  go (releaseId rt) 0
  where
    go rid attempt
      | attempt >= maxAttempts = do
          let msg =
                "Scheduler pod readiness timeout after "
                  <> T.pack (show maxAttempts)
                  <> " polls × "
                  <> T.pack (show pollSeconds)
                  <> "s"
          logErrorS $ "    " <> msg
          fetchAndLogPodLogs cfg ctx rid
          liftIO $ throwIO $ WorkflowError "scheduler-readiness" msg
      | otherwise = do
          liftIO $ threadDelaySec pollSeconds
          (ready, _avail, desired) <-
            runK8sIO $
              getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
          logInfoS $
            "    Poll "
              <> T.pack (show (attempt + 1))
              <> "/"
              <> T.pack (show maxAttempts)
              <> ": ready="
              <> T.pack (show ready)
              <> "/"
              <> T.pack (show desired)
          if ready >= desired && desired > 0
            then logInfoS "    Verification pod is Ready"
            else go rid (attempt + 1)

fetchAndLogPodLogs :: Config -> K8sReleaseContext -> T.Text -> StateFlow ()
fetchAndLogPodLogs cfg ctx rid = do
  let ns = namespace ctx
      dep = deploymentName ctx
      svc = serviceName ctx
      ver = newVersion ctx
      selector = "app=" <> T.unpack svc <> ",version=" <> T.unpack ver
      podNameCmd =
        unwords
          [ kubectlBin cfg,
            "-n",
            shellQuote ns,
            "get pods",
            "--selector=" <> selector,
            "--sort-by=.metadata.creationTimestamp",
            "-o",
            "jsonpath={.items[-1:].metadata.name}"
          ]
      logCmd podName =
        unwords
          [ kubectlBin cfg,
            "-n",
            shellQuote ns,
            "logs",
            shellQuote podName,
            "--tail=100",
            "--previous",
            "2>/dev/null",
            "||",
            kubectlBin cfg,
            "-n",
            shellQuote ns,
            "logs",
            shellQuote podName,
            "--tail=100"
          ]
  logInfoS $ "  Fetching pod logs for " <> dep <> " (last 100 lines)"
  podResult <- liftIO $ runCmd podNameCmd
  case podResult of
    Left (K8sError err) ->
      insertReleaseEvent
        rid
        "BUSINESS"
        "POD_LOGS_FAILED"
        (object ["error" .= ("Could not list pods: " <> err)])
    Right (K8sResult podName)
      | T.null (T.strip podName) ->
          insertReleaseEvent
            rid
            "BUSINESS"
            "POD_LOGS_FAILED"
            (object ["error" .= ("No pods found for deployment " <> dep)])
    Right (K8sResult podName) -> do
      let pn = T.strip podName
      logsResult <- liftIO $ runCmd (logCmd pn)
      case logsResult of
        Left (K8sError err) ->
          insertReleaseEvent
            rid
            "BUSINESS"
            "POD_LOGS_FAILED"
            (object ["pod" .= pn, "error" .= err])
        Right (K8sResult logs) ->
          insertReleaseEvent
            rid
            "BUSINESS"
            "POD_LOGS"
            (object ["pod" .= pn, "deployment" .= dep, "logs" .= logs])

-- | Monitor health: poll replica status for stabilisation period
monitorHealth :: StateFlow ()
monitorHealth = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  logInfoS $ "MONITORING health for scheduler " <> appGroup rt

  updateK8sStatus BSMonitoring
  logInfoS "  MONITORING pod health metrics"

  updateK8sStatus BSStabilize
  logInfoS "  Stabilization period (30s)"
  let checks = 6 :: Int -- 6 * 5s = 30s
  forM_ [1 .. checks] $ \i -> do
    liftIO $ threadDelaySec 5
    (ready, _available, desired) <-
      runK8sIO $
        getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
    logInfoS $
      "    Check "
        <> T.pack (show i)
        <> "/"
        <> T.pack (show checks)
        <> ": ready="
        <> T.pack (show ready)
        <> "/"
        <> T.pack (show desired)

  logInfoS "Health monitoring complete for scheduler"

-- | Cleanup old version: optionally delete old deployment and its HPA
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  logInfoS $ "Cleaning up old version for scheduler " <> appGroup rt

  updateK8sStatus BSScaleDownOld
  let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
      oldHpaName = oldDepName <> "-hpa"

  -- Clean up old deployment's HPA if it exists
  oldHpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
  when oldHpaFound $ do
    logInfoS $ "  Deleting old HPA: " <> oldHpaName
    _ <- runK8sIO $ runCmd (buildDeleteHpaCommand cfg (namespace ctx) oldHpaName)
    pure ()

  -- Scale old deployment to 0 replicas (keep the resource so revert can
  -- scale it back up). Deleting the deployment outright would block any
  -- future revert because the workflow needs the old deployment present
  -- (see revertReleaseH's deploymentExists check). Matches what
  -- BackendServiceWorkflow does for backend services.
  shouldScaleDown <- isScaleDownPodsOnCompletion
  when shouldScaleDown $ do
    logInfoS $ "  Scaling old deployment to 0: " <> oldDepName
    _ <- runK8sIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) oldDepName 0)
    pure ()

  -- Capture AFTER snapshot (new deployment)
  cfgAfter <- getCfg
  rtAfter <- getRT
  ctxAfter <- getK8sCtx
  captureDeploymentSnapshot cfgAfter (releaseId rtAfter) (namespace ctxAfter) (deploymentName ctxAfter) "DEPLOYMENT_AFTER"

  logInfoS "Cleanup complete for scheduler"

-- | Notify complete
notifyComplete :: StateFlow ()
notifyComplete = do
  rt <- getRT
  updateK8sStatus BSDone

  logInfoS $ "Release " <> releaseId rt <> " completed successfully!"
  logInfoS $ "   Service: " <> appGroup rt
  logInfoS $ "   Category: BackendScheduler"
  logInfoS $ "   Status: COMPLETED"

  updateRT $ \r -> r {status = COMPLETED}

  -- Notify Slack
  currentTS <- gets targetState
  lift $ notifyReleaseCompleted rt currentTS

-- ============================================================================
-- K8s State Helpers
-- ============================================================================

-- | Update K8s workflow status
updateK8sStatus :: BackendServiceWFStatus -> StateFlow ()
updateK8sStatus newStatus = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = k8s {categoryWorkflowStatus = newStatus}
      modify $ \s -> s {targetState = Just (K8sState k8s')}
    _ -> return ()

-- | Update K8s deployment state field
updateK8sField :: (K8sDeploymentState -> K8sDeploymentState) -> StateFlow ()
updateK8sField f = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = f k8s
      modify $ \s -> s {targetState = Just (K8sState k8s')}
    _ -> return ()
