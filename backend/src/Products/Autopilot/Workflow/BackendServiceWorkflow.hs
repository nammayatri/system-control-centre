{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Backend service workflow (K8s deployment).

Re-entrant rollout: each poll cycle processes ONE step, re-reads the tracker
between steps (to catch pause/abort), records history per step. AUTO mode
consults the decision engine; MANUAL only advances on cooloff.
-}
module Products.Autopilot.Workflow.BackendServiceWorkflow (
    backendServiceSpec,
)
where

import Control.Applicative ((<|>))
import qualified Control.Concurrent as CC
import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import Core.Types.Time (Seconds (..), threadDelay)

import Core.Environment (getConfig, getLoggerEnv, logError, logInfo, logWarning)
import Core.Logging (LoggerEnv, logErrorIO, logInfoIO)
import Core.Workflow.Spec (WorkflowSpec (..))
import Core.Workflow.Stage (Stage)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE

import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Products.Autopilot.DecisionEngine (
    DecisionResult (..),
    PromCheckResult (..),
    checkPromQueries,
    getABDecision,
    getCombinedDecision,
    getHSDecision,
    initiateABDecisionForRelease,
    initiatePostMonitoringABDecisionForRelease,
    stopDecisionEngineHS,
 )

import Products.Autopilot.EventLog (logDecisionResult, logStatusUpdated, logTrafficUpdated)
import Products.Autopilot.K8s.Deployment (
    buildApplyFileCommand,
    buildCloneDeploymentCommand,
    buildCloneDeploymentWithEnvsCommand,
    buildConfigMapApplyCommand,
    buildPatchDeploymentEnvsCommand,
    buildScaleDeploymentCommand,
    buildScaleNamedDeploymentCommand,
    deploymentExists,
    getDeploymentReplicaStatus,
    serviceExists,
 )
import Products.Autopilot.K8s.DestinationRule (ensureDestinationRule)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd)
import Products.Autopilot.K8s.HPA (buildCloneHpaCommand, buildCreateHpaFromTemplateCommand, buildDeleteHpaCommand, getHpaMinMax, hpaExists)
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
    getPodsScaleDownDelayFromConfig,
    getReleaseStartDelay,
    isABHSDecisionEnabledForAppGroupService,
    isABHSPostMonitoringDecisionEnabledForAppGroupService,
    isHpaEnabledForProduct,
    isScaleDownPodsOnCompletion,
 )

import Products.Autopilot.Types.Release (
    Decision (..),
    Mode (..),
    ReleaseStatus (..),
    ReleaseTracker (appGroup, endTime, envOverrideData, mode, releaseId, rolloutHistory, rolloutStrategy, service, status),
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
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..), PodsScaleDownStatus (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers (
    captureDeploymentSnapshot,
    getRT,
    persistWorkflowState,
    updateRT,
 )
import Products.Autopilot.Workflow.StageHelpers (mkLegacyStateFlowStage)
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    StateFlow,
 )
import Shared.Config.Runtime (getConfigBoolForProduct)
import Prelude

{- | Six-stage backend service workflow (init → prepare → deploy → monitor →
finalize → done). Rollback is a no-op here; VS traffic restore on failure
is handled by the runner's 'restoreVsTrafficOnFailure'.
-}
backendServiceSpec :: WorkflowSpec ReleaseState
backendServiceSpec =
    WorkflowSpec
        { wsName = "BackendService"
        , wsStages =
            [ serviceStageInit
            , serviceStagePrepare
            , serviceStageDeploy
            , serviceStageMonitor
            , serviceStageFinalize
            , serviceStageDone
            ]
        , wsRollback = \_err -> pure ()
        , wsPersist = persistWorkflowState
        }

serviceStageInit
    , serviceStagePrepare
    , serviceStageDeploy
    , serviceStageMonitor
    , serviceStageFinalize
    , serviceStageDone ::
        Stage ReleaseState
serviceStageInit = mkLegacyStateFlowStage "init" INIT validatePreconditions
serviceStagePrepare = mkLegacyStateFlowStage "prepare" PREPARING prepareK8sResources
serviceStageDeploy = mkLegacyStateFlowStage "deploy" DEPLOYING progressiveRollout
serviceStageMonitor = mkLegacyStateFlowStage "monitor" MONITORING monitorHealth
serviceStageFinalize = mkLegacyStateFlowStage "finalize" FINALIZING cleanupOldVersion
serviceStageDone = mkLegacyStateFlowStage "done" DONE notifyComplete

getCfg :: StateFlow Config
getCfg = lift getConfig

logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

logErrorS :: T.Text -> StateFlow ()
logErrorS = lift . logError

getK8sCtx :: StateFlow K8sReleaseContext
getK8sCtx = do
    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) -> pure (context k8s)
        _ -> liftIO $ throwIO $ WorkflowError "init" "Missing K8sState in targetState"

isNewServiceRelease :: StateFlow Bool
isNewServiceRelease = do
    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) -> pure (newService k8s)
        _ -> pure False

runK8sIO :: IO (Either K8sError a) -> StateFlow a
runK8sIO action = do
    result <- liftIO action
    case result of
        Right a -> pure a
        Left (K8sError err) -> liftIO $ throwIO $ WorkflowError "k8s" err

