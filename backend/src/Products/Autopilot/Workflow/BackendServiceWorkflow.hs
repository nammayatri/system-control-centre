{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Backend service workflow (K8s deployment)

This module implements the workflow for deploying backend services to Kubernetes.
It uses the new type system with:
- ReleaseCategory (BackendService)
- ReleaseWFStatus (generic stages)
- BackendServiceWFStatus (K8s-specific sub-stages)
- Recorded monad for checkpoint/resume

Production parity notes (service.jl):
- The rollout loop is re-entrant: each poll cycle processes ONE step.
- Between steps the tracker is re-read from DB to catch user pause/abort.
- Rollout history is recorded after every completed step.
- AUTO mode checks decision engine; MANUAL mode only advances on cooloff.
- Pod counts are calculated using podsCalculationFactor and old-version ratio.
-}
module Products.Autopilot.Workflow.BackendServiceWorkflow (
    backendServiceWorkflow,
)
where

import Control.Exception (throwIO)
import Control.Applicative ((<|>))
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import qualified Control.Concurrent as CC
import Core.Types.Time (Seconds (..), threadDelay)

-- getPodsCalculationFactor reserved for future pod-count calculation

import Core.Environment (getConfig, getLoggerEnv, logError, logInfo, logWarning)
import Core.Logging (LoggerEnv, logErrorIO, logInfoIO)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.Text as T

-- (Data.ByteString.Lazy removed - not used after refactor)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Products.Autopilot.DecisionEngine (
    DecisionResult (..),
    PromCheckResult (..),
    checkPromQueries,
    getABDecision,
    getCombinedDecision,
    getHSDecision,
    initiateABDecisionForRelease,
 )

-- buildDeleteDeploymentCommand removed: scale-down handled by Runner

import Products.Autopilot.EventLog (logDecisionResult, logStatusUpdated, logTrafficUpdated)
import Products.Autopilot.K8s.Deployment (
    buildApplyFileCommand,
    buildCloneDeploymentCommand,
    buildConfigMapApplyCommand,
    buildScaleDeploymentCommand,
    buildScaleNamedDeploymentCommand,
    deploymentExists,
    getDeploymentReplicaStatus,
    serviceExists,
 )
import Products.Autopilot.K8s.DestinationRule (ensureDestinationRule)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd)
import Products.Autopilot.K8s.HPA (buildCloneHpaCommand, buildCreateHpaFromTemplateCommand, buildDeleteHpaCommand, buildPatchHpaReplicasCommand, hpaExists)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRolloutWithRetries, getVirtualServiceJson)
import Products.Autopilot.Notifications (
    notifyGenericThreadMessage,
    notifyReleaseCompleted,
    notifyReleaseProgress,
 )
import Products.Autopilot.Queries.ProductService (findServiceByProductAndName, withVsLock)
import Products.Autopilot.Queries.ReleaseTracker (conditionalUpdateTracker, findReleaseTracker, insertReleaseEvent, insertReleaseTracker)
import Products.Autopilot.RuntimeConfig (
    getCollectMetricsDelay,
    getHpaDefaultMinPods,
    getHpaMinMaxFactor,
    getHpaTemplate,
    getMaxK8sRetries,
    getPodReadinessMaxAttempts,
    getPodReadinessPollSeconds,
    getPodRestartCountThreshold,
    getPodsCalculationFactor,
    getReleaseStartDelay,
    isABHSDecisionEnabledForAppGroupService,
    isABHSPostMonitoringDecisionEnabledForAppGroupService,
    isHpaEnabledForProduct,
    isScaleDownPodsOnCompletion,
 )

-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (
    Decision (..),
    Mode (..),
    ReleaseStatus (..),
    ReleaseTracker (appGroup, endTime, mode, releaseId, rolloutHistory, rolloutStrategy, service, status),
    RolloutHistory (..),
    RolloutStep (..),
    releaseStatusText,
 )
import qualified Products.Autopilot.Types.Storage.Schema as S
import Products.Autopilot.Types.Target (
    BackendServiceWFStatus (..),
    K8sDeploymentState (..),
    TargetState (..),
    emptyK8sState,
 )
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers (
    captureDeploymentSnapshot,
    getRT,
    updateRT,
    (|>>),
 )
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
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

-- | StateFlow-level logging (lifts from Flow)
logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

logErrorS :: T.Text -> StateFlow ()
logErrorS = lift . logError

-- | Extract K8sReleaseContext from the current workflow state
getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = do
    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) -> pure (context k8s)
        _ -> liftIO $ throwIO $ WorkflowError "init" "Missing K8sState in targetState"

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
        Left (K8sError err) -> liftIO $ throwIO $ WorkflowError "k8s" err

{- | Pick the primary destination subset for a host out of an istio
VirtualService JSON document. Returns the subset of the highest-weighted
route in the first http rule that targets `host`. Used by the internal-VS
cross-validation in validatePreconditions.
-}
extractInternalVsPrimarySubset :: Value -> T.Text -> Maybe T.Text
extractInternalVsPrimarySubset vsJson host =
    case vsJson of
        Object o ->
            case KM.lookup (K.fromText "spec") o of
                Just (Object spec) ->
                    case KM.lookup (K.fromText "http") spec of
                        Just (Array routes) ->
                            let matchHost (Object rule) =
                                    case KM.lookup (K.fromText "route") rule of
                                        Just (Array dests) ->
                                            let bestSubset = foldr pickBest Nothing dests
                                             in bestSubset
                                        _ -> Nothing
                                matchHost _ = Nothing
                                pickBest (Object dest) acc =
                                    case KM.lookup (K.fromText "destination") dest of
                                        Just (Object d) ->
                                            let h = case KM.lookup (K.fromText "host") d of
                                                    Just (String s) -> s
                                                    _ -> ""
                                                s = case KM.lookup (K.fromText "subset") d of
                                                    Just (String x) -> Just x
                                                    _ -> Nothing
                                             in if h == host then s <|> acc else acc
                                        _ -> acc
                                pickBest _ acc = acc
                                tryRules [] = Nothing
                                tryRules (r : rs) = case matchHost r of
                                    Just s -> Just s
                                    Nothing -> tryRules rs
                             in tryRules (foldr (:) [] routes)
                        _ -> Nothing
                _ -> Nothing
        _ -> Nothing

