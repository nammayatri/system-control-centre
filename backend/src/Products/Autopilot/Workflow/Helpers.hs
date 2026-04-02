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

    -- * Utility Functions
    continueIf,
    scheduleAfter,
    getRT,
    getReleaseTracker,
    updateRT,
)
where

import Control.Monad (unless)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State.Strict (get, gets, modify)
import Control.Monad.Trans.Class (lift)
import Core.Config (Config (..))
import Core.Environment (DBEnv)
import Core.Utils.FlowMonad (Flow, getDBEnv)
import Data.Aeson (Value (..), eitherDecode, encode, toJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, addUTCTime, getCurrentTime)
import Products.Autopilot.K8s.Execute (K8sError (..), K8sResult (..), runCmd)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import qualified Products.Autopilot.Queries.ReleaseTracker as DB
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
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
    db <- getDBEnv
    let rt = releaseTracker rs
        mts = targetState rs
    liftIO $ DB.insertReleaseTracker db rt mts

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

{- | Schedule workflow to resume after a delay

Updates scheduleTime in ReleaseTracker
-}
scheduleAfter :: NominalDiffTime -> ReleaseWorkFlow ()
scheduleAfter delay = do
    now <- lift $ lift $ liftIO getCurrentTime -- ExceptT -> Recorded -> Flow -> IO
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

-- ============================================================================
-- Snapshot Capture Functions
-- ============================================================================

-- | Capture deployment YAML snapshot and store as release event
captureDeploymentSnapshot :: Config -> DBEnv -> Text -> Text -> Text -> Text -> IO ()
captureDeploymentSnapshot cfg db releaseId ns depName label = do
    -- Use JSON output so we can strip metadata noise before storing
    result <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack depName, "-o", "json"])
    case result of
        Right (K8sResult jsonStr) -> DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON (stripK8sNoise jsonStr))
        Left _ -> pure ()

-- | Generate a preview of what the deployment will look like after changes.
-- Fetches old deployment JSON, modifies specific fields (name, version labels, image),
-- stores as event. This makes the diff available at creation time.
captureDeploymentPreview :: Config -> DBEnv -> Text -> Text -> Text -> Text -> Text -> Text -> IO ()
captureDeploymentPreview cfg db releaseId ns oldDepName newVer newImage label = do
    result <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get deployment", T.unpack oldDepName, "-o", "json"])
    case result of
        Right (K8sResult jsonStr) -> do
            let cleaned = stripK8sNoise jsonStr
            case eitherDecode (LBS.fromStrict (TE.encodeUtf8 cleaned)) :: Either String Value of
                Right (Object obj) -> do
                    -- Extract service host from old deployment name (e.g. "test-svc" from "test-svc-e2e-v1")
                    let svcHost = T.intercalate "-" (init (T.splitOn "-" oldDepName))
                        newDepName = svcHost <> "-" <> newVer
                        -- Update metadata.name
                        obj1 = updateNestedText ["metadata", "name"] newDepName obj
                        -- Update metadata.labels.version
                        obj2 = updateNestedText ["metadata", "labels", "version"] newVer obj1
                        -- Update spec.selector.matchLabels.version
                        obj3 = updateNestedText ["spec", "selector", "matchLabels", "version"] newVer obj2
                        -- Update spec.template.metadata.labels.version
                        obj4 = updateNestedText ["spec", "template", "metadata", "labels", "version"] newVer obj3
                        -- Update container image if provided
                        obj5 = if T.null newImage then obj4
                               else updateContainerImage newImage obj4
                        result' = TE.decodeUtf8 (LBS.toStrict (encode (Object obj5)))
                    DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON result')
                _ -> do
                    -- Can't parse, store as-is
                    DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON cleaned)
        Left _ -> pure ()