{- | Subset of the first matching-host route in an istio VirtualService JSON doc.
Used by the internal-VS cross-validation in 'validatePreconditions'.
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
                                            let hostVal = case KM.lookup (K.fromText "host") d of
                                                    Just (String hostTxt) -> hostTxt
                                                    _ -> ""
                                                subsetVal = case KM.lookup (K.fromText "subset") d of
                                                    Just (String subsetTxt) -> Just subsetTxt
                                                    _ -> Nothing
                                             in if hostVal == host then subsetVal <|> acc else acc
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

{- | Block until the new deployment has desired replicas Ready before flipping
VS traffic — otherwise we 5xx spike routing to ContainerCreating pods.
Fast-fails on ImagePullBackOff/CrashLoopBackOff/restart-threshold.
-}
waitForStagePodsReady :: Config -> K8sReleaseContext -> StateFlow ()
waitForStagePodsReady cfg ctx = do
    maxAttempts <- getPodReadinessMaxAttempts
    pollSeconds <- getPodReadinessPollSeconds
    restartThreshold <- getPodRestartCountThreshold
    logEnv <- lift getLoggerEnv
    logInfoS "    [stage] waiting for new deployment pods to be Ready before flipping VS"
    waitResult <- liftIO $ waitForPodsReady logEnv cfg ctx maxAttempts pollSeconds restartThreshold
    case waitResult of
        Left errMsg -> do
            logErrorS $ "    [stage] Pod readiness FAILED before VS flip: " <> errMsg
            rt <- getRT
            insertReleaseEvent
                (releaseId rt)
                "BUSINESS"
                "STAGE_PODS_NOT_READY"
                (toJSON errMsg)
            lift $
                notifyGenericThreadMessage
                    rt
                    ("Aborting at stage transition — new pods never became Ready: " <> errMsg)
            liftIO $ throwIO $ WorkflowError "rollout-stage" ("Stage pod readiness: " <> errMsg)
        Right () ->
            logInfoS "    [stage] new deployment pods Ready, proceeding with VS flip"

scaleNewDeploymentForStage ::
    Config ->
    K8sReleaseContext ->
    -- | rolloutPercent (traffic %) for this stage
    Int ->
    -- | operator's explicit minimum pod count (raw, not %)
    Int ->
    StateFlow ()
scaleNewDeploymentForStage cfg ctx routePct stagePodCount = do
    rtNow <- getRT
    wfCfg <- loadWorkflowConfig (appGroup rtNow)
    let oldDep = serviceName ctx <> "-" <> oldVersion ctx
        newDep = deploymentName ctx
        newHpa = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
        ns = namespace ctx
    oldStatus <- liftIO $ getDeploymentReplicaStatus cfg ns oldDep
    newStatus <- liftIO $ getDeploymentReplicaStatus cfg ns newDep
    let
        -- (ready, available, desired)
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
        -- factor × oldDesired × routePct/100
        strategyByFactor =
            ceiling
                ( factor
                    * (fromIntegral currentOld :: Double)
                    / 100.0
                    * fromIntegral routePct
                )
        -- Share of old pods at (routePct + 10%), capped at 100 — headroom for mid-shift.
        predictedFromOld =
            let pct = min (routePct + 10) 100
             in ceiling
                    ( (fromIntegral oldVersionPods :: Double)
                        * fromIntegral pct
                        / 100.0
                    )
        operatorFloor = max 1 stagePodCount
        -- max-of-all-inputs: never shrink, never under-provision.
        target =
            maximum
                [ currentNew
                , strategyByFactor
                , availableNew
                , predictedFromOld
                , operatorFloor
                ]
    -- Pre-warm to the next stage's operator pods so [50%@5, 100%@10] doesn't
    -- wait out cooloff under-provisioned; HPA is too slow to close the gap.
    let nextStageFloor =
            let strat = rolloutStrategy rtNow
                idxAndNext = case dropWhile (\(_, s) -> rolloutPercent s /= routePct) (zip [0 :: Int ..] strat) of
                    ((i, _) : _) -> drop (i + 1) strat
                    _ -> []
             in case idxAndNext of
                    (next : _) -> max 1 (podCount next)
                    _ -> 0
        safeTarget =
            let baseTarget = if currentOld <= 0 then max 1 operatorFloor else target
             in max baseTarget nextStageFloor
    if currentNew >= safeTarget
        then
            logInfoS $
                "  [pods] "
                    <> newDep
                    <> " already at "
                    <> T.pack (show currentNew)
                    <> " replicas (safeTarget="
                    <> T.pack (show safeTarget)
                    <> ", currentOld="
                    <> T.pack (show currentOld)
                    <> ", route%="
                    <> T.pack (show routePct)
                    <> "), no-op"
        else do
            let logCtx =
                    " (safeTarget="
                        <> T.pack (show safeTarget)
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
                        <> ", podCount="
                        <> T.pack (show stagePodCount)
                        <> ", factor="
                        <> T.pack (show factor)
                        <> ")"
            -- Cap at HPA max; never mutate HPA here (only prepare stage does).
            (_liveMin, liveMax) <- liftIO $ getHpaMinMax cfg ns newHpa
            let cappedTarget
                    | liveMax > 0 = min safeTarget liveMax
                    | otherwise = safeTarget -- no HPA, or read failure
                wasCapped = liveMax > 0 && safeTarget > liveMax
            when wasCapped $ do
                logWarningS $
                    "  [pods] Rollout target "
                        <> T.pack (show safeTarget)
                        <> " exceeds HPA "
                        <> newHpa
                        <> " maxReplicas="
                        <> T.pack (show liveMax)
                        <> " — capping at "
                        <> T.pack (show liveMax)
                        <> logCtx
                insertReleaseEvent
                    (releaseId rtNow)
                    "BUSINESS"
                    "ROLLOUT_CAPPED_BY_HPA"
                    ( object
                        [ "hpa" .= newHpa
                        , "safeTarget" .= safeTarget
                        , "hpaMaxReplicas" .= liveMax
                        , "cappedTo" .= liveMax
                        , "routePct" .= routePct
                        ]
                    )
            logInfoS $
                "  [pods] Scaling "
                    <> newDep
                    <> " to "
                    <> T.pack (show cappedTarget)
                    <> (if wasCapped then " (capped from " <> T.pack (show safeTarget) <> ")" else "")
                    <> logCtx
            _ <- runK8sIO $ runCmd (buildScaleDeploymentCommand cfg ctx cappedTarget)
            pure ()

{- | Apply VS rollout under a pessimistic lock. Exp backoff (500ms → 8s, ~15s)
so parallel releases on the same app group serialize instead of aborting.
-}
runVsRolloutWithLock :: Config -> K8sReleaseContext -> Int -> Int -> Int -> StateFlow ()
runVsRolloutWithLock cfg ctx maxRetries oldW newW = do
    rt <- getRT
    let lockOwner = "release:" <> releaseId rt
        delaysMs = [500, 1000, 2000, 4000, 8000] :: [Int]
        attempt remainingDelays = do
            r <-
                withVsLock (appGroup rt) lockOwner $
                    liftIO $
                        applyVirtualServiceRolloutWithRetries maxRetries cfg ctx oldW newW
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

{- | Snapshot of RuntimeConfig values loaded once per workflow phase, so a
config change mid-rollout can't produce inconsistent decisions.
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
    -- ^ Safety multiplier on (oldDesired × routePct/100) (default 1.2).
    , wcPodsScaleDownDelay :: Double
    -- ^ Minutes after rollout success before scaling old deployment to 0.
    }

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
    psd <- getPodsScaleDownDelayFromConfig
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
            , wcPodsScaleDownDelay = psd
            }

