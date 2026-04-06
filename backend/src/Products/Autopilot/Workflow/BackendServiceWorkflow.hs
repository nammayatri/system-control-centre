{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Backend service workflow (K8s deployment)
--
-- This module implements the workflow for deploying backend services to Kubernetes.
-- It uses the new type system with:
-- - ReleaseCategory (BackendService)
-- - ReleaseWFStatus (generic stages)
-- - BackendServiceWFStatus (K8s-specific sub-stages)
-- - Recorded monad for checkpoint/resume
--
-- Production parity notes (service.jl):
-- - The rollout loop is re-entrant: each poll cycle processes ONE step.
-- - Between steps the tracker is re-read from DB to catch user pause/abort.
-- - Rollout history is recorded after every completed step.
-- - AUTO mode checks decision engine; MANUAL mode only advances on cooloff.
-- - Pod counts are calculated using podsCalculationFactor and old-version ratio.
module Products.Autopilot.Workflow.BackendServiceWorkflow
  ( backendServiceWorkflow,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Config (Config (..))
-- getPodsCalculationFactor reserved for future pod-count calculation

import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (getConfig, getDBEnv)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
-- (Data.ByteString.Lazy removed - not used after refactor)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Products.Autopilot.DecisionEngine
  ( DecisionResult (..),
    PromCheckResult (..),
    checkPromQueries,
    getABDecision,
    getCombinedDecision,
    getHSDecision,
  )
-- buildDeleteDeploymentCommand removed: scale-down handled by Runner

import Products.Autopilot.EventLog (logDecisionResult, logStatusUpdated, logTrafficUpdated)
import Products.Autopilot.K8s.Deployment
  ( buildApplyFileCommand,
    buildCloneDeploymentCommand,
    buildConfigMapApplyCommand,
    buildScaleNamedDeploymentCommand,
    deploymentExists,
    getDeploymentReplicaStatus,
    serviceExists,
  )
import Products.Autopilot.K8s.DestinationRule (ensureDestinationRule)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd)
import Products.Autopilot.K8s.HPA (buildCloneHpaCommand, buildDeleteHpaCommand, hpaExists)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout, getVirtualServiceJson)
import Products.Autopilot.Notifications
  ( notifyGenericThreadMessage,
    notifyReleaseCompleted,
    notifyReleaseProgress,
  )
import Products.Autopilot.Queries.ProductService (findServiceByProductAndName, withVsLock)
import Products.Autopilot.Queries.ReleaseTracker (findReleaseTracker, insertReleaseEvent, insertReleaseTracker)
import Products.Autopilot.RuntimeConfig
  ( getCollectMetricsDelay,
    getHpaMinMaxFactor,
    getReleaseStartDelay,
    isHpaEnabledForProduct,
    isScaleDownPodsOnCompletion,
  )
-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release
  ( Decision (..),
    Mode (..),
    ReleaseStatus (..),
    ReleaseTracker (appGroup, endTime, mode, releaseId, rolloutHistory, rolloutStrategy, service, status),
    RolloutHistory (..),
    RolloutStep (..),
  )
import qualified Products.Autopilot.Types.Storage.Schema as S
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
    captureVSSnapshot,
    getRT,
    updateRT,
    (|>>),
  )
import Products.Autopilot.Workflow.Types
  ( ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
  )
import Shared.Config.Runtime (getConfigBoolForProduct)
import Prelude

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend service workflow using generic stages
backendServiceWorkflow :: ReleaseWorkFlow ()
backendServiceWorkflow = do
  INIT |>> validatePreconditions
  PREPARING |>> prepareK8sResources
  DEPLOYING |>> progressiveRollout
  MONITORING |>> monitorHealth
  FINALIZING |>> cleanupOldVersion
  DONE |>> notifyComplete

-- ============================================================================
-- Helpers: Config / Context / K8s IO
-- ============================================================================

-- | Get bootstrap config from the Flow (ReaderT) environment
getCfg :: StateFlow Config
getCfg = lift getConfig

-- | Get DBEnv from the Flow (ReaderT) environment
getDB :: StateFlow DBEnv
getDB = lift getDBEnv

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> pure (context k8s)
    _ -> liftIO $ fail "BackendServiceWorkflow: missing K8sState in targetState"

-- | Check if this is a new service release (no existing deployment)
isNewServiceRelease :: StateFlow Bool
isNewServiceRelease = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> pure (newService k8s)
    _ -> pure False

-- | Run an IO action that returns Either K8sError, lifting into StateFlow
runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
  result <- liftIO action
  case result of
    Right a -> pure a
    Left (K8sError err) -> liftIO $ fail ("K8s error: " <> T.unpack err)

