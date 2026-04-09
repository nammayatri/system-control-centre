{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- | Workflow helper functions for Recorded monad

Ported from Mobius.Utils.WorkFlow
Provides high-level combinators for checkpoint-based workflow composition
-}
module Products.Autopilot.Workflow.Helpers (
    -- * State Persistence Functions
    persistWorkflowState,

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
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
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

{- | Result of a snapshot fetch attempt.

Three outcomes, each handled differently by 'captureK8sYamlSnapshot':

* 'SnapshotFailed' — the underlying kubectl / HTTP call failed. Surface
  the error message in a 'SNAPSHOT_FAILED' release event so operators
  can see what went wrong in the audit log. Do NOT abort the workflow.
* 'SnapshotRaw' — the call succeeded but YAML/JSON parsing failed.
  Persist the raw text as the snapshot payload (best-effort fallback).
* 'SnapshotOk' — fully parsed; strip K8s noise and persist as YAML.
-}
data SnapshotFetch
    = SnapshotFailed Text
    | SnapshotRaw Text
    | SnapshotOk Value

{- | Internal: shared snapshot pipeline.

Takes a fetch action that yields a 'SnapshotFetch' and persists the result
as a release event. Failures are NOT swallowed silently — they are recorded
as 'SNAPSHOT_FAILED' events with the underlying error message, so the diff
API and audit log surface kubectl problems instead of having mysteriously
missing snapshots.
-}
captureK8sYamlSnapshot ::
    (MonadFlow m) =>
    Text -> -- releaseId
    Text -> -- label
    IO SnapshotFetch ->
    m ()
captureK8sYamlSnapshot releaseId label fetch = do
    result <- liftIO fetch
    case result of
        SnapshotFailed err ->
            -- Visibility fix (B6): record the failure as a release event so
            -- operators can see kubectl problems in the audit trail. We use a
            -- distinct label suffix so 'release_events' rows for failed
            -- snapshots don't get mistaken for successful ones.
            DB.insertReleaseEvent
                releaseId
                "SNAPSHOT"
                (label <> "_FAILED")
                (String ("snapshot fetch failed: " <> err))
        SnapshotRaw raw ->
            DB.insertReleaseEvent releaseId "SNAPSHOT" label (String raw)
        SnapshotOk val ->
            let cleaned = stripK8sNoiseValue val
                cleanYaml = TE.decodeUtf8 (Yaml.encode cleaned)
             in DB.insertReleaseEvent releaseId "SNAPSHOT" label (String cleanYaml)

{- | Decode YAML bytes into a 'SnapshotFetch'. On parse failure, fall back to
  the raw text. The kubectl call itself must have already succeeded —
  callers convert kubectl 'K8sError' to 'SnapshotFailed' before calling.
-}
decodeYamlForSnapshot :: ByteString -> Text -> SnapshotFetch
decodeYamlForSnapshot bs fallback =
    case Yaml.decodeEither' bs :: Either Yaml.ParseException Value of
        Right v -> SnapshotOk v
        Left _ -> SnapshotRaw fallback

-- | Build a kubectl command line from a list of Text args.
kubectlCmd :: Config -> [Text] -> String
kubectlCmd cfg args = kubectlBin cfg <> " " <> T.unpack (T.intercalate " " args)

{- | Run a kubectl command and parse its YAML output, surfacing failures as
  'SnapshotFailed' so the snapshot pipeline can record them in the audit
  log instead of swallowing them.
-}
runKubectlYaml :: Config -> [Text] -> IO SnapshotFetch
runKubectlYaml cfg args = do
    res <- runCmd (kubectlCmd cfg args)
    case res of
        Right (K8sResult yamlStr) -> pure (decodeYamlForSnapshot (TE.encodeUtf8 yamlStr) yamlStr)
        Left (K8sError errMsg) -> pure (SnapshotFailed errMsg)

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
                         in pure (SnapshotOk preview)
                    Left parseErr -> pure (SnapshotFailed ("deployment YAML parse failed: " <> T.pack (show parseErr)))
            Left (K8sError errMsg) -> pure (SnapshotFailed errMsg)

-- | Capture VirtualService YAML snapshot and store as release event.
captureVSSnapshot :: (MonadFlow m) => Config -> Text -> Text -> Text -> Text -> m ()
captureVSSnapshot cfg releaseId ns vsName label =
    captureK8sYamlSnapshot releaseId label $ do
        res <- getVirtualServiceJson cfg ns vsName
        case res of
            Right vsJson ->
                case eitherDecode (LBS.fromStrict (TE.encodeUtf8 vsJson)) :: Either String Value of
                    Right v -> pure (SnapshotOk v)
                    Left _ -> pure (SnapshotRaw vsJson)
            Left err -> pure (SnapshotFailed ("getVirtualServiceJson failed: " <> T.pack (show err)))

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

Removes the @status@ field entirely (runtime state, not spec) and filters
@metadata@ down to just @name@, @namespace@, @labels@. All other top-level
keys (@spec@, @apiVersion@, @kind@, @data@, etc.) are preserved unchanged.
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

-- The legacy '|>>' / 'cprV2' / 'stateCheckFuncV2' operators were removed
-- after all three active workflows (BackendService, BackendScheduler,
-- BackendConfig) migrated to the 'WorkflowSpec' pattern in
-- 'Core.Workflow.Engine'. The equivalent skip-if-past semantics are now
-- encoded per-stage via 'stageGuard' and 'stageOnAdvance' in
-- 'Products.Autopilot.Workflow.StageHelpers.mkLegacyStateFlowStage'.
