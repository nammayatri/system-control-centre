{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Background watcher that polls secondary cluster status for all active
sync-enabled releases and logs status updates back to the primary.

Julia parity: globalWatcher.jl — polls secondary trackers via HTTP,
updates primary's event log with secondary status, detects
COMPLETED/ABORTED/FAILED states on the secondary.
-}
module Products.Autopilot.SyncWatcher (
    syncWatcherLoop,
    syncWatcherPollLoop,
) where

import qualified Control.Exception as E
import Control.Monad (forM_, forever, when)
import qualified Control.Monad.Catch as MC
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (AppState, Flow, forkFlow, getConfig, logError, logInfo, logWarning, runFlow)
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Types.Time (Seconds (..), threadDelaySec)
import Data.Aeson (Value (..), decode, object, (.=))
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Products.Autopilot.Queries.ReleaseTracker (findActiveSyncTrackers, findEventByLabel, insertReleaseEvent)
import Products.Autopilot.RuntimeConfig (getReleaseWatchDelay, isSyncClusterEnabled)
import Products.Autopilot.Sync (buildAuthHeaders, normaliseBase)
import Products.Autopilot.Types
import Products.Autopilot.Types.Storage.Schema (rePayload)

-- ──────────────────────────────────────────────────────────────────
-- Entry points
-- ──────────────────────────────────────────────────────────────────

-- | Entry point for running the sync watcher from IO (e.g. from Main.hs).
syncWatcherLoop :: AppState -> IO ()
syncWatcherLoop st = runFlow st syncWatcherPollLoop

{- | Forever poll loop. Errors in each iteration are caught and logged
so a transient failure doesn't kill the watcher thread.
-}
syncWatcherPollLoop :: Flow ()
syncWatcherPollLoop = forever $ do
    result <- MC.try @_ @E.SomeException syncWatcherIteration
    case result of
        Left e ->
            logError $
                "[SYNC_WATCHER] Poll iteration failed (continuing): " <> T.pack (show e)
        Right () -> pure ()
    pollDelay <- getReleaseWatchDelay
    threadDelaySec pollDelay

-- ──────────────────────────────────────────────────────────────────
-- Iteration
-- ──────────────────────────────────────────────────────────────────

-- | Single poll iteration: check gate, find trackers, fork one poller per tracker.
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

-- ──────────────────────────────────────────────────────────────────
-- Per-tracker poller
-- ──────────────────────────────────────────────────────────────────

-- | Terminal statuses — if the secondary reaches one of these, the sync is done.
terminalStatuses :: [Text]
terminalStatuses =
    ["COMPLETED", "ABORTED", "USER_ABORTED", "GCLT_ABORTED", "DISCARDED", "REVERTED"]

-- | Poll secondary cluster for the status of a single tracker's secondary release.
pollSecondarySyncStatus :: Config -> ReleaseTracker -> Flow ()
pollSecondarySyncStatus cfg tracker = do
    -- Look up the secondary tracker ID stored when the sync was triggered.
    mEvent <- findEventByLabel (releaseId tracker) "SYNC_SECONDARY_TRACKER_ID"
    case mEvent of
        Nothing -> do
            -- Sync hasn't fired yet or hasn't stored the secondary ID — skip silently.
            logInfo $
                "[SYNC_WATCHER] No SYNC_SECONDARY_TRACKER_ID event yet for release "
                    <> releaseId tracker
                    <> ", skipping"
        Just ev -> do
            -- Extract "secondaryId" from the event payload.
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

-- ──────────────────────────────────────────────────────────────────
-- Helpers
-- ──────────────────────────────────────────────────────────────────

-- | Extract a Text field from a JSON Object by key.
extractText :: Text -> Value -> Maybe Text
extractText key (Object obj) =
    case KM.lookup (AK.fromText key) obj of
        Just (String t) -> Just t
        _ -> Nothing
extractText _ _ = Nothing