-- | Update a nested text field in a JSON object
updateNestedText :: [Text] -> Text -> KM.KeyMap Value -> KM.KeyMap Value
updateNestedText [] _ obj = obj
updateNestedText [k] v obj = KM.insert (K.fromText k) (String v) obj
updateNestedText (k:ks) v obj =
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

-- | Capture VirtualService JSON snapshot and store as release event
captureVSSnapshot :: Config -> DBEnv -> Text -> Text -> Text -> Text -> IO ()
captureVSSnapshot cfg db releaseId ns vsName label = do
    result <- getVirtualServiceJson cfg ns vsName
    case result of
        Right vsJson -> DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON (stripK8sNoise vsJson))
        Left _ -> pure ()

-- | Capture ConfigMap snapshot and store as release event
captureConfigMapSnapshot :: Config -> DBEnv -> Text -> Text -> Text -> Text -> IO ()
captureConfigMapSnapshot cfg db releaseId ns cmName label = do
    result <- runCmd (unwords [kubectlBin cfg, "-n", T.unpack ns, "get configmap", T.unpack cmName, "-o", "json"])
    case result of
        Right (K8sResult jsonStr) -> DB.insertReleaseEvent db releaseId "SNAPSHOT" label (toJSON (stripK8sNoise jsonStr))
        Left _ -> pure ()

-- | Strip K8s metadata noise: annotations, resourceVersion, uid, generation, status, managedFields
-- Keeps only name, namespace, labels in metadata. Like production autopilot's getContentWithoutExtraMetadata.
stripK8sNoise :: Text -> Text
stripK8sNoise raw =
    case eitherDecode (LBS.fromStrict (TE.encodeUtf8 raw)) :: Either String Value of
        Left _ -> raw -- not JSON, return as-is
        Right (Object obj) ->
            let cleaned = KM.delete (K.fromText "status") obj
                cleanMeta = case KM.lookup (K.fromText "metadata") cleaned of
                    Just (Object meta) ->
                        let keep = KM.filterWithKey (\k _ -> K.toText k `elem` ["name", "namespace", "labels"]) meta
                        in KM.insert (K.fromText "metadata") (Object keep) cleaned
                    _ -> cleaned
            in TE.decodeUtf8 (LBS.toStrict (encode (Object cleanMeta)))
        Right other -> TE.decodeUtf8 (LBS.toStrict (encode other))

-- ============================================================================
-- ReleaseWFStatus-based Helpers
-- ============================================================================

{- | Check if workflow has reached a particular checkpoint

Returns Just () if releaseWFStatus >= target checkpoint
Returns Nothing if not yet reached (should execute the step)
-}
stateCheckFuncV2 :: ReleaseWFStatus -> ReleaseState -> Maybe ()
stateCheckFuncV2 targetStatus rs =
    let rt = releaseTracker rs
        currentStatus = releaseWFStatus rt
     in if currentStatus >= targetStatus
            then Just () -- Already completed this checkpoint
            else Nothing -- Not yet completed, need to execute

{- | Checkpoint-resume operator

Automatically checks if step is complete via releaseWFStatus, skips if done.
After execution, persists state to DB.

Usage:
@
workflow = do
 Init |>> validatePreconditions
 Deploying |>> deployApplication
 Monitoring |>> monitorHealth
 Finalizing |>> cleanup
@
-}
cprV2 :: ReleaseWFStatus -> StateFlow () -> ReleaseWorkFlow ()
cprV2 targetStatus func =
    lift $ recordedWithPersist persistWorkflowState funcExec (stateCheckFuncV2 targetStatus)
  where
    funcExec = do
        func
        -- Update releaseWFStatus after execution
        modify $ \rs ->
            let rt = releaseTracker rs
                rt' = rt{releaseWFStatus = targetStatus}
             in rs{releaseTracker = rt'}

-- | Infix synonym for 'cprV2'
(|>>) :: ReleaseWFStatus -> StateFlow () -> ReleaseWorkFlow ()
(|>>) = cprV2

infixl 1 |>>
