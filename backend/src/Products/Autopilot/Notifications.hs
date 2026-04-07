{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Slack notification helpers for autopilot release lifecycle.

Thread-aware: the first message (CREATED) starts a thread,
all subsequent messages (Approved, Progress, COMPLETED, etc.)
reply in that thread using the thread_ts stored in release_tracker.slack_thread_ts.

Uses Slack Block Kit with colored attachments for rich formatting.

== Monad

Every public notification function lives in 'Flow' (the canonical
service monad), so callers don't pass 'DBEnv' or wrap with 'liftIO'.
The actual Slack HTTP call ('sendSlackRich') stays in 'IO' because it
has no DB / config dependencies.
-}
module Products.Autopilot.Notifications (
    notifyReleaseCreated,
    notifyReleaseApproved,
    notifyReleaseProgress,
    notifyReleaseCompleted,
    notifyReleaseAborted,
    notifyReleasePaused,
    notifyReleaseResumed,
    notifyReleaseReverted,
    notifyReleaseDiscarded,
    notifyReleaseDeleted,
    notifyReleaseUpdated,
    notifyReleaseRestarted,
    notifyReleaseFastForwarded,
    notifyImmediateReverted,
    notifyPodsScaledDown,
    notifyVsEditCreated,
    notifyVsEditLocked,
    notifyVsEditApplied,
    notifyVsEditApproved,
    notifyVsEditDiscarded,
    notifyVsEditReverted,
    notifyVsEditUnlocked,
    notifyConfigMapCreated,
    notifyConfigMapUpdated,
    notifyConfigMapApproved,
    notifyConfigMapInProgress,
    notifyConfigMapCompleted,
    notifyConfigMapAborted,
    notifyConfigMapPaused,
    notifyConfigMapResumed,
    notifyConfigMapReverted,
    notifyConfigMapDiscarded,
    notifyConfigMapFastForwarded,
    notifyGenericThreadMessage,
)
where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (MonadFlow)
import Core.Logging (logErrorG, logInfoG, logWarningG)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client (RequestBody (..), httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseTimeout, responseTimeoutMicro)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Products.Autopilot.Queries.ProductService (findProductByName, getSlackChannelDirect)
import qualified Products.Autopilot.Queries.ReleaseTracker as RTQ
import Products.Autopilot.RuntimeConfig (isSlackEnabled)
import Products.Autopilot.Sync (triggerSyncIfEnabled)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import System.Environment (lookupEnv)
import Prelude

-- ── Colors ───────────────────────────────────────────────────────

colorCreated, colorApproved, colorInProgress, colorCompleted :: Text
colorAborted, colorPaused, colorReverted, colorDefault :: Text
colorCreated = "#2563eb" -- blue
colorApproved = "#0891b2" -- cyan
colorInProgress = "#d97706" -- amber
colorCompleted = "#16a34a" -- green
colorAborted = "#dc2626" -- red
colorPaused = "#6366f1" -- indigo
colorReverted = "#7c3aed" -- violet
colorDefault = "#71717a" -- zinc

-- ── Internal helpers ──────────────────────────────────────────────

getSlackToken :: IO (Maybe String)
getSlackToken = lookupEnv "SLACK_BOT_TOKEN"

getDashboardUrl :: IO Text
getDashboardUrl = do
    mUrl <- lookupEnv "DASHBOARD_URL"
    pure $ T.pack $ maybe "http://localhost:5173" id mUrl

{- | Slack channel is owned by the app group. One channel per app group
covers all releases, configmaps, and VS edits.
-}
getSlackChannel :: (MonadFlow m) => Text -> Text -> m (Maybe Text)
getSlackChannel prod _svc = do
    mProd <- findProductByName prod
    pure (mProd >>= getSlackChannelDirect)

