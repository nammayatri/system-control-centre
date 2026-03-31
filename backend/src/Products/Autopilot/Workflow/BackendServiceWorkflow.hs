{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Backend service workflow (K8s deployment)

This module implements the workflow for deploying backend services to Kubernetes.
It uses the new type system with:
- ReleaseCategory (BackendService)
- ReleaseWFStatus (generic stages)
- BackendServiceWFStatus (K8s-specific sub-stages)
- Recorded monad for checkpoint/resume
-}
module Products.Autopilot.Workflow.BackendServiceWorkflow (
    backendServiceWorkflow,
)
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Config (Config (..))
import Products.Autopilot.RuntimeConfig (isScaleDownPodsOnCompletion, isHpaEnabledForProduct, getHpaMinMaxFactor)
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (getConfig, getDBEnv)
import qualified Data.Text as T
import Data.Aeson (Value (..), eitherDecode, toJSON)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.Encoding as TE
import Products.Autopilot.K8s.Deployment (
    buildApplyFileCommand,
    buildCloneDeploymentCommand,
    buildConfigMapApplyCommand,
    buildDeleteDeploymentCommand,
    buildScaleNamedDeploymentCommand,
    deploymentExists,
    getDeploymentReplicaStatus,
    serviceExists,
 )
import Products.Autopilot.K8s.DestinationRule (ensureDestinationRule)
import Products.Autopilot.K8s.HPA (hpaExists, buildCloneHpaCommand)
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), executeWithRetry, runCmd)
import Products.Autopilot.K8s.VirtualService (applyVirtualServiceRollout, getVirtualServiceJson)
import Products.Autopilot.Notifications (
    notifyPodsScaledDown,
    notifyReleaseCompleted,
    notifyReleaseProgress,
 )

-- Selective import: exclude oldVersion/newVersion to avoid clash with K8sReleaseContext
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (product, releaseId, status))
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
    captureVSSnapshot,
    getRT,
    updateRT,
    (|>>),
 )
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
 )
import Prelude hiding (product)

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend service workflow using generic stages
backendServiceWorkflow :: ReleaseWorkFlow ()
backendServiceWorkflow = do
    Init |>> validatePreconditions
    Preparing |>> prepareK8sResources
    Deploying |>> progressiveRollout
    Monitoring |>> monitorHealth
    Finalizing |>> cleanupOldVersion
    Done |>> notifyComplete

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

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate preconditions: cluster reachable, namespace exists
validatePreconditions :: StateFlow ()
validatePreconditions = do
    rt <- getRT
    cfg <- getCfg
    liftIO $ putStrLn $ "Validating preconditions for " <> T.unpack (product rt)

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
                    [ kubectlBin cfg
                    , "-n"
                    , T.unpack (namespace ctx)
                    , "get namespace"
                    , T.unpack (namespace ctx)
                    ]
                )

    when isNew $
        liftIO $ putStrLn "  New service release: skipping old version validation"

    -- Check internal VS (if exists) and log if found
    let internalVsName = serviceName ctx <> "-internal-vs"
    internalResult <- liftIO $ getVirtualServiceJson cfg (namespace ctx) internalVsName
    case internalResult of
        Left _ -> pure ()  -- No internal VS, that's fine
        Right _ -> do
            db <- getDB
            rt <- getRT
            liftIO $ putStrLn $ "  Internal VS found: " <> T.unpack internalVsName
            liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "INTERNAL_VS_FOUND"
                (toJSON internalVsName)

    liftIO $ putStrLn "  Cluster reachable, namespace exists"
    liftIO $ putStrLn "Preconditions validated"

-- | Prepare K8s resources: ConfigMap, clone/create deployment, service check, DestinationRule
prepareK8sResources :: StateFlow ()
prepareK8sResources = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    db <- getDB
    isNew <- isNewServiceRelease
    liftIO $ putStrLn $ "Preparing K8s resources for " <> T.unpack (product rt) <> if isNew then " (NEW SERVICE)" else ""

    -- Capture BEFORE snapshots
    when (not isNew) $ do
        let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
        liftIO $ captureDeploymentSnapshot cfg db (releaseId rt) (namespace ctx) oldDepName "DEPLOYMENT_BEFORE"
    liftIO $ captureVSSnapshot cfg db (releaseId rt) (namespace ctx) (virtualServiceName ctx) "VS_BEFORE"

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
        hpaEnabled <- liftIO $ isHpaEnabledForProduct db (product rt)
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
                        liftIO $ insertReleaseEvent db (releaseId rt) "BUSINESS" "HPA_CLONED"
                            (toJSON (serviceName ctx <> "-" <> newVersion ctx <> "-hpa"))
                    Left (K8sError err) -> liftIO $ putStrLn $ "  [HPA] Clone failed (non-fatal): " <> T.unpack err

    liftIO $ putStrLn "K8s resources prepared"

