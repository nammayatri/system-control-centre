{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Pre-apply safety check for ConfigMap changes.

Before a ConfigMap change is written for real, find every currently-running
deployment that references it (by name, across volumes / envFrom / env
valueFrom), test-deploy the proposed new content against a throwaway clone
of each (1 replica, unique name/labels, same image), and watch it come up.
If any clone fails to reach Ready (CrashLoopBackOff, ImagePullBackOff,
missing key, ...), the whole check fails and the caller aborts the real
apply instead of rolling out a config that would have crashed production.
Test resources are deleted afterwards regardless of outcome.

Gated by the @configmap_safety_check_enabled@ server config (default on;
see 'Products.Autopilot.RuntimeConfig.isConfigMapSafetyCheckEnabled') —
callers check that flag before invoking 'runConfigMapSafetyCheck'.
-}
module Products.Autopilot.K8s.ConfigMapSafetyCheck (
    SafetyCheckFailure (..),
    runConfigMapSafetyCheck,
)
where

import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (Flow, getLoggerEnv)
import Core.Logging (LoggerEnv)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (sortOn)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Data.Yaml qualified as Yaml
import Products.Autopilot.K8s.Deployment (buildDeleteDeploymentCommand)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd, shellQuote)
import Products.Autopilot.K8s.PodHealth (waitForPodsReady)
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (getPodReadinessMaxAttempts, getPodReadinessPollSeconds, getPodRestartCountThreshold)
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..), defaultK8sReleaseContext)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- | One referencing deployment that failed its test deploy.
data SafetyCheckFailure = SafetyCheckFailure
    { scfDeployment :: Text
    , scfReason :: Text
    }
    deriving (Eq, Show)

-- | A running deployment found to reference the target ConfigMap.
data DeployRef = DeployRef
    { drName :: Text
    , drApp :: Text
    , drReadyReplicas :: Int
    , drSpec :: Value
    }

{- | Run the safety check. Right () means either every tested clone came up
Ready, or there was nothing running to test against (nothing to protect).
Left failures lists which referencing deployment(s) failed and why —
callers should abort the real apply and surface this in the release event
log, per-pod detail included in 'scfReason' (from
"Products.Autopilot.K8s.PodHealth"'s CrashLoopBackOff/ImagePullBackOff/etc
classification).
-}
runConfigMapSafetyCheck :: Config -> Text -> Text -> Text -> Text -> Flow (Either [SafetyCheckFailure] ())
runConfigMapSafetyCheck cfg releaseId ns cmName newConfigMapJson = do
    logEnv <- getLoggerEnv
    maxAttempts <- getPodReadinessMaxAttempts
    pollSeconds <- getPodReadinessPollSeconds
    restartThreshold <- getPodRestartCountThreshold
    refsResult <- liftIO $ findDeploymentsReferencingConfigMap cfg ns cmName
    case refsResult of
        Left err -> do
            -- Can't determine blast radius -- fail OPEN (let the real apply
            -- proceed) rather than block every ConfigMap release on a
            -- kubectl hiccup unrelated to the new content.
            insertReleaseEvent
                releaseId
                "BUSINESS"
                "CONFIGMAP_SAFETY_CHECK_SKIPPED"
                (object ["reason" .= ("could not list deployments to check: " <> err)])
            pure (Right ())
        Right allRefs -> do
            let targets = pickMaxReplicaPerApp (filter (\d -> drReadyReplicas d > 0) allRefs)
            if null targets
                then do
                    insertReleaseEvent
                        releaseId
                        "BUSINESS"
                        "CONFIGMAP_SAFETY_CHECK_SKIPPED"
                        (object ["reason" .= ("no running deployment references configmap " <> cmName)])
                    pure (Right ())
                else do
                    insertReleaseEvent
                        releaseId
                        "BUSINESS"
                        "CONFIGMAP_SAFETY_CHECK_STARTED"
                        (object ["testing" .= map drName targets, "configmap" .= cmName])
                    results <-
                        liftIO $
                            mapM
                                (testOneDeployment cfg logEnv maxAttempts pollSeconds restartThreshold ns cmName newConfigMapJson)
                                targets
                    let failures = [SafetyCheckFailure (drName t) e | (t, Left e) <- zip targets results]
                    if null failures
                        then do
                            insertReleaseEvent
                                releaseId
                                "BUSINESS"
                                "CONFIGMAP_SAFETY_CHECK_PASSED"
                                (object ["tested" .= map drName targets])
                            pure (Right ())
                        else do
                            insertReleaseEvent
                                releaseId
                                "BUSINESS"
                                "CONFIGMAP_SAFETY_CHECK_FAILED"
                                (object
                                    [ "failures"
                                        .= [ object ["deployment" .= scfDeployment f, "reason" .= scfReason f]
                                           | f <- failures
                                           ]
                                    ]
                                )
                            pure (Left failures)