-- | Loop bail-outs: paused-and-forgotten releases must not spin forever.
maxLoopIterations :: Int
maxLoopIterations = 10000

maxLoopDurationSec :: Double
maxLoopDurationSec = 24 * 60 * 60

{- | CAS-protected persistence: write only if on-disk status matches the
snapshot baseline, else bail with 'WorkflowError'.
-}
casUpdateOrBail ::
    T.Text ->
    ReleaseTracker ->
    Maybe TargetState ->
    -- | snapshot baseline status
    ReleaseStatus ->
    StateFlow ()
casUpdateOrBail tag updated mts oldStatus = do
    ok <- conditionalUpdateTracker updated mts (releaseStatusText oldStatus)
    when (not ok) $ do
        logWarningS $ "[" <> tag <> "] CAS failed - concurrent state change, exiting loop"
        liftIO $ throwIO $ WorkflowError "cas" "concurrent state change"

unsnocList :: [a] -> Maybe ([a], a)
unsnocList [] = Nothing
unsnocList xs = Just (Prelude.init xs, Prelude.last xs)

safeIndex :: [a] -> Int -> Maybe a
safeIndex xs i
    | i < 0 = Nothing
    | otherwise = case drop i xs of
        (x : _) -> Just x
        [] -> Nothing

-- | Transform the last rolloutHistory entry in-memory. Caller must persist.
updateLastHistoryEntry :: (RolloutHistory -> RolloutHistory) -> StateFlow ()
updateLastHistoryEntry f = do
    rt <- getRT
    case unsnocList (rolloutHistory rt) of
        Nothing -> pure ()
        Just (initH, lastH) ->
            updateRT $ \r -> r{rolloutHistory = initH <> [f lastH]}

-- | Mark ABORTED and persist unconditionally. For unrecoverable input errors.
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