-- | Progressive rollout: shift traffic old -> new in steps
progressiveRollout :: StateFlow ()
progressiveRollout = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    liftIO $ putStrLn $ "Starting progressive rollout for " <> T.unpack (product rt)

    updateK8sStatus BSFlipVirtualService
    updateK8sField (\k8s -> k8s{virtualServiceApplied = True})

    updateK8sStatus BSProgressiveRollout
    db <- getDB

    if isNew
        then do
            -- New service: route 100% traffic to new version directly (no old version)
            liftIO $ putStrLn "  New service: routing 100% traffic to new version"
            _ <- runK8sIO $ applyVirtualServiceRollout cfg ctx 0 100
            updateK8sField (\k8s -> k8s{trafficPercentage = 100})
            currentRT <- getRT
            liftIO $ notifyReleaseProgress db currentRT 100
        else do
            -- Existing service: progressive traffic shift
            let steps = [(75, 25), (50, 50), (0, 100)] :: [(Int, Int)]
            forM_ steps $ \(oldW, newW) -> do
                liftIO $ putStrLn $ "  Shifting traffic: old=" <> show oldW <> "% new=" <> show newW <> "%"
                _ <- runK8sIO $ applyVirtualServiceRollout cfg ctx oldW newW
                updateK8sField (\k8s -> k8s{trafficPercentage = newW})

                -- Notify Slack of traffic shift
                currentRT <- getRT
                liftIO $ notifyReleaseProgress db currentRT newW

                -- Health check between steps (skip after final 100% step)
                when (newW < 100) $ do
                    liftIO $ threadDelay 5000000 -- 5 seconds between steps
                    checkDeploymentHealth cfg ctx

    liftIO $ putStrLn "Progressive rollout complete"

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
    liftIO $ putStrLn $ "Monitoring health for " <> T.unpack (product rt)

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

    liftIO $ putStrLn "Health monitoring complete"

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
        cmd = unwords
            [ kubectlBin cfg
            , "-n", T.unpack ns
            , "get pods"
            , "-l", "app=" <> T.unpack svcHost <> ",version=" <> T.unpack version
            , "-o", "json"
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
        phase = statusObj >>= \case
            Object s -> case KM.lookup (K.fromText "phase") s of
                Just (String p) -> Just p
                _ -> Nothing
            _ -> Nothing
        containerStatuses = statusObj >>= \case
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
            errs = []
                <> [podName <> ": CrashLoopBackOff detected" | waitingReason == Just "CrashLoopBackOff"]
                <> [podName <> ": ImagePullBackOff detected" | waitingReason == Just "ImagePullBackOff"]
                <> [podName <> ": ErrImagePull detected" | waitingReason == Just "ErrImagePull"]
                <> [podName <> ": restartCount=" <> T.pack (show restartCount) <> " exceeds threshold (3)" | restartCount > 3]
        in errs
    checkContainer _ _ = []
checkSinglePod _ = Right "unknown"

-- | Cleanup old version: scale down (and optionally delete) old deployment
cleanupOldVersion :: StateFlow ()
cleanupOldVersion = do
    rt <- getRT
    cfg <- getCfg
    ctx <- getK8sCtx
    isNew <- isNewServiceRelease
    liftIO $ putStrLn $ "Cleaning up old version for " <> T.unpack (product rt)

    updateK8sStatus BSScaleDownOld

    if isNew
        then do
            -- New service: no old deployment to clean up
            liftIO $ putStrLn "  New service: no old deployment to clean up"
            updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})
        else do
            let oldDepName = serviceName ctx <> "-" <> oldVersion ctx
            liftIO $ putStrLn $ "  Scaling down old deployment: " <> T.unpack oldDepName

            -- Scale old deployment to 0 replicas
            _ <- runK8sIO $ runCmd (buildScaleNamedDeploymentCommand cfg (namespace ctx) oldDepName 0)
            updateK8sField (\k8s -> k8s{oldDeploymentScaledDown = True})

            -- Notify Slack of pods scaled down
            db <- getDB
            liftIO $ notifyPodsScaledDown db rt (oldVersion ctx)

            -- Optionally delete old deployment
            db <- getDB
            shouldDelete <- liftIO $ isScaleDownPodsOnCompletion db
            when shouldDelete $ do
                liftIO $ putStrLn $ "  Deleting old deployment: " <> T.unpack oldDepName
                _ <- runK8sIO $ runCmd (buildDeleteDeploymentCommand cfg (namespace ctx) oldDepName)
                pure ()

    -- Capture AFTER snapshots
    cfgAfter <- getCfg
    dbAfter <- getDB
    rtAfter <- getRT
    ctxAfter <- getK8sCtx
    liftIO $ captureDeploymentSnapshot cfgAfter dbAfter (releaseId rtAfter) (namespace ctxAfter) (deploymentName ctxAfter) "DEPLOYMENT_AFTER"
    liftIO $ captureVSSnapshot cfgAfter dbAfter (releaseId rtAfter) (namespace ctxAfter) (virtualServiceName ctxAfter) "VS_AFTER"

    liftIO $ putStrLn "Cleanup complete"

-- | Notify complete
notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    db <- getDB
    updateK8sStatus BSDone

    liftIO $ putStrLn $ "Release " <> T.unpack (releaseId rt) <> " completed successfully!"
    liftIO $ putStrLn $ "   Service: " <> T.unpack (product rt)
    liftIO $ putStrLn $ "   Category: BackendService"
    liftIO $ putStrLn $ "   Status: Completed"

    updateRT $ \r -> r{status = Completed}

    -- Notify Slack
    liftIO $ notifyReleaseCompleted db rt

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