{- | Scale the new deployment for the upcoming rollout stage.

FULL Julia formula (service.jl:426-431):

  podsRolloutRatio       = pods_calculation_factor × oldDesiredPods / 100
  predictionFromOldPods  = ceil(oldVersionPods × min(routePercent + 10, 100) / 100)
  calculatedPods         = max(
      currentNewPods,                                  -- never shrink
      ceil(podsRolloutRatio × routePercent),           -- strategy target with factor buffer
      currentNewAvailable,                             -- already-ready replicas
      predictionFromOldPods                            -- 10% headroom over proportional old-pod share
  )

Then the floor is patched on the new deployment's HPA via `updateMinPods!`
(if HPA exists). HPA reconciles every ~15s; a direct kubectl scale would
be immediately undone, so we raise the HPA min instead. HPA can still
scale UP above the floor under load, but cannot scale DOWN below it.

Falls back to direct kubectl scale if no HPA on the new deployment.
-}
scaleNewDeploymentForStage ::
    Config ->
    K8sReleaseContext ->
    -- | rolloutPercent (traffic %) for this stage — feeds the formula
    Int ->
    -- | podPercent from rollout strategy (operator's explicit floor)
    Int ->
    StateFlow ()
scaleNewDeploymentForStage cfg ctx routePct podPct = do
    rtNow <- getRT
    wfCfg <- loadWorkflowConfig (appGroup rtNow)
    let oldDep = serviceName ctx <> "-" <> oldVersion ctx
        newDep = deploymentName ctx
        newHpa = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
        ns = namespace ctx
    oldStatus <- liftIO $ getDeploymentReplicaStatus cfg ns oldDep
    newStatus <- liftIO $ getDeploymentReplicaStatus cfg ns newDep
    let -- (ready, available, desired)
        (oldReady, _, oldDesired) = case oldStatus of
            Right tup -> tup
            Left _ -> (0, 0, 0)
        (newReady, _, newDesired) = case newStatus of
            Right tup -> tup
            Left _ -> (0, 0, 0)
        currentOld = max 0 oldDesired
        currentNew = max 0 newDesired
        oldVersionPods = max 0 oldReady
        availableNew = max 0 newReady
        factor = wcPodsCalculationFactor wfCfg
        -- Strategy target: pods_calculation_factor × oldDesired/100 × routePct
        --   matches Julia's `podsRolloutRatio × routePercent` (service.jl:17,429).
        strategyByFactor =
            ceiling
                ( factor
                    * (fromIntegral currentOld :: Double)
                    / 100.0
                    * fromIntegral routePct
                )
        -- Predict pods needed from current old-version load: take the share of
        -- old pods proportional to (routePct + 10), capped at 100. The +10
        -- gives ~10% headroom over a strict proportional share so we don't
        -- under-provision while traffic is mid-shift.
        --   Julia: getOldVersionRelationPodsCount (service.jl:117-120, 428).
        predictedFromOld =
            let pct = min (routePct + 10) 100
             in ceiling
                    ( (fromIntegral oldVersionPods :: Double)
                        * fromIntegral pct
                        / 100.0
                    )
        -- Operator's explicit floor: podPct% of currentOld, never below 1.
        operatorFloor = max 1 (ceiling ((fromIntegral currentOld * fromIntegral podPct :: Double) / 100.0))
        -- Final = max of every input. Never shrink, never under-provision.
        target =
            maximum
                [ currentNew
                , strategyByFactor
                , availableNew
                , predictedFromOld
                , operatorFloor
                ]
    if currentOld <= 0
        then logInfoS $ "  [pods] Skipping scale (old deployment " <> oldDep <> " has 0/unknown desired replicas)"
        else
            if currentNew >= target
                then
                    logInfoS $
                        "  [pods] "
                            <> newDep
                            <> " already at "
                            <> T.pack (show currentNew)
                            <> " replicas (target="
                            <> T.pack (show target)
                            <> ", currentOld="
                            <> T.pack (show currentOld)
                            <> ", route%="
                            <> T.pack (show routePct)
                            <> "), no-op"
                else do
                    let logCtx =
                            " (target="
                                <> T.pack (show target)
                                <> ", inputs: currentNew="
                                <> T.pack (show currentNew)
                                <> ", availableNew="
                                <> T.pack (show availableNew)
                                <> ", strategyByFactor="
                                <> T.pack (show strategyByFactor)
                                <> ", predictedFromOld="
                                <> T.pack (show predictedFromOld)
                                <> ", operatorFloor="
                                <> T.pack (show operatorFloor)
                                <> ", oldDesired="
                                <> T.pack (show currentOld)
                                <> ", oldVersionPods="
                                <> T.pack (show oldVersionPods)
                                <> ", route%="
                                <> T.pack (show routePct)
                                <> ", podPct%="
                                <> T.pack (show podPct)
                                <> ", factor="
                                <> T.pack (show factor)
                                <> ")"
                    -- Prefer HPA min-floor patching; HPA holds the floor against
                    -- its own scale-down reconciliation cycle.
                    hpaPresent <- liftIO $ hpaExists cfg ns newHpa
                    if hpaPresent
                        then do
                            let hpaMin = target
                                hpaMax = max hpaMin (round (fromIntegral target * wcHpaMinMaxFactor wfCfg :: Double))
                            logInfoS $ "  [pods] Patching HPA " <> newHpa <> " min=" <> T.pack (show hpaMin) <> " max=" <> T.pack (show hpaMax) <> logCtx
                            _ <- liftIO $ runCmd (buildPatchHpaReplicasCommand cfg ns newHpa hpaMin hpaMax)
                            pure ()
                        else do
                            logInfoS $ "  [pods] No HPA, direct scaling " <> newDep <> " to " <> T.pack (show target) <> logCtx
                            _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx target)
                            pure ()

{- | Apply VS rollout with a pessimistic lock around the operation.
Acquires vs_locked_by before the kubectl call, releases after (success or fail).
If the lock is held by another release/editor, retries with exponential backoff
(500ms → 1s → 2s → 4s → 8s, total ~15s) before giving up. This makes parallel
releases on the same app group serialize cleanly instead of having the losing
side abort immediately.
-}
runVsRolloutWithLock :: Config -> K8sReleaseContext -> Int -> Int -> Int -> StateFlow ()
runVsRolloutWithLock cfg ctx maxRetries oldW newW = do
    rt <- getRT
    let lockOwner = "release:" <> releaseId rt
        delaysMs = [500, 1000, 2000, 4000, 8000] :: [Int]
        attempt remainingDelays = do
            r <- withVsLock (appGroup rt) lockOwner $
                liftIO $ applyVirtualServiceRolloutWithRetries maxRetries cfg ctx oldW newW
            case r of
                Left _ -> case remainingDelays of
                    [] -> pure r
                    (d : ds) -> do
                        liftIO (CC.threadDelay (d * 1000)) -- millis → micros
                        attempt ds
                _ -> pure r
    result <- attempt delaysMs
    case result of
        Left err -> do
            insertReleaseEvent (releaseId rt) "BUSINESS" "VS_LOCK_FAILED" (toJSON err)
            liftIO $ throwIO $ WorkflowError "vs-lock" err
        Right (Left (K8sError k8sErr)) -> do
            insertReleaseEvent (releaseId rt) "BUSINESS" "KUBECTL_FAILED" (toJSON k8sErr)
            liftIO $ throwIO $ WorkflowError "k8s" k8sErr
        Right (Right _) -> pure ()

-- ============================================================================
-- Workflow-local config snapshot + safe helpers
-- ============================================================================

{- | Snapshot of all RuntimeConfig values needed by the workflow.
Loaded ONCE per workflow phase (instead of re-reading on every loop iteration)
so a config change mid-rollout cannot cause inconsistent decisions inside a
single loop body. The values are intentionally simple (Int / Bool / Double).
-}
data WorkflowConfig = WorkflowConfig
    { wcCollectMetricsDelay :: Int
    , wcReleaseStartDelay :: Int
    , wcMaxK8sRetries :: Int
    , wcHpaMinMaxFactor :: Double
    , wcHpaDefaultMinPods :: Int
    , wcHpaEnabled :: Bool
    , wcScaleDownOnCompletion :: Bool
    , wcPodsCalculationFactor :: Double
    -- ^ Multiplier on (oldDesiredPods × routePercent / 100) for the pod-count
    -- formula. Matches Julia's pods_calculation_factor (default 1.2). Lets
    -- operators add a global safety buffer above the strict ratio.
    }

-- | Build a 'WorkflowConfig' by reading every relevant runtime knob once.
loadWorkflowConfig :: T.Text -> StateFlow WorkflowConfig
loadWorkflowConfig product_ = do
    cmd <- getCollectMetricsDelay
    rsd <- getReleaseStartDelay
    mkr <- getMaxK8sRetries
    hmf <- getHpaMinMaxFactor
    hdm <- getHpaDefaultMinPods
    hpa <- isHpaEnabledForProduct product_
    scd <- isScaleDownPodsOnCompletion
    pcf <- getPodsCalculationFactor
    pure
        WorkflowConfig
            { wcCollectMetricsDelay = cmd
            , wcReleaseStartDelay = rsd
            , wcMaxK8sRetries = mkr
            , wcHpaMinMaxFactor = hmf
            , wcHpaDefaultMinPods = hdm
            , wcHpaEnabled = hpa
            , wcScaleDownOnCompletion = scd
            , wcPodsCalculationFactor = pcf
            }