-- | Validate preconditions: cluster reachable, namespace exists.
validatePreconditions :: StateFlow ()
validatePreconditions = do
    rt <- getRT
    cfg <- getCfg
    logInfoS $ "Validating preconditions for " <> appGroup rt

    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) ->
            modify $ \s -> s{targetState = Just (K8sState (k8s{categoryWorkflowStatus = BSInit}))}
        _ -> do
            let k8sState = emptyK8sState{categoryWorkflowStatus = BSInit}
            modify $ \s -> s{targetState = Just (K8sState k8sState)}

    ctx <- getK8sCtx
    isNew <- isNewServiceRelease

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

    -- Cross-check internal VS subset against tracker oldVersion; DISCARD on mismatch.
    let internalVsName = case internalVirtualServiceName ctx of
            Just t | not (T.null t) -> t
            _ -> serviceName ctx <> "-internal-vs"
    internalResult <- liftIO $ getVirtualServiceJson cfg (namespace ctx) internalVsName
    case internalResult of
        Left _ -> pure ()
        Right internalText -> do
            rt' <- getRT
            logInfoS $ "  Internal VS found: " <> internalVsName
            insertReleaseEvent
                (releaseId rt')
                "BUSINESS"
                "INTERNAL_VS_FOUND"
                (toJSON internalVsName)
            unless isNew $ do
                let host = serviceName ctx
                    expectedOld = oldVersion ctx
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
                            -- Re-read baseline: stale 'rt'' predates kubectl,
                            -- a concurrent write would orphan the tracker on CAS fail.
                            freshM <- findReleaseTracker (releaseId rt')
                            let baselineStatus = case freshM of
                                    Just (freshRT, _) -> releaseStatusText (status freshRT)
                                    Nothing -> releaseStatusText (status rt')
                            updateRT $ \r -> r{status = DISCARDED}
                            currentRT <- getRT
                            currentTS <- gets targetState
                            casOk <- conditionalUpdateTracker currentRT currentTS baselineStatus
                            unless casOk $ do
                                logErrorS $
                                    "  CAS failed when marking DISCARDED — tracker "
                                        <> releaseId rt'
                                        <> " was concurrently modified by another process; leaving DB status as-is"
                                insertReleaseEvent
                                    (releaseId rt')
                                    "BUSINESS"
                                    "CAS_FAILED_VS_VERSION_MISMATCH"
                                    (toJSON ("CAS baseline=" <> baselineStatus :: T.Text))
                            liftIO $ throwIO $ WorkflowError "vs-internal" msg

    logInfoS "  Cluster reachable, namespace exists"

    currentRT <- getRT
    currentTS <- gets targetState
    insertReleaseTracker currentRT currentTS

    logInfoS "Preconditions validated"

-- | ConfigMap, clone/create deployment, service check, DestinationRule, HPA.
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "PREPARING K8s resources for " <> appGroup rt <> if isNew then " (NEW SERVICE)" else ""

    -- On revert, delete stale new-version HPA so the clone branch recreates it clean.
    let isRevert = case revert ctx of
            Just n -> n /= 0
            Nothing -> False
    when isRevert $ do
        let revertHpaName = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
        logInfoS $ "  [PREPARING] Revert release — deleting stale new HPA " <> revertHpaName
        _ <- liftIO $ runCmd (buildDeleteHpaCommand cfg (namespace ctx) revertHpaName)
        pure ()

    updateK8sStatus BSApplyConfigMap
    logInfoS "  Applying ConfigMap"
    _ <- runK8sIO $ executeWithRetry cfg (buildConfigMapApplyCommand cfg ctx)
    updateK8sField (\k8s -> k8s{configMapApplied = True})

    -- envOverrideData: inject envs on clone, or patch in place on resume.
    updateK8sStatus BSCreateDeployment
    let envOverride = case envOverrideData rt of
            Just t | not (T.null t) -> Just t
            _ -> Nothing
    newDepExists <- liftIO $ deploymentExists cfg (namespace ctx) (deploymentName ctx)
    if newDepExists
        then case envOverride of
            Just envs -> do
                logInfoS "  Deployment already exists; patching envs from envOverrideData"
                _ <- runK8sIO $ executeWithRetry cfg (buildPatchDeploymentEnvsCommand cfg ctx envs)
                pure ()
            Nothing -> logInfoS "  Deployment already exists, skipping create/clone"
        else
            if isNew
                then do
                    case deployFilePath ctx of
                        Just fp -> do
                            logInfoS $ "  Creating new deployment from: " <> fp
                            _ <- runK8sIO $ executeWithRetry cfg (buildApplyFileCommand cfg fp)
                            pure ()
                        Nothing -> do
                            logErrorS $ "  ERROR: New service requires deployFilePath"
                            liftIO $ throwIO $ WorkflowError "deploy" "New service release requires deployFilePath"
                else case envOverride of
                    Just envs -> do
                        logInfoS $ "  Cloning deployment to " <> deploymentName ctx <> " with envOverrideData injected"
                        _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentWithEnvsCommand cfg ctx envs)
                        pure ()
                    Nothing -> do
                        logInfoS $ "  Cloning deployment to " <> deploymentName ctx
                        _ <- runK8sIO $ executeWithRetry cfg (buildCloneDeploymentCommand cfg ctx)
                        pure ()
    updateK8sField (\k8s -> k8s{deploymentCreated = True})

    -- Block until new pods Ready BEFORE VS flip / HPA setup so broken images
    -- abort immediately instead of routing to zero-ready pods.
    do
        -- Warmup: a skipped clone may leave deployment at 0 replicas (e.g.
        -- janitor scaled down a prior aborted release); waitForPodsReady's
        -- `desired > 0` precondition would otherwise loop to timeout.
        do
            curStatus <- liftIO $ getDeploymentReplicaStatus cfg (namespace ctx) (deploymentName ctx)
            let curDesired = case curStatus of
                    Right (_, _, d) -> d
                    Left _ -> 0
            when (curDesired <= 0) $ do
                oldStat <- liftIO $ getDeploymentReplicaStatus cfg (namespace ctx) (serviceName ctx <> "-" <> oldVersion ctx)
                let warmupReplicas = case oldStat of
                        Right (_, _, d) | d > 0 -> d
                        _ -> 1
                logInfoS $
                    "  [PREPARING] New deployment "
                        <> deploymentName ctx
                        <> " at 0 replicas — scaling to "
                        <> T.pack (show warmupReplicas)
                        <> " before readiness wait"
                _ <- liftIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) (deploymentName ctx) warmupReplicas)
                pure ()
        maxAttempts0 <- getPodReadinessMaxAttempts
        pollSeconds0 <- getPodReadinessPollSeconds
        restartThreshold0 <- getPodRestartCountThreshold
        logEnv0 <- lift getLoggerEnv
        logInfoS "  [PREPARING] Waiting for new deployment pods to become Ready"
        waitResult0 <- liftIO $ waitForPodsReady logEnv0 cfg ctx maxAttempts0 pollSeconds0 restartThreshold0
        case waitResult0 of
            Left errMsg -> do
                logErrorS $ "  [PREPARING] Pod readiness FAILED before traffic shift: " <> errMsg
                insertReleaseEvent
                    (releaseId rt)
                    "BUSINESS"
                    "PREPARING_PODS_NOT_READY"
                    (toJSON errMsg)
                lift $
                    notifyGenericThreadMessage
                        rt
                        ("Aborting before traffic shift — new deployment never became Ready: " <> errMsg)
                liftIO $ throwIO $ WorkflowError "deploy" ("Pod readiness in PREPARING: " <> errMsg)
            Right () ->
                logInfoS "  [PREPARING] New deployment pods Ready"

    updateK8sStatus BSUpdateService
    logInfoS "  Checking Service exists"
    svcOk <- liftIO $ serviceExists cfg (namespace ctx) (serviceName ctx)
    when (not svcOk) $
        logWarningS "  WARNING: Service not found (pods may still route via selector)"
    updateK8sField (\k8s -> k8s{serviceCreated = svcOk})

    updateK8sStatus BSApplyDestinationRule
    logInfoS "  Ensuring DestinationRule"
    _ <- runK8sIO $ ensureDestinationRule cfg ctx
    updateK8sField (\k8s -> k8s{destinationRuleApplied = True})

    -- HPA: preserve existing / clone from old / create from template.
    -- Mutated ONLY in prepare stage; rollout never touches HPA. Keeps operator's
    -- min/max sacred for the release lifetime.
    let hpaEnabled = wcHpaEnabled wfCfg
    when hpaEnabled $ do
        let newHpaName = serviceName ctx <> "-" <> newVersion ctx <> "-hpa"
            oldHpaName = serviceName ctx <> "-" <> oldVersion ctx <> "-hpa"
            hpaMinMaxFactor = wcHpaMinMaxFactor wfCfg
            defaultMinPods = wcHpaDefaultMinPods wfCfg
            -- Only used for first-release template creation.
            computeTemplateMinMax desired =
                let hpaMin = max 1 desired
                    hpaMax = max hpaMin (round (fromIntegral desired * hpaMinMaxFactor))
                 in (hpaMin, hpaMax)

        newHpaFound <- liftIO $ hpaExists cfg (namespace ctx) newHpaName
        if newHpaFound
            then do
                -- New HPA already exists (retry or operator patch): leave it alone.
                logInfoS $ "  HPA " <> newHpaName <> " already exists, preserving (no patch)"
                updateK8sField (\k8s -> k8s{hpaCreated = True})
                insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_PRESERVED" (toJSON newHpaName)
            else do
                oldHpaFound <- liftIO $ hpaExists cfg (namespace ctx) oldHpaName
                if oldHpaFound
                    then do
                        -- Clone old HPA verbatim; only name/scaleTargetRef rewritten.
                        logInfoS $ "  Cloning HPA from " <> oldHpaName <> " (preserving min/max/metrics/behavior)"
                        cloneResult <- liftIO $ runCmd (buildCloneHpaCommand cfg (namespace ctx) (serviceName ctx) (oldVersion ctx) (newVersion ctx) oldHpaName)
                        case cloneResult of
                            Right _ -> do
                                logInfoS "  HPA cloned successfully"
                                updateK8sField (\k8s -> k8s{hpaCreated = True})
                                insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_CLONED" (toJSON newHpaName)
                            Left (K8sError err) -> logErrorS $ "  [HPA] Clone failed (non-fatal): " <> err
                    else do
                        -- First release: create from template using last stage's
                        -- podCount as steady-state target. This is the only place
                        -- we compute HPA bounds (no prior HPA to inherit from).
                        let targetPods = case rolloutStrategy rt of
                                [] -> defaultMinPods
                                steps -> max 1 (podCount (last steps))
                        mTemplate <- getHpaTemplate
                        case mTemplate of
                            Just tmpl | not (T.null tmpl) -> do
                                let (hpaMin, hpaMax) = computeTemplateMinMax targetPods
                                logInfoS $ "  Creating HPA from template: " <> newHpaName <> " (min=" <> T.pack (show hpaMin) <> " max=" <> T.pack (show hpaMax) <> ")"
                                createResult <- liftIO $ runCmd (buildCreateHpaFromTemplateCommand cfg (namespace ctx) (serviceName ctx) (newVersion ctx) tmpl hpaMin hpaMax)
                                case createResult of
                                    Right _ -> do
                                        logInfoS "  HPA created from template"
                                        updateK8sField (\k8s -> k8s{hpaCreated = True})
                                        insertReleaseEvent (releaseId rt) "BUSINESS" "HPA_CREATED_FROM_TEMPLATE" (toJSON newHpaName)
                                    Left (K8sError err) -> logErrorS $ "  [HPA] Create from template failed (non-fatal): " <> err
                            _ -> logInfoS "  No hpa_template configured; skipping HPA create"

    -- Initiate AB decision pod ONCE per release; verdict read later by getHSDecision.
    -- Fail-closed: abort the release if initiate fails.
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

{- | Progressive rollout: shift traffic old -> new per tracker rollout_strategy.
One step per loop iteration; re-reads tracker each iteration to catch
pause/abort/strategy changes. MANUAL advances on cooloff only; AUTO also
requires decision engine Continue. Sleeps collectMetricsDelay per iteration.
-}
progressiveRollout :: StateFlow ()
progressiveRollout = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "Starting progressive rollout for " <> appGroup rt

    updateK8sStatus BSFlipVirtualService
    updateK8sField (\k8s -> k8s{virtualServiceApplied = True})

    updateK8sStatus BSProgressiveRollout

    let releaseStartDelay = wcReleaseStartDelay wfCfg
    when (releaseStartDelay > 0) $ do
        logInfoS $ "  Release start delay: " <> T.pack (show releaseStartDelay) <> " seconds"
        threadDelay (Seconds releaseStartDelay)
    -- Re-fetch after start delay so any RM edit (strategy/mode) lands before rollout.
    when (releaseStartDelay > 0) $ do
        mFresh <- findReleaseTracker (releaseId rt)
        case mFresh of
            Just (freshRT, freshTS) -> do
                modify $ \s -> s{releaseTracker = freshRT, targetState = freshTS}
                logInfoS "  Re-read tracker after release-start delay"
            Nothing -> pure ()

    if isNew
        then do
            logInfoS "  New service: routing 100% traffic to new version"
            runVsRolloutWithLock cfg ctx (wcMaxK8sRetries wfCfg) 0 100
            updateK8sField (\k8s -> k8s{trafficPercentage = 100})
            now <- liftIO getCurrentTime
            let histEntry = mkRolloutHistory 100 0 100 now (Just now)
            updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [histEntry]}
            currentRT <- getRT
            casUpdateOrBail
                "progressiveRollout/new"
                currentRT
                (Just (K8sState (emptyK8sState{context = ctx, trafficPercentage = 100})))
                (status rt)
            lift $ notifyReleaseProgress currentRT 100
        else do
            case rolloutStrategy rt of
                [] -> abortWithReason "empty rolloutStrategy"
                strategy -> do
                    let totalSteps = length strategy
                        existingHistory = rolloutHistory rt
                        alreadyStarted = not (null existingHistory)

                    if alreadyStarted
                        then do
                            let currentIndex = length existingHistory
                            logInfoS $ "  Resuming rollout from step " <> T.pack (show currentIndex) <> "/" <> T.pack (show totalSteps)
                            loopStart <- liftIO getCurrentTime
                            rolloutLoop wfCfg cfg ctx currentIndex totalSteps loopStart 0 loopStart
                        else do
                            let (firstStep : _) = strategy
                                firstNewW = rolloutPercent firstStep
                                firstOldW = max 0 (100 - firstNewW)
                            logInfoS $ "  Initial rollout step: new=" <> T.pack (show firstNewW) <> "%, cooloff=" <> T.pack (show (cooloffMinutes firstStep)) <> "min"
                            scaleNewDeploymentForStage cfg ctx firstNewW (podCount firstStep)
                            waitForStagePodsReady cfg ctx
                            runVsRolloutWithLock cfg ctx (wcMaxK8sRetries wfCfg) firstOldW firstNewW
                            updateK8sField (\k8s -> k8s{trafficPercentage = firstNewW})

                            stepStartTime <- liftIO getCurrentTime
                            let firstHist = mkRolloutHistory firstNewW (cooloffMinutes firstStep) (podCount firstStep) stepStartTime Nothing
                            updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [firstHist]}
                            currentRT <- getRT
                            casUpdateOrBail
                                "progressiveRollout/first"
                                currentRT
                                (Just (K8sState (emptyK8sState{context = ctx, trafficPercentage = firstNewW})))
                                (status rt)
                            lift $ notifyReleaseProgress currentRT firstNewW
                            logTrafficUpdated currentRT 0

                            rolloutLoop wfCfg cfg ctx 1 totalSteps stepStartTime 0 stepStartTime

    logInfoS "Progressive rollout complete"

