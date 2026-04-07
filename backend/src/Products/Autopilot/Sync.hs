{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | Cross-cluster sync — pushes a completed release to a secondary
cluster's @namma-ap@ instance via HTTP.

All entry points run in 'MonadFlow'; background fan-out uses
'forkFlow' so the spawned thread inherits 'AppState'.
-}
module Products.Autopilot.Sync (
    triggerSyncIfEnabled,
    triggerRevertSyncIfEnabled,
    triggerImmediateRevertSync,
)
where

import Control.Concurrent (forkIO)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Core.Config (Config (..))
import Core.Environment (Flow, MonadFlow, forkFlow, getConfig, runFlow)
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Int (Int32)
import Products.Autopilot.Queries.ProductService (findProductByName, getProductSyncCluster)
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (isK8sEnabled, isSyncClusterEnabled)
import Products.Autopilot.Types
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (
    K8sDeploymentState (context),
    K8sReleaseContext (dockerImage, revert, syncClusterEnvOverrideData, syncClusterRolloutStrategy, syncXForwardedEmail, syncXPomeriumJwt),
 )
import Prelude

-- ──────────────────────────────────────────────────────────────────
-- Shared helpers
-- ──────────────────────────────────────────────────────────────────

getK8sContext :: Maybe TargetState -> Maybe K8sReleaseContext
getK8sContext (Just (K8sState k8s)) = Just (context k8s)
getK8sContext _ = Nothing

normaliseBase :: String -> Text
normaliseBase raw =
    let withScheme = if "http" `T.isPrefixOf` T.pack raw then T.pack raw else "http://" <> T.pack raw
     in if T.null withScheme || T.last withScheme == '/'
            then withScheme
            else withScheme <> "/"

buildAuthHeaders :: Config -> Maybe K8sReleaseContext -> ([(Text, Text)], Text)
buildAuthHeaders cfg mCtx =
    let mXfe = mCtx >>= syncXForwardedEmail
        mJwt = mCtx >>= syncXPomeriumJwt
        hasXfe = maybe False (not . T.null . T.strip) mXfe
        hasJwt = maybe False (not . T.null . T.strip) mJwt
        baseAuth = syncClusterBaseAuth cfg
     in if hasXfe || hasJwt
            then
                let xfe = case mXfe of Just t | not (T.null (T.strip t)) -> [("X-Forwarded-Email", t)]; _ -> []
                    jwt = case mJwt of Just t | not (T.null (T.strip t)) -> [("x-pomerium-jwt-assertion", t)]; _ -> []
                 in (xfe <> jwt, "forwarded_headers")
            else
                if not (null baseAuth)
                    then ([("Authorization", "Basic " <> T.pack baseAuth)], "basic_auth")
                    else ([], "none")

revertValue :: ReleaseTracker -> Int
revertValue _ = 0

getSyncRolloutStrategy :: ReleaseTracker -> Maybe K8sReleaseContext -> Value
getSyncRolloutStrategy tracker mCtx =
    case mCtx >>= syncClusterRolloutStrategy of
        Just s | not (T.null s) ->
            case eitherDecode (LBS.pack (T.unpack s)) :: Either String Value of
                Right v -> v
                Left _ -> toJSON (rolloutStrategy tracker)
        _ -> toJSON (rolloutStrategy tracker)

-- ──────────────────────────────────────────────────────────────────
-- Shared HTTP send
-- ──────────────────────────────────────────────────────────────────

sendSyncRequest ::
    (MonadFlow m) =>
    ReleaseTracker ->
    Text ->
    HttpReq ->
    Value ->
    m ()
sendSyncRequest tracker labelPrefix req reqLogPayload = do
    insertReleaseEvent (releaseId tracker) "BUSINESS" (labelPrefix <> "_REQUEST") reqLogPayload
    sendSyncRequestNoReqLog tracker labelPrefix req

-- | Variant that skips emitting the _REQUEST event (caller already did).
sendSyncRequestNoReqLog ::
    (MonadFlow m) =>
    ReleaseTracker ->
    Text ->
    HttpReq ->
    m ()
