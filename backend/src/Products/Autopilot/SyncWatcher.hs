{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Background watcher that polls the secondary cluster for all active
sync-enabled releases and writes status updates back to the primary's
event log, flagging terminal secondary states as COMPLETED/FAILED.
-}
module Products.Autopilot.SyncWatcher (
    syncWatcherLoop,
    syncWatcherPollLoop,
)
where

import Control.Exception qualified as E
import Control.Monad (forM_, forever, when)
import Control.Monad.Catch qualified as MC
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (AppState, Flow, forkFlow, getConfig, logError, logInfo, logWarning, runFlow)
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Types.Time (Seconds (..), threadDelaySec)
import Data.Aeson (Value (..), decode, object, (.=))
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Products.Autopilot.Queries.ReleaseTracker (findActiveSyncTrackers, findEventByLabel, insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (getReleaseWatchDelay, isSyncClusterEnabled)
import Products.Autopilot.Sync (buildAuthHeaders, normaliseBase)
import Products.Autopilot.Types
import Products.Autopilot.Types.Storage.Schema (rePayload)

-- | IO entry point (e.g. from Main).
syncWatcherLoop :: AppState -> IO ()
syncWatcherLoop st = runFlow st syncWatcherPollLoop

-- | Forever loop; per-iteration errors are caught + logged.
syncWatcherPollLoop :: Flow ()
syncWatcherPollLoop = forever $ do
    result <- MC.try @_ @E.SomeException $ do
        syncWatcherIteration
        pollDelay <- getReleaseWatchDelay
        threadDelaySec pollDelay
    case result of
        Left e ->
            logError $
                "[SYNC_WATCHER] Poll iteration failed (continuing): " <> T.pack (show e)
        Right () -> pure ()

syncWatcherIteration :: Flow ()
syncWatcherIteration = do
    syncOn <- isSyncClusterEnabled
    when syncOn $ do
        trackers <- findActiveSyncTrackers
        cfg <- getConfig
        logInfo $
            "[SYNC_WATCHER] Polling " <> T.pack (show (length trackers)) <> " active sync tracker(s)"
        forM_ trackers $ \tracker -> do
            _ <- forkFlow (pollSecondarySyncStatus cfg tracker)
            pure ()

-- | Terminal secondary statuses — once hit, sync is done.
terminalStatuses :: [Text]
terminalStatuses =
    ["COMPLETED", "ABORTED", "USER_ABORTED", "GCLT_ABORTED", "DISCARDED", "REVERTED"]

pollSecondarySyncStatus :: Config -> ReleaseTracker -> Flow ()
pollSecondarySyncStatus cfg tracker = do
    alreadyDone <- isJust <$> findEventByLabel (releaseId tracker) "SYNC_COMPLETED"
    alreadyFailed <- isJust <$> findEventByLabel (releaseId tracker) "SYNC_FAILED"
    if alreadyDone || alreadyFailed
        then pure ()
        else pollSecondarySyncStatus' cfg tracker

pollSecondarySyncStatus' :: Config -> ReleaseTracker -> Flow ()
pollSecondarySyncStatus' cfg tracker = do
    mEvent <- findEventByLabel (releaseId tracker) "SYNC_SECONDARY_TRACKER_ID"
    case mEvent of
        Nothing -> do
            logInfo $
                "[SYNC_WATCHER] No SYNC_SECONDARY_TRACKER_ID event yet for release "
                    <> releaseId tracker
                    <> ", skipping"
        Just ev -> do
            let payload = rePayload ev
            case extractText "secondaryId" payload of
                Nothing ->
                    logWarning $
                        "[SYNC_WATCHER] SYNC_SECONDARY_TRACKER_ID payload missing 'secondaryId' for release "
                            <> releaseId tracker
                Just secondaryId -> do
                    let base = normaliseBase (syncClusterUrl cfg)
                        url = base <> "releases/" <> secondaryId
                        (auth, _authMode) = buildAuthHeaders cfg Nothing
                        req =
                            (defaultReq url)
                                { reqMethod = GET
                                , reqHeaders = ("Content-Type", "application/json") : auth
                                , reqTimeout = Seconds 10
                                , reqLogTag = "sync-watcher"
                                }
                    result <- liftIO $ httpRaw req
                    case result of
                        Right HttpResponse{respStatus = s, respBody = b}
                            | s < 400 -> do
                                let mStatus = decode b >>= extractText "status"
                                    statusText = maybe "UNKNOWN" id mStatus
                                insertReleaseEvent
                                    (releaseId tracker)
                                    "BUSINESS"
                                    "SYNC_STATUS_UPDATE"
                                    ( object
                                        [ "secondaryId" .= secondaryId
                                        , "secondaryStatus" .= statusText
                                        , "url" .= url
                                        ]
                                    )
                                when (statusText `elem` terminalStatuses) $ do
                                    let evLabel =
                                            if statusText == "COMPLETED"
                                                then "SYNC_COMPLETED"
                                                else "SYNC_FAILED"
                                    insertReleaseEvent
                                        (releaseId tracker)
                                        "BUSINESS"
                                        evLabel
                                        ( object
                                            [ "secondaryId" .= secondaryId
                                            , "secondaryStatus" .= statusText
                                            ]
                                        )
                                    logInfo $
                                        "[SYNC_WATCHER] "
                                            <> evLabel
                                            <> " for release "
                                            <> releaseId tracker
                                            <> " (secondary="
                                            <> secondaryId
                                            <> ", status="
                                            <> statusText
                                            <> ")"
                        Right HttpResponse{respStatus = s, respBody = b} -> do
                            let bodyText = TE.decodeUtf8 (LBS.toStrict b)
                            insertReleaseEvent
                                (releaseId tracker)
                                "BUSINESS"
                                "SYNC_STATUS_POLL_ERROR"
                                ( object
                                    [ "secondaryId" .= secondaryId
                                    , "httpStatus" .= s
                                    , "body" .= bodyText
                                    , "url" .= url
                                    ]
                                )
                        Left e -> do
                            let errText = T.pack (show e)
                            insertReleaseEvent
                                (releaseId tracker)
                                "BUSINESS"
                                "SYNC_STATUS_POLL_ERROR"
                                ( object
                                    [ "secondaryId" .= secondaryId
                                    , "error" .= errText
                                    , "url" .= url
                                    ]
                                )

extractText :: Text -> Value -> Maybe Text
extractText key (Object obj) =
    case KM.lookup (AK.fromText key) obj of
        Just (String t) -> Just t
        _ -> Nothing
extractText _ _ = Nothing