{- | Re-entrant rollout loop: each iter re-reads the tracker, handles terminal
states, advances on cooloff, sleeps collectMetricsDelay between polls.
-}
rolloutLoop ::
    WorkflowConfig ->
    Config ->
    K8sReleaseContext ->
    Int ->
    Int ->
    UTCTime ->
    -- | iteration counter (bail-out)
    Int ->
    -- | loop start (bail-out)
    UTCTime ->
    StateFlow ()
rolloutLoop wfCfg cfg ctx currentIndex totalSteps stepStartTime iterCount loopStart = do
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
        _ <- conditionalUpdateTracker currentRT currentTS (releaseStatusText (status rtStuck))
        liftIO $ throwIO $ WorkflowError "rollout" "Stuck rollout: max loop bail-out"

    rt <- getRT
    freshResult <- findReleaseTracker (releaseId rt)
    case freshResult of
        Nothing -> do
            logErrorS "  [rolloutLoop] Tracker deleted from DB, aborting"
            liftIO $ throwIO $ WorkflowError "rollout" "Tracker deleted during rollout"
        Just (freshRT, freshMts) -> do
            updateRT $ \_ -> freshRT
            case freshMts of
                Just ts -> modify $ \s -> s{targetState = Just ts}
                Nothing -> pure ()

            -- Re-read strategy each iteration so mid-flight edits take effect.
            let strategy = rolloutStrategy freshRT
                freshTotalSteps = length strategy
                freshStatus = status freshRT
                recurse newIdx newStepStart =
                    rolloutLoop wfCfg cfg ctx newIdx freshTotalSteps newStepStart (iterCount + 1) loopStart
                recurseSame =
                    rolloutLoop wfCfg cfg ctx currentIndex freshTotalSteps stepStartTime (iterCount + 1) loopStart

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
                    logInfoS "  [rolloutLoop] Tracker is PAUSED, waiting..."
                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                    recurseSame
                INPROGRESS -> do
                    -- Fast-fail pod health each iteration so mid-rollout crashes
                    -- are caught immediately, not at final readiness.
                    do
                        restartThresholdRL <- getPodRestartCountThreshold
                        healthRL <- liftIO $ checkPodHealthDetailed cfg ctx restartThresholdRL
                        case healthRL of
                            Left errMsg -> do
                                logErrorS $ "  [rolloutLoop] Pod health FAILED mid-rollout: " <> errMsg
                                insertReleaseEvent
                                    (releaseId freshRT)
                                    "BUSINESS"
                                    "ROLLOUT_PODS_UNHEALTHY"
                                    (toJSON errMsg)
                                lift $
                                    notifyGenericThreadMessage
                                        freshRT
                                        ("Aborting mid-rollout — pod health degraded: " <> errMsg)
                                liftIO $ throwIO $ WorkflowError "rollout" ("Pod health: " <> errMsg)
                            Right _ -> pure ()

                    let currentMode = mode freshRT

                    if currentIndex >= totalSteps
                        then do
                            logInfoS "  [rolloutLoop] All rollout steps completed"
                            -- Race guard: single-stage 100% rollouts don't loop, so an
                            -- abort/pause between fresh read and final CAS would be lost.
                            finalFresh <- findReleaseTracker (releaseId freshRT)
                            case finalFresh of
                                Just (finalRT, _)
                                    | status finalRT /= INPROGRESS -> do
                                        logWarningS $
                                            "  [rolloutLoop] Status changed to "
                                                <> T.pack (show (status finalRT))
                                                <> " during final-step commit — bailing (user abort/pause landed in race window)"
                                        liftIO $ throwIO $ WorkflowError "rollout" ("Concurrent status change to " <> T.pack (show (status finalRT)))
                                _ -> pure ()
                            now <- liftIO getCurrentTime
                            case unsnocList (rolloutHistory freshRT) of
                                Nothing -> pure ()
                                Just _ -> do
                                    updateLastHistoryEntry $ \lastH ->
                                        lastH{historyCompletedAt = Just now, historyDecision = Just Continue}
                                    currentRT <- getRT
                                    casUpdateOrBail "rolloutLoop/finalHist" currentRT freshMts freshStatus
                        else do
                            -- Fast-forward sets cooloff to 0.
                            now <- liftIO getCurrentTime
                            -- Strategy may have shrunk under us since snapshot.
                            currentStep <- case safeIndex strategy (currentIndex - 1) of
                                Just s -> pure s
                                Nothing -> abortWithReason "rolloutStrategy index out of range (current step)"
                            let cooloffMins = cooloffMinutes currentStep
                                elapsed = diffUTCTime now stepStartTime
                                cooloffSecs = fromIntegral cooloffMins * 60 :: Double
                                cooloffExceeded = realToFrac elapsed >= cooloffSecs

                            if not cooloffExceeded
                                then do
                                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                                    recurseSame
                                else do
                                    shouldAdvance <- case currentMode of
                                        MANUAL -> do
                                            logInfoS "  [rolloutLoop] MANUAL mode: cooloff exceeded, advancing"
                                            pure True
                                        AUTO -> do
                                            logInfoS "  [rolloutLoop] AUTO mode: checking health before advancing"
                                            checkDeploymentHealth cfg ctx

                                            mSvcConfig <- findServiceByProductAndName (appGroup freshRT) (service freshRT)
                                            let mDecisionConfig = mSvcConfig >>= S.dcDecisionConfig
                                            promResult <- checkPromQueries cfg freshRT mDecisionConfig
                                            case promResult of
                                                PromAbort reason -> do
                                                    logErrorS $ "[DECISION] Prometheus ABORT: " <> reason
                                                    logStatusUpdated freshRT ("ABORTING the release because prom query checks failing: " <> reason)
                                                    lift $ notifyGenericThreadMessage freshRT ("Prometheus check ABORT: " <> reason)
                                                    updateRT $ \r -> r{status = ABORTING}
                                                    currentRT' <- getRT
                                                    currentTS' <- gets targetState
                                                    casUpdateOrBail "rolloutLoop/promAbort" currentRT' currentTS' freshStatus
                                                    liftIO $ throwIO $ WorkflowError "decision" ("Prometheus ABORT: " <> reason)
                                                PromWarn reason -> do
                                                    logWarningS $ "[DECISION] Prometheus WARN: " <> reason
                                                    lift $ notifyGenericThreadMessage freshRT ("Prometheus warning: " <> reason)
                                                PromOK -> pure ()

                                            -- AB + HS decisions, per-(product,service) gated.
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

                                            let combinedDecision = getCombinedDecision abDecision hsDecision
                                                abReasonText = maybe "" id (drReason abDecision)
                                                hsReasonText = maybe "" id (drReason hsDecision)
                                                combinedReasons = filter (not . T.null) [abReasonText, hsReasonText]
                                                combinedResultText =
                                                    "AB="
                                                        <> T.pack (show (drDecision abDecision))
                                                        <> " HS="
                                                        <> T.pack (show (drDecision hsDecision))

                                            -- Write decision into last history entry BEFORE the
                                            -- DECISION_RESULT event so its embedded history includes it.
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

                                            rtForEvent <- getRT
                                            logDecisionResult rtForEvent combinedDecision combinedResultText combinedReasons

                                            case combinedDecision of
                                                Continue -> pure True
                                                Wait -> pure False
                                                WaitForMoreIteration -> pure False
                                                Abort -> do
                                                    logStatusUpdated rtForEvent "ABORTING the release because of the Decision Engine"
                                                    updateRT $ \r -> r{status = ABORTING}
                                                    currentRT' <- getRT
                                                    currentTS' <- gets targetState
                                                    casUpdateOrBail "rolloutLoop/decisionAbort" currentRT' currentTS' freshStatus
                                                    logStatusUpdated currentRT' ("Rolling back the traffic to version " <> oldVersion ctx)
                                                    liftIO $ throwIO $ WorkflowError "decision" "Decision engine: ABORT"

                                    if shouldAdvance
                                        then do
                                            updateLastHistoryEntry $ \lastH ->
                                                lastH
                                                    { historyCompletedAt = Just now
                                                    , historyDecision = Just Continue
                                                    }

                                            nextStep <- case safeIndex strategy currentIndex of
                                                Just s -> pure s
                                                Nothing -> abortWithReason "rolloutStrategy index out of range (next step)"
                                            let nextNewW = rolloutPercent nextStep
                                                nextOldW = max 0 (100 - nextNewW)
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

                                            -- Scale + wait Ready BEFORE VS flip (see waitForStagePodsReady).
                                            scaleNewDeploymentForStage cfg ctx nextNewW (podCount nextStep)
                                            waitForStagePodsReady cfg ctx
                                            runVsRolloutWithLock cfg ctx (wcMaxK8sRetries wfCfg) nextOldW nextNewW
                                            updateK8sField (\k8s -> k8s{trafficPercentage = nextNewW})

                                            newStepStart <- liftIO getCurrentTime
                                            let newHist = mkRolloutHistory nextNewW (cooloffMinutes nextStep) (podCount nextStep) newStepStart Nothing
                                            updateRT $ \r -> r{rolloutHistory = rolloutHistory r <> [newHist]}

                                            currentRT <- getRT
                                            currentTS <- gets targetState
                                            casUpdateOrBail "rolloutLoop/advance" currentRT currentTS freshStatus

                                            lift $ notifyReleaseProgress currentRT nextNewW
                                            logTrafficUpdated currentRT previousRolloutW

                                            when (nextNewW < 100) $
                                                checkDeploymentHealth cfg ctx

                                            recurse (currentIndex + 1) newStepStart
                                        else do
                                            threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                                            recurseSame
                _ -> do
                    logInfoS $ "  [rolloutLoop] Unexpected status: " <> T.pack (show (status freshRT)) <> ", stopping"
                    liftIO $ throwIO $ WorkflowError "rollout" ("Unexpected status: " <> T.pack (show (status freshRT)))