sendSyncRequestNoReqLog tracker labelPrefix req = do
    result <- liftIO $ httpRaw req
    case result of
        Right HttpResponse{respStatus = s, respBody = b}
            | s < 400 ->
                insertReleaseEvent
                    (releaseId tracker)
                    "BUSINESS"
                    (labelPrefix <> "_RESPONSE")
                    (object ["status" .= ("SUCCESS" :: Text), "body" .= TE.decodeUtf8 (LBS.toStrict b), "url" .= reqUrl req])
        Right HttpResponse{respStatus = s, respBody = b} ->
            insertReleaseEvent
                (releaseId tracker)
                "BUSINESS"
                (labelPrefix <> "_FAILED_FINAL")
                (object ["status" .= s, "body" .= TE.decodeUtf8 (LBS.toStrict b), "url" .= reqUrl req])
        Left e ->
            insertReleaseEvent
                (releaseId tracker)
                "BUSINESS"
                (labelPrefix <> "_FAILED_FINAL")
                (object ["error" .= T.pack (show e), "url" .= reqUrl req])

-- ──────────────────────────────────────────────────────────────────
-- Public entry points
-- ──────────────────────────────────────────────────────────────────

triggerSyncIfEnabled :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> m ()
triggerSyncIfEnabled tracker mts = do
    cfg <- getConfig
    let syncUrl = syncClusterUrl cfg
    if null syncUrl
        then insertReleaseEvent (releaseId tracker) "BUSINESS" "SYNC_SKIPPED" (String "No SYNC_CLUSTER_URL configured")
        else do
            k8sEnabled <- isK8sEnabled
            syncClusterOn <- isSyncClusterEnabled
            let syncFlag = maybe False (\t -> T.toLower t == "true") (syncEnabled tracker)
            mProduct <- findProductByName (appGroup tracker)
            let mSyncCluster = mProduct >>= getProductSyncCluster
                hasSyncCluster = maybe False (not . T.null) mSyncCluster
            insertReleaseEvent
                (releaseId tracker)
                "BUSINESS"
                "SYNC_GATE_CHECK"
                (object ["k8sEnabled" .= k8sEnabled, "syncClusterOn" .= syncClusterOn, "syncFlag" .= syncFlag, "hasSyncCluster" .= hasSyncCluster, "syncCluster" .= mSyncCluster])
            if k8sEnabled && syncClusterOn && syncFlag && hasSyncCluster
                then do
                    let target = maybe "" id mSyncCluster
                    insertReleaseEvent (releaseId tracker) "BUSINESS" "SYNC_TRIGGERED" (String ("Syncing to cluster: " <> target))
                    st <- ask
                    _ <- liftIO $ forkIO $ runFlow st (doCreate cfg tracker mts target)
                    pure ()
                else
                    insertReleaseEvent
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_SKIPPED"
                        (object ["syncClusterOn" .= syncClusterOn, "syncFlag" .= syncFlag, "hasSyncCluster" .= hasSyncCluster])

doCreate :: Config -> ReleaseTracker -> Maybe TargetState -> Text -> Flow ()
doCreate cfg tracker mts targetCluster = do
    let base = normaliseBase (syncClusterUrl cfg)
        url = base <> "releases/create"
        mCtx = getK8sContext mts
        syncEnvOverride = case mCtx >>= syncClusterEnvOverrideData of
            Just t | not (T.null t) -> Just t
            _ -> envOverrideData tracker
        body =
            object
                [ "release_tag" .= releaseTag tracker
                , "product" .= appGroup tracker
                , "service" .= [service tracker]
                , "env" .= env tracker
                , "mode" .= show (mode tracker)
                , "priority" .= (0 :: Int32)
                , "release_manager" .= createdBy tracker
                , "new_version" .= newVersion tracker
                , "description" .= description tracker
                , "rollout_strategy" .= getSyncRolloutStrategy tracker mCtx
                , "cluster" .= targetCluster
                , "docker_image" .= (mCtx >>= dockerImage)
                , "change_log" .= changeLog tracker
                , "info" .= info tracker
                , "udf2" .= syncEnvOverride
                , "revert" .= revertValue tracker
                , "global_id" .= globalId tracker
                , "is_infra_approved" .= (1 :: Int)
                , "is_approved" .= True
                , "udf3" .= slackThreadTs tracker
                , "isReleaseSync" .= False
                , "isSystemTriggered" .= True
                ]
        (auth, authMode) = buildAuthHeaders cfg mCtx
        req =
            (defaultReq url)
                { reqMethod = POST
                , reqHeaders = ("Content-Type", "application/json") : ("Connection", "close") : auth
                , reqBody = Just (encode body)
                , reqTimeout = Seconds 30
                , reqRetries = 1
                , reqLogTag = "sync"
                }
        reqLog =
            object
                [ "url" .= url
                , "cluster" .= targetCluster
                , "auth_mode" .= authMode
                , "has_x_forwarded_email" .= maybe False (not . T.null . T.strip) (mCtx >>= syncXForwardedEmail)
                , "has_pomerium_jwt" .= maybe False (not . T.null . T.strip) (mCtx >>= syncXPomeriumJwt)
                , "body" .= body
                ]
    sendSyncRequest tracker "SYNC" req reqLog