-- | Apply VS rollout with a pessimistic lock around the operation.
-- Acquires vs_locked_by before the kubectl call, releases after (success or fail).
-- If the lock is already held, fails with an error (caller should retry).
runVsRolloutWithLock :: Config -> K8sReleaseContext -> Int -> Int -> StateFlow ()
runVsRolloutWithLock cfg ctx oldW newW = do
  db <- getDB
  rt <- getRT
  let lockOwner = "release:" <> releaseId rt
  result <-
    liftIO $
      withVsLock db (appGroup rt) lockOwner $
        applyVirtualServiceRollout cfg ctx oldW newW
  case result of
    Left err -> liftIO $ fail ("VS lock failed: " <> T.unpack err)
    Right (Left (K8sError k8sErr)) -> liftIO $ fail ("K8s error: " <> T.unpack k8sErr)
    Right (Right _) -> pure ()

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
  rt <- getRT
  cfg <- getCfg
  liftIO $ putStrLn $ "Validating preconditions for " <> T.unpack (appGroup rt)

  -- Initialise or update K8s deployment state
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) ->
      modify $ \s -> s{targetState = Just (K8sState (k8s{categoryWorkflowStatus = BSInit}))}
    _ -> do
      let k8sState = emptyK8sState{categoryWorkflowStatus = BSInit}
      modify $ \s -> s{targetState = Just (K8sState k8sState)}

  ctx <- getK8sCtx
  isNew <- isNewServiceRelease

  -- Check cluster reachable by verifying namespace exists
  liftIO $ putStrLn "  Checking cluster reachability"
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

  when isNew $
    liftIO $
      putStrLn "  New service release: skipping old version validation"

  -- Check internal VS (if exists) and log if found
  let internalVsName = serviceName ctx <> "-internal-vs"
  internalResult <- liftIO $ getVirtualServiceJson cfg (namespace ctx) internalVsName
  case internalResult of
    Left _ -> pure () -- No internal VS, that's fine
    Right _ -> do
      db' <- getDB
      rt' <- getRT
      liftIO $ putStrLn $ "  Internal VS found: " <> T.unpack internalVsName
      liftIO $
        insertReleaseEvent
          db'
          (releaseId rt')
          "BUSINESS"
          "INTERNAL_VS_FOUND"
          (toJSON internalVsName)

  liftIO $ putStrLn "  Cluster reachable, namespace exists"

  -- Persist state after validation (production persists status changes immediately)
  db <- getDB
  currentRT <- getRT
  currentTS <- gets targetState
  liftIO $ insertReleaseTracker db currentRT currentTS

  liftIO $ putStrLn "Preconditions validated"

-- | Prepare K8s resources: ConfigMap, clone/create deployment, service check, DestinationRule
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  db <- getDB
  isNew <- isNewServiceRelease
  liftIO $ putStrLn $ "PREPARING K8s resources for " <> T.unpack (appGroup rt) <> if isNew then " (NEW SERVICE)" else ""

  -- BEFORE snapshots are captured at release creation time (createReleaseH)
  -- so diffs are available before the workflow starts.

  -- 1. Apply ConfigMap
  updateK8sStatus BSApplyConfigMap
  liftIO $ putStrLn "  Applying ConfigMap"
  _ <- runK8sIO $ executeWithRetry cfg (buildConfigMapApplyCommand cfg ctx)
  updateK8sField (\k8s -> k8s{configMapApplied = True})

  -- 2. Create/clone deployment (skip if target already exists, e.g. checkpoint resume)
  updateK8sStatus BSCreateDeployment
  newDepExists <- liftIO $ deploymentExists cfg (namespace ctx) (deploymentName ctx)
  if newDepExists
    then liftIO $ putStrLn "  Deployment already exists, skipping create/clone"
    else
      if isNew
        then do
          -- New service: create from deploy file path or error
          case deployFilePath ctx of
            Just fp -> do
              liftIO $ putStrLn $ "  Creating new deployment from: " <> T.unpack fp
              _ <- runK8sIO $ executeWithRetry cfg (buildApplyFileCommand cfg fp)
              pure ()
            Nothing -> do
              liftIO $ putStrLn $ "  ERROR: New service requires deployFilePath"
              liftIO $ fail "New service release requires deployFilePath to create deployment from scratch"
        else do
          liftIO $ putStrLn $ "  Cloning deployment to " <> T.unpack (deploymentName ctx)
          _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentCommand cfg ctx)
          pure ()
  updateK8sField (\k8s -> k8s{deploymentCreated = True})

  -- 3. Check Service exists
  updateK8sStatus BSUpdateService
  liftIO $ putStrLn "  Checking Service exists"
  svcOk <- liftIO $ serviceExists cfg (namespace ctx) (serviceName ctx)
  when (not svcOk) $
    liftIO $
      putStrLn "  WARNING: Service not found (pods may still route via selector)"
  updateK8sField (\k8s -> k8s{serviceCreated = svcOk})

  -- 4. Ensure DestinationRule (creates if missing, adds subset if existing)
  updateK8sStatus BSApplyDestinationRule
  liftIO $ putStrLn "  Ensuring DestinationRule"
  _ <- runK8sIO $ ensureDestinationRule cfg ctx
  updateK8sField (\k8s -> k8s{destinationRuleApplied = True})

  -- 5. Clone HPA if exists for old version
  when (not isNew) $ do
    hpaEnabled <- liftIO $ isHpaEnabledForProduct db (appGroup rt)
    when hpaEnabled $ do
      let oldHpaName = serviceName ctx <> "-" <> oldVersion ctx <> "-hpa"
      hpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
      when hpaFound $ do
        liftIO $ putStrLn $ "  Cloning HPA from " <> T.unpack oldHpaName
        hpaMinMaxFactor <- liftIO $ getHpaMinMaxFactor db
        -- Get current replicas from old deployment to calculate HPA min/max
        oldReplicaResult <- liftIO $ getDeploymentReplicaStatus cfg (namespace ctx) (serviceName ctx <> "-" <> oldVersion ctx)
        let (_, _, desiredReplicas) = case oldReplicaResult of
              Right v -> v
              Left _ -> (1, 1, 1)
            hpaMin = max 1 desiredReplicas
            hpaMax = max hpaMin (round (fromIntegral desiredReplicas * hpaMinMaxFactor))
        cloneResult <- liftIO $ runCmd (buildCloneHpaCommand cfg (namespace ctx) (serviceName ctx) (oldVersion ctx) (newVersion ctx) oldHpaName hpaMin hpaMax)
        case cloneResult of
          Right _ -> do
            liftIO $ putStrLn "  HPA cloned successfully"
            updateK8sField (\k8s -> k8s{hpaCreated = True})
            liftIO $
              insertReleaseEvent
                db
                (releaseId rt)
                "BUSINESS"
                "HPA_CLONED"
                (toJSON (serviceName ctx <> "-" <> newVersion ctx <> "-hpa"))
          Left (K8sError err) -> liftIO $ putStrLn $ "  [HPA] Clone failed (non-fatal): " <> T.unpack err

  liftIO $ putStrLn "K8s resources prepared"