{- | Among deployments sharing the same @app@ label (typically blue/green
versions of one logical service), keep only the one with the most ready
replicas -- testing every dead/idle old version alongside the live one is
noise, and the live one is what actually matters. Deployments with no
@app@ label are each their own group (keyed by name).
-}
pickMaxReplicaPerApp :: [DeployRef] -> [DeployRef]
pickMaxReplicaPerApp refs = go [] (sortOn (Down . drReadyReplicas) refs)
  where
    go _ [] = []
    go seenApps (r : rest)
        | drApp r `elem` seenApps = go seenApps rest
        | otherwise = r : go (drApp r : seenApps) rest

-- | List every Deployment in the namespace that references the given
-- ConfigMap (by volume, envFrom, or env valueFrom, across containers and
-- initContainers), with its ready replica count and full spec Value.
findDeploymentsReferencingConfigMap :: Config -> Text -> Text -> IO (Either Text [DeployRef])
findDeploymentsReferencingConfigMap cfg ns cmName = do
    result <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get deployments", "-o", "json"])
    case result of
        Left (K8sError err) -> pure (Left err)
        Right (K8sResult out) ->
            case A.decodeStrict' (TE.encodeUtf8 out) :: Maybe Value of
                Nothing -> pure (Left "failed to parse deployment list JSON")
                Just (Object root) ->
                    case KM.lookup "items" root of
                        Just (Array items) -> pure (Right [d | Just d <- map toDeployRef (foldr (:) [] items), referencesConfigMap cmName (drSpec d)])
                        _ -> pure (Right [])
                Just _ -> pure (Right [])
  where
    toDeployRef v@(Object o) = do
        Object meta <- KM.lookup "metadata" o
        String name <- KM.lookup "name" meta
        let app = case KM.lookup "labels" meta of
                Just (Object labels) -> case KM.lookup "app" labels of
                    Just (String a) -> a
                    _ -> name
                _ -> name
            ready = case KM.lookup "status" o of
                Just (Object st) -> case KM.lookup "readyReplicas" st of
                    Just (Number n) -> round n
                    _ -> 0
                _ -> 0
        pure (DeployRef name app ready v)
    toDeployRef _ = Nothing

-- | Does this deployment's pod spec reference the given ConfigMap anywhere
-- (volumes / envFrom / env valueFrom, containers or initContainers)?
referencesConfigMap :: Text -> Value -> Bool
referencesConfigMap cmName = walk
  where
    refKeys = ["configMap", "configMapRef", "configMapKeyRef"] :: [Text]
    walk (Object o) =
        any (\(k, v) -> (K.toText k `elem` refKeys && refNameMatches v) || walk v) (KM.toList o)
    walk (Array a) = any walk a
    walk _ = False
    refNameMatches (Object inner) = case KM.lookup "name" inner of
        Just (String n) -> n == cmName
        _ -> False
    refNameMatches _ = False

-- | Rewrite every ConfigMap reference (volume / envFrom / env valueFrom)
-- pointing at @oldName@ to point at @newName@ instead, leaving everything
-- else untouched.
rewriteConfigMapRefs :: Text -> Text -> Value -> Value
rewriteConfigMapRefs oldName newName = walk
  where
    refKeys = ["configMap", "configMapRef", "configMapKeyRef"] :: [Text]
    walk (Object o) = Object (KM.mapWithKey step o)
    walk (Array a) = Array (fmap walk a)
    walk v = v
    step k v
        | K.toText k `elem` refKeys = renameInside v
        | otherwise = walk v
    renameInside (Object inner) = case KM.lookup "name" inner of
        Just v -> Object (KM.insert "name" (renameIfMatch v) inner)
        Nothing -> Object inner
    renameInside v = v
    renameIfMatch (String s) | s == oldName = String newName
    renameIfMatch v = v