{- | Post a rich message to Slack using Block Kit attachments.
Returns the message ts (thread ID) if successful.
-}
sendSlackRich :: Text -> Text -> Text -> [Value] -> Maybe Text -> IO (Maybe Text)
sendSlackRich channel fallbackText color blocks mThreadTs = do
    mToken <- getSlackToken
    case mToken of
        Nothing -> do
            logWarningG "[SLACK] No SLACK_BOT_TOKEN env var set, skipping"
            pure Nothing
        Just token -> do
            result <- try $ do
                manager <- newManager tlsManagerSettings
                initReq <- parseRequest "https://slack.com/api/chat.postMessage"
                let attachment = object ["color" .= color, "blocks" .= blocks]
                    baseBody =
                        [ "channel" .= channel
                        , "text" .= fallbackText
                        , "attachments" .= [attachment]
                        ]
                    bodyObj = object $ case mThreadTs of
                        Nothing -> baseBody
                        Just threadTs -> ("thread_ts" .= threadTs) : baseBody
                    req =
                        initReq
                            { method = "POST"
                            , requestHeaders =
                                [ ("Authorization", "Bearer " <> TE.encodeUtf8 (T.pack token))
                                , ("Content-Type", "application/json; charset=utf-8")
                                ]
                            , requestBody = RequestBodyLBS (encode bodyObj)
                            , responseTimeout = responseTimeoutMicro 10000000 -- 10 second timeout
                            }
                resp <- httpLbs req manager
                let mTs = do
                        val <- decode (responseBody resp) :: Maybe Value
                        case val of
                            Object obj -> case KM.lookup (K.fromText "ts") obj of
                                Just (String ts) -> Just ts
                                _ -> Nothing
                            _ -> Nothing
                logInfoG $ "[SLACK] Sent to #" <> channel <> maybe "" (\ts -> " (ts=" <> ts <> ")") mTs
                pure mTs
            case result of
                Left (err :: SomeException) -> do
                    logErrorG $ "[SLACK] Error: " <> T.pack (show err)
                    pure Nothing
                Right mTs -> pure mTs

-- | Build a section block with markdown text
sectionBlock :: Text -> Value
sectionBlock txt =
    object
        [ "type" .= ("section" :: Text)
        , "text" .= object ["type" .= ("mrkdwn" :: Text), "text" .= txt]
        ]

-- | Build a context block (small grey text)
contextBlock :: [Text] -> Value
contextBlock items =
    object
        [ "type" .= ("context" :: Text)
        , "elements" .= map (\t -> object ["type" .= ("mrkdwn" :: Text), "text" .= t]) items
        ]

whenSlackEnabled :: (MonadFlow m) => m () -> m ()
whenSlackEnabled action = do
    enabled <- isSlackEnabled
    if enabled
        then action
        else liftIO $ logInfoG "[SLACK] Disabled, skipping"

withChannel :: (MonadFlow m) => Text -> Text -> (Text -> m ()) -> m ()
withChannel prod svc f = do
    mCh <- getSlackChannel prod svc
    case mCh of
        Nothing -> liftIO $ logWarningG $ "[SLACK] No channel for " <> prod <> "/" <> svc
        Just ch -> f ch

-- | Read thread_ts fresh from DB every time (avoids stale in-memory tracker).
getThreadTs :: (MonadFlow m) => Text -> m (Maybe Text)
getThreadTs rid = do
    m <- RTQ.findReleaseTracker rid
    case m of
        Just (tracker, _) -> pure (slackThreadTs tracker)
        Nothing -> pure Nothing

saveThreadTs :: (MonadFlow m) => Text -> Text -> m ()
saveThreadTs = RTQ.updateReleaseTrackerSlackThreadTs

-- | Clickable header link only (no redundant product/service text)
releaseLink :: ReleaseTracker -> IO Text
releaseLink t = do
    base <- getDashboardUrl
    let url = base <> "/releases/" <> releaseId t
    pure $ "<" <> url <> "|" <> appGroup t <> " | " <> service t <> " | " <> env t <> " Release>"

-- | Version line with arrow
versionLine :: ReleaseTracker -> Text
versionLine t = oldVersion t <> " → " <> newVersion t <> " | " <> createdBy t

-- ── Public notification functions ─────────────────────────────────

notifyReleaseCreated :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseCreated tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        link <- liftIO $ releaseLink tracker
        let blocks = [sectionBlock link, sectionBlock (versionLine tracker)]
        mTs <- liftIO $ sendSlackRich channel (appGroup tracker <> " | " <> service tracker) colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs (releaseId tracker) ts
            Nothing -> pure ()

notifyReleaseApproved :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseApproved tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock ("Approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")]
        _ <- liftIO $ sendSlackRich channel "Approved" colorApproved blocks threadTs
        pure ()

notifyReleaseProgress :: (MonadFlow m) => ReleaseTracker -> Int -> m ()
notifyReleaseProgress tracker percentage = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let pct = T.pack (show percentage)
            blocks =
                [ sectionBlock ("*INPROGRESS*  " <> pct <> "%")
                , contextBlock ["Routing " <> pct <> "% traffic to `" <> newVersion tracker <> "` | " <> T.pack (show (100 - percentage)) <> "% on `" <> oldVersion tracker <> "`"]
                ]
        _ <- liftIO $ sendSlackRich channel ("INPROGRESS " <> pct <> "%") colorInProgress blocks threadTs
        pure ()

