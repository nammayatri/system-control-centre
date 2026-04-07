{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Workflow helper functions for Recorded monad

Ported from Mobius.Utils.WorkFlow
Provides high-level combinators for checkpoint-based workflow composition
-}
module Products.Autopilot.Workflow.Helpers (
    -- * Workflow Combinators
    (|>>),
    stateCheckFuncV2,

    -- * State Persistence Functions
    persistWorkflowState,
    persistFinalState,

    -- * Snapshot Capture Functions
    captureDeploymentSnapshot,
    captureDeploymentPreview,
    captureVSSnapshot,
    captureConfigMapSnapshot,

    -- * K8s Noise Stripping
    stripK8sNoiseValue,

    -- * Utility Functions
    continueIf,
    scheduleAfter,
    nowS,
    getRT,
    getReleaseTracker,
    updateRT,
    withK8sContext,
)
where

import Control.Exception (throwIO)
import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.State.Strict (get, gets, modify)
import Control.Monad.Trans.Class (lift)
import qualified Core.AppError as AppErr
import Core.Config (Config (..))
import Core.Environment (Flow, MonadFlow)
import Data.Aeson (Value (..), eitherDecode)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import qualified Data.Vector as V
import qualified Data.Yaml as Yaml
import Products.Autopilot.K8s.Execute (K8sResult (..), runCmd)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import qualified Products.Autopilot.Queries.ReleaseTracker as DB
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Products.Autopilot.Types.Target (K8sDeploymentState (..), TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext)
import Products.Autopilot.Types.Workflow (ReleaseWFStatus (..))
import Products.Autopilot.Workflow.Recorded (recordedWithPersist)
import Products.Autopilot.Workflow.Types (
    ReleaseState (..),
    ReleaseWorkFlow,
    StateFlow,
    WorkFlowError (..),
 )

-- ============================================================================
-- State Persistence
-- ============================================================================

{- | Persist workflow state to database

Saves both the ReleaseTracker and the target state.
-}
persistWorkflowState :: ReleaseState -> Flow ()
persistWorkflowState rs = do
    let rt = releaseTracker rs
        mts = targetState rs
    DB.insertReleaseTracker rt mts

{- | Persist final state to database

Used for the final workflow step. Updates all fields including
those that might be set externally (like release_action).
-}
persistFinalState :: ReleaseState -> Flow ()
persistFinalState = persistWorkflowState

-- ============================================================================
-- Workflow Utilities
-- ============================================================================

{- | Continue workflow execution only if predicate is true

Useful for conditional workflow branching
-}
continueIf :: (ReleaseState -> Bool) -> ReleaseWorkFlow ()
continueIf predicate = do
    rs <- lift get
    unless (predicate rs) $
        throwError (DomainError "Condition not met for workflow continuation")

-- | Get current UTC time inside any MonadIO (use in StateFlow / ReleaseWorkFlow)
nowS :: (MonadIO m) => m UTCTime
nowS = liftIO getCurrentTime

