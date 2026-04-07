{-# LANGUAGE OverloadedStrings #-}

{- | Backend config workflow (K8s ConfigMap apply)

Implements the ConfigMap apply workflow using the Recorded monad pattern.
Migrated from Runner.hs's processConfigMapTracker.
-}
module Products.Autopilot.Workflow.BackendConfigWorkflow (
    backendConfigWorkflow,
)
where

import Control.Exception (throwIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.AppError (WorkflowError (..))
import Core.Config (Config (..))
import Core.Environment (getConfig, logInfo, logWarning)
import Data.Aeson (Value (..), eitherDecodeStrict', encode)
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
import Products.Autopilot.Queries.ReleaseTracker (conditionalUpdateTracker, findReleaseTracker, insertReleaseEvent, insertReleaseTracker)
import Products.Autopilot.Sync (triggerRevertSyncIfEnabled)
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
import Products.Autopilot.Types.Target (BackendConfigWFStatus (..), ConfigDeploymentState (..), TargetState (..), emptyConfigState)
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Helpers (
    captureConfigMapSnapshot,
    getRT,
    updateRT,
    (|>>),
 )
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
 )
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Prelude

-- ============================================================================
-- Workflow Definition
-- ============================================================================

-- | Backend config workflow using generic stages
backendConfigWorkflow :: ReleaseWorkFlow ()
backendConfigWorkflow = do
    INIT |>> validateConfig
    PREPARING |>> resolveConfigContent
    DEPLOYING |>> applyConfigMap
    DONE |>> notifyComplete

-- ============================================================================
-- Helpers
-- ============================================================================

getCfg :: StateFlow Config
getCfg = lift getConfig

-- | StateFlow-level logging (lifts from Flow)
logInfoS :: T.Text -> StateFlow ()
logInfoS = lift . logInfo

logWarningS :: T.Text -> StateFlow ()
logWarningS = lift . logWarning

-- | Get file content from metadata
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

-- | Update config workflow status in target state
updateConfigStatus :: BackendConfigWFStatus -> StateFlow ()
updateConfigStatus newStatus = do
    rs <- gets id
    case targetState rs of
        Just (ConfigState cs) ->
            modify $ \s -> s{targetState = Just (ConfigState (cs{categoryWorkflowStatus = newStatus}))}
        _ ->
            modify $ \s -> s{targetState = Just (ConfigState (emptyConfigState{categoryWorkflowStatus = newStatus}))}

-- ============================================================================
-- Workflow Step Implementations
-- ============================================================================

-- | Validate that the tracker has config/file content
validateConfig :: StateFlow ()
validateConfig = do
    rt <- getRT
    logInfoS $ "Validating config for " <> appGroup rt
    updateConfigStatus BCInit

    fileContent <- getFileContent
    case fileContent of
        Nothing -> liftIO $ throwIO $ WorkflowError "validate" "No file/config content"
        Just fc | T.null (T.strip fc) -> liftIO $ throwIO $ WorkflowError "validate" "Empty file/config content"
        Just _ -> pure ()

    logInfoS "Config validation passed"

-- | Resolve the config content: if raw K8s manifest use directly, otherwise patch existing ConfigMap
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
            -- Resolve namespace from product config
            p <- findProductByName (appGroup rt)
            let ns = case p of
                    Just pCfg -> T.unpack (getProductNamespace pCfg)
                    Nothing -> case metadata rt of
                        Just (Object o) -> case KM.lookup (K.fromText "cluster") o of
                            Just (String c) | not (T.null c) -> T.unpack c
                            _ -> T.unpack (env rt)
                        _ -> T.unpack (env rt)

            -- Capture BEFORE snapshot of configmap
            captureConfigMapSnapshot cfg (releaseId rt) (T.pack ns) (service rt) "CONFIGMAP_BEFORE"

            if isK8sManifest fc
                then do
                    -- Store resolved content + namespace in workflowMetadata for DEPLOYING stage
                    let resolved =
                            Object $
                                KM.fromList
                                    [ ("namespace", String (T.pack ns))
                                    , ("resolvedContent", String fc)
                                    ]
                    modify $ \s -> s{workflowMetadata = Just resolved}
                    logInfoS "  Content is raw K8s manifest, will apply directly"
                else do
                    -- Fetch existing ConfigMap and patch it
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

-- | Apply the resolved ConfigMap content via kubectl replace
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
                    -- Capture AFTER snapshot of configmap
                    captureConfigMapSnapshot cfg (releaseId rt) (T.pack ns) (service rt) "CONFIGMAP_AFTER"
                    logInfoS "ConfigMap applied successfully"
                Left err -> do
                    insertReleaseEvent (releaseId rt) "BUSINESS" "KUBECTL_FAILED" (String err)
                    liftIO $ throwIO $ WorkflowError "apply" ("kubectl apply failed: " <> err)
        _ -> do
            insertReleaseEvent (releaseId rt) "BUSINESS" "KUBECTL_FAILED" (String "Missing workflow metadata (resolveConfigContent did not run?)")
            liftIO $ throwIO $ WorkflowError "apply" "Missing workflow metadata"

-- | Mark workflow as complete
notifyComplete :: StateFlow ()
notifyComplete = do
    rt <- getRT
    logInfoS $ "ConfigMap release " <> releaseId rt <> " completed!"
    lift $ notifyConfigMapCompleted rt
    -- If this is a revert tracker, mark the original as REVERTED
    case (info rt, description rt) of
        (Just "REVERT", Just desc) ->
            case T.stripPrefix "Revert of " desc of
                Just origId -> do
                    mOrig <- findReleaseTracker origId
                    case mOrig of
                        Just (origRt, origTs) | status origRt == REVERTING -> do
                            -- CAS: only transition REVERTING → REVERTED if nobody
                            -- else has touched the original tracker since we read it.
                            -- Prevents a concurrent abort/discard of the original
                            -- being silently overwritten by this revert-completion.
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

-- ============================================================================
-- ConfigMap Helpers (moved from Runner.hs)
-- ============================================================================

-- | Pipe content into kubectl replace -f -
replaceFromStdin :: Config -> String -> Text -> IO (Either Text ())
replaceFromStdin cfg ns content = do
    let args = ["-n", ns, "apply", "-f", "-"]
    (exitCode, _out, err) <- readProcessWithExitCode (kubectlBin cfg) args (T.unpack content)
    case exitCode of
        ExitSuccess -> pure (Right ())
        ExitFailure _ -> pure (Left ("kubectl apply failed: " <> T.pack err))

-- | Check if content looks like a raw K8s YAML manifest
isK8sManifest :: Text -> Bool
isK8sManifest t =
    let stripped = T.strip t
     in T.isPrefixOf "apiVersion:" stripped
            || T.isPrefixOf "kind:" stripped
            || T.isPrefixOf "---" stripped

-- | Patch an existing ConfigMap JSON: replace "data" with new content, strip extra metadata.
patchConfigMapJson :: Text -> Text -> Either Text Text
patchConfigMapJson existingJson newDataContent =
    case eitherDecodeStrict' (encodeUtf8 existingJson) of
        Left err -> Left ("Failed to parse existing ConfigMap JSON: " <> T.pack err)
        Right (Object obj) ->
            let newData = case eitherDecodeStrict' (encodeUtf8 newDataContent) of
                    Right val -> val
                    Left _ -> String newDataContent
                cleanMeta = case KM.lookup "metadata" obj of
                    Just (Object meta) ->
                        let kept =
                                KM.fromList $
                                    concat
                                        [ maybe [] (\v -> [("name", v)]) (KM.lookup "name" meta)
                                        , maybe [] (\v -> [("namespace", v)]) (KM.lookup "namespace" meta)
                                        , maybe [] (\v -> [("labels", v)]) (KM.lookup "labels" meta)
                                        ]
                         in Object kept
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