notifyReleaseCompleted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseCompleted tracker = do
    whenSlackEnabled $
        withChannel (appGroup tracker) (service tracker) $ \channel -> do
            threadTs <- getThreadTs (releaseId tracker)
            let blocks =
                    [ sectionBlock "*COMPLETED*  100%"
                    , contextBlock ["All traffic on `" <> newVersion tracker <> "`"]
                    ]
            _ <- liftIO $ sendSlackRich channel "COMPLETED" colorCompleted blocks threadTs
            pure ()
    triggerSyncIfEnabled tracker Nothing

notifyReleaseAborted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseAborted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks =
                [ sectionBlock "*ABORTED*"
                , contextBlock ["Traffic restored to `" <> oldVersion tracker <> "`"]
                ]
        _ <- liftIO $ sendSlackRich channel "ABORTED" colorAborted blocks threadTs
        pure ()

notifyReleasePaused :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleasePaused tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- liftIO $ sendSlackRich channel "PAUSED" colorPaused blocks threadTs
        pure ()

notifyReleaseResumed :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseResumed tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*RESUMED*"]
        _ <- liftIO $ sendSlackRich channel "Resumed" colorInProgress blocks threadTs
        pure ()

notifyReleaseReverted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["Rolled back to `" <> oldVersion tracker <> "`"]
                ]
        _ <- liftIO $ sendSlackRich channel "REVERTED" colorReverted blocks threadTs
        pure ()

notifyReleaseDiscarded :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseDiscarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*DISCARDED*"]
        _ <- liftIO $ sendSlackRich channel "DISCARDED" colorDefault blocks threadTs
        pure ()

notifyReleaseDeleted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseDeleted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*DELETED*"]
        _ <- liftIO $ sendSlackRich channel "Deleted" colorAborted blocks threadTs
        pure ()

notifyReleaseUpdated :: (MonadFlow m) => ReleaseTracker -> Text -> m ()
notifyReleaseUpdated tracker detail = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock ("*UPDATED*  " <> detail)]
        _ <- liftIO $ sendSlackRich channel ("Updated: " <> detail) colorDefault blocks threadTs
        pure ()

notifyReleaseRestarted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseRestarted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*RESTARTED*  — reset to CREATED"]
        _ <- liftIO $ sendSlackRich channel "Restarted" colorCreated blocks threadTs
        pure ()

notifyReleaseFastForwarded :: (MonadFlow m) => ReleaseTracker -> m ()
notifyReleaseFastForwarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- liftIO $ sendSlackRich channel "Fast Forwarded" colorInProgress blocks threadTs
        pure ()

notifyImmediateReverted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyImmediateReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks =
                [ sectionBlock "*IMMEDIATE REVERT*"
                , contextBlock ["Image swapped back to `" <> oldVersion tracker <> "` | rollout bypassed"]
                ]
        _ <- liftIO $ sendSlackRich channel "Immediate Revert" colorAborted blocks threadTs
        pure ()

notifyPodsScaledDown :: (MonadFlow m) => ReleaseTracker -> Text -> m ()
notifyPodsScaledDown tracker oldVer = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock ("Pods scaled down for `" <> oldVer <> "`")]
        _ <- liftIO $ sendSlackRich channel ("Pods scaled down: " <> oldVer) colorDefault blocks threadTs
        pure ()

-- ── VS Edit Notifications ────────────────────────────────────────

notifyVsEditCreated :: (MonadFlow m) => Text -> Text -> Text -> Maybe Text -> m ()
notifyVsEditCreated trackerId prod svc mCreatedByUser = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        link <- liftIO getDashboardUrl
        let vsLink = "<" <> link <> "/vs-editor/" <> trackerId <> "|" <> prod <> " | " <> svc <> " | VS Edit>"
            createdByUser = maybe "admin" id mCreatedByUser
            blocks =
                [ sectionBlock vsLink
                , contextBlock ["CREATED by *" <> createdByUser <> "*"]
                ]
        mTs <- liftIO $ sendSlackRich channel "VS CREATED" colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs trackerId ts
            Nothing -> pure ()

notifyVsEditLocked :: (MonadFlow m) => Text -> Text -> Text -> Text -> m ()
notifyVsEditLocked trackerId prod svc lockedByUser = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        link <- liftIO getDashboardUrl
        let vsLink = "<" <> link <> "/vs-editor/" <> trackerId <> "|" <> prod <> " | " <> svc <> " | VS Edit>"
            blocks =
                [ sectionBlock vsLink
                , contextBlock ["LOCKED by *" <> lockedByUser <> "*"]
                ]
        mTs <- liftIO $ sendSlackRich channel "VS LOCKED" colorPaused blocks Nothing
        case mTs of
            Just ts -> saveThreadTs trackerId ts
            Nothing -> pure ()