mkRolloutHistory :: Int -> Int -> Int -> UTCTime -> Maybe UTCTime -> RolloutHistory
mkRolloutHistory rollout cooloff pods startedAt completedAt =
    RolloutHistory
        { historyRolloutPercent = rollout
        , historyCooloffMinutes = cooloff
        , historyPodsCount = pods
        , historyDecision = Nothing
        , historyDecisionReason = Nothing
        , historyStartedAt = startedAt
        , historyCompletedAt = completedAt
        , historyManualOverride = False
        , historyDecisionHs = Nothing
        , historyDecisionHsReason = Nothing
        }

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

-- | Poll pods until Running+Ready, max ~5 min. Runs post-monitoring if enabled.
monitorHealth :: StateFlow ()
monitorHealth = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
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

    -- Post-monitoring HS check once at 100%: master kill switch AND per-service gate.
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
        -- Spawn post-monitoring AB pod ONCE; HS GET loop reads run_id "<id>-post".
        _ <- lift $ initiatePostMonitoringABDecisionForRelease cfg rt
        loopStart <- liftIO getCurrentTime
        postMonitorLoop wfCfg cfg rt 0 loopStart
        lift $ stopDecisionEngineHS cfg (releaseId rt <> "-post")

    logInfoS "Health monitoring complete"