-- | Progressive rollout: shift traffic old -> new following the tracker's rollout_strategy.
--
-- Production parity (service.jl while-loop at line 459):
-- - Each iteration of the loop handles ONE rollout step.
-- - Re-reads the tracker from DB to catch user pause/abort/strategy changes.
-- - Records rollout history after each completed step.
-- - In MANUAL mode: only advances if cooloff exceeded (no decision engine).
-- - In AUTO mode: advances if cooloff exceeded AND decision engine says Continue.
-- - The loop blocks on collectMetricsDelay between iterations (not the full cooloff).
progressiveRollout :: StateFlow ()
progressiveRollout = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  isNew <- isNewServiceRelease
  liftIO $ putStrLn $ "Starting progressive rollout for " <> T.unpack (appGroup rt)

  updateK8sStatus BSFlipVirtualService
  updateK8sField (\k8s -> k8s{virtualServiceApplied = True})

  updateK8sStatus BSProgressiveRollout
  db <- getDB

  -- Production: sleep(getReleaseStartDelay(conn)) before starting
  releaseStartDelay <- liftIO $ getReleaseStartDelay db
  when (releaseStartDelay > 0) $ do
    liftIO $ putStrLn $ "  Release start delay: " <> show releaseStartDelay <> " seconds"
    liftIO $ threadDelay (releaseStartDelay * 1000000)

  if isNew
    then do
      -- New service: route 100% traffic to new version directly (no old version)
      liftIO $ putStrLn "  New service: routing 100% traffic to new version"
      runVsRolloutWithLock cfg ctx 0 100
      updateK8sField (\k8s -> k8s{trafficPercentage = 100})
      -- Record rollout history for the 100% step
      now <- liftIO getCurrentTime
      let histEntry = mkRolloutHistory 100 0 100 now (Just now)
      updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [histEntry]}
      currentRT <- getRT
      liftIO $ insertReleaseTracker db currentRT (Just (K8sState (emptyK8sState{context = ctx, trafficPercentage = 100})))
      liftIO $ notifyReleaseProgress db currentRT 100
    else do
      -- Use the tracker's rollout strategy (e.g. 5%/25%/50%/75%/100% with cooloffs)
      -- If rollout strategy is empty, fallback to a single 100% step
      let strategy = case rolloutStrategy rt of
            [] -> [RolloutStep 100 0 1]
            ss -> ss
          totalSteps = length strategy
          existingHistory = rolloutHistory rt
          alreadyStarted = not (null existingHistory)

      -- Resume from existing history if workflow was restarted (e.g., after VS lock failure)
      if alreadyStarted
        then do
          let currentIndex = length existingHistory
          liftIO $ putStrLn $ "  Resuming rollout from step " <> show currentIndex <> "/" <> show totalSteps
          now <- liftIO getCurrentTime
          rolloutLoop cfg ctx db strategy currentIndex totalSteps now
        else do
          -- Apply first step immediately (production line 359: getInitialCoolOffAndRoutingPercentage)
          let firstStep = head strategy
              firstNewW = rolloutPercent firstStep
              firstOldW = max 0 (100 - firstNewW)
          liftIO $ putStrLn $ "  Initial rollout step: new=" <> show firstNewW <> "%, cooloff=" <> show (cooloffMinutes firstStep) <> "min"
          runVsRolloutWithLock cfg ctx firstOldW firstNewW
          updateK8sField (\k8s -> k8s{trafficPercentage = firstNewW})

          -- Record rollout history for first step
          stepStartTime <- liftIO getCurrentTime
          let firstHist = mkRolloutHistory firstNewW (cooloffMinutes firstStep) (podPercent firstStep) stepStartTime Nothing
          updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [firstHist]}
          currentRT <- getRT
          liftIO $ insertReleaseTracker db currentRT (Just (K8sState (emptyK8sState{context = ctx, trafficPercentage = firstNewW})))
          liftIO $ notifyReleaseProgress db currentRT firstNewW
          -- Production parity: BUSINESS / TRAFFIC_UPDATED with previous_rollout=0 for first step
          liftIO $ logTrafficUpdated db currentRT 0

          -- Production while-loop: iterate through remaining steps with re-entrant checks
          -- index starts at 1 (0-based), first step already applied
          rolloutLoop cfg ctx db strategy 1 totalSteps stepStartTime

  liftIO $ putStrLn "Progressive rollout complete"