{- | Schedule workflow to resume after a delay

Updates scheduleTime in ReleaseTracker
-}
scheduleAfter :: NominalDiffTime -> ReleaseWorkFlow ()
scheduleAfter delay = do
    now <- nowS
    let scheduledTime = addUTCTime delay now
    modify $ \rs ->
        let rt = releaseTracker rs
            rt' = rt{scheduleTime = Just scheduledTime}
         in rs{releaseTracker = rt'}

-- | Get ReleaseTracker from current state
getRT :: StateFlow ReleaseTracker
getRT = gets releaseTracker

-- | Alias for getRT
getReleaseTracker :: StateFlow ReleaseTracker
getReleaseTracker = getRT

-- | Update ReleaseTracker in current state
updateRT :: (ReleaseTracker -> ReleaseTracker) -> StateFlow ()
updateRT f = modify $ \rs -> rs{releaseTracker = f (releaseTracker rs)}

{- | Extract K8sReleaseContext from current StateFlow, throwing a
'Core.AppError.WorkflowError' if the target state is not a K8sState.
Replaces the duplicated @getK8sCtx@ helpers across backend workflows.
-}
withK8sContext :: StateFlow K8sReleaseContext
withK8sContext = do
    rs <- get
    case targetState rs of
        Just (K8sState k8s) -> pure (context k8s)
        _ -> liftIO $ throwIO $ AppErr.WorkflowError "init" "Missing K8sState in targetState"

-- ============================================================================
-- Snapshot Capture Functions
-- ============================================================================

{- | Internal: shared snapshot pipeline.

Takes a fetch action that yields either a fallback raw text (Left) or
a parsed JSON/YAML 'Value' (Right). The Value is stripped of K8s noise
and re-encoded as YAML before being persisted as a release event.
-}
captureK8sYamlSnapshot ::
    (MonadFlow m) =>
    Text -> -- releaseId
    Text -> -- label
    IO (Maybe (Either Text Value)) ->
    m ()
captureK8sYamlSnapshot releaseId label fetch = do
    mResult <- liftIO fetch
    case mResult of
        Nothing -> pure ()
        Just (Left raw) -> DB.insertReleaseEvent releaseId "SNAPSHOT" label (String raw)
        Just (Right val) ->
            let cleaned = stripK8sNoiseValue val
                cleanYaml = TE.decodeUtf8 (Yaml.encode cleaned)
             in DB.insertReleaseEvent releaseId "SNAPSHOT" label (String cleanYaml)

-- | Decode YAML bytes into 'Either fallback Value' for the snapshot pipeline.
decodeYamlForSnapshot :: ByteString -> Text -> Either Text Value
decodeYamlForSnapshot bs fallback =
    case Yaml.decodeEither' bs :: Either Yaml.ParseException Value of
        Right v -> Right v
        Left _ -> Left fallback

-- | Build a kubectl command line from a list of Text args.
kubectlCmd :: Config -> [Text] -> String
kubectlCmd cfg args = kubectlBin cfg <> " " <> T.unpack (T.intercalate " " args)

-- | Run a kubectl command and parse its YAML output, suitable for the snapshot pipeline.
runKubectlYaml :: Config -> [Text] -> IO (Maybe (Either Text Value))
runKubectlYaml cfg args = do
    res <- runCmd (kubectlCmd cfg args)
    case res of
        Right (K8sResult yamlStr) -> pure (Just (decodeYamlForSnapshot (TE.encodeUtf8 yamlStr) yamlStr))
        Left _ -> pure Nothing

-- | Capture deployment YAML snapshot and store as release event.
captureDeploymentSnapshot :: (MonadFlow m) => Config -> Text -> Text -> Text -> Text -> m ()
captureDeploymentSnapshot cfg releaseId ns depName label =
    captureK8sYamlSnapshot releaseId label $
        runKubectlYaml cfg ["-n", ns, "get deployment", depName, "-o", "yaml"]

-- | Generate a preview of the deployment after applying name/version/image changes.
captureDeploymentPreview :: (MonadFlow m) => Config -> Text -> Text -> Text -> Text -> Text -> Text -> m ()
captureDeploymentPreview cfg releaseId ns oldDepName newVer newImage label =
    captureK8sYamlSnapshot releaseId label $ do
        res <- runCmd (kubectlCmd cfg ["-n", ns, "get deployment", oldDepName, "-o", "yaml"])
        case res of
            Right (K8sResult yamlStr) ->
                case Yaml.decodeEither' (TE.encodeUtf8 yamlStr) :: Either Yaml.ParseException Value of
                    Right val ->
                        let cleaned = stripK8sNoiseValue val
                            preview = modifyDeploymentForPreview cleaned oldDepName newVer newImage
                         in pure (Just (Right preview))
                    Left _ -> pure Nothing
            Left _ -> pure Nothing

-- | Capture VirtualService YAML snapshot and store as release event.
captureVSSnapshot :: (MonadFlow m) => Config -> Text -> Text -> Text -> Text -> m ()
captureVSSnapshot cfg releaseId ns vsName label =
    captureK8sYamlSnapshot releaseId label $ do
        res <- getVirtualServiceJson cfg ns vsName
        case res of
            Right vsJson ->
                case eitherDecode (LBS.fromStrict (TE.encodeUtf8 vsJson)) :: Either String Value of
                    Right v -> pure (Just (Right v))
                    Left _ -> pure (Just (Left vsJson))
            Left _ -> pure Nothing

-- | Capture ConfigMap YAML snapshot and store as release event.
captureConfigMapSnapshot :: (MonadFlow m) => Config -> Text -> Text -> Text -> Text -> m ()
captureConfigMapSnapshot cfg releaseId ns cmName label =
    captureK8sYamlSnapshot releaseId label $
        runKubectlYaml cfg ["-n", ns, "get configmap", cmName, "-o", "yaml"]

-- | Update a nested text field in a JSON object
updateNestedText :: [Text] -> Text -> KM.KeyMap Value -> KM.KeyMap Value
updateNestedText [] _ obj = obj
updateNestedText [k] v obj = KM.insert (K.fromText k) (String v) obj
updateNestedText (k : ks) v obj =
    case KM.lookup (K.fromText k) obj of
        Just (Object inner) -> KM.insert (K.fromText k) (Object (updateNestedText ks v inner)) obj
        _ -> obj

-- | Update the first container's image in a deployment spec
updateContainerImage :: Text -> KM.KeyMap Value -> KM.KeyMap Value
updateContainerImage img obj =
    case KM.lookup (K.fromText "spec") obj of
        Just (Object spec) -> case KM.lookup (K.fromText "template") spec of
            Just (Object tmpl) -> case KM.lookup (K.fromText "spec") tmpl of
                Just (Object podSpec) -> case KM.lookup (K.fromText "containers") podSpec of
                    Just (Array containers) ->
                        let cList = V.toList containers
                         in case cList of
                                (Object c : rest) ->
                                    let c' = KM.insert (K.fromText "image") (String img) c
                                        containers' = Array (V.fromList (Object c' : rest))
                                        podSpec' = KM.insert (K.fromText "containers") containers' podSpec
                                        tmpl' = KM.insert (K.fromText "spec") (Object podSpec') tmpl
                                        spec' = KM.insert (K.fromText "template") (Object tmpl') spec
                                     in KM.insert (K.fromText "spec") (Object spec') obj
                                _ -> obj
                    _ -> obj
                _ -> obj
            _ -> obj
        _ -> obj

{- | Strip K8s noise from a parsed Value directly.
Removes status, strips metadata to only name/namespace/labels.
-}
stripK8sNoiseValue :: Value -> Value
stripK8sNoiseValue (Object obj) =
    let cleaned = KM.delete (K.fromText "status") obj
        cleanMeta = case KM.lookup (K.fromText "metadata") cleaned of
            Just (Object meta) ->
                let keep = KM.filterWithKey (\k _ -> K.toText k `elem` ["name", "namespace", "labels"]) meta
                 in KM.insert (K.fromText "metadata") (Object keep) cleaned
            _ -> cleaned
     in Object cleanMeta
stripK8sNoiseValue other = other

-- | Modify a deployment Value for preview: update name, version labels, image.
modifyDeploymentForPreview :: Value -> Text -> Text -> Text -> Value
modifyDeploymentForPreview (Object obj) oldDepName newVer newImage =
    let parts = T.splitOn "-" oldDepName
        svcHost = if length parts > 1 then T.intercalate "-" (init parts) else oldDepName
        newDepName = svcHost <> "-" <> newVer
        obj1 = updateNestedText ["metadata", "name"] newDepName obj
        obj2 = updateNestedText ["metadata", "labels", "version"] newVer obj1
        obj3 = updateNestedText ["spec", "selector", "matchLabels", "version"] newVer obj2
        obj4 = updateNestedText ["spec", "template", "metadata", "labels", "version"] newVer obj3
        obj5 = if T.null newImage then obj4 else updateContainerImage newImage obj4
     in Object obj5
modifyDeploymentForPreview other _ _ _ = other

-- ============================================================================
-- ReleaseWFStatus-based Helpers
-- ============================================================================

-- | Check if workflow has reached a particular checkpoint
stateCheckFuncV2 :: ReleaseWFStatus -> ReleaseState -> Maybe ()
stateCheckFuncV2 targetStatus rs =
    let rt = releaseTracker rs
        currentStatus = releaseWFStatus rt
     in if currentStatus >= targetStatus
            then Just ()
            else Nothing

-- | Checkpoint-resume operator
cprV2 :: ReleaseWFStatus -> StateFlow () -> ReleaseWorkFlow ()
cprV2 targetStatus func =
    lift $ recordedWithPersist persistWorkflowState funcExec (stateCheckFuncV2 targetStatus)
  where
    funcExec = do
        func
        modify $ \rs ->
            let rt = releaseTracker rs
                rt' = rt{releaseWFStatus = targetStatus}
             in rs{releaseTracker = rt'}

-- | Infix synonym for 'cprV2'
(|>>) :: ReleaseWFStatus -> StateFlow () -> ReleaseWorkFlow ()
(|>>) = cprV2

infixl 1 |>>
