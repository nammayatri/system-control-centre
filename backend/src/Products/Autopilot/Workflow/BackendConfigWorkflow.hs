{-# LANGUAGE OverloadedStrings #-}

-- | Backend config (K8s ConfigMap apply) workflow spec.
module Products.Autopilot.Workflow.BackendConfigWorkflow (
    backendConfigSpec,
)
where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import Core.Environment (getConfig, logInfo, logWarning)
import Core.Workflow.Spec (WorkflowSpec (..))
import Core.Workflow.Stage (Stage)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
import Products.Autopilot.Notifications (notifyConfigMapCompleted)
import Products.Autopilot.Queries.ProductService (findProductByName, getProductNamespace)
import Products.Autopilot.Queries.ReleaseTracker (conditionalUpdateTracker, findReleaseTracker, insertReleaseEvent)
import Products.Autopilot.Sync (triggerRevertSyncIfEnabled)
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
import Products.Autopilot.Types.Target (BackendConfigWFStatus (..), ConfigDeploymentState (..), TargetState (..), emptyConfigState)
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers (
    captureConfigMapSnapshot,
    getRT,
    persistWorkflowState,
    updateRT,
 )
import Products.Autopilot.Workflow.StageHelpers (mkLegacyStateFlowStage)
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    StateFlow,
 )
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Prelude

{- | Four-stage spec: init → prepare → deploy → done. No rollback — a
  failed ConfigMap is either applied or not (best-effort).
-}
backendConfigSpec :: WorkflowSpec ReleaseState
backendConfigSpec =
    WorkflowSpec
        { wsName = "BackendConfig"
        , wsStages =
            [ configStageInit
            , configStagePrepare
            , configStageDeploy
            , configStageDone
            ]
        , wsRollback = \_err -> pure ()
        , wsPersist = persistWorkflowState
        }

configStageInit
    , configStagePrepare
    , configStageDeploy
    , configStageDone ::
        Stage ReleaseState
configStageInit = mkLegacyStateFlowStage "init" INIT validateConfig
configStagePrepare = mkLegacyStateFlowStage "prepare" PREPARING resolveConfigContent
configStageDeploy = mkLegacyStateFlowStage "deploy" DEPLOYING applyConfigMap
configStageDone = mkLegacyStateFlowStage "done" DONE notifyComplete

getCfg :: StateFlow Config
getCfg = lift getConfig

logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

-- | Tracker metadata carries the file content under either "file" or "config".
getFileContent :: StateFlow (Maybe Text)
getFileContent = do
    rt <- getRT
    pure $ case metadata rt of
        Just (Object o) ->
            case KM.lookup (K.fromText "file") o of
                Just (String t) | not (T.null t) -> Just t
                _ -> case KM.lookup (K.fromText "config") o of
                    Just (String t) | not (T.null t) -> Just t
                    _ -> Nothing
        _ -> Nothing

updateConfigStatus :: BackendConfigWFStatus -> StateFlow ()
updateConfigStatus newStatus = do
    rs <- gets id
    case targetState rs of
        Just (ConfigState cs) ->
            modify $ \s -> s{targetState = Just (ConfigState (cs{categoryWorkflowStatus = newStatus}))}
        _ ->
            modify $ \s -> s{targetState = Just (ConfigState (emptyConfigState{categoryWorkflowStatus = newStatus}))}

validateConfig :: StateFlow ()
validateConfig = do
    rt <- getRT
    logInfoS $ "Validating config for " <> appGroup rt
    updateConfigStatus BCInit
    -- Set INPROGRESS up front so a crash mid-step leaves an unambiguous
    -- "running" marker; otherwise startup-rollback can't distinguish
    -- "never picked" from "picked but crashed mid-apply".
    updateRT $ \r -> r{status = INPROGRESS}

    fileContent <- getFileContent
    case fileContent of
        Nothing -> liftIO $ throwIO $ WorkflowError "validate" "No file/config content"
        Just fc | T.null (T.strip fc) -> liftIO $ throwIO $ WorkflowError "validate" "Empty file/config content"
        Just _ -> pure ()

    logInfoS "Config validation passed"