-- | Re-entrant rollout loop matching production's while-true loop (service.jl line 459).
--
-- Each iteration:
-- 1. Re-reads tracker from DB (catches user pause/abort/strategy change)
-- 2. Checks if tracker is in terminal state (abort/complete)
-- 3. If cooloff exceeded for current step: advance to next step
-- 4. If all steps done: mark as complete
-- 5. Otherwise: sleep collectMetricsDelay and loop
rolloutLoop :: Config -> K8sReleaseContext -> DBEnv -> [RolloutStep] -> Int -> Int -> UTCTime -> StateFlow ()
rolloutLoop cfg ctx db strategy currentIndex totalSteps stepStartTime = do
  -- Production line 460: tracker = get_release_from_id(conn, tracker.id)[1]
  rt <- getRT
  freshResult <- liftIO $ findReleaseTracker db (releaseId rt)
  case freshResult of
    Nothing -> do
      liftIO $ putStrLn "  [rolloutLoop] Tracker deleted from DB, aborting"
      liftIO $ fail "Tracker deleted during rollout"
    Just (freshRT, freshMts) -> do
      -- Sync our in-memory state with what the DB has
      updateRT $ \_ -> freshRT
      case freshMts of
        Just ts -> modify $ \s -> s{targetState = Just ts}
        Nothing -> pure ()

      -- Production line 462: isTrackerInTerminalState!
      case status freshRT of
        ABORTING -> do
          liftIO $ putStrLn $ "  [rolloutLoop] Release " <> T.unpack (releaseId freshRT) <> " is aborting, exiting workflow. Runner will handle cleanup."
          liftIO $ fail "Release aborted by user — runner will restore traffic"
        USER_ABORTED -> do
          liftIO $ putStrLn "  [rolloutLoop] Tracker is USER_ABORTED, stopping rollout"
          liftIO $ fail "Release user-aborted during rollout"
        ABORTED -> do
          liftIO $ putStrLn "  [rolloutLoop] Tracker is ABORTED, stopping rollout"
          liftIO $ fail "Release aborted during rollout"
        COMPLETED -> do
          liftIO $ putStrLn "  [rolloutLoop] Tracker is COMPLETED (externally), finishing"
          pure ()
        PAUSED -> do
          -- Production line 195: if isReleasePaused(tracker) return (routePercent, coolOff, podsCount)
          liftIO $ putStrLn "  [rolloutLoop] Tracker is PAUSED, waiting..."
          collectDelay <- liftIO $ getCollectMetricsDelay db
          liftIO $ threadDelay (collectDelay * 1000000)
          rolloutLoop cfg ctx db strategy currentIndex totalSteps stepStartTime
        INPROGRESS -> do
          -- Check AUTO vs MANUAL mode behavior
          let currentMode = mode freshRT
          -- Production line 197: MANUAL calls getNewRollout directly
          -- Production line 199-238: AUTO checks decision engine first
          -- We implement both paths

          if currentIndex >= totalSteps
            then do
              -- All steps complete - production line 134-181: final completion
              liftIO $ putStrLn "  [rolloutLoop] All rollout steps completed"
              -- Update final rollout history entry with completion time
              now <- liftIO getCurrentTime
              let curHistory = rolloutHistory freshRT
              when (not (null curHistory)) $ do
                let lastH = last curHistory
                    updatedLast = lastH{historyCompletedAt = Just now, historyDecision = Just Continue}
                    updatedHistory = init curHistory <> [updatedLast]
                updateRT $ \r -> r{rolloutHistory = updatedHistory}
                currentRT <- getRT
                liftIO $ insertReleaseTracker db currentRT freshMts
              pure ()
            else do
              -- Check if cooloff has elapsed for current step
              -- Reads from rollout strategy (fast-forward sets strategy cooloff to 0)
              now <- liftIO getCurrentTime
              let currentStep = (rolloutStrategy freshRT) !! (currentIndex - 1)
                  cooloffMins = cooloffMinutes currentStep
                  elapsed = diffUTCTime now stepStartTime
                  cooloffSecs = fromIntegral cooloffMins * 60 :: Double
                  cooloffExceeded = realToFrac elapsed >= cooloffSecs

              if not cooloffExceeded
                then do
                  -- Cooloff not exceeded, sleep and re-check
                  -- Production line 518: sleep(getCollectMetricsDelay(conn))
                  collectDelay <- liftIO $ getCollectMetricsDelay db
                  liftIO $ threadDelay (collectDelay * 1000000)
                  rolloutLoop cfg ctx db strategy currentIndex totalSteps stepStartTime
                else do
                  -- Cooloff exceeded - decide whether to advance
                  shouldAdvance <- case currentMode of
                    MANUAL -> do
                      -- MANUAL: advance if cooloff exceeded and status is INPROGRESS
                      -- Production line 128: isCoolOffExceeded && tracker.status == INPROGRESS
                      liftIO $ putStrLn "  [rolloutLoop] MANUAL mode: cooloff exceeded, advancing"
                      pure True
                    AUTO -> do
                      -- AUTO: check health/decision engine first
                      -- Production lines 520-553: collect metrics, get decision
                      liftIO $ putStrLn "  [rolloutLoop] AUTO mode: checking health before advancing"
                      checkDeploymentHealth cfg ctx

                      -- 1. Prometheus query checks
                      mSvcConfig <- liftIO $ findServiceByProductAndName db (appGroup freshRT) (service freshRT)
                      let mDecisionConfig = mSvcConfig >>= S.dcDecisionConfig
                      promResult <- liftIO $ checkPromQueries db cfg freshRT mDecisionConfig
                      case promResult of
                        PromAbort reason -> do
                          liftIO $ putStrLn $ "[DECISION] Prometheus ABORT: " <> T.unpack reason
                          -- Production parity (service.jl:203): NOTIFICATION / STATUS_UPDATED
                          liftIO $ logStatusUpdated db freshRT ("ABORTING the release because prom query checks failing: " <> reason)
                          liftIO $ notifyGenericThreadMessage db freshRT ("Prometheus check ABORT: " <> reason)
                          updateRT $ \r -> r{status = ABORTING}
                          currentRT' <- getRT
                          currentTS' <- gets targetState
                          liftIO $ insertReleaseTracker db currentRT' currentTS'
                          liftIO $ fail ("Prometheus ABORT: " <> T.unpack reason)
                        PromWarn reason -> do
                          liftIO $ putStrLn $ "[DECISION] Prometheus WARN: " <> T.unpack reason
                          -- Production parity (service.jl:206-208): Slack only, no DB event
                          liftIO $ notifyGenericThreadMessage db freshRT ("Prometheus warning: " <> reason)
                        -- Continue despite warning
                        PromOK -> pure ()

                      -- 2. AB Decision
                      abDecision <- liftIO $ getABDecision db cfg freshRT
                      -- 3. HS Decision (pre-monitoring)
                      hsDecision <- liftIO $ getHSDecision db cfg freshRT False

                      -- Log combined decision event
                      let combinedDecision = getCombinedDecision abDecision hsDecision
                          abReasonText = maybe "" id (drReason abDecision)
                          hsReasonText = maybe "" id (drReason hsDecision)
                          combinedReasons = filter (not . T.null) [abReasonText, hsReasonText]
                          combinedResultText =
                            "AB=" <> T.pack (show (drDecision abDecision))
                              <> " HS="
                              <> T.pack (show (drDecision hsDecision))

                      -- Production parity (service.jl:548): write decision fields into
                      -- the last rollout history entry BEFORE emitting DECISION_RESULT,
                      -- so the embedded rollout_history in the event shows the decision.
                      -- Do this for Continue, Wait AND Abort paths.
                      let curHistoryDR = rolloutHistory freshRT
                      when (not (null curHistoryDR)) $ do
                        let lastHDR = last curHistoryDR
                            updatedLastDR =
                              lastHDR
                                { historyDecision = Just combinedDecision,
                                  historyDecisionReason = Just combinedResultText,
                                  historyDecisionHs = Just (drDecision hsDecision),
                                  historyDecisionHsReason = drReason hsDecision
                                }
                            updatedHistoryDR = init curHistoryDR <> [updatedLastDR]
                        updateRT $ \r -> r{rolloutHistory = updatedHistoryDR}
                        currentRTDR <- getRT
                        currentTSDR <- gets targetState
                        liftIO $ insertReleaseTracker db currentRTDR currentTSDR

                      -- Read back so the event payload sees the updated history
                      rtForEvent <- getRT
                      liftIO $ logDecisionResult db rtForEvent combinedDecision combinedResultText combinedReasons

                      case combinedDecision of
                        Continue -> pure True -- advance
                        Wait -> pure False -- stay at current step, re-loop
                        Abort -> do
                          -- Production parity (service.jl:213): first STATUS_UPDATED
                          liftIO $ logStatusUpdated db rtForEvent "ABORTING the release because of the Decision Engine"
                          updateRT $ \r -> r{status = ABORTING}
                          currentRT' <- getRT
                          currentTS' <- gets targetState
                          liftIO $ insertReleaseTracker db currentRT' currentTS'
                          -- Production parity (service.jl:222): second STATUS_UPDATED for rollback
                          liftIO $ logStatusUpdated db currentRT' ("Rolling back the traffic to version " <> oldVersion ctx)
                          liftIO $ fail "Decision engine: ABORT"

                  if shouldAdvance
                    then do
                      -- Complete current step in rollout history
                      -- Production line 481: updateTrackerRolloutHistory
                      -- Decision was Continue (otherwise we wouldn't advance)
                      let curHistory = rolloutHistory freshRT
                      when (not (null curHistory)) $ do
                        let lastH = last curHistory
                            updatedLast =
                              lastH{historyCompletedAt = Just now,
                                    historyDecision = Just Continue
                                   }
                            updatedHistory = init curHistory <> [updatedLast]
                        updateRT $ \r -> r{rolloutHistory = updatedHistory}

                      -- Apply next step
                      -- Production line 129: index = index + 1
                      let nextStep = strategy !! currentIndex
                          nextNewW = rolloutPercent nextStep
                          nextOldW = max 0 (100 - nextNewW)
                          -- Capture previous rollout % before we append the new history entry
                          previousRolloutW =
                            case rolloutHistory freshRT of
                              [] -> 0
                              xs -> historyRolloutPercent (last xs)
                      liftIO $
                        putStrLn $
                          "  Rollout step "
                            <> show (currentIndex + 1)
                            <> "/"
                            <> show totalSteps
                            <> ": new="
                            <> show nextNewW
                            <> "%, cooloff="
                            <> show (cooloffMinutes nextStep)
                            <> "min"

                      -- Apply VS rollout with lock
                      runVsRolloutWithLock cfg ctx nextOldW nextNewW
                      updateK8sField (\k8s -> k8s{trafficPercentage = nextNewW})

                      -- Record new rollout history entry
                      -- Production line 489: setRolloutHistory!(tracker, push!(...))
                      newStepStart <- liftIO getCurrentTime
                      let newHist = mkRolloutHistory nextNewW (cooloffMinutes nextStep) (podPercent nextStep) newStepStart Nothing
                      updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [newHist]}

                      -- Persist to DB
                      currentRT <- getRT
                      currentTS <- gets targetState
                      liftIO $ insertReleaseTracker db currentRT currentTS

                      -- Notify Slack
                      liftIO $ notifyReleaseProgress db currentRT nextNewW
                      -- Production parity: BUSINESS / TRAFFIC_UPDATED
                      liftIO $ logTrafficUpdated db currentRT previousRolloutW

                      -- Check health after applying step
                      when (nextNewW < 100) $
                        checkDeploymentHealth cfg ctx

                      -- Continue loop with next index
                      rolloutLoop cfg ctx db strategy (currentIndex + 1) totalSteps newStepStart
                    else do
                      -- Decision engine said wait/abort - re-loop
                      collectDelay <- liftIO $ getCollectMetricsDelay db
                      liftIO $ threadDelay (collectDelay * 1000000)
                      rolloutLoop cfg ctx db strategy currentIndex totalSteps stepStartTime
        _ -> do
          -- Unexpected status during rollout
          liftIO $ putStrLn $ "  [rolloutLoop] Unexpected status: " <> show (status freshRT) <> ", stopping"
          liftIO $ fail $ "Unexpected tracker status during rollout: " <> show (status freshRT)