{- | Loop bail-out safety: max iterations and max wall-clock duration for
the rollout/post-monitor loops. A paused-and-forgotten release must not
spin a worker forever.
-}
maxLoopIterations :: Int
maxLoopIterations = 10000

maxLoopDurationSec :: Double
maxLoopDurationSec = 24 * 60 * 60 -- 24 hours

{- | CAS-protected persistence. Replaces blind 'insertReleaseTracker' inside
loops: only writes if the on-disk status still matches the snapshot the
loop computed against. On mismatch we BAIL with a 'WorkflowError' so the
runner's exception handler can clean up — the alternative (silently
overwriting concurrent state) is the bug class we are eliminating.
-}
casUpdateOrBail ::
    -- | caller tag for log messages
    T.Text ->
    -- | updated tracker to write
    ReleaseTracker ->
    -- | updated target state
    Maybe TargetState ->
    -- | status of the snapshot we computed against
    ReleaseStatus ->
    StateFlow ()
casUpdateOrBail tag updated mts oldStatus = do
    ok <- conditionalUpdateTracker updated mts (releaseStatusText oldStatus)
    when (not ok) $ do
        logWarningS $ "[" <> tag <> "] CAS failed - concurrent state change, exiting loop"
        liftIO $ throwIO $ WorkflowError "cas" "concurrent state change"

{- | Safe last/init replacement: split a list into (init, last) without
calling partial functions. Returns 'Nothing' for the empty list.
-}
unsnocList :: [a] -> Maybe ([a], a)
unsnocList [] = Nothing
unsnocList xs = Just (Prelude.init xs, Prelude.last xs)

-- | Bounds-checked list indexing. Returns 'Nothing' for out-of-range indices.
safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
    | i < 0 = Nothing
    | otherwise = case drop i xs of
        (x : _) -> Just x
        [] -> Nothing

{- | Apply a transformation to the LAST entry of the in-memory tracker's
rollout history. No-op if history is empty. Pure state mutation only;
caller is responsible for persistence (typically via 'casUpdateOrBail').
-}
updateLastHistoryEntry :: (RolloutHistory -> RolloutHistory) -> StateFlow ()
updateLastHistoryEntry f = do
    rt <- getRT
    case unsnocList (rolloutHistory rt) of
        Nothing -> pure ()
        Just (initH, lastH) ->
            updateRT $ \r -> r{rolloutHistory = initH <> [f lastH]}