{- | If the content is a raw K8s manifest, use it directly; otherwise fetch
  the existing ConfigMap and patch its @data@ section.
-}
resolveConfigContent :: StateFlow ()
resolveConfigContent = do
    rt <- getRT
    cfg <- getCfg
    logInfoS $ "Resolving config content for " <> appGroup rt
    updateConfigStatus BCApplyConfigMap

    fileContent <- getFileContent
    case fileContent of
        Nothing -> liftIO $ throwIO $ WorkflowError "resolve" "No file content"
        Just fc -> do
            p <- findProductByName (appGroup rt)
            let ns = case p of
                    Just pCfg -> T.unpack (getProductNamespace pCfg)
                    Nothing -> case metadata rt of
                        Just (Object o) -> case KM.lookup (K.fromText "cluster") o of
                            Just (String c) | not (T.null c) -> T.unpack c
                            _ -> T.unpack (env rt)
                        _ -> T.unpack (env rt)

            captureConfigMapSnapshot cfg (releaseId rt) (T.pack ns) (service rt) "CONFIGMAP_BEFORE"

            if isK8sManifest fc
                then do
                    let resolved =
                            Object $
                                KM.fromList
                                    [ ("namespace", String (T.pack ns))
                                    , ("resolvedContent", String fc)
                                    ]
                    modify $ \s -> s{workflowMetadata = Just resolved}
                    logInfoS "  Content is raw K8s manifest, will apply directly"
                else do
                    let cmName' = T.unpack (service rt)
                        getCmd = unwords [kubectlBin cfg, "get configmap", cmName', "-n", ns, "-o json"]
                    logInfoS $ "  Fetching existing ConfigMap: " <> T.pack cmName'
                    getRes <- liftIO $ runCmd getCmd
                    case getRes of
                        Left (K8sError err) -> liftIO $ throwIO $ WorkflowError "k8s" ("Failed to fetch ConfigMap: " <> err)
                        Right (K8sResult existingJson) -> do
                            case patchConfigMapJson existingJson fc of
                                Left err -> liftIO $ throwIO $ WorkflowError "resolve" err
                                Right patchedContent -> do
                                    let resolved =
                                            Object $
                                                KM.fromList
                                                    [ ("namespace", String (T.pack ns))
                                                    , ("resolvedContent", String patchedContent)
                                                    ]
                                    modify $ \s -> s{workflowMetadata = Just resolved}
                                    logInfoS "  Patched existing ConfigMap with new data"

    logInfoS "Config content resolved"

applyConfigMap :: StateFlow ()
applyConfigMap = do
    rt <- getRT
    cfg <- getCfg
    logInfoS $ "Applying ConfigMap for " <> appGroup rt

    rs <- gets id
    case workflowMetadata rs of
        Just (Object wm) -> do
            ns <- case KM.lookup "namespace" wm of
                Just (String n) -> pure (T.unpack n)
                _ -> liftIO $ throwIO $ WorkflowError "apply" "Missing namespace"
            content <- case KM.lookup "resolvedContent" wm of
                Just (String c) -> pure c
                _ -> liftIO $ throwIO $ WorkflowError "apply" "Missing resolvedContent"
            result <- liftIO $ replaceFromStdin cfg ns content
            case result of
                Right () -> do
                    updateConfigStatus BCDone
                    modify $ \s ->
                        s
                            { targetState =
                                case targetState s of
                                    Just (ConfigState cs) -> Just (ConfigState (cs{configMapsUpdated = [service rt], rolloutComplete = True}))
                                    _ -> Just (ConfigState (emptyConfigState{configMapsUpdated = [service rt], rolloutComplete = True}))
                            }
                    captureConfigMapSnapshot cfg (releaseId rt) (T.pack ns) (service rt) "CONFIGMAP_AFTER"
                    -- Emit a success event so the audit trail records
                    -- successful applies, not just failures.
                    insertReleaseEvent
                        (releaseId rt)
                        "BUSINESS"
                        "CONFIGMAP_APPLIED"
                        (object ["configmap" .= service rt, "namespace" .= T.pack ns])
                    logInfoS "ConfigMap applied successfully"
                Left err -> do
                    insertReleaseEvent (releaseId rt) "BUSINESS" "KUBECTL_FAILED" (String err)
                    liftIO $ throwIO $ WorkflowError "apply" ("kubectl replace failed: " <> err)
        _ -> do
            insertReleaseEvent (releaseId rt) "BUSINESS" "KUBECTL_FAILED" (String "Missing workflow metadata (resolveConfigContent did not run?)")
            liftIO $ throwIO $ WorkflowError "apply" "Missing workflow metadata"

notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    logInfoS $ "ConfigMap release " <> releaseId rt <> " completed!"
    lift $ notifyConfigMapCompleted rt
    -- If this tracker is a revert of another, CAS-transition the original
    -- REVERTING → REVERTED so a concurrent abort/discard can't be silently
    -- overwritten.
    case (info rt, description rt) of
        (Just "REVERT", Just desc) ->
            case T.stripPrefix "Revert of " desc of
                Just origId -> do
                    mOrig <- findReleaseTracker origId
                    case mOrig of
                        Just (origRt, origTs) | status origRt == REVERTING -> do
                            let reverted = origRt{status = REVERTED}
                            ok <- conditionalUpdateTracker reverted origTs "REVERTING"
                            if ok
                                then do
                                    lift $ triggerRevertSyncIfEnabled reverted origTs
                                    logInfoS $ "Marked original " <> origId <> " as REVERTED"
                                else
                                    logWarningS $
                                        "Skipped REVERTED write for "
                                            <> origId
                                            <> ": concurrent modification (CAS miss)"
                        _ -> pure ()
                Nothing -> pure ()
        _ -> pure ()
    updateRT $ \r -> r{status = COMPLETED}

{- | Pipe content into @kubectl replace -f -@. We use @replace@ (overwrite)
instead of @apply@ (3-way merge) because @apply@ produces surprising results
when the ConfigMap is owned by GitOps tooling or has drifted annotations.
-}
replaceFromStdin :: Config -> String -> Text -> IO (Either Text ())
replaceFromStdin cfg ns content = do
    let args = ["-n", ns, "replace", "-f", "-"]
    (exitCode, _out, err) <- readProcessWithExitCode (kubectlBin cfg) args (T.unpack content)
    case exitCode of
        ExitSuccess -> pure (Right ())
        ExitFailure _ -> pure (Left ("kubectl replace failed: " <> T.pack err))

isK8sManifest :: Text -> Bool
isK8sManifest t =
    let stripped = T.strip t
     in T.isPrefixOf "apiVersion:" stripped
            || T.isPrefixOf "kind:" stripped
            || T.isPrefixOf "---" stripped

{- | Replace the ConfigMap's @data@ section, preserving metadata except for
K8s-internal fields. Do NOT strip annotations or ownerReferences — doing so
broke GitOps reconciliation (Helm/Flux/ArgoCD ownership was lost on every
config-map release).
-}
patchConfigMapJson :: Text -> Text -> Either Text Text
patchConfigMapJson existingJson newDataContent =
    case eitherDecodeStrict' (encodeUtf8 existingJson) of
        Left err -> Left ("Failed to parse existing ConfigMap JSON: " <> T.pack err)
        Right (Object obj) ->
            let newData = case eitherDecodeStrict' (encodeUtf8 newDataContent) of
                    Right val -> val
                    Left _ -> String newDataContent
                -- K8s server rejects writes containing these fields.
                internalMetaKeys =
                    [ "resourceVersion"
                    , "uid"
                    , "generation"
                    , "creationTimestamp"
                    , "managedFields"
                    , "selfLink"
                    ]
                cleanMeta = case KM.lookup "metadata" obj of
                    Just (Object meta) ->
                        Object (foldr KM.delete meta internalMetaKeys)
                    other -> fromMaybe (Object KM.empty) other
                cleaned =
                    Object $
                        KM.fromList
                            [ ("apiVersion", fromMaybe (String "v1") (KM.lookup "apiVersion" obj))
                            , ("kind", fromMaybe (String "ConfigMap") (KM.lookup "kind" obj))
                            , ("metadata", cleanMeta)
                            , ("data", newData)
                            ]
             in Right (TL.toStrict (TLE.decodeUtf8 (encode cleaned)))
        Right _ -> Left "Existing ConfigMap is not a JSON object"