-- | Create a RolloutHistory entry (matches production RolloutHistory struct)
mkRolloutHistory :: Int -> Int -> Int -> UTCTime -> Maybe UTCTime -> RolloutHistory
mkRolloutHistory rollout cooloff pods startedAt completedAt =
  RolloutHistory
    { historyRolloutPercent = rollout,
      historyCooloffMinutes = cooloff,
      historyPodsPercent = pods,
      historyDecision = Nothing,
      historyDecisionReason = Nothing,
      historyStartedAt = startedAt,
      historyCompletedAt = completedAt,
      historyManualOverride = False,
      historyDecisionHs = Nothing,
      historyDecisionHsReason = Nothing
    }

-- | Check deployment health via replica status
checkDeploymentHealth :: Config -> K8sReleaseContext -> StateFlow ()
checkDeploymentHealth cfg ctx = do
  (ready, available, desired) <-
    runK8sIO $
      getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
  liftIO $
    putStrLn $
      "    Health: ready="
        <> show ready
        <> " available="
        <> show available
        <> " desired="
        <> show desired
  when (ready < desired) $
    liftIO $
      putStrLn "    WARNING: Not all replicas ready yet"

-- | Monitor health: poll pods until all are Running+Ready, max 5 minutes
monitorHealth :: StateFlow ()
monitorHealth = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  db <- getDB
  liftIO $ putStrLn $ "MONITORING health for " <> T.unpack (appGroup rt)

  updateK8sStatus BSMonitoring
  liftIO $ putStrLn "  Waiting for pods to be ready (max 5 min, polling every 10s)"

  updateK8sStatus BSStabilize
  let maxAttempts = 30 :: Int -- 30 * 10s = 300s = 5 minutes
  waitResult <- liftIO $ waitForPodsReady cfg ctx maxAttempts
  case waitResult of
    Left errMsg -> do
      liftIO $ putStrLn $ "  Pod readiness check FAILED: " <> T.unpack errMsg
      liftIO $ fail ("Pod readiness check failed: " <> T.unpack errMsg)
    Right () ->
      liftIO $ putStrLn "  All pods ready"

  -- Post-monitoring: after all pods are healthy at 100%, check HS decision
  postMonitoringEnabled <- liftIO $ getConfigBoolForProduct db "ab_hs_post_monitoring_enabled" (Just (appGroup rt)) False
  when postMonitoringEnabled $ do
    liftIO $ putStrLn "[WORKFLOW] Starting post-monitoring phase"
    liftIO $
      insertReleaseEvent
        db
        (releaseId rt)
        "BUSINESS"
        "POST_MONITORING_STARTED"
        (toJSON ("Post-monitoring phase" :: T.Text))
    postMonitorLoop cfg db rt 0

  liftIO $ putStrLn "Health monitoring complete"