{- | Mark the workflow's tracker as ABORTED with a reason and persist
unconditionally (we are intentionally exiting). Used for unrecoverable
input errors like an empty rollout strategy.
-}
abortWithReason :: T.Text -> StateFlow a
abortWithReason reason = do
    logErrorS $ "[workflow] Aborting: " <> reason
    rt <- getRT
    updateRT $ \r -> r{status = ABORTED}
    insertReleaseEvent (releaseId rt) "BUSINESS" "WORKFLOW_ABORTED" (toJSON reason)
    currentRT <- getRT
    currentTS <- gets targetState
    insertReleaseTracker currentRT currentTS
    liftIO $ throwIO $ WorkflowError "workflow" reason

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
    rt <- getRT
    cfg <- getCfg
    logInfoS $ "Validating preconditions for " <> appGroup rt

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
    logInfoS "  Checking cluster reachability"
    _ <-
        runK8sIO $
            runCmd
                ( unwords
                    [ kubectlBin cfg
                    , "-n"
                    , T.unpack (namespace ctx)
                    , "get namespace"
                    , T.unpack (namespace ctx)
                    ]
                )

    when isNew $
        logInfoS "  New service release: skipping old version validation"

    -- Check internal VS (if exists) and cross-validate the version against
    -- the external VS. Julia: validationInternalVSVersionFromExternalVS
    -- (service.jl:338-343) — DISCARD on mismatch.
    let internalVsName = case internalVirtualServiceName ctx of
            Just t | not (T.null t) -> t
            _ -> serviceName ctx <> "-internal-vs"
    internalResult <- liftIO $ getVirtualServiceJson cfg (namespace ctx) internalVsName
    case internalResult of
        Left _ -> pure () -- No internal VS, that's fine
        Right internalText -> do
            rt' <- getRT
            logInfoS $ "  Internal VS found: " <> internalVsName
            insertReleaseEvent
                (releaseId rt')
                "BUSINESS"
                "INTERNAL_VS_FOUND"
                (toJSON internalVsName)
            -- Cross-validate the internal VS subset against the tracker's
            -- oldVersion (Julia: validationInternalVSVersionFromExternalVS,
            -- service.jl:338-343). DISCARD on mismatch.
            unless isNew $ do
                let host = serviceName ctx
                    expectedOld = oldVersion ctx -- from K8sReleaseContext
                    parsed = A.eitherDecode (TLE.encodeUtf8 (TL.fromStrict internalText)) :: Either String Value
                    internalSubset = case parsed of
                        Right v -> extractInternalVsPrimarySubset v host
                        Left _ -> Nothing
                case internalSubset of
                    Nothing -> logInfoS "  Internal VS has no matching route for this host — skipping cross-check"
                    Just subset
                        | subset == expectedOld -> logInfoS $ "  Internal VS subset matches tracker oldVersion (" <> subset <> ")"
                        | otherwise -> do
                            let msg = "Internal VS subset (" <> subset <> ") does not match tracker oldVersion (" <> expectedOld <> ")"
                            logErrorS $ "  " <> msg
                            insertReleaseEvent (releaseId rt') "BUSINESS" "VERSION_MISMATCH_INTERNAL_VS" (toJSON msg)
                            updateRT $ \r -> r{status = DISCARDED}
                            currentRT <- getRT
                            currentTS <- gets targetState
                            _ <- conditionalUpdateTracker currentRT currentTS (releaseStatusText (status rt'))
                            liftIO $ throwIO $ WorkflowError "vs-internal" msg

    logInfoS "  Cluster reachable, namespace exists"

    -- Persist state after validation (production persists status changes immediately)
    currentRT <- getRT
    currentTS <- gets targetState
    insertReleaseTracker currentRT currentTS

    logInfoS "Preconditions validated"

-- | Prepare K8s resources: ConfigMap, clone/create deployment, service check, DestinationRule
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    -- Snapshot config once for this phase.
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "PREPARING K8s resources for " <> appGroup rt <> if isNew then " (NEW SERVICE)" else ""

    -- BEFORE snapshots are captured at release creation time (createReleaseH)
    -- so diffs are available before the workflow starts.

    -- 1. Apply ConfigMap
    updateK8sStatus BSApplyConfigMap
    logInfoS "  Applying ConfigMap"
    _ <- runK8sIO $ executeWithRetry cfg (buildConfigMapApplyCommand cfg ctx)
    updateK8sField (\k8s -> k8s{configMapApplied = True})

    -- 2. Create/clone deployment (skip if target already exists, e.g. checkpoint resume)
    updateK8sStatus BSCreateDeployment
    newDepExists <- liftIO $ deploymentExists cfg (namespace ctx) (deploymentName ctx)
    if newDepExists
        then logInfoS "  Deployment already exists, skipping create/clone"
        else
            if isNew
                then do
                    -- New service: create from deploy file path or error
                    case deployFilePath ctx of
                        Just fp -> do
                            logInfoS $ "  Creating new deployment from: " <> fp
                            _ <- runK8sIO $ executeWithRetry cfg (buildApplyFileCommand cfg fp)
                            pure ()
                        Nothing -> do
                            logErrorS $ "  ERROR: New service requires deployFilePath"
                            liftIO $ throwIO $ WorkflowError "deploy" "New service release requires deployFilePath"
                else do
                    logInfoS $ "  Cloning deployment to " <> deploymentName ctx
                    _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentCommand cfg ctx)
                    pure ()
    updateK8sField (\k8s -> k8s{deploymentCreated = True})

    -- 3. Check Service exists
    updateK8sStatus BSUpdateService
    logInfoS "  Checking Service exists"
    svcOk <- liftIO $ serviceExists cfg (namespace ctx) (serviceName ctx)
    when (not svcOk) $
        logWarningS "  WARNING: Service not found (pods may still route via selector)"
    updateK8sField (\k8s -> k8s{serviceCreated = svcOk})

    -- 4. Ensure DestinationRule (creates if missing, adds subset if existing)
    updateK8sStatus BSApplyDestinationRule
    logInfoS "  Ensuring DestinationRule"
    _ <- runK8sIO $ ensureDestinationRule cfg ctx
    updateK8sField (\k8s -> k8s{destinationRuleApplied = True})

    -- 5. HPA: patch existing new / clone old / create from template (Julia parity, kubernetes.jl:1641-1698)
    let hpaEnabled = wcHpaEnabled wfCfg
    when hpaEnabled $ do
        let newHpaName = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
            oldHpaName = serviceName ctx <> "-" <> oldVersion ctx <> "-hpa"
            hpaMinMaxFactor = wcHpaMinMaxFactor wfCfg
            defaultMinPods = wcHpaDefaultMinPods wfCfg
            computeMinMax desired =
                let hpaMin = max 1 desired
                    hpaMax = max hpaMin (round (fromIntegral desired * hpaMinMaxFactor))
                 in (hpaMin, hpaMax)

        -- Read desired replicas from old deployment if it exists; otherwise fall back to default.
        desiredFromOld <- liftIO $ getDeploymentReplicaStatus cfg (namespace ctx) (serviceName ctx <> "-" <> oldVersion ctx)
        let desiredReplicas = case desiredFromOld of
                Right (_, _, d) -> d
                Left _ -> defaultMinPods

        newHpaFound <- liftIO $ hpaExists cfg (namespace ctx) newHpaName
        if newHpaFound
            then do
                -- Branch 1: new HPA already exists (retry / partial previous run). Patch min/max.
                let (hpaMin, hpaMax) = computeMinMax desiredReplicas
                logInfoS $ "  Patching existing HPA " <> newHpaName <> " (min=" <> T.pack (show hpaMin) <> " max=" <> T.pack (show hpaMax) <> ")"
                patchResult <- liftIO $ runCmd (buildPatchHpaReplicasCommand cfg (namespace ctx) newHpaName hpaMin hpaMax)
                case patchResult of
                    Right _ -> do
                        logInfoS "  HPA patched successfully"
                        updateK8sField (\k8s -> k8s{hpaCreated = True})
                        insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_PATCHED" (toJSON newHpaName)
                    Left (K8sError err) -> logErrorS $ "  [HPA] Patch failed (non-fatal): " <> err
            else do
                oldHpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
                if oldHpaFound
                    then do
                        -- Branch 2: clone the old HPA into new
                        let (hpaMin, hpaMax) = computeMinMax desiredReplicas
                        logInfoS $ "  Cloning HPA from " <> oldHpaName
                        cloneResult <- liftIO $ runCmd (buildCloneHpaCommand cfg (namespace ctx) (serviceName ctx) (oldVersion ctx) (newVersion ctx) oldHpaName hpaMin hpaMax)
                        case cloneResult of
                            Right _ -> do
                                logInfoS "  HPA cloned successfully"
                                updateK8sField (\k8s -> k8s{hpaCreated = True})
                                insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_CLONED" (toJSON newHpaName)
                            Left (K8sError err) -> logErrorS $ "  [HPA] Clone failed (non-fatal): " <> err
                    else do
                        -- Branch 3: first release. Create from template.
                        mTemplate <- getHpaTemplate
                        case mTemplate of
                            Just tmpl | not (T.null tmpl) -> do
                                let (hpaMin, hpaMax) = computeMinMax defaultMinPods
                                logInfoS $ "  Creating HPA from template: " <> newHpaName
                                createResult <- liftIO $ runCmd (buildCreateHpaFromTemplateCommand cfg (namespace ctx) (serviceName ctx) (newVersion ctx) tmpl hpaMin hpaMax)
                                case createResult of
                                    Right _ -> do
                                        logInfoS "  HPA created from template"
                                        updateK8sField (\k8s -> k8s{hpaCreated = True})
                                        insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_CREATED_FROM_TEMPLATE" (toJSON newHpaName)
                                    Left (K8sError err) -> logErrorS $ "  [HPA] Create from template failed (non-fatal): " <> err
                            _ -> logInfoS "  No hpa_template configured; skipping HPA create"

    -- Initiate AB decision pod ONCE per release (Julia parity, global_changelog.jl).
    -- The verdict is read later by getHSDecision in the rollout loop using the
    -- same run_id. Gated by master ab_decision_enabled AND per-service flag.
    -- On fail-closed initiate failure, abort the release before rollout begins.
    abInit <- lift $ initiateABDecisionForRelease cfg rt
    case drDecision abInit of
        Abort -> do
            let reason = maybe "AB initiate failed" id (drReason abInit)
            logErrorS $ "[DECISION] AB initiate failed: " <> reason
            insertReleaseEvent
                (releaseId rt)
                "DECISION_ENGINE"
                "AB_INITIATE_FAILED"
                (object ["reason" .= reason])
            liftIO $ throwIO $ WorkflowError "ab-initiate" reason
        _ -> pure ()

    logInfoS "K8s resources prepared"

{- | Progressive rollout: shift traffic old -> new following the tracker's rollout_strategy.

Production parity (service.jl while-loop at line 459):
- Each iteration of the loop handles ONE rollout step.
- Re-reads the tracker from DB to catch user pause/abort/strategy changes.
- Records rollout history after each completed step.
- In MANUAL mode: only advances if cooloff exceeded (no decision engine).
- In AUTO mode: advances if cooloff exceeded AND decision engine says Continue.
- The loop blocks on collectMetricsDelay between iterations (not the full cooloff).
-}
progressiveRollout :: StateFlow ()
progressiveRollout = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    -- Snapshot RuntimeConfig ONCE for the entire rollout phase. Re-reading
    -- inside the loop would let a config change mid-rollout produce
    -- inconsistent decisions across iterations.
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "Starting progressive rollout for " <> appGroup rt

    updateK8sStatus BSFlipVirtualService
    updateK8sField (\k8s -> k8s{virtualServiceApplied = True})

    updateK8sStatus BSProgressiveRollout

    -- Production: sleep(getReleaseStartDelay(conn)) before starting.
    let releaseStartDelay = wcReleaseStartDelay wfCfg
    when (releaseStartDelay > 0) $ do
        logInfoS $ "  Release start delay: " <> T.pack (show releaseStartDelay) <> " seconds"
        threadDelay (Seconds releaseStartDelay)
    -- Bug fix (round 6 / Julia parity): re-fetch the tracker AFTER the start
    -- delay so any RM edit (rollout strategy adjust, mode flip, etc.) lands
    -- before the rollout actually begins. Julia: service.jl:352 — `tracker =
    -- get_release_from_id(conn, tracker.id)[1]` immediately after sleep.
    when (releaseStartDelay > 0) $ do
        mFresh <- findReleaseTracker (releaseId rt)
        case mFresh of
            Just (freshRT, freshTS) -> do
                modify $ \s -> s{releaseTracker = freshRT, targetState = freshTS}
                logInfoS "  Re-read tracker after release-start delay"
            Nothing -> pure ()

    if isNew
        then do
            -- New service: route 100% traffic to new version directly (no old version)
            logInfoS "  New service: routing 100% traffic to new version"
            runVsRolloutWithLock cfg ctx (wcMaxK8sRetries wfCfg) 0 100
            updateK8sField (\k8s -> k8s{trafficPercentage = 100})
            -- Record rollout history for the 100% step
            now <- liftIO getCurrentTime
            let histEntry = mkRolloutHistory 100 0 100 now (Just now)
            updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [histEntry]}
            currentRT <- getRT
            -- CAS: only persist if status hasn't changed under us.
            casUpdateOrBail
                "progressiveRollout/new"
                currentRT
                (Just (K8sState (emptyK8sState{context = ctx, trafficPercentage = 100})))
                (status rt)
            lift $ notifyReleaseProgress currentRT 100
        else do
            -- Use the tracker's rollout strategy (e.g. 5%/25%/50%/75%/100% with cooloffs)
            case rolloutStrategy rt of
                [] -> abortWithReason "empty rolloutStrategy"
                strategy -> do
                    let totalSteps = length strategy
                        existingHistory = rolloutHistory rt
                        alreadyStarted = not (null existingHistory)

                    -- Resume from existing history if workflow was restarted (e.g., after VS lock failure)
                    if alreadyStarted
                        then do
                            let currentIndex = length existingHistory
                            logInfoS $ "  Resuming rollout from step " <> T.pack (show currentIndex) <> "/" <> T.pack (show totalSteps)
                            loopStart <- liftIO getCurrentTime
                            rolloutLoop wfCfg cfg ctx currentIndex totalSteps loopStart 0 loopStart
                        else do
                            -- Apply first step immediately (production line 359: getInitialCoolOffAndRoutingPercentage)
                            -- Safe destructuring — strategy is non-empty by the case match above.
                            let (firstStep : _) = strategy
                                firstNewW = rolloutPercent firstStep
                                firstOldW = max 0 (100 - firstNewW)
                            logInfoS $ "  Initial rollout step: new=" <> T.pack (show firstNewW) <> "%, cooloff=" <> T.pack (show (cooloffMinutes firstStep)) <> "min"
                            -- Scale new deployment via the Julia max() formula BEFORE shifting traffic.
                            scaleNewDeploymentForStage cfg ctx firstNewW (podPercent firstStep)
                            runVsRolloutWithLock cfg ctx (wcMaxK8sRetries wfCfg) firstOldW firstNewW
                            updateK8sField (\k8s -> k8s{trafficPercentage = firstNewW})

                            -- Record rollout history for first step
                            stepStartTime <- liftIO getCurrentTime
                            let firstHist = mkRolloutHistory firstNewW (cooloffMinutes firstStep) (podPercent firstStep) stepStartTime Nothing
                            updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [firstHist]}
                            currentRT <- getRT
                            casUpdateOrBail
                                "progressiveRollout/first"
                                currentRT
                                (Just (K8sState (emptyK8sState{context = ctx, trafficPercentage = firstNewW})))
                                (status rt)
                            lift $ notifyReleaseProgress currentRT firstNewW
                            -- Production parity: BUSINESS / TRAFFIC_UPDATED with previous_rollout=0 for first step
                            logTrafficUpdated currentRT 0

                            -- Production while-loop: iterate through remaining steps with re-entrant checks
                            -- index starts at 1 (0-based), first step already applied
                            rolloutLoop wfCfg cfg ctx 1 totalSteps stepStartTime 0 stepStartTime

    logInfoS "Progressive rollout complete"

{- | Re-entrant rollout loop matching production's while-true loop (service.jl line 459).

Each iteration:
1. Re-reads tracker from DB (catches user pause/abort/strategy change)
2. Checks if tracker is in terminal state (abort/complete)
3. If cooloff exceeded for current step: advance to next step
4. If all steps done: mark as complete
5. Otherwise: sleep collectMetricsDelay and loop
-}
rolloutLoop ::
    WorkflowConfig ->
    Config ->
    K8sReleaseContext ->
    Int ->
    Int ->
    UTCTime ->
    -- | iteration counter (bail-out safety)
    Int ->
    -- | loop wall-clock start (bail-out safety)
    UTCTime ->
    StateFlow ()
rolloutLoop wfCfg cfg ctx currentIndex totalSteps stepStartTime iterCount loopStart = do
    -- Bail-out safety: a paused-and-forgotten release must not spin a worker forever.
    nowGuard <- liftIO getCurrentTime
    let elapsedTotal = realToFrac (diffUTCTime nowGuard loopStart) :: Double
    when (iterCount > maxLoopIterations || elapsedTotal > maxLoopDurationSec) $ do
        logErrorS $
            "  [rolloutLoop] Bail-out: iter="
                <> T.pack (show iterCount)
                <> " elapsed="
                <> T.pack (show elapsedTotal)
                <> "s, aborting stuck rollout"
        rtStuck <- getRT
        updateRT $ \r -> r{status = ABORTED}
        currentRT <- getRT
        currentTS <- gets targetState
        -- Best-effort CAS — if it loses, exception still flies.
        _ <- conditionalUpdateTracker currentRT currentTS (releaseStatusText (status rtStuck))
        liftIO $ throwIO $ WorkflowError "rollout" "Stuck rollout: max loop bail-out"

    -- Production line 460: tracker = get_release_from_id(conn, tracker.id)[1]
    rt <- getRT
    freshResult <- findReleaseTracker (releaseId rt)
    case freshResult of
        Nothing -> do
            logErrorS "  [rolloutLoop] Tracker deleted from DB, aborting"
            liftIO $ throwIO $ WorkflowError "rollout" "Tracker deleted during rollout"
        Just (freshRT, freshMts) -> do
            -- Sync our in-memory state with what the DB has
            updateRT $ \_ -> freshRT
            case freshMts of
                Just ts -> modify $ \s -> s{targetState = Just ts}
                Nothing -> pure ()

            -- Re-read strategy from DB on every iteration so mid-flight updates take effect
            let strategy = rolloutStrategy freshRT
                freshTotalSteps = length strategy
                freshStatus = status freshRT
                recurse newIdx newStepStart =
                    rolloutLoop wfCfg cfg ctx newIdx freshTotalSteps newStepStart (iterCount + 1) loopStart
                recurseSame =
                    rolloutLoop wfCfg cfg ctx currentIndex freshTotalSteps stepStartTime (iterCount + 1) loopStart

            -- Production line 462: isTrackerInTerminalState!
            case freshStatus of
                ABORTING -> do
                    logErrorS $ "  [rolloutLoop] Release " <> releaseId freshRT <> " is aborting, exiting workflow. Runner will handle cleanup."
                    liftIO $ throwIO $ WorkflowError "rollout" "Release aborted by user"
                USER_ABORTED -> do
                    logInfoS "  [rolloutLoop] Tracker is USER_ABORTED, stopping rollout"
                    liftIO $ throwIO $ WorkflowError "rollout" "Release user-aborted during rollout"
                ABORTED -> do
                    logErrorS "  [rolloutLoop] Tracker is ABORTED, stopping rollout"
                    liftIO $ throwIO $ WorkflowError "rollout" "Release aborted during rollout"
                COMPLETED -> do
                    logInfoS "  [rolloutLoop] Tracker is COMPLETED (externally), finishing"
                    pure ()
                PAUSED -> do
                    -- Production line 195: if isReleasePaused(tracker) return (routePercent, coolOff, podsCount)
                    logInfoS "  [rolloutLoop] Tracker is PAUSED, waiting..."
                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                    recurseSame
                INPROGRESS -> do
                    -- Check AUTO vs MANUAL mode behavior
                    let currentMode = mode freshRT
                    -- Production line 197: MANUAL calls getNewRollout directly
                    -- Production line 199-238: AUTO checks decision engine first
                    -- We implement both paths

                    if currentIndex >= totalSteps
                        then do
                            -- All steps complete - production line 134-181: final completion
                            logInfoS "  [rolloutLoop] All rollout steps completed"
                            -- Update final rollout history entry with completion time
                            now <- liftIO getCurrentTime
                            case unsnocList (rolloutHistory freshRT) of
                                Nothing -> pure ()
                                Just _ -> do
                                    updateLastHistoryEntry $ \lastH ->
                                        lastH{historyCompletedAt = Just now, historyDecision = Just Continue}
                                    currentRT <- getRT
                                    casUpdateOrBail "rolloutLoop/finalHist" currentRT freshMts freshStatus
                        else do
                            -- Check if cooloff has elapsed for current step
                            -- Reads from rollout strategy (fast-forward sets strategy cooloff to 0)
                            now <- liftIO getCurrentTime
                            -- Bounds-checked indexing: production strategy may have shrunk under us.
                            currentStep <- case safeIndex strategy (currentIndex - 1) of
                                Just s -> pure s
                                Nothing -> abortWithReason "rolloutStrategy index out of range (current step)"
                            let cooloffMins = cooloffMinutes currentStep
                                elapsed = diffUTCTime now stepStartTime
                                cooloffSecs = fromIntegral cooloffMins * 60 :: Double
                                cooloffExceeded = realToFrac elapsed >= cooloffSecs

                            if not cooloffExceeded
                                then do
                                    -- Cooloff not exceeded, sleep and re-check
                                    -- Production line 518: sleep(getCollectMetricsDelay(conn))
                                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                                    recurseSame
                                else do
                                    -- Cooloff exceeded - decide whether to advance
                                    shouldAdvance <- case currentMode of
                                        MANUAL -> do
                                            -- MANUAL: advance if cooloff exceeded and status is INPROGRESS
                                            -- Production line 128: isCoolOffExceeded && tracker.status == INPROGRESS
                                            logInfoS "  [rolloutLoop] MANUAL mode: cooloff exceeded, advancing"
                                            pure True
                                        AUTO -> do
                                            -- AUTO: check health/decision engine first
                                            -- Production lines 520-553: collect metrics, get decision
                                            logInfoS "  [rolloutLoop] AUTO mode: checking health before advancing"
                                            checkDeploymentHealth cfg ctx

                                            -- 1. Prometheus query checks
                                            mSvcConfig <- findServiceByProductAndName (appGroup freshRT) (service freshRT)
                                            let mDecisionConfig = mSvcConfig >>= S.dcDecisionConfig
                                            promResult <- checkPromQueries cfg freshRT mDecisionConfig
                                            case promResult of
                                                PromAbort reason -> do
                                                    logErrorS $ "[DECISION] Prometheus ABORT: " <> reason
                                                    -- Production parity (service.jl:203): NOTIFICATION / STATUS_UPDATED
                                                    logStatusUpdated freshRT ("ABORTING the release because prom query checks failing: " <> reason)
                                                    lift $ notifyGenericThreadMessage freshRT ("Prometheus check ABORT: " <> reason)
                                                    updateRT $ \r -> r{status = ABORTING}
                                                    currentRT' <- getRT
                                                    currentTS' <- gets targetState
                                                    casUpdateOrBail "rolloutLoop/promAbort" currentRT' currentTS' freshStatus
                                                    liftIO $ throwIO $ WorkflowError "decision" ("Prometheus ABORT: " <> reason)
                                                PromWarn reason -> do
                                                    logWarningS $ "[DECISION] Prometheus WARN: " <> reason
                                                    -- Production parity (service.jl:206-208): Slack only, no DB event
                                                    lift $ notifyGenericThreadMessage freshRT ("Prometheus warning: " <> reason)
                                                -- Continue despite warning
                                                PromOK -> pure ()

                                            -- 2/3. AB + HS Decisions, gated per (product, service).
                                            -- Master flags (ab_decision_enabled / ab_hs_enabled) are
                                            -- enforced inside getABDecision/getHSDecision; here we
                                            -- additionally enforce Julia's per-service granularity
                                            -- (ab_hs_decision_enabled_app_groups JSON map).
                                            perServiceEnabled <-
                                                isABHSDecisionEnabledForAppGroupService
                                                    (appGroup freshRT)
                                                    (service freshRT)
                                            (abDecision, hsDecision) <-
                                                if perServiceEnabled
                                                    then do
                                                        ab <- getABDecision cfg freshRT
                                                        hs <- getHSDecision cfg freshRT False
                                                        pure (ab, hs)
                                                    else
                                                        pure
                                                            ( DecisionResult Continue Nothing "AB_ENGINE"
                                                            , DecisionResult Continue Nothing "HEALTH_SCORE"
                                                            )

                                            -- Log combined decision event
                                            let combinedDecision = getCombinedDecision abDecision hsDecision
                                                abReasonText = maybe "" id (drReason abDecision)
                                                hsReasonText = maybe "" id (drReason hsDecision)
                                                combinedReasons = filter (not . T.null) [abReasonText, hsReasonText]
                                                combinedResultText =
                                                    "AB="
                                                        <> T.pack (show (drDecision abDecision))
                                                        <> " HS="
                                                        <> T.pack (show (drDecision hsDecision))

                                            -- Production parity (service.jl:548): write decision fields into
                                            -- the last rollout history entry BEFORE emitting DECISION_RESULT,
                                            -- so the embedded rollout_history in the event shows the decision.
                                            -- Do this for Continue, Wait AND Abort paths.
                                            case unsnocList (rolloutHistory freshRT) of
                                                Nothing -> pure ()
                                                Just _ -> do
                                                    updateLastHistoryEntry $ \lastHDR ->
                                                        lastHDR
                                                            { historyDecision = Just combinedDecision
                                                            , historyDecisionReason = Just combinedResultText
                                                            , historyDecisionHs = Just (drDecision hsDecision)
                                                            , historyDecisionHsReason = drReason hsDecision
                                                            }
                                                    currentRTDR <- getRT
                                                    currentTSDR <- gets targetState
                                                    casUpdateOrBail "rolloutLoop/decisionHist" currentRTDR currentTSDR freshStatus

                                            -- Read back so the event payload sees the updated history
                                            rtForEvent <- getRT
                                            logDecisionResult rtForEvent combinedDecision combinedResultText combinedReasons

                                            case combinedDecision of
                                                Continue -> pure True -- advance
                                                Wait -> pure False -- stay at current step, re-loop
                                                Abort -> do
                                                    -- Production parity (service.jl:213): first STATUS_UPDATED
                                                    logStatusUpdated rtForEvent "ABORTING the release because of the Decision Engine"
                                                    updateRT $ \r -> r{status = ABORTING}
                                                    currentRT' <- getRT
                                                    currentTS' <- gets targetState
                                                    casUpdateOrBail "rolloutLoop/decisionAbort" currentRT' currentTS' freshStatus
                                                    -- Production parity (service.jl:222): second STATUS_UPDATED for rollback
                                                    logStatusUpdated currentRT' ("Rolling back the traffic to version " <> oldVersion ctx)
                                                    liftIO $ throwIO $ WorkflowError "decision" "Decision engine: ABORT"

                                    if shouldAdvance
                                        then do
                                            -- Complete current step in rollout history
                                            -- Production line 481: updateTrackerRolloutHistory
                                            -- Decision was Continue (otherwise we wouldn't advance)
                                            updateLastHistoryEntry $ \lastH ->
                                                lastH
                                                    { historyCompletedAt = Just now
                                                    , historyDecision = Just Continue
                                                    }

                                            -- Apply next step
                                            -- Production line 129: index = index + 1
                                            -- Bounds-checked: strategy may have shrunk under us.
                                            nextStep <- case safeIndex strategy currentIndex of
                                                Just s -> pure s
                                                Nothing -> abortWithReason "rolloutStrategy index out of range (next step)"
                                            let nextNewW = rolloutPercent nextStep
                                                nextOldW = max 0 (100 - nextNewW)
                                                -- Capture previous rollout % before we append the new history entry
                                                previousRolloutW =
                                                    case unsnocList (rolloutHistory freshRT) of
                                                        Nothing -> 0
                                                        Just (_, lastEntry) -> historyRolloutPercent lastEntry
                                            logInfoS $
                                                "  Rollout step "
                                                    <> T.pack (show (currentIndex + 1))
                                                    <> "/"
                                                    <> T.pack (show totalSteps)
                                                    <> ": new="
                                                    <> T.pack (show nextNewW)
                                                    <> "%, cooloff="
                                                    <> T.pack (show (cooloffMinutes nextStep))
                                                    <> "min"

                                            -- Scale new deployment via the Julia max() formula BEFORE shifting traffic.
                                            scaleNewDeploymentForStage cfg ctx nextNewW (podPercent nextStep)
                                            -- LOOKAHEAD: pre-warm next-next stage's HPA min during the upcoming
                                            -- cooloff so the workflow doesn't pay a cold-start penalty when it
                                            -- advances. Mirrors Julia's `service.jl:511-515` pattern.
                                            case drop (currentIndex + 1) (rolloutStrategy freshRT) of
                                                (lookahead : _) ->
                                                    scaleNewDeploymentForStage cfg ctx (rolloutPercent lookahead) (podPercent lookahead)
                                                [] -> pure ()
                                            -- Apply VS rollout with lock
                                            runVsRolloutWithLock cfg ctx (wcMaxK8sRetries wfCfg) nextOldW nextNewW
                                            updateK8sField (\k8s -> k8s{trafficPercentage = nextNewW})

                                            -- Record new rollout history entry
                                            -- Production line 489: setRolloutHistory!(tracker, push!(...))
                                            newStepStart <- liftIO getCurrentTime
                                            let newHist = mkRolloutHistory nextNewW (cooloffMinutes nextStep) (podPercent nextStep) newStepStart Nothing
                                            updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [newHist]}

                                            -- Persist to DB via CAS — bail if a concurrent state
                                            -- change overtook us between the snapshot and now.
                                            currentRT <- getRT
                                            currentTS <- gets targetState
                                            casUpdateOrBail "rolloutLoop/advance" currentRT currentTS freshStatus

                                            -- Notify Slack
                                            lift $ notifyReleaseProgress currentRT nextNewW
                                            -- Production parity: BUSINESS / TRAFFIC_UPDATED
                                            logTrafficUpdated currentRT previousRolloutW

                                            -- Check health after applying step
                                            when (nextNewW < 100) $
                                                checkDeploymentHealth cfg ctx

                                            -- Continue loop with next index
                                            recurse (currentIndex + 1) newStepStart
                                        else do
                                            -- Decision engine said wait/abort - re-loop
                                            threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                                            recurseSame
                _ -> do
                    -- Unexpected status during rollout
                    logInfoS $ "  [rolloutLoop] Unexpected status: " <> T.pack (show (status freshRT)) <> ", stopping"
                    liftIO $ throwIO $ WorkflowError "rollout" ("Unexpected status: " <> T.pack (show (status freshRT)))

-- | Create a RolloutHistory entry (matches production RolloutHistory struct)
mkRolloutHistory :: Int -> Int -> Int -> UTCTime -> Maybe UTCTime -> RolloutHistory
mkRolloutHistory rollout cooloff pods startedAt completedAt =
    RolloutHistory
        { historyRolloutPercent = rollout
        , historyCooloffMinutes = cooloff
        , historyPodsPercent = pods
        , historyDecision = Nothing
        , historyDecisionReason = Nothing
        , historyStartedAt = startedAt
        , historyCompletedAt = completedAt
        , historyManualOverride = False
        , historyDecisionHs = Nothing
        , historyDecisionHsReason = Nothing
        }

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

-- | Monitor health: poll pods until all are Running+Ready, max 5 minutes
monitorHealth :: StateFlow ()
monitorHealth = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    -- Snapshot config for the monitor phase as well — postMonitorLoop polls
    -- in a tight loop and must not re-read on every iteration.
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "MONITORING health for " <> appGroup rt

    updateK8sStatus BSMonitoring
    logInfoS "  Waiting for pods to be ready (max 5 min, polling every 10s)"

    updateK8sStatus BSStabilize
    maxAttempts <- getPodReadinessMaxAttempts
    pollSeconds <- getPodReadinessPollSeconds
    restartThreshold <- getPodRestartCountThreshold
    logEnv <- lift getLoggerEnv
    waitResult <- liftIO $ waitForPodsReady logEnv cfg ctx maxAttempts pollSeconds restartThreshold
    case waitResult of
        Left errMsg -> do
            logErrorS $ "  Pod readiness check FAILED: " <> errMsg
            liftIO $ throwIO $ WorkflowError "monitoring" ("Pod readiness: " <> errMsg)
        Right () ->
            logInfoS "  All pods ready"

    -- Post-monitoring: after all pods are healthy at 100%, check HS decision
    -- Master gate (legacy flat boolean, kept as a kill switch) AND per-service gate.
    masterPostEnabled <- getConfigBoolForProduct "ab_hs_post_monitoring_enabled" (Just (appGroup rt)) False
    perServicePostEnabled <-
        if masterPostEnabled
            then isABHSPostMonitoringDecisionEnabledForAppGroupService (appGroup rt) (service rt)
            else pure False
    when perServicePostEnabled $ do
        logInfoS "[WORKFLOW] Starting post-monitoring phase"
        insertReleaseEvent
            (releaseId rt)
            "BUSINESS"
            "POST_MONITORING_STARTED"
            (toJSON ("Post-monitoring phase" :: T.Text))
        loopStart <- liftIO getCurrentTime
        postMonitorLoop wfCfg cfg rt 0 loopStart

    logInfoS "Health monitoring complete"

{- | Post-monitoring loop: poll HS decision engine after 100% traffic.
Max 30 iterations with collectMetricsDelay between polls.
-}
postMonitorLoop :: WorkflowConfig -> Config -> ReleaseTracker -> Int -> UTCTime -> StateFlow ()
postMonitorLoop wfCfg cfg rt iteration loopStart = do
    -- Bail-out safety: cap iterations and wall-clock duration.
    nowGuard <- liftIO getCurrentTime
    let elapsedTotal = realToFrac (diffUTCTime nowGuard loopStart) :: Double
    when (iteration > maxLoopIterations || elapsedTotal > maxLoopDurationSec) $ do
        logErrorS "  [postMonitorLoop] Bail-out: max iterations / duration exceeded"
        liftIO $ throwIO $ WorkflowError "monitoring" "Stuck post-monitor: max loop bail-out"
    if iteration > 30
        then do
            logInfoS "[WORKFLOW] Post-monitoring: max iterations reached, continuing"
            insertReleaseEvent
                (releaseId rt)
                "DECISION_ENGINE"
                "POST_MONITORING_TIMEOUT"
                (object ["iterations" .= (iteration :: Int)])
        else do
            hsResult <- getHSDecision cfg rt True -- isPostMonitoring=True
            insertReleaseEvent
                (releaseId rt)
                "DECISION_ENGINE"
                "POST_MONITORING_POLL"
                ( object
                    [ "iteration" .= iteration
                    , "decision" .= show (drDecision hsResult)
                    , "reason" .= drReason hsResult
                    ]
                )
            case drDecision hsResult of
                Continue -> do
                    logInfoS "[WORKFLOW] Post-monitoring: CONTINUE"
                    insertReleaseEvent
                        (releaseId rt)
                        "DECISION_ENGINE"
                        "POST_MONITORING_RESULT"
                        (object ["decision" .= ("Continue" :: T.Text)])
                Abort -> do
                    logErrorS "[WORKFLOW] Post-monitoring: ABORT"
                    insertReleaseEvent
                        (releaseId rt)
                        "DECISION_ENGINE"
                        "POST_MONITORING_RESULT"
                        (object ["decision" .= ("Abort" :: T.Text), "reason" .= drReason hsResult])
                    lift $ notifyGenericThreadMessage rt ("Post-monitoring ABORT: " <> maybe "no reason" id (drReason hsResult))
                    updateRT $ \r -> r{status = ABORTING}
                    currentRT <- getRT
                    currentTS <- gets targetState
                    -- CAS with the snapshot we read at the top of the loop iteration.
                    casUpdateOrBail "postMonitorLoop/abort" currentRT currentTS (status rt)
                    liftIO $ throwIO $ WorkflowError "monitoring" "Post-monitoring ABORT"
                Wait -> do
                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                    postMonitorLoop wfCfg cfg rt (iteration + 1) loopStart

-- | Poll pods until all are Running+Ready or timeout/failure
waitForPodsReady :: LoggerEnv -> Config -> K8sReleaseContext -> Int -> Int -> Int -> IO (Either T.Text ())
waitForPodsReady logEnv cfg ctx maxAttempts pollSeconds restartThreshold = go 0
  where
    go attempt
        | attempt >= maxAttempts = pure (Left "Timeout waiting for pods to be ready")
        | otherwise = do
            threadDelay (Seconds pollSeconds)
            (readyCount, _available, desired) <- do
                result <- getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
                case result of
                    Left _ -> pure (0, 0, 1)
                    Right vals -> pure vals
            logInfoIO logEnv $
                "    Poll "
                    <> T.pack (show (attempt + 1))
                    <> "/"
                    <> T.pack (show maxAttempts)
                    <> ": ready="
                    <> T.pack (show readyCount)
                    <> "/"
                    <> T.pack (show desired)

            -- Check for pod-level failures (CrashLoopBackOff, ImagePullBackOff, etc.)
            podHealth <- checkPodHealthDetailed cfg ctx restartThreshold
            case podHealth of
                Left errMsg -> do
                    logErrorIO logEnv $ "    Pod health check FAILED: " <> errMsg
                    pure (Left errMsg)
                Right msg -> do
                    -- TODO: migrate to structured logging
                    logInfoIO logEnv $ "    Pod health: " <> msg
                    if readyCount >= desired && desired > 0
                        then pure (Right ())
                        else go (attempt + 1)

{- | Detailed pod health check: restart count, CrashLoopBackOff, ImagePullBackOff
Returns Left errorMessage if pods are unhealthy, Right statusMessage if OK.
-}
checkPodHealthDetailed :: Config -> K8sReleaseContext -> Int -> IO (Either T.Text T.Text)
checkPodHealthDetailed cfg ctx restartThreshold = do
    let svcHost = serviceName ctx
        version = newVersion ctx
        ns = namespace ctx
        cmd =
            unwords
                [ kubectlBin cfg
                , "-n"
                , T.unpack ns
                , "get pods"
                , "-l"
                , "app=" <> T.unpack svcHost <> ",version=" <> T.unpack version
                , "-o"
                , "json"
                ]
    result <- runCmd cmd
    case result of
        Left _ -> pure (Right "Could not fetch pod status (non-fatal)")
        Right (K8sResult jsonStr) ->
            case A.decodeStrict' (TE.encodeUtf8 jsonStr) :: Maybe Value of
                Nothing -> pure (Right "Could not parse pod JSON (non-fatal)")
                Just podJson -> pure (analyzePodHealth restartThreshold podJson)

-- | Analyze pod health from kubectl JSON output
analyzePodHealth :: Int -> Value -> Either T.Text T.Text
analyzePodHealth restartThreshold (Object root) =
    case KM.lookup (K.fromText "items") root of
        Just (Array items) ->
            let podResults = map (checkSinglePod restartThreshold) (foldr (:) [] items)
                errors = [e | Left e <- podResults]
             in if null errors
                    then Right ("All " <> T.pack (show (length podResults)) <> " pod(s) healthy")
                    else Left (T.intercalate "; " errors)
        _ -> Right "No pods found (non-fatal)"
analyzePodHealth _ _ = Right "Unexpected JSON format (non-fatal)"

-- | Check a single pod for unhealthy conditions
checkSinglePod :: Int -> Value -> Either T.Text T.Text
checkSinglePod restartThreshold (Object podObj) =
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
                    <> [podName <> ": restartCount=" <> T.pack (show restartCount) <> " exceeds threshold (" <> T.pack (show restartThreshold) <> ")" | restartCount > restartThreshold]
         in errs
    checkContainer _ _ = []
checkSinglePod _ _ = Right "unknown"

{- | Cleanup old version.

Production parity (releaseCompletionActions, line 558-596):
- Records end time on the tracker
- Schedules scale-down of old pods (done by Runner's scaleDownOldDeployment on next poll)
rather than scaling down immediately
- Only scales down immediately if scale_down_pods_on_completion is enabled
- Captures AFTER snapshots for diff
-}
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "Cleaning up old version for " <> appGroup rt

    updateK8sStatus BSScaleDownOld

    -- Production line 559: update_release_end_time!(conn, tracker)
    now <- liftIO getCurrentTime
    updateRT $ \r -> r{endTime = Just now}

    if isNew
        then do
            -- New service: no old deployment to clean up
            logInfoS "  New service: no old deployment to clean up"
            updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})
        else do
            let oldDepName = serviceName ctx <> "-" <> oldVersion ctx

            -- Production line 560: scheduleScaleDownOfPods(tracker, conn)
            -- This schedules scale-down to happen later via the Runner's poll loop.
            -- The Runner's findCompletedTrackersForScaleDown + scaleDownOldDeployment handles this.
            -- We mark the intent so the Runner knows to scale down.
            logInfoS $ "  Scheduling scale-down for old deployment: " <> oldDepName
            updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = False})
            insertReleaseEvent
                (releaseId rt)
                "BUSINESS"
                "SCALE_DOWN_SCHEDULED"
                (toJSON $ "Scale-down scheduled for " <> T.unpack oldDepName)

            -- If scale_down_pods_on_completion is enabled, do it immediately too
            -- (production has this commented out but the Runner handles it)
            -- NOTE: Slack notification for pods scaled down is sent ONLY from the Runner's
            -- scaleDownOldDeployment on actual success — not here (avoids duplicates).
            let shouldScaleDownNow = wcScaleDownOnCompletion wfCfg
            when shouldScaleDownNow $ do
                logInfoS $ "  Immediate scale-down: " <> oldDepName
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
                logInfoS $ "  Deleting old HPA: " <> oldHpaName
                deleteResult <- liftIO $ runCmd (buildDeleteHpaCommand cfg (namespace ctx) oldHpaName)
                case deleteResult of
                    Right _ -> do
                        logInfoS "  Old HPA deleted"
                        insertReleaseEvent
                            (releaseId rt)
                            "BUSINESS"
                            "HPA_DELETED"
                            (toJSON oldHpaName)
                    Left err ->
                        logErrorS $ "  WARNING: Failed to delete old HPA: " <> T.pack (show err)

    -- Capture AFTER snapshots
    cfgAfter <- getCfg
    rtAfter <- getRT
    ctxAfter <- getK8sCtx
    captureDeploymentSnapshot cfgAfter (releaseId rtAfter) (namespace ctxAfter) (deploymentName ctxAfter) "DEPLOYMENT_AFTER"

    logInfoS "Cleanup complete"

{- | Notify complete.

Production parity (service.jl line 176 + releaseCompletionActions):
- Sets tracker status to COMPLETED
- Records completion event
- Persists final state to DB
- Notifies Slack
-}
notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    updateK8sStatus BSDone

    logInfoS $ "Release " <> releaseId rt <> " completed successfully!"
    logInfoS $ "   Service: " <> appGroup rt
    logInfoS $ "   Category: BackendService"
    logInfoS $ "   Status: COMPLETED"

    -- Production line 176: update_tracker_status!(conn, COMPLETED, tracker)
    now <- liftIO getCurrentTime
    updateRT $ \r -> r{status = COMPLETED, endTime = Just now}

    -- Persist final state to DB immediately (production does this in update_tracker_status!)
    currentRT <- getRT
    currentTS <- gets targetState
    insertReleaseTracker currentRT currentTS

    -- Log completion event
    -- Production parity: NOTIFICATION / STATUS_UPDATED
    let completionMsg = "Tracker marked as COMPLETED with " <> T.pack (show (getTrafficPct currentTS)) <> "% traffic"
    logStatusUpdated currentRT completionMsg

    -- Notify Slack
    lift $ notifyReleaseCompleted currentRT currentTS
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