-- | Poll HS decision after 100% traffic. Max 30 iterations, delay between polls.
postMonitorLoop :: WorkflowConfig -> Config -> ReleaseTracker -> Int -> UTCTime -> StateFlow ()
postMonitorLoop wfCfg cfg rt iteration loopStart = do
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
            hsResult <- getHSDecision cfg rt True
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
                    -- Post-monitoring is AFTER 100% traffic; auto-rollback would kill
                    -- live traffic on a deployment that passed every gate. Alert only.
                    logErrorS "[WORKFLOW] Post-monitoring ABORT — alerting (NOT auto-rolling back, traffic stays at 100%)"
                    insertReleaseEvent
                        (releaseId rt)
                        "DECISION_ENGINE"
                        "POST_MONITORING_RESULT"
                        ( object
                            [ "decision" .= ("Abort" :: T.Text)
                            , "reason" .= drReason hsResult
                            , "action" .= ("alert_only_no_rollback" :: T.Text)
                            ]
                        )
                    lift $
                        notifyGenericThreadMessage
                            rt
                            ( "🚨 POST-MONITORING ABORT (NOT auto-reverted — traffic at 100%): "
                                <> maybe "no reason" id (drReason hsResult)
                                <> " — operator must decide whether to revert manually."
                            )
                Wait -> do
                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                    postMonitorLoop wfCfg cfg rt (iteration + 1) loopStart
                WaitForMoreIteration -> do
                    threadDelay (Seconds (wcCollectMetricsDelay wfCfg))
                    postMonitorLoop wfCfg cfg rt (iteration + 1) loopStart

-- | Poll pods until Running+Ready, or fast-fail on bad container states.
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

            podHealth <- checkPodHealthDetailed cfg ctx restartThreshold
            case podHealth of
                Left errMsg -> do
                    logErrorIO logEnv $ "    Pod health check FAILED: " <> errMsg
                    pure (Left errMsg)
                Right msg -> do
                    logInfoIO logEnv $ "    Pod health: " <> msg
                    if readyCount >= desired && desired > 0
                        then pure (Right ())
                        else go (attempt + 1)