-- | Post-monitoring loop: poll HS decision engine after 100% traffic.
-- Max 30 iterations with collectMetricsDelay between polls.
postMonitorLoop :: Config -> DBEnv -> ReleaseTracker -> Int -> StateFlow ()
postMonitorLoop cfg db rt iteration = do
  if iteration > 30
    then do
      liftIO $ putStrLn "[WORKFLOW] Post-monitoring: max iterations reached, continuing"
      liftIO $
        insertReleaseEvent
          db
          (releaseId rt)
          "DECISION_ENGINE"
          "POST_MONITORING_TIMEOUT"
          (object ["iterations" .= (iteration :: Int)])
    else do
      hsResult <- liftIO $ getHSDecision db cfg rt True -- isPostMonitoring=True
      liftIO $
        insertReleaseEvent
          db
          (releaseId rt)
          "DECISION_ENGINE"
          "POST_MONITORING_POLL"
          ( object
              [ "iteration" .= iteration,
                "decision" .= show (drDecision hsResult),
                "reason" .= drReason hsResult
              ]
          )
      case drDecision hsResult of
        Continue -> do
          liftIO $ putStrLn "[WORKFLOW] Post-monitoring: CONTINUE"
          liftIO $
            insertReleaseEvent
              db
              (releaseId rt)
              "DECISION_ENGINE"
              "POST_MONITORING_RESULT"
              (object ["decision" .= ("Continue" :: T.Text)])
        Abort -> do
          liftIO $ putStrLn "[WORKFLOW] Post-monitoring: ABORT"
          liftIO $
            insertReleaseEvent
              db
              (releaseId rt)
              "DECISION_ENGINE"
              "POST_MONITORING_RESULT"
              (object ["decision" .= ("Abort" :: T.Text), "reason" .= drReason hsResult])
          liftIO $ notifyGenericThreadMessage db rt ("Post-monitoring ABORT: " <> maybe "no reason" id (drReason hsResult))
          updateRT $ \r -> r{status = ABORTING}
          currentRT <- getRT
          currentTS <- gets targetState
          liftIO $ insertReleaseTracker db currentRT currentTS
          liftIO $ fail "Post-monitoring ABORT"
        Wait -> do
          collectDelay <- liftIO $ getCollectMetricsDelay db
          liftIO $ threadDelay (collectDelay * 1000000)
          postMonitorLoop cfg db rt (iteration + 1)

