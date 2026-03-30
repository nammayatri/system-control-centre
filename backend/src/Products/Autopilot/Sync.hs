{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Sync (
    triggerSyncIfEnabled,
    triggerRevertSyncIfEnabled,
    triggerImmediateRevertSync,
)
where

import Control.Concurrent (forkIO)
import Control.Exception (SomeException, try)
import Core.Config (Config (..))
import Core.Config.Runtime (isSyncClusterEnabled)
import Core.Environment (DBEnv)
import Data.Aeson (Value (..), encode, object, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Int (Int32)
import Products.Autopilot.Queries.ProductService (findProductByName, getProductSyncCluster)
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.Types
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes (
    K8sDeploymentState (context),
    K8sReleaseContext (dockerImage, revert, syncClusterUdf2, syncXForwardedEmail, syncXPomeriumJwt),
 )
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Prelude hiding (product)

-- | Extract K8s context from a Maybe TargetState
getK8sContext :: Maybe TargetState -> Maybe K8sReleaseContext
getK8sContext (Just (K8sState k8s)) = Just (context k8s)
getK8sContext _ = Nothing

{- | Trigger sync to secondary cluster if all gates pass.
Called after release reaches COMPLETED status.
Gates: sync_cluster_enabled in DB, product has sync_cluster,
release has udf1="true".
-}
triggerSyncIfEnabled :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
triggerSyncIfEnabled cfg db tracker mts = do
    let syncUrl = syncClusterUrl cfg
    if null syncUrl
        then insertReleaseEvent db (releaseId tracker) "BUSINESS" "SYNC_SKIPPED" (String "No SYNC_CLUSTER_URL configured")
        else do
            syncEnabled <- isSyncClusterEnabled db
            let udf1Flag = maybe False (\t -> T.toLower t == "true") (udf1 tracker)
            mProduct <- findProductByName db (product tracker)
            let mSyncCluster = mProduct >>= getProductSyncCluster
                hasSyncCluster = maybe False (not . T.null) mSyncCluster
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "SYNC_GATE_CHECK"
                ( object
                    [ "syncEnabled" .= syncEnabled
                    , "udf1" .= udf1Flag
                    , "hasSyncCluster" .= hasSyncCluster
                    , "syncCluster" .= mSyncCluster
                    ]
                )
            if syncEnabled && udf1Flag && hasSyncCluster
                then do
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_TRIGGERED"
                        (String ("Syncing to cluster: " <> maybe "" id mSyncCluster))
                    _ <- forkIO $ createTrackerForSyncCluster cfg db tracker mts (maybe "" id mSyncCluster)
                    pure ()
                else
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_SKIPPED"
                        ( object
                            [ "syncEnabled" .= syncEnabled
                            , "udf1" .= udf1Flag
                            , "hasSyncCluster" .= hasSyncCluster
                            ]
                        )

{- | Build auth headers for sync request.
Priority: forwarded headers from K8s context > Basic auth fallback.
-}
buildSyncAuthArgs :: Config -> Maybe K8sReleaseContext -> ([String], Text)
buildSyncAuthArgs cfg mCtx =
    let mXfe = mCtx >>= syncXForwardedEmail
        mJwt = mCtx >>= syncXPomeriumJwt
        hasXfe = maybe False (not . T.null . T.strip) mXfe
        hasJwt = maybe False (not . T.null . T.strip) mJwt
        baseAuth = syncClusterBaseAuth cfg
     in if hasXfe || hasJwt
            then
                let xfeArgs = case mXfe of
                        Just xfe | not (T.null (T.strip xfe)) -> ["-H", "X-Forwarded-Email: " <> T.unpack xfe]
                        _ -> []
                    jwtArgs = case mJwt of
                        Just jwt | not (T.null (T.strip jwt)) -> ["-H", "x-pomerium-jwt-assertion: " <> T.unpack jwt]
                        _ -> []
                 in (xfeArgs <> jwtArgs, "forwarded_headers")
            else
                if not (null baseAuth)
                    then (["-H", "Authorization: Basic " <> baseAuth], "basic_auth")
                    else ([], "none")

-- | POST release to sync cluster URL using curl.
createTrackerForSyncCluster :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> Text -> IO ()
createTrackerForSyncCluster cfg db tracker mts targetCluster = do
    let rawUrl = syncClusterUrl cfg
        normalised =
            let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
             in if last u == '/' then u else u <> "/"
        url = normalised <> "releases/create"
        mCtx = getK8sContext mts
        syncUdf2 = case mCtx >>= syncClusterUdf2 of
            Just t | not (T.null t) -> Just t
            _ -> udf2 tracker
        body =
            object
                [ "release_tag" .= releaseTag tracker
                , "product" .= product tracker
                , "service" .= [service tracker]
                , "env" .= env tracker
                , "mode" .= show (mode tracker)
                , "priority" .= (0 :: Int32)
                , "release_manager" .= createdBy tracker
                , "new_version" .= newVersion tracker
                , "description" .= description tracker
                , "rollout_strategy" .= rolloutStrategy tracker
                , "cluster" .= targetCluster
                , "docker_image" .= (mCtx >>= dockerImage)
                , "change_log" .= changeLog tracker
                , "info" .= info tracker
                , "udf2" .= syncUdf2
                , "revert" .= (0 :: Int)
                , "global_id" .= globalId tracker
                , "is_infra_approved" .= True
                , "udf3" .= udf3 tracker
                , "isReleaseSync" .= False
                , "isSystemTriggered" .= True
                ]
        bodyStr = LBS.unpack (encode body)
        (authArgs, authMode) = buildSyncAuthArgs cfg mCtx
        curlArgs =
            [ "-s"
            , "-X"
            , "POST"
            , url
            , "-H"
            , "Content-Type: application/json"
            , "-H"
            , "Connection: close"
            , "-d"
            , bodyStr
            , "--max-time"
            , "30"
            ]
                <> authArgs

    -- Log the outgoing sync request
    insertReleaseEvent
        db
        (releaseId tracker)
        "BUSINESS"
        "SYNC_REQUEST"
        ( object
            [ "url" .= url
            , "cluster" .= targetCluster
            , "auth_mode" .= authMode
            , "has_x_forwarded_email" .= maybe False (not . T.null . T.strip) (mCtx >>= syncXForwardedEmail)
            , "has_pomerium_jwt" .= maybe False (not . T.null . T.strip) (mCtx >>= syncXPomeriumJwt)
            , "body" .= body
            ]
        )

    result <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
    case result of
        Left e -> do
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "SYNC_FAILED"
                ( object
                    [ "error" .= show e
                    , "url" .= url
                    , "auth_mode" .= authMode
                    ]
                )
            -- Retry once
            retryResult <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
            case retryResult of
                Right (ExitSuccess, out2, _) ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_RESPONSE"
                        (object ["status" .= ("SUCCESS_ON_RETRY" :: Text), "body" .= out2, "url" .= url])
                Right (ExitFailure code2, _, err2) ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_FAILED_RETRY"
                        (object ["exitCode" .= code2, "error" .= err2, "url" .= url])
                Left e2 ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_FAILED_RETRY"
                        (object ["error" .= show e2, "url" .= url])
        Right (ExitSuccess, out, _) ->
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "SYNC_RESPONSE"
                ( object
                    [ "status" .= ("SUCCESS" :: Text)
                    , "body" .= out
                    , "url" .= url
                    , "auth_mode" .= authMode
                    ]
                )
        Right (ExitFailure code, _, err) -> do
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "SYNC_FAILED"
                ( object
                    [ "exitCode" .= code
                    , "error" .= err
                    , "url" .= url
                    , "auth_mode" .= authMode
                    ]
                )
            -- Retry once
            retryResult <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
            case retryResult of
                Right (ExitSuccess, out2, _) ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_RESPONSE"
                        (object ["status" .= ("SUCCESS_ON_RETRY" :: Text), "body" .= out2, "url" .= url])
                _ ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "SYNC_FAILED_FINAL"
                        (object ["url" .= url, "message" .= ("Both attempts failed" :: Text)])

-- | Trigger revert sync after a revert release completes.
triggerRevertSyncIfEnabled :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
triggerRevertSyncIfEnabled cfg db tracker mts = do
    let syncUrl = syncClusterUrl cfg
        mCtx = getK8sContext mts
        isRevert = maybe False (maybe False (/= 0) . revert) mCtx
        udf1Flag = maybe False (\t -> T.toLower t == "true") (udf1 tracker)
        mGlobalId = globalId tracker
        hasGlobalId = maybe False (not . T.null) mGlobalId
    if not isRevert || not udf1Flag || not hasGlobalId || null syncUrl
        then pure ()
        else do
            syncEnabled <- isSyncClusterEnabled db
            mProduct <- findProductByName db (product tracker)
            let mSyncCluster = mProduct >>= getProductSyncCluster
                hasSyncCluster = maybe False (not . T.null) mSyncCluster
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "REVERT_SYNC_GATE_CHECK"
                ( object
                    [ "syncEnabled" .= syncEnabled
                    , "udf1" .= udf1Flag
                    , "hasGlobalId" .= hasGlobalId
                    , "hasSyncCluster" .= hasSyncCluster
                    , "globalId" .= mGlobalId
                    ]
                )
            if syncEnabled && hasSyncCluster
                then do
                    let gid = maybe "" id mGlobalId
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_TRIGGERED"
                        (String ("Triggering revert sync for global_id=" <> gid))
                    _ <- forkIO $ revertTrackerSyncCluster cfg db tracker mts gid
                    pure ()
                else
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_SKIPPED"
                        (object ["syncEnabled" .= syncEnabled, "hasSyncCluster" .= hasSyncCluster])

-- | PUT to sync cluster to revert a release by global_id.
revertTrackerSyncCluster :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> Text -> IO ()
revertTrackerSyncCluster cfg db tracker mts gid = do
    let rawUrl = syncClusterUrl cfg
        normalised =
            let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
             in if last u == '/' then u else u <> "/"
        url = normalised <> "release/revert/global/" <> T.unpack gid
        mCtx = getK8sContext mts
        (authArgs, authMode) = buildSyncAuthArgs cfg mCtx
        curlArgs =
            [ "-s"
            , "-X"
            , "PUT"
            , url
            , "-H"
            , "Content-Type: application/json"
            , "-H"
            , "Connection: close"
            , "--max-time"
            , "30"
            ]
                <> authArgs
    insertReleaseEvent
        db
        (releaseId tracker)
        "BUSINESS"
        "REVERT_SYNC_REQUEST"
        (object ["url" .= url, "global_id" .= gid, "auth_mode" .= authMode])
    result <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
    case result of
        Right (ExitSuccess, out, _) ->
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "REVERT_SYNC_RESPONSE"
                (object ["status" .= ("SUCCESS" :: Text), "body" .= out, "url" .= url])
        Right (ExitFailure code, _, err) -> do
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "REVERT_SYNC_FAILED"
                (object ["exitCode" .= code, "error" .= err, "url" .= url])
            -- Retry once
            retryResult <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
            case retryResult of
                Right (ExitSuccess, out2, _) ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_RESPONSE"
                        (object ["status" .= ("SUCCESS_ON_RETRY" :: Text), "body" .= out2, "url" .= url])
                _ ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_FAILED_FINAL"
                        (object ["url" .= url, "message" .= ("Both attempts failed" :: Text)])
        Left e -> do
            insertReleaseEvent
                db
                (releaseId tracker)
                "BUSINESS"
                "REVERT_SYNC_FAILED"
                (object ["error" .= show e, "url" .= url])
            retryResult <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
            case retryResult of
                Right (ExitSuccess, out2, _) ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_RESPONSE"
                        (object ["status" .= ("SUCCESS_ON_RETRY" :: Text), "body" .= out2, "url" .= url])
                _ ->
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "REVERT_SYNC_FAILED_FINAL"
                        (object ["url" .= url, "message" .= ("Both attempts failed" :: Text)])

-- | Trigger immediate revert sync directly from the revert endpoint.
triggerImmediateRevertSync :: Config -> DBEnv -> ReleaseTracker -> Maybe TargetState -> IO ()
triggerImmediateRevertSync cfg db tracker mts = do
    let syncUrl = syncClusterUrl cfg
        mGlobalId = globalId tracker
        hasGlobalId = maybe False (not . T.null) mGlobalId
    if null syncUrl || not hasGlobalId
        then pure ()
        else do
            syncEnabled <- isSyncClusterEnabled db
            mProduct <- findProductByName db (product tracker)
            let mSyncCluster = mProduct >>= getProductSyncCluster
                hasSyncCluster = maybe False (not . T.null) mSyncCluster
                gid = maybe "" id mGlobalId
            if syncEnabled && hasSyncCluster
                then do
                    let rawUrl = syncUrl
                        normalised =
                            let u = if "http" `T.isPrefixOf` T.pack rawUrl then rawUrl else "http://" <> rawUrl
                             in if last u == '/' then u else u <> "/"
                        url = normalised <> "release/revert/immediate/global/" <> T.unpack gid
                        mCtx = getK8sContext mts
                        (authArgs, authMode) = buildSyncAuthArgs cfg mCtx
                        curlArgs =
                            [ "-s"
                            , "-X"
                            , "PUT"
                            , url
                            , "-H"
                            , "Content-Type: application/json"
                            , "-H"
                            , "Connection: close"
                            , "--max-time"
                            , "30"
                            ]
                                <> authArgs
                    insertReleaseEvent
                        db
                        (releaseId tracker)
                        "BUSINESS"
                        "IMMEDIATE_REVERT_SYNC_REQUEST"
                        (object ["url" .= url, "global_id" .= gid, "auth_mode" .= authMode])
                    _ <- forkIO $ do
                        result <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
                        case result of
                            Right (ExitSuccess, out, _) ->
                                insertReleaseEvent
                                    db
                                    (releaseId tracker)
                                    "BUSINESS"
                                    "IMMEDIATE_REVERT_SYNC_RESPONSE"
                                    (object ["status" .= ("SUCCESS" :: Text), "body" .= out, "url" .= url])
                            Right (ExitFailure code, _, err) -> do
                                insertReleaseEvent
                                    db
                                    (releaseId tracker)
                                    "BUSINESS"
                                    "IMMEDIATE_REVERT_SYNC_FAILED"
                                    (object ["exitCode" .= code, "error" .= err, "url" .= url])
                                -- Retry once
                                retryResult <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
                                case retryResult of
                                    Right (ExitSuccess, out2, _) ->
                                        insertReleaseEvent
                                            db
                                            (releaseId tracker)
                                            "BUSINESS"
                                            "IMMEDIATE_REVERT_SYNC_RESPONSE"
                                            (object ["status" .= ("SUCCESS_ON_RETRY" :: Text), "body" .= out2, "url" .= url])
                                    _ ->
                                        insertReleaseEvent
                                            db
                                            (releaseId tracker)
                                            "BUSINESS"
                                            "IMMEDIATE_REVERT_SYNC_FAILED_FINAL"
                                            (object ["url" .= url, "message" .= ("Both attempts failed" :: Text)])
                            Left e -> do
                                insertReleaseEvent
                                    db
                                    (releaseId tracker)
                                    "BUSINESS"
                                    "IMMEDIATE_REVERT_SYNC_FAILED"
                                    (object ["error" .= show e, "url" .= url])
                                retryResult <- try (readProcessWithExitCode "curl" curlArgs "") :: IO (Either SomeException (ExitCode, String, String))
                                case retryResult of
                                    Right (ExitSuccess, out2, _) ->
                                        insertReleaseEvent
                                            db
                                            (releaseId tracker)
                                            "BUSINESS"
                                            "IMMEDIATE_REVERT_SYNC_RESPONSE"
                                            (object ["status" .= ("SUCCESS_ON_RETRY" :: Text), "body" .= out2, "url" .= url])
                                    _ ->
                                        insertReleaseEvent
                                            db
                                            (releaseId tracker)
                                            "BUSINESS"
                                            "IMMEDIATE_REVERT_SYNC_FAILED_FINAL"
                                            (object ["url" .= url, "message" .= ("Both attempts failed" :: Text)])
                    pure ()
                else pure ()