triggerRevertSyncIfEnabled :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> m ()
triggerRevertSyncIfEnabled tracker mts = do
    cfg <- getConfig
    let syncUrl = syncClusterUrl cfg
        mCtx = getK8sContext mts
        isRevert = maybe False (maybe False (/= 0) . revert) mCtx
        syncFlag = maybe False (\t -> T.toLower t == "true") (syncEnabled tracker)
        mGlobalId = globalId tracker
        hasGlobalId = maybe False (not . T.null) mGlobalId
    if not isRevert || not syncFlag || not hasGlobalId || null syncUrl
        then pure ()
        else do
            syncClusterOn <- isSyncClusterEnabled
            mProduct <- findProductByName (appGroup tracker)
            let mSyncCluster = mProduct >>= getProductSyncCluster
                hasSyncCluster = maybe False (not . T.null) mSyncCluster
            insertReleaseEvent
                (releaseId tracker)
                "BUSINESS"
                "REVERT_SYNC_GATE_CHECK"
                (object ["syncClusterOn" .= syncClusterOn, "syncFlag" .= syncFlag, "hasGlobalId" .= hasGlobalId, "hasSyncCluster" .= hasSyncCluster, "globalId" .= mGlobalId])
            if syncClusterOn && hasSyncCluster
                then do
                    let gid = maybe "" id mGlobalId
                    insertReleaseEvent (releaseId tracker) "BUSINESS" "REVERT_SYNC_TRIGGERED" (String ("Triggering revert sync for global_id=" <> gid))
                    st <- ask
                    _ <- liftIO $ forkIO $ runFlow st (doRevert cfg tracker mts gid)
                    pure ()
                else
                    insertReleaseEvent
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_SKIPPED"
                        (object ["syncClusterOn" .= syncClusterOn, "hasSyncCluster" .= hasSyncCluster])

doRevert :: Config -> ReleaseTracker -> Maybe TargetState -> Text -> Flow ()
doRevert cfg tracker mts gid = do
    let base = normaliseBase (syncClusterUrl cfg)
        url = base <> "release/revert/global/" <> gid
        mCtx = getK8sContext mts
        (auth, authMode) = buildAuthHeaders cfg mCtx
        req =
            (defaultReq url)
                { reqMethod = PUT
                , reqHeaders = ("Content-Type", "application/json") : ("Connection", "close") : auth
                , reqTimeout = Seconds 30
                , reqRetries = 1
                , reqLogTag = "revert-sync"
                }
        reqLog = object ["url" .= url, "global_id" .= gid, "auth_mode" .= authMode]
    sendSyncRequest tracker "REVERT_SYNC" req reqLog

triggerImmediateRevertSync :: ReleaseTracker -> Maybe TargetState -> Flow ()
triggerImmediateRevertSync tracker mts = do
    cfg <- getConfig
    let syncUrl = syncClusterUrl cfg
        mGlobalId = globalId tracker
        hasGlobalId = maybe False (not . T.null) mGlobalId
    if null syncUrl || not hasGlobalId
        then pure ()
        else do
            syncClusterOn <- isSyncClusterEnabled
            mProduct <- findProductByName (appGroup tracker)
            let mSyncCluster = mProduct >>= getProductSyncCluster
                hasSyncCluster = maybe False (not . T.null) mSyncCluster
                gid = maybe "" id mGlobalId
            if syncClusterOn && hasSyncCluster
                then do
                    let base = normaliseBase syncUrl
                        url = base <> "release/revert/immediate/global/" <> gid
                        mCtx = getK8sContext mts
                        (auth, authMode) = buildAuthHeaders cfg mCtx
                        req =
                            (defaultReq url)
                                { reqMethod = PUT
                                , reqHeaders = ("Content-Type", "application/json") : ("Connection", "close") : auth
                                , reqTimeout = Seconds 30
                                , reqRetries = 1
                                , reqLogTag = "immediate-revert-sync"
                                }
                        reqLog = object ["url" .= url, "global_id" .= gid, "auth_mode" .= authMode]
                    -- Emit the REQUEST event on the caller thread (matches pre-refactor ordering)
                    insertReleaseEvent (releaseId tracker) "BUSINESS" "IMMEDIATE_REVERT_SYNC_REQUEST" reqLog
                    _ <- forkFlow $ sendSyncRequestNoReqLog tracker "IMMEDIATE_REVERT_SYNC" req
                    pure ()
                else pure ()