-- | Poll pods until all are Running+Ready or timeout/failure
waitForPodsReady :: Config -> K8sReleaseContext -> Int -> IO (Either T.Text ())
waitForPodsReady cfg ctx maxAttempts = go 0
  where
    go attempt
      | attempt >= maxAttempts = pure (Left "Timeout waiting for pods to be ready (5 min)")
      | otherwise = do
        threadDelay 10000000 -- 10 seconds
        (readyCount, _available, desired) <- do
          result <- getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
          case result of
            Left _ -> pure (0, 0, 1)
            Right vals -> pure vals
        putStrLn $
          "    Poll "
            <> show (attempt + 1)
            <> "/"
            <> show maxAttempts
            <> ": ready="
            <> show readyCount
            <> "/"
            <> show desired

        -- Check for pod-level failures (CrashLoopBackOff, ImagePullBackOff, etc.)
        podHealth <- checkPodHealthDetailed cfg ctx
        case podHealth of
          Left errMsg -> do
            putStrLn $ "    Pod health check FAILED: " <> T.unpack errMsg
            pure (Left errMsg)
          Right msg -> do
            putStrLn $ "    Pod health: " <> T.unpack msg
            if readyCount >= desired && desired > 0
              then pure (Right ())
              else go (attempt + 1)

-- | Detailed pod health check: restart count, CrashLoopBackOff, ImagePullBackOff
-- Returns Left errorMessage if pods are unhealthy, Right statusMessage if OK.
checkPodHealthDetailed :: Config -> K8sReleaseContext -> IO (Either T.Text T.Text)
checkPodHealthDetailed cfg ctx = do
  let svcHost = serviceName ctx
      version = newVersion ctx
      ns = namespace ctx
      cmd =
        unwords
          [ kubectlBin cfg,
            "-n",
            T.unpack ns,
            "get pods",
            "-l",
            "app=" <> T.unpack svcHost <> ",version=" <> T.unpack version,
            "-o",
            "json"
          ]
  result <- runCmd cmd
  case result of
    Left _ -> pure (Right "Could not fetch pod status (non-fatal)")
    Right (K8sResult jsonStr) ->
      case A.decodeStrict' (TE.encodeUtf8 jsonStr) :: Maybe Value of
        Nothing -> pure (Right "Could not parse pod JSON (non-fatal)")
        Just podJson -> pure (analyzePodHealth podJson)

-- | Analyze pod health from kubectl JSON output
analyzePodHealth :: Value -> Either T.Text T.Text
analyzePodHealth (Object root) =
  case KM.lookup (K.fromText "items") root of
    Just (Array items) ->
      let podResults = map checkSinglePod (foldr (:) [] items)
          errors = [e | Left e <- podResults]
       in if null errors
            then Right ("All " <> T.pack (show (length podResults)) <> " pod(s) healthy")
            else Left (T.intercalate "; " errors)
    _ -> Right "No pods found (non-fatal)"
analyzePodHealth _ = Right "Unexpected JSON format (non-fatal)"

-- | Check a single pod for unhealthy conditions
checkSinglePod :: Value -> Either T.Text T.Text
checkSinglePod (Object podObj) =
  let podName = case KM.lookup (K.fromText "metadata") podObj >>= getObj' "name" of
        Just n -> n
        Nothing -> "unknown-pod"
      statusObj = KM.lookup (K.fromText "status") podObj
      phase =
        statusObj >>= \case
          Object s -> case KM.lookup (K.fromText "phase") s of
            Just (String p) -> Just p
            _ -> Nothing
          _ -> Nothing
      containerStatuses =
        statusObj >>= \case
          Object s -> case KM.lookup (K.fromText "containerStatuses") s of
            Just (Array cs) -> Just (foldr (:) [] cs)
            _ -> Nothing
          _ -> Nothing
      -- Check for bad container states
      containerErrors = case containerStatuses of
        Nothing -> []
        Just cs -> concatMap (checkContainer podName) cs
   in case phase of
        Just "Failed" -> Left (podName <> ": pod phase is Failed")
        _ ->
          if null containerErrors
            then Right (podName <> ": OK")
            else Left (T.intercalate "; " containerErrors)
  where
    getObj' key (Object o) = case KM.lookup (K.fromText key) o of
      Just (String t) -> Just t
      _ -> Nothing
    getObj' _ _ = Nothing

    checkContainer podName (Object cObj) =
      let restartCount = case KM.lookup (K.fromText "restartCount") cObj of
            Just (Number n) -> round n :: Int
            _ -> 0
          waitingReason = case KM.lookup (K.fromText "state") cObj of
            Just (Object stateObj) -> case KM.lookup (K.fromText "waiting") stateObj of
              Just (Object waitObj) -> case KM.lookup (K.fromText "reason") waitObj of
                Just (String r) -> Just r
                _ -> Nothing
              _ -> Nothing
            _ -> Nothing
          errs =
            []
              <> [podName <> ": CrashLoopBackOff detected" | waitingReason == Just "CrashLoopBackOff"]
              <> [podName <> ": ImagePullBackOff detected" | waitingReason == Just "ImagePullBackOff"]
              <> [podName <> ": ErrImagePull detected" | waitingReason == Just "ErrImagePull"]
              <> [podName <> ": restartCount=" <> T.pack (show restartCount) <> " exceeds threshold (3)" | restartCount > 3]
       in errs
    checkContainer _ _ = []
checkSinglePod _ = Right "unknown"