notifyVsEditApplied :: (MonadFlow m) => Text -> Text -> Text -> Text -> m ()
notifyVsEditApplied trackerId prod svc appliedBy = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *APPLIED*")
                , contextBlock ["APPLIED by " <> appliedBy]
                ]
        _ <- liftIO $ sendSlackRich channel "VS APPLIED" colorCompleted blocks threadTs
        pure ()

notifyVsEditApproved :: (MonadFlow m) => Text -> Text -> Text -> Text -> m ()
notifyVsEditApproved trackerId prod svc approvedByUser = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("Approved by *" <> approvedByUser <> "*")]
        _ <- liftIO $ sendSlackRich channel "VS Approved" colorApproved blocks threadTs
        pure ()

notifyVsEditDiscarded :: (MonadFlow m) => Text -> Text -> Text -> m ()
notifyVsEditDiscarded trackerId prod svc = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *DISCARDED*")]
        _ <- liftIO $ sendSlackRich channel "VS DISCARDED" colorDefault blocks threadTs
        pure ()

notifyVsEditReverted :: (MonadFlow m) => Text -> Text -> Text -> m ()
notifyVsEditReverted trackerId prod svc = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *REVERTED*")]
        _ <- liftIO $ sendSlackRich channel "VS REVERTED" colorReverted blocks threadTs
        pure ()

notifyVsEditUnlocked :: (MonadFlow m) => Text -> Text -> Text -> m ()
notifyVsEditUnlocked trackerId prod svc = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *UNLOCKED*")]
        _ <- liftIO $ sendSlackRich channel "VS UNLOCKED" colorDefault blocks threadTs
        pure ()

-- ── ConfigMap Notifications ──────────────────────────────────────

notifyConfigMapCreated :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapCreated tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> appGroup tracker <> "* | *" <> service tracker <> "* | ConfigMap Release")
                , sectionBlock (appGroup tracker <> " | " <> createdBy tracker)
                ]
        mTs <- liftIO $ sendSlackRich channel "ConfigMap CREATED" colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs (releaseId tracker) ts
            Nothing -> pure ()

notifyConfigMapUpdated :: (MonadFlow m) => ReleaseTracker -> Text -> m ()
notifyConfigMapUpdated tracker detail = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock ("*" <> appGroup tracker <> "* | ConfigMap " <> detail)]
        _ <- liftIO $ sendSlackRich channel ("ConfigMap " <> detail) colorInProgress blocks threadTs
        pure ()

notifyConfigMapApproved :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapApproved tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock ("Approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")]
        _ <- liftIO $ sendSlackRich channel "ConfigMap Approved" colorApproved blocks threadTs
        pure ()

notifyConfigMapInProgress :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapInProgress tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*INPROGRESS*  — Applying ConfigMap"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap INPROGRESS" colorInProgress blocks threadTs
        pure ()

notifyConfigMapCompleted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapCompleted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*COMPLETED*"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap COMPLETED" colorCompleted blocks threadTs
        pure ()

notifyConfigMapAborted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapAborted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*ABORTED*"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap ABORTED" colorAborted blocks threadTs
        pure ()

notifyConfigMapPaused :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapPaused tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap PAUSED" colorPaused blocks threadTs
        pure ()

notifyConfigMapResumed :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapResumed tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*RESUMED*"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap Resumed" colorInProgress blocks threadTs
        pure ()

notifyConfigMapReverted :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["ConfigMap rolled back"]
                ]
        _ <- liftIO $ sendSlackRich channel "ConfigMap REVERTED" colorReverted blocks threadTs
        pure ()

notifyConfigMapDiscarded :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapDiscarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*DISCARDED*"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap DISCARDED" colorDefault blocks threadTs
        pure ()

notifyConfigMapFastForwarded :: (MonadFlow m) => ReleaseTracker -> m ()
notifyConfigMapFastForwarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- liftIO $ sendSlackRich channel "ConfigMap Fast Forwarded" colorInProgress blocks threadTs
        pure ()

notifyGenericThreadMessage :: (MonadFlow m) => ReleaseTracker -> Text -> m ()
notifyGenericThreadMessage tracker msg = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs (releaseId tracker)
        let blocks = [sectionBlock msg]
        _ <- liftIO $ sendSlackRich channel msg colorDefault blocks threadTs
        pure ()