-- | Detailed pod health check. Left = unhealthy reason; Right = status msg.
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
        containerErrors = case containerStatuses of
            Nothing -> []
            Just cs -> concatMap (checkContainer podName) cs
     in case phase of
            Just "Failed" -> Left (podName <> ": pod phase is Failed")
            Just "Error" -> Left (podName <> ": pod phase is Error (application crashing)")
            _ ->
                if null containerErrors
                    then Right (podName <> ": OK")
                    else Left (T.intercalate "; " containerErrors)
  where
    getObj' key (Object o) = case KM.lookup (K.fromText key) o of
        Just (String t) -> Just t
        _ -> Nothing
    getObj' _ _ = Nothing

    -- Fail-fast waiting-reason list: only states kubelet sets on first sync
    -- (no transient Pending/ContainerCreating). Runs inside the poll loop.
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
            terminatedReason = case KM.lookup (K.fromText "state") cObj of
                Just (Object stateObj) -> case KM.lookup (K.fromText "terminated") stateObj of
                    Just (Object termObj) -> case KM.lookup (K.fromText "reason") termObj of
                        Just (String r) -> Just r
                        _ -> Nothing
                    _ -> Nothing
                _ -> Nothing
            errs =
                []
                    <> [podName <> ": ImagePullBackOff (image pull failed)" | waitingReason == Just "ImagePullBackOff"]
                    <> [podName <> ": ErrImagePull (image pull error)" | waitingReason == Just "ErrImagePull"]
                    <> [podName <> ": InvalidImageName (malformed image reference)" | waitingReason == Just "InvalidImageName"]
                    <> [podName <> ": ImageInspectError" | waitingReason == Just "ImageInspectError"]
                    <> [podName <> ": CreateContainerConfigError (referenced secret/configmap missing or invalid)" | waitingReason == Just "CreateContainerConfigError"]
                    <> [podName <> ": CreateContainerError" | waitingReason == Just "CreateContainerError"]
                    <> [podName <> ": RunContainerError (referenced envs not in configmap/secrets)" | waitingReason == Just "RunContainerError"]
                    <> [podName <> ": CrashLoopBackOff (env vars missing or app crashing)" | waitingReason == Just "CrashLoopBackOff"]
                    <> [podName <> ": container terminated with OOMKilled" | terminatedReason == Just "OOMKilled"]
                    <> [podName <> ": container terminated with reason " <> r | Just r <- [terminatedReason], r `elem` ["ContainerCannotRun", "DeadlineExceeded", "Error"]]
                    -- Catches app crashes that haven't escalated to CrashLoopBackOff yet.
                    <> [podName <> ": restartCount=" <> T.pack (show restartCount) <> " exceeds threshold (" <> T.pack (show restartThreshold) <> ")" | restartCount > restartThreshold]
         in errs
    checkContainer _ _ = []
checkSinglePod _ _ = Right "unknown"

{- | Finalize: record end time, schedule old-deployment scale-down, delete old HPA.
Actual scale-down happens in Runner after tracker reaches COMPLETED.
-}
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    wfCfg <- loadWorkflowConfig (appGroup rt)
    logInfoS $ "Cleaning up old version for " <> appGroup rt

    -- Best-effort stop of the primary AB decision pod on the success path.
    lift $ stopDecisionEngineHS cfg (releaseId rt)

    updateK8sStatus BSScaleDownOld

    now <- liftIO getCurrentTime
    updateRT $ \r -> r{endTime = Just now}

    if isNew
        then do
            logInfoS "  New service: no old deployment to clean up"
            updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})
        else do
            let oldDepName = serviceName ctx <> "-" <> oldVersion ctx

            -- Write SCALE_DOWN_SCHEDULED + timestamp so the Runner's
            -- findCompletedTrackersForScaleDown picks the tracker up.
            logInfoS $ "  Scheduling scale-down for old deployment: " <> oldDepName
            scheduleAt <- liftIO $ do
                t <- getCurrentTime
                let delaySec = wcPodsScaleDownDelay wfCfg * 60.0
                pure (addUTCTime (realToFrac delaySec :: NominalDiffTime) t)
            updateK8sField $ \k8s ->
                let oldCtx = context k8s
                    newCtx = oldCtx{podsScaleDownStatus = Just ScaleDownScheduled, podsScaleDownTimestamp = Just scheduleAt}
                 in k8s{oldDeploymentScaledDown = False, context = newCtx}
            insertReleaseEvent
                (releaseId rt)
                "BUSINESS"
                "SCALE_DOWN_SCHEDULED"
                ( object
                    [ "oldDeployment" .= oldDepName
                    , "scheduledAt" .= scheduleAt
                    ]
                )

            -- NEVER scale down the old deployment from inside the workflow: a
            -- backend restart before the COMPLETED transition would leave an
            -- orphan INPROGRESS tracker and restoreVsTrafficOnFailure would
            -- route to zero pods (5xx outage). Runner handles it post-COMPLETED.
            let _ = wcScaleDownOnCompletion wfCfg

            -- Delete old-version HPA so a revert can re-create it cleanly.
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

    cfgAfter <- getCfg
    rtAfter <- getRT
    ctxAfter <- getK8sCtx
    captureDeploymentSnapshot cfgAfter (releaseId rtAfter) (namespace ctxAfter) (deploymentName ctxAfter) "DEPLOYMENT_AFTER"

    logInfoS "Cleanup complete"

-- | Mark COMPLETED, persist, emit STATUS_UPDATED, notify Slack.
notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    updateK8sStatus BSDone

    logInfoS $ "Release " <> releaseId rt <> " completed successfully!"
    logInfoS $ "   Service: " <> appGroup rt
    logInfoS $ "   Category: BackendService"
    logInfoS $ "   Status: COMPLETED"

    now <- liftIO getCurrentTime
    updateRT $ \r -> r{status = COMPLETED, endTime = Just now}

    currentRT <- getRT
    currentTS <- gets targetState
    insertReleaseTracker currentRT currentTS

    let completionMsg = "Tracker marked as COMPLETED with " <> T.pack (show (getTrafficPct currentTS)) <> "% traffic"
    logStatusUpdated currentRT completionMsg

    lift $ notifyReleaseCompleted currentRT currentTS
  where
    getTrafficPct Nothing = 100 :: Int
    getTrafficPct (Just (K8sState k8s)) = trafficPercentage k8s
    getTrafficPct _ = 100

updateK8sStatus :: BackendServiceWFStatus -> StateFlow ()
updateK8sStatus newStatus = do
    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) -> do
            let k8s' = k8s{categoryWorkflowStatus = newStatus}
            modify $ \s -> s{targetState = Just (K8sState k8s')}
        _ -> return ()

updateK8sField :: (K8sDeploymentState -> K8sDeploymentState) -> StateFlow ()
updateK8sField f = do
    rs <- gets id
    case targetState rs of
        Just (K8sState k8s) -> do
            let k8s' = f k8s
            modify $ \s -> s{targetState = Just (K8sState k8s')}
        _ -> return ()