-- | Cleanup old version.
--
-- Production parity (releaseCompletionActions, line 558-596):
-- - Records end time on the tracker
-- - Schedules scale-down of old pods (done by Runner's scaleDownOldDeployment on next poll)
-- rather than scaling down immediately
-- - Only scales down immediately if scale_down_pods_on_completion is enabled
-- - Captures AFTER snapshots for diff
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
  rt <- getRT
  cfg <- getCfg
  ctx <- getK8sCtx
  isNew <- isNewServiceRelease
  db <- getDB
  liftIO $ putStrLn $ "Cleaning up old version for " <> T.unpack (appGroup rt)

  updateK8sStatus BSScaleDownOld

  -- Production line 559: update_release_end_time!(conn, tracker)
  now <- liftIO getCurrentTime
  updateRT $ \r -> r{endTime = Just now}

  if isNew
    then do
      -- New service: no old deployment to clean up
      liftIO $ putStrLn "  New service: no old deployment to clean up"
      updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})
    else do
      let oldDepName = serviceName ctx <> "-" <> oldVersion ctx

      -- Production line 560: scheduleScaleDownOfPods(tracker, conn)
      -- This schedules scale-down to happen later via the Runner's poll loop.
      -- The Runner's findCompletedTrackersForScaleDown + scaleDownOldDeployment handles this.
      -- We mark the intent so the Runner knows to scale down.
      liftIO $ putStrLn $ "  Scheduling scale-down for old deployment: " <> T.unpack oldDepName
      updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = False})
      liftIO $
        insertReleaseEvent
          db
          (releaseId rt)
          "BUSINESS"
          "SCALE_DOWN_SCHEDULED"
          (toJSON $ "Scale-down scheduled for " <> T.unpack oldDepName)

      -- If scale_down_pods_on_completion is enabled, do it immediately too
      -- (production has this commented out but the Runner handles it)
      -- NOTE: Slack notification for pods scaled down is sent ONLY from the Runner's
      -- scaleDownOldDeployment on actual success — not here (avoids duplicates).
      shouldScaleDownNow <- liftIO $ isScaleDownPodsOnCompletion db
      when shouldScaleDownNow $ do
        liftIO $ putStrLn $ "  Immediate scale-down: " <> T.unpack oldDepName
        _ <- runK8sIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) oldDepName 0)
        updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})

      -- Delete old version's HPA so a revert can re-create it cleanly and
      -- we don't leak HPAs across releases. Mirrors prepareK8sResources
      -- which clones the HPA when isHpaEnabledForProduct; only attempt the
      -- delete if one actually exists (no-op when HPA was never created).
      -- Julia parity (service.jl:138-154 — cleanup of old-version HPA post
      -- rollout).
      let oldHpaName = serviceName ctx <> "-" <> oldVersion ctx <> "-hpa"
      oldHpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
      when oldHpaFound $ do
        liftIO $ putStrLn $ "  Deleting old HPA: " <> T.unpack oldHpaName
        deleteResult <- liftIO $ runCmd (buildDeleteHpaCommand cfg (namespace ctx) oldHpaName)
        case deleteResult of
          Right _ -> do
            liftIO $ putStrLn "  Old HPA deleted"
            liftIO $
              insertReleaseEvent
                db
                (releaseId rt)
                "BUSINESS"
                "HPA_DELETED"
                (toJSON oldHpaName)
          Left err ->
            liftIO $ putStrLn $ "  WARNING: Failed to delete old HPA: " <> show err

  -- Capture AFTER snapshots
  cfgAfter <- getCfg
  dbAfter <- getDB
  rtAfter <- getRT
  ctxAfter <- getK8sCtx
  liftIO $ captureDeploymentSnapshot cfgAfter dbAfter (releaseId rtAfter) (namespace ctxAfter) (deploymentName ctxAfter) "DEPLOYMENT_AFTER"

  liftIO $ putStrLn "Cleanup complete"

-- | Notify complete.
--
-- Production parity (service.jl line 176 + releaseCompletionActions):
-- - Sets tracker status to COMPLETED
-- - Records completion event
-- - Persists final state to DB
-- - Notifies Slack
notifyComplete :: StateFlow ()
notifyComplete = do
  rt <- getRT
  db <- getDB
  updateK8sStatus BSDone

  liftIO $ putStrLn $ "Release " <> T.unpack (releaseId rt) <> " completed successfully!"
  liftIO $ putStrLn $ "   Service: " <> T.unpack (appGroup rt)
  liftIO $ putStrLn $ "   Category: BackendService"
  liftIO $ putStrLn $ "   Status: COMPLETED"

  -- Production line 176: update_tracker_status!(conn, COMPLETED, tracker)
  now <- liftIO getCurrentTime
  updateRT $ \r -> r{status = COMPLETED, endTime = Just now}

  -- Persist final state to DB immediately (production does this in update_tracker_status!)
  currentRT <- getRT
  currentTS <- gets targetState
  liftIO $ insertReleaseTracker db currentRT currentTS

  -- Log completion event
  -- Production parity: NOTIFICATION / STATUS_UPDATED
  let completionMsg = "Tracker marked as COMPLETED with " <> T.pack (show (getTrafficPct currentTS)) <> "% traffic"
  liftIO $ logStatusUpdated db currentRT completionMsg

  -- Notify Slack
  liftIO $ notifyReleaseCompleted db currentRT
  where
    getTrafficPct Nothing = 100 :: Int
    getTrafficPct (Just (K8sState k8s)) = trafficPercentage k8s
    getTrafficPct _ = 100

-- ============================================================================
-- K8s State Helpers
-- ============================================================================

-- | Update K8s workflow status
updateK8sStatus :: BackendServiceWFStatus -> StateFlow ()
updateK8sStatus newStatus = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = k8s{categoryWorkflowStatus = newStatus}
      modify $ \s -> s{targetState = Just (K8sState k8s')}
    _ -> return ()

-- | Update K8s deployment state field
updateK8sField :: (K8sDeploymentState -> K8sDeploymentState) -> StateFlow ()
updateK8sField f = do
  rs <- gets id
  case targetState rs of
    Just (K8sState k8s) -> do
      let k8s' = f k8s
      modify $ \s -> s{targetState = Just (K8sState k8s')}
    _ -> return ()