-- | Clone a fetched Deployment Value into a throwaway, 1-replica test
-- deployment: new unique name/labels (so it never collides with the real
-- deployment's Service/selector), stripped server-managed metadata, and
-- its ConfigMap references swapped to the temp ConfigMap.
prepareTestDeployment :: Text -> Text -> Text -> Text -> Text -> Value -> Maybe Value
prepareTestDeployment newDepName testApp testVersion oldCm newCm (Object o) = do
    Object meta <- KM.lookup "metadata" o
    Object spec <- KM.lookup "spec" o
    Object tmpl <- KM.lookup "template" spec
    Object tmplSpecObj <- KM.lookup "spec" tmpl
    let cleanMeta =
            KM.insert "name" (String newDepName) $
                KM.insert "labels" testLabels $
                    foldr KM.delete meta ["resourceVersion", "uid", "generation", "creationTimestamp", "selfLink", "managedFields", "ownerReferences", "annotations", "namespace"]
        tmplSpecRewritten = rewriteConfigMapRefs oldCm newCm (Object tmplSpecObj)
        tmplMeta = case KM.lookup "metadata" tmpl of
            Just (Object tm) -> Object (KM.insert "labels" testLabels (foldr KM.delete tm ["creationTimestamp", "annotations"]))
            _ -> object ["labels" .= testLabels]
        newTmpl = Object (KM.insert "metadata" tmplMeta (KM.insert "spec" tmplSpecRewritten tmpl))
        newSpec =
            KM.insert "replicas" (toJSON (1 :: Int)) $
                KM.insert "selector" (object ["matchLabels" .= testLabels]) $
                    KM.insert "template" newTmpl $
                        foldr KM.delete spec ["template", "selector", "replicas"]
    pure $ Object (KM.insert "metadata" (Object cleanMeta) (KM.insert "spec" (Object newSpec) (KM.delete "status" o)))
  where
    testLabels = object [("app", String testApp), ("version", String testVersion)]
prepareTestDeployment _ _ _ _ _ _ = Nothing

-- | Point a fetched ConfigMap Value's name at the temp name, for applying
-- alongside the test deployment. Server-managed metadata stripped same as
-- the deployment clone.
prepareTestConfigMap :: Text -> Value -> Maybe Value
prepareTestConfigMap newCmName (Object o) = do
    Object meta <- KM.lookup "metadata" o
    let cleanMeta =
            KM.insert "name" (String newCmName) $
                foldr KM.delete meta ["resourceVersion", "uid", "generation", "creationTimestamp", "selfLink", "managedFields", "ownerReferences", "annotations", "namespace"]
    pure $ Object (KM.insert "metadata" (Object cleanMeta) (KM.delete "status" o))
prepareTestConfigMap _ _ = Nothing

-- | Fetch, clone, apply, wait, and (always) clean up a single test
-- deployment for one referencing deployment. Left = failure reason.
testOneDeployment :: Config -> LoggerEnv -> Int -> Int -> Int -> Text -> Text -> Text -> DeployRef -> IO (Either Text ())
testOneDeployment cfg logEnv maxAttempts pollSeconds restartThreshold ns cmName newConfigMapJson target = do
    suffix <- T.take 8 . T.filter (/= '-') . UUID.toText <$> UUID.nextRandom
    let testDepName = T.take 63 (drName target <> "-cmtest-" <> suffix)
        testCmName = T.take 63 (cmName <> "-safetycheck-" <> suffix)
        testApp = T.take 63 (drApp target <> "-cmtest")
        testVersion = "cmtest-" <> suffix
        cleanup = do
            _ <- runCmd (buildDeleteDeploymentCommand cfg ns testDepName)
            _ <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "delete configmap", shellQuote testCmName, "--ignore-not-found=true"])
            pure ()
    result <- do
        -- YAML-decode, not JSON: the resolved content can be either
        -- (raw manifests are typically YAML; the patched-existing-configmap
        -- path is JSON, but valid JSON parses fine under a YAML decoder too).
        mNewCmVal <-
            pure $
                either (const Nothing) Just (Yaml.decodeEither' (TE.encodeUtf8 newConfigMapJson) :: Either Yaml.ParseException Value)
                    >>= prepareTestConfigMap testCmName
        case mNewCmVal of
            Nothing -> pure (Left "could not build test ConfigMap (unparseable content)")
            Just testCmVal ->
                case prepareTestDeployment testDepName testApp testVersion cmName testCmName (drSpec target) of
                    Nothing -> pure (Left "could not build test deployment (unexpected deployment shape)")
                    Just testDepVal -> do
                        cmApply <- applyStdin cfg ns (encodeValue testCmVal)
                        case cmApply of
                            Left err -> pure (Left ("apply test configmap failed: " <> err))
                            Right () -> do
                                depApply <- applyStdin cfg ns (encodeValue testDepVal)
                                case depApply of
                                    Left err -> pure (Left ("apply test deployment failed: " <> err))
                                    Right () -> do
                                        let ctx =
                                                defaultK8sReleaseContext
                                                    { namespace = ns
                                                    , deploymentName = testDepName
                                                    , serviceName = testApp
                                                    , newVersion = testVersion
                                                    }
                                        waitForPodsReady logEnv cfg ctx maxAttempts pollSeconds restartThreshold
    cleanup
    pure result

encodeValue :: Value -> Text
encodeValue = TL.toStrict . TLE.decodeUtf8 . A.encode

applyStdin :: Config -> Text -> Text -> IO (Either Text ())
applyStdin cfg ns content = do
    (exitCode, _out, err) <- readProcessWithExitCode (kubectlBin cfg) ["-n", T.unpack ns, "apply", "-f", "-"] (T.unpack content)
    case exitCode of
        ExitSuccess -> pure (Right ())
        ExitFailure _ -> pure (Left (T.pack err))

