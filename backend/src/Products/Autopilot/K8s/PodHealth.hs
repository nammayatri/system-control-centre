{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Shared pod-readiness polling and crashloop/image-pull/OOM detection.

Extracted out of "Products.Autopilot.Workflow.BackendServiceWorkflow" (where
it originally lived as the pre-VS-flip readiness gate) so it can also back
the ConfigMap safety check's throwaway test deployment
("Products.Autopilot.K8s.ConfigMapSafetyCheck"), which needs the exact same
fail-fast pod-health classification without depending on the workflow's
'StateFlow' machinery.
-}
module Products.Autopilot.K8s.PodHealth (
    waitForPodsReady,
    checkPodHealthDetailed,
    analyzePodHealth,
    checkSinglePod,
)
where

import Core.Config (Config (..))
import Core.Logging (LoggerEnv, logErrorIO, logInfoIO)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Products.Autopilot.K8s.Deployment (getDeploymentReplicaStatus)
import Products.Autopilot.K8s.Execute (K8sResult (..), runCmd)
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))

{- | Poll a deployment (by namespace/name from the given context) until its
ready replica count reaches desired, or bail out early on a fail-fast pod
health signal (ImagePullBackOff, CrashLoopBackOff, OOMKilled, restart
threshold exceeded, ...). Right () = ready; Left msg = why it gave up.
-}
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
        -- Set the moment a pod is deleted for ANY reason -- HPA scaling it
        -- down, our own scale commands between stages, a rolling update.
        -- SIGTERM often makes the container's own exit look like a crash
        -- (terminatedReason "Error", occasionally a stray restart bump), but
        -- it isn't one: this pod was never meant to keep running. Skip the
        -- crash checks entirely for it so a normal scale-down never gets
        -- misread as the new version being broken.
        isTerminating = case KM.lookup (K.fromText "metadata") podObj >>= getObj' "deletionTimestamp" of
            Just _ -> True
            Nothing -> False
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
        containerErrors
            | isTerminating = []
            | otherwise = case containerStatuses of
                Nothing -> []
                Just cs -> concatMap (checkContainer podName) cs
     in case phase of
            -- Non-fatal: phase Failed is almost always infra-caused (node
            -- eviction/preemption, scheduling churn) rather than a bad new
            -- version -- the ReplicaSet controller already replaces it with a
            -- new pod on its own. Hard-failing here on a single transient
            -- Failed pod aborted the whole release before the replacement
            -- ever got a chance to come up; let readyCount/desired (checked
            -- by the caller's poll loop, with its own timeout) be the real
            -- gate instead.
            Just "Failed" -> Right (podName <> ": pod phase is Failed (transient, likely node/infra — waiting for K8s to replace it)")
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
