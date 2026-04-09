{-# LANGUAGE OverloadedStrings #-}

-- | Kubernetes Deployment operations: create, clone, scale, check existence.
module Products.Autopilot.K8s.Deployment (
    buildSetImageCommand,
    buildCloneDeploymentCommand,
    buildScaleDeploymentCommand,
    buildScaleNamedDeploymentCommand,
    buildDeleteDeploymentCommand,
    buildRolloutStatusCommand,
    buildRolloutCommands,
    buildCreateServiceCommand,
    buildConfigMapApplyCommand,
    buildApplyFileCommand,
    deploymentExists,
    getDeploymentEnvs,
    getRunningVersionFromVS,
    buildCloneDeploymentWithEnvsCommand,
    buildPatchDeploymentEnvsCommand,
    serviceExists,
    getDeploymentReplicaStatus,
)
where

import Core.Config (Config (..))
import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Products.Autopilot.K8s.Execute
import Products.Autopilot.Types.Release (RolloutStep (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))

buildSetImageCommand :: Config -> K8sReleaseContext -> String
buildSetImageCommand cfg ctx =
    let nsQ = shellQuote (namespace ctx)
        dep = T.unpack (deploymentName ctx)
        depQ = shellQuote (deploymentName ctx)
        container = T.unpack (containerName ctx)
        explicitDockerImage = maybe "" T.unpack (dockerImage ctx)
        oldV = T.unpack (oldVersion ctx)
        newV = T.unpack (newVersion ctx)
        currentImageCmd = unwords [kubectlBin cfg, "-n", nsQ, "get deployment", depQ, "-o jsonpath='{.spec.template.spec.containers[?(@.name==\"" <> container <> "\")].image}'"]
        rewriteImageCmd = "img=$(" <> currentImageCmd <> "); if echo \"$img\" | sed -E \"s/-" <> oldV <> "$/-" <> newV <> "/\" >/dev/null; then newimg=$(echo \"$img\" | sed -E \"s/-" <> oldV <> "$/-" <> newV <> "/\"); else newimg=$(echo \"$img\" | sed -E \"s/(.*-)[^-:]+$/\\1" <> newV <> "/\"); fi; "
        rewriteAndSetCmd = rewriteImageCmd <> unwords [kubectlBin cfg, "-n", nsQ, "set image deployment/" <> dep, container <> "=\"$newimg\""]
        metadataTagOrImageSetCmd = "img=$(" <> currentImageCmd <> "); if echo \"" <> explicitDockerImage <> "\" | grep -q '/'; then newimg=\"" <> explicitDockerImage <> "\"; elif echo \"$img\" | grep -q ':'; then repo=${img%:*}; newimg=\"$repo:" <> explicitDockerImage <> "\"; else newimg=$(echo \"$img\" | sed -E \"s/(.*-)[^-:]+$/\\1" <> explicitDockerImage <> "/\"); fi; " <> unwords [kubectlBin cfg, "-n", nsQ, "set image deployment/" <> dep, container <> "=\"$newimg\""]
     in if null explicitDockerImage then rewriteAndSetCmd else metadataTagOrImageSetCmd

buildCloneDeploymentCommand :: Config -> K8sReleaseContext -> String
buildCloneDeploymentCommand cfg ctx =
    let sourceDep = T.unpack (serviceName ctx) <> "-" <> T.unpack (oldVersion ctx)
        targetDep = T.unpack (deploymentName ctx)
        explicitDockerImage = maybe "" T.unpack (dockerImage ctx)
        -- Strip env vars with unsupported fieldRef paths (e.g. metadata.labels[...])
        stripUnsupportedEnvs = "(.spec.template.spec.containers[].env) |= [.[]? | select((.valueFrom.fieldRef.fieldPath // \"\") | startswith(\"metadata.labels[\") | not)]"
        patchFilter = ".metadata.name = $targetDep | .metadata.labels.version = $newTag | .spec.selector.matchLabels.version = $newTag | .spec.template.metadata.labels.version = $newTag | (.spec.template.spec.containers[] | select(.name == $container) | .image) |= (if ($dockerImage != \"\") then (if (($dockerImage | test(\"/\")) or ($dockerImage | test(\":\"))) then $dockerImage elif test(\":\") then sub(\":[^:]+$\"; \":\" + $dockerImage) elif test(\"-\" + $oldTag + \"$\") then sub(\"-\" + $oldTag + \"$\"; \"-\" + $dockerImage) elif test(\"-\") then sub(\"-(?<last>[^-:]+)$\"; \"-\" + $dockerImage) else . end) elif test(\"-\" + $oldTag + \"$\") then sub(\"-\" + $oldTag + \"$\"; \"-\" + $newTag) elif test(\"-\") then sub(\"-(?<last>[^-:]+)$\"; \"-\" + $newTag) else . end) | " <> stripUnsupportedEnvs <> " | del(.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.metadata.annotations.\"deployment.kubernetes.io/revision\",.status)"
     in unwords [kubectlBin cfg, "-n", shellQuote (namespace ctx), "get deployment", shellQuote (T.pack sourceDep), "-o json | jq", "--arg targetDep", shellQuote (T.pack targetDep), "--arg container", shellQuote (containerName ctx), "--arg newTag", shellQuote (newVersion ctx), "--arg oldTag", shellQuote (oldVersion ctx), "--arg dockerImage", shellQuote (T.pack explicitDockerImage), "'" <> patchFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote (namespace ctx), "apply -f -"]

{- | Clone deployment with env vars injected from envOverrideData (env switch).
Matches ny-autopilot's updateDeploymentWithNewEnvs: replaces the
containers[0].env array in the cloned deployment with the user-provided envs.
-}
buildCloneDeploymentWithEnvsCommand :: Config -> K8sReleaseContext -> Text -> String
buildCloneDeploymentWithEnvsCommand cfg ctx envsJson =
    let sourceDep = T.unpack (serviceName ctx) <> "-" <> T.unpack (oldVersion ctx)
        targetDep = T.unpack (deploymentName ctx)
        explicitDockerImage = maybe "" T.unpack (dockerImage ctx)
        -- Same jq filter as buildCloneDeploymentCommand, plus env injection
        -- Strip env vars with unsupported fieldRef paths (e.g. metadata.labels[...])
        stripUnsupportedEnvs = "(.spec.template.spec.containers[].env) |= [.[]? | select((.valueFrom.fieldRef.fieldPath // \"\") | startswith(\"metadata.labels[\") | not)]"
        patchFilter = ".metadata.name = $targetDep | .metadata.labels.version = $newTag | .spec.selector.matchLabels.version = $newTag | .spec.template.metadata.labels.version = $newTag | (.spec.template.spec.containers[] | select(.name == $container) | .image) |= (if ($dockerImage != \"\") then (if (($dockerImage | test(\"/\")) or ($dockerImage | test(\":\"))) then $dockerImage elif test(\":\") then sub(\":[^:]+$\"; \":\" + $dockerImage) elif test(\"-\" + $oldTag + \"$\") then sub(\"-\" + $oldTag + \"$\"; \"-\" + $dockerImage) elif test(\"-\") then sub(\"-(?<last>[^-:]+)$\"; \"-\" + $dockerImage) else . end) elif test(\"-\" + $oldTag + \"$\") then sub(\"-\" + $oldTag + \"$\"; \"-\" + $newTag) elif test(\"-\") then sub(\"-(?<last>[^-:]+)$\"; \"-\" + $newTag) else . end) | (.spec.template.spec.containers[] | select(.name == $container) | .env) = ($envs | fromjson) | " <> stripUnsupportedEnvs <> " | del(.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.metadata.annotations.\"deployment.kubernetes.io/revision\",.status)"
     in unwords [kubectlBin cfg, "-n", shellQuote (namespace ctx), "get deployment", shellQuote (T.pack sourceDep), "-o json | jq", "--arg targetDep", shellQuote (T.pack targetDep), "--arg container", shellQuote (containerName ctx), "--arg newTag", shellQuote (newVersion ctx), "--arg oldTag", shellQuote (oldVersion ctx), "--arg dockerImage", shellQuote (T.pack explicitDockerImage), "--arg envs", shellQuote envsJson, "'" <> patchFilter <> "'", "|", kubectlBin cfg, "-n", shellQuote (namespace ctx), "apply -f -"]

buildScaleDeploymentCommand :: Config -> K8sReleaseContext -> Int -> String
buildScaleDeploymentCommand cfg ctx replicas =
    unwords [kubectlBin cfg, "-n", shellQuote (namespace ctx), "scale deployment", shellQuote (deploymentName ctx), "--replicas=" <> show replicas]

buildScaleNamedDeploymentCommand :: Config -> Text -> Text -> Int -> String
buildScaleNamedDeploymentCommand cfg ns depName replicas =
    unwords [kubectlBin cfg, "-n", shellQuote ns, "scale deployment", shellQuote depName, "--replicas=" <> show replicas]

buildDeleteDeploymentCommand :: Config -> Text -> Text -> String
buildDeleteDeploymentCommand cfg ns depName =
    unwords [kubectlBin cfg, "-n", shellQuote ns, "delete deployment", shellQuote depName, "--ignore-not-found=true"]

buildRolloutStatusCommand :: Config -> K8sReleaseContext -> String
buildRolloutStatusCommand cfg ctx =
    unwords [kubectlBin cfg, "-n", shellQuote (namespace ctx), "rollout status deployment", shellQuote (deploymentName ctx), "--timeout=300s"]

{- | REPLACE the env array of the first container on an existing deployment.

Used in two places:
  * Env switch when the target deployment already exists (skip-clone path)
  * Immediate revert env restore (restore old deployment's envs)

Bug fix: previously used @--type=strategic@ which merges @containers[].env@
by the @name@ key — keeping pre-existing env vars and only adding new
ones. That made env switches cumulative and broke immediate-revert's
attempt to restore old envs (the new envs stayed). Switched to JSON
Patch (@--type=json@) with an explicit @replace@ operation on
@/spec/template/spec/containers/0/env@, which atomically replaces the
entire array of container 0. Single-container assumption matches the
rest of the deployment helpers in this file.
-}
buildPatchDeploymentEnvsCommand :: Config -> K8sReleaseContext -> Text -> String
buildPatchDeploymentEnvsCommand cfg ctx envsJson =
    -- Build the JSON Patch body via jq so envsJson (a serialized JSON array
    -- of env objects) is parsed and embedded as a real JSON value, not a
    -- string. We also strip env entries whose fieldRef points at
    -- metadata.labels[...] — those require a downward API rule and break
    -- kubectl patch when not configured.
    let stripAndPatch =
            "($envs | fromjson | [.[] | select((.valueFrom.fieldRef.fieldPath // \"\") | startswith(\"metadata.labels[\") | not)]) as $filtered | [{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env\",\"value\":$filtered}]"
     in unwords
            [ kubectlBin cfg
            , "-n"
            , shellQuote (namespace ctx)
            , "patch deployment"
            , shellQuote (deploymentName ctx)
            , "--type=json"
            , "-p"
            , "\"$(echo null | jq --arg envs"
            , shellQuote envsJson
            , "'" <> stripAndPatch <> "'" <> ")\""
            ]

buildCreateServiceCommand :: Config -> K8sReleaseContext -> String
buildCreateServiceCommand cfg ctx =
    unwords [kubectlBin cfg, "-n", shellQuote (namespace ctx), "create service clusterip", shellQuote (serviceName ctx), "--tcp=80:80"]

buildConfigMapApplyCommand :: Config -> K8sReleaseContext -> String
buildConfigMapApplyCommand cfg ctx =
    unwords [kubectlBin cfg, "-n", shellQuote (namespace ctx), "create configmap", shellQuote (serviceName ctx <> "-release"), "--from-literal=release.image=" <> shellQuote (newVersion ctx), "--dry-run=client -o yaml |", kubectlBin cfg, "apply -f -"]

buildApplyFileCommand :: Config -> Text -> String
buildApplyFileCommand cfg filePath =
    unwords [kubectlBin cfg, "apply -f", shellQuote filePath]

buildRolloutCommands :: Config -> K8sReleaseContext -> RolloutStep -> [String]
buildRolloutCommands cfg ctx step =
    let targetReplicas = max 1 (podCount step)
     in [ buildSetImageCommand cfg ctx
        , buildCreateServiceCommand cfg ctx
        , buildConfigMapApplyCommand cfg ctx
        , buildScaleDeploymentCommand cfg ctx targetReplicas
        , buildRolloutStatusCommand cfg ctx
        ]

deploymentExists :: Config -> Text -> Text -> IO Bool
deploymentExists cfg ns depName = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get deployment", shellQuote depName, "-o name"])
    pure $ case res of Right _ -> True; Left _ -> False

serviceExists :: Config -> Text -> Text -> IO Bool
serviceExists cfg ns svcName = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get service", shellQuote svcName, "-o name"])
    pure $ case res of Right _ -> True; Left _ -> False

getDeploymentReplicaStatus :: Config -> Text -> Text -> IO (Either K8sError (Int, Int, Int))
getDeploymentReplicaStatus cfg ns depName = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get deployment", shellQuote depName, "-o jsonpath='{.status.readyReplicas} {.status.availableReplicas} {.spec.replicas}'"])
    pure $ case res of
        Left err -> Left err
        Right (K8sResult out) ->
            let ws = words (T.unpack out)
                pick i = if length ws > i then parseInt (ws !! i) else 0
             in Right (pick 0, pick 1, pick 2)
  where
    parseInt s = case reads s of ((n, _) : _) -> n; _ -> 0

{- | Get environment variables from a running deployment's first container.
Matches ny-autopilot's getEnvsFromDeployment: first discovers the running
version from the VirtualService, constructs the full deployment name
(e.g. beckn-driver-offer-bpp-master-4fa110), then fetches envs from that deployment.
-}
getDeploymentEnvs :: Config -> Text -> Text -> Text -> IO (Either K8sError Value)
getDeploymentEnvs cfg ns vsName svcHost = do
    -- Step 1: Get running version from VirtualService (like ny-autopilot's getRunningVersionOfService)
    versionRes <- getRunningVersionFromVS cfg ns vsName svcHost
    case versionRes of
        Left err -> pure (Left err)
        Right runningVersion -> do
            -- Step 2: Construct full deployment name: <service_host>-<version>
            let fullDepName = T.unpack svcHost <> "-" <> T.unpack runningVersion
            -- Step 3: kubectl get deployment <full-name> to fetch envs
            res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get deployment", shellQuote (T.pack fullDepName), "-o jsonpath='{.spec.template.spec.containers[0].env}'"])
            pure $ case res of
                Left err -> Left err
                Right (K8sResult out) -> parseEnvJson out
  where
    parseEnvJson out =
        let cleaned = T.strip (T.dropWhile (== '\'') (T.dropWhileEnd (== '\'') (T.strip out)))
         in case A.decodeStrict' (encodeUtf8 cleaned) :: Maybe Value of
                Just v -> Right v
                Nothing -> Right (A.toJSON ([] :: [Value]))

{- | Discover the currently running version/subset from a VirtualService.
Parses the VS JSON, finds the route matching svcHost with the highest weight,
and returns its subset (the version tag like "4fa110").
-}
getRunningVersionFromVS :: Config -> Text -> Text -> Text -> IO (Either K8sError Text)
getRunningVersionFromVS cfg ns vsName svcHost = do
    res <- runCmd (unwords [kubectlBin cfg, "-n", shellQuote ns, "get virtualservice", shellQuote vsName, "-o json"])
    pure $ case res of
        Left err -> Left err
        Right (K8sResult out) ->
            case A.decodeStrict' (encodeUtf8 out) :: Maybe Value of
                Nothing -> Left (K8sError "Failed to decode VirtualService JSON")
                Just v -> case pickSubset v of
                    Nothing -> Left (K8sError ("No active subset found for service " <> svcHost <> " in VS " <> vsName))
                    Just subset -> Right subset
  where
    pickSubset (Object root) = do
        spec <- getObj "spec" root
        httpRules <- getArr "http" spec
        let pairs = concatMap parseHttp httpRules
        case pairs of
            [] -> Nothing
            _ -> Just (fst (foldr1 (\a b -> if snd a < snd b then b else a) pairs))
    pickSubset _ = Nothing

    parseHttp (Object httpRule) = case getArr "route" httpRule of
        Nothing -> []
        Just routes -> mapMaybeList parseRoute routes
    parseHttp _ = []

    parseRoute (Object routeObj) = do
        dest <- getObj "destination" routeObj
        host <- getTxt "host" dest
        subset <- getTxt "subset" dest
        if hostMatch host svcHost
            then Just (subset, getIntVal "weight" routeObj)
            else Nothing
    parseRoute _ = Nothing

    hostMatch a b = a == b || T.takeWhile (/= '.') a == T.takeWhile (/= '.') b
    getObj key obj = case KM.lookup (K.fromText key) obj of Just (Object o) -> Just o; _ -> Nothing
    getArr key obj = case KM.lookup (K.fromText key) obj of Just (Array a) -> Just (foldr (:) [] a); _ -> Nothing
    getTxt key obj = case KM.lookup (K.fromText key) obj of Just (String t) -> Just t; _ -> Nothing
    getIntVal :: Text -> KM.KeyMap Value -> Int
    getIntVal key obj = case KM.lookup (K.fromText key) obj of Just (Number n) -> round n; _ -> 0
    mapMaybeList f = foldr (\x acc -> maybe acc (: acc) (f x)) []
