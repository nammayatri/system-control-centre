{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Slack notification helpers for autopilot release lifecycle.

Thread-aware: the first message (CREATED) starts a thread,
all subsequent messages (Approved, Progress, COMPLETED, etc.)
reply in that thread using the thread_ts stored in release_tracker.slack_thread_ts.

Uses Slack Block Kit with colored attachments for rich formatting.

== Monad / perf

Notifications run in 'Flow'. The actual Slack HTTP call goes through
'Core.Http.Client.httpRaw' which uses the process-wide pooled TLS
manager (no per-call 'newManager'). Notifications are dispatched
asynchronously via 'forkFlow' so HTTP handlers do not block on Slack.
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

import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, forkFlow)
import Core.Types.Time (Seconds (..))
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Logging (logErrorG, logInfoG, logWarningG)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Products.Autopilot.Queries.ProductService (findProductByName, getSlackChannelDirect)
import qualified Products.Autopilot.Queries.ReleaseTracker as RTQ
import Products.Autopilot.RuntimeConfig (isSlackEnabled)
import Products.Autopilot.Sync (triggerSyncIfEnabled)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Products.Autopilot.Types.Target (TargetState)
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
getSlackChannel :: Text -> Flow (Maybe Text)
getSlackChannel prod = do
    mProd <- findProductByName prod
    pure (mProd >>= getSlackChannelDirect)

-- | Truncate to N chars, appending an ellipsis marker if cut.
truncateT :: Int -> Text -> Text
truncateT n t
    | T.length t <= n = t
    | otherwise = T.take n t <> "..."

{- | Post a rich message to Slack using Block Kit attachments.
Returns the message ts (thread ID) if successful. Uses the pooled
HTTP manager from 'Core.Http.Client'. Logs HTTP/exception failures
inline (channel name + truncated error).
-}
sendSlackRich :: Text -> Text -> Text -> [Value] -> Maybe Text -> Flow (Maybe Text)
sendSlackRich channel fallbackText color blocks mThreadTs = do
    mToken <- liftIO getSlackToken
    case mToken of
        Nothing -> do
            logWarningG "[SLACK] No SLACK_BOT_TOKEN env var set, skipping"
            pure Nothing
        Just token -> do
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
                    (defaultReq "https://slack.com/api/chat.postMessage")
                        { reqMethod = POST
                        , reqHeaders =
                            [ ("Authorization", "Bearer " <> T.pack token)
                            , ("Content-Type", "application/json; charset=utf-8")
                            ]
                        , reqBody = Just (encode bodyObj)
                        , reqLogTag = "slack"
                        , -- Bug fix (round 7 / E10): cap Slack POST at 5s so the
                          -- synchronous notifyReleaseCreated/notifyConfigMapCreated
                          -- /notifyVsEditLocked paths can never wedge an HTTP
                          -- handler waiting for Slack. On timeout, we return
                          -- Nothing — the caller logs and proceeds.
                          reqTimeout = Seconds 5
                        }
            result <- liftIO (httpRaw req)
            case result of
                Left err -> do
                    liftIO $
                        logErrorG $
                            "[SLACK] HTTP failure for #"
                                <> channel
                                <> ": "
                                <> truncateT 200 (T.pack (show err))
                    pure Nothing
                Right HttpResponse{respStatus = s, respBody = b}
                    | s >= 400 -> do
                        liftIO $
                            logErrorG $
                                "[SLACK] HTTP "
                                    <> T.pack (show s)
                                    <> " for #"
                                    <> channel
                                    <> ": "
                                    <> truncateT 200 (TL.toStrict (TLE.decodeUtf8 b))
                        pure Nothing
                    | otherwise -> do
                        let mTs = do
                                val <- decode b :: Maybe Value
                                case val of
                                    Object obj -> case KM.lookup (K.fromText "ts") obj of
                                        Just (String ts) -> Just ts
                                        _ -> Nothing
                                    _ -> Nothing
                        logInfoG $ "[SLACK] Sent to #" <> channel <> maybe "" (\ts -> " (ts=" <> ts <> ")") mTs
                        pure mTs

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

{- | Run the notification body asynchronously iff Slack is enabled.
The DB hit for 'isSlackEnabled' happens on the caller thread (cheap)
so we can short-circuit before forking, but the actual Slack HTTP
work runs on a background thread and never blocks the HTTP handler.
-}
whenSlackEnabled :: Flow () -> Flow ()
whenSlackEnabled action = do
    enabled <- isSlackEnabled
    if enabled
        then void (forkFlow action)
        else logInfoG "[SLACK] Disabled, skipping"

withChannel :: Text -> Text -> (Text -> Flow ()) -> Flow ()
withChannel prod svc f = do
    mCh <- getSlackChannel prod
    case mCh of
        Nothing -> logWarningG $ "[SLACK] No channel for " <> prod <> "/" <> svc
        Just ch -> f ch

{- | Read thread_ts fresh from DB. Use this only when the caller does
not already have a 'ReleaseTracker' in hand (e.g. VS-edit paths that
only carry a trackerId).
-}
getThreadTs :: Text -> Flow (Maybe Text)
getThreadTs rid = do
    m <- RTQ.findReleaseTracker rid
    case m of
        Just (tracker, _) -> pure (slackThreadTs tracker)
        Nothing -> pure Nothing

-- | Cheap accessor when the caller already has the tracker — no DB hit.
getThreadTsFromTracker :: ReleaseTracker -> Maybe Text
getThreadTsFromTracker = slackThreadTs

{- | Resolve the slack thread_ts for a tracker, with single DB fallback.

Race we are guarding against: createReleaseH inserts the tracker with
slack_thread_ts=NULL and forks the create-Slack POST asynchronously. A user
who clicks Approve immediately may hit approveReleaseH before the POST
completes and saves the thread_ts. The in-memory tracker is stale (Nothing)
so the approve notification would post a NEW top-level Slack message
instead of replying in-thread.

Strategy: if in-memory is Just, use it (zero cost). Otherwise hit the DB
once. No retry loop — if the create POST hasn't landed yet, accept the
fallback to a top-level message rather than blocking the request.
-}
resolveThreadTs :: ReleaseTracker -> Flow (Maybe Text)
resolveThreadTs tracker = case slackThreadTs tracker of
    Just ts -> pure (Just ts)
    Nothing -> getThreadTs (releaseId tracker)

saveThreadTs :: Text -> Text -> Flow ()
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

{- | Send the "release created" Slack message SYNCHRONOUSLY (not via forkFlow).
This is critical: every subsequent notification (Approved, Progress, Completed,
etc.) needs to thread under the create message via thread_ts. If create is
fired-and-forgotten, an immediate Approve hits DB before the create POST has
saved thread_ts, so the Approved message lands as a new top-level message.
By blocking the create handler on this one Slack POST (~200-500ms), we
guarantee the DB has thread_ts before the user can possibly call approve.
All other notify* functions remain async via whenSlackEnabled.
-}
notifyReleaseCreated :: ReleaseTracker -> Flow ()
notifyReleaseCreated tracker = do
    enabled <- isSlackEnabled
    if not enabled
        then logInfoG "[SLACK] Disabled, skipping create"
        else withChannel (appGroup tracker) (service tracker) $ \channel -> do
            link <- liftIO $ releaseLink tracker
            let blocks = [sectionBlock link, sectionBlock (versionLine tracker)]
            mTs <- sendSlackRich channel (appGroup tracker <> " | " <> service tracker) colorCreated blocks Nothing
            case mTs of
                Just ts -> saveThreadTs (releaseId tracker) ts
                Nothing -> pure ()

notifyReleaseApproved :: ReleaseTracker -> Flow ()
notifyReleaseApproved tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock ("Approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")]
        _ <- sendSlackRich channel "Approved" colorApproved blocks threadTs
        pure ()

notifyReleaseProgress :: ReleaseTracker -> Int -> Flow ()
notifyReleaseProgress tracker percentage = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            pct = T.pack (show percentage)
            blocks =
                [ sectionBlock ("*INPROGRESS*  " <> pct <> "%")
                , contextBlock ["Routing " <> pct <> "% traffic to `" <> newVersion tracker <> "` | " <> T.pack (show (100 - percentage)) <> "% on `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel ("INPROGRESS " <> pct <> "%") colorInProgress blocks threadTs
        pure ()

notifyReleaseCompleted :: ReleaseTracker -> Maybe TargetState -> Flow ()
notifyReleaseCompleted tracker mts = do
    whenSlackEnabled $
        withChannel (appGroup tracker) (service tracker) $ \channel -> do
            let threadTs = getThreadTsFromTracker tracker
                blocks =
                    [ sectionBlock "*COMPLETED*  100%"
                    , contextBlock ["All traffic on `" <> newVersion tracker <> "`"]
                    ]
            _ <- sendSlackRich channel "COMPLETED" colorCompleted blocks threadTs
            pure ()
    triggerSyncIfEnabled tracker mts

notifyReleaseAborted :: ReleaseTracker -> Flow ()
notifyReleaseAborted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks =
                [ sectionBlock "*ABORTED*"
                , contextBlock ["Traffic restored to `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "ABORTED" colorAborted blocks threadTs
        pure ()

notifyReleasePaused :: ReleaseTracker -> Flow ()
notifyReleasePaused tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- sendSlackRich channel "PAUSED" colorPaused blocks threadTs
        pure ()

notifyReleaseResumed :: ReleaseTracker -> Flow ()
notifyReleaseResumed tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*RESUMED*"]
        _ <- sendSlackRich channel "Resumed" colorInProgress blocks threadTs
        pure ()

notifyReleaseReverted :: ReleaseTracker -> Flow ()
notifyReleaseReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["Rolled back to `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "REVERTED" colorReverted blocks threadTs
        pure ()

notifyReleaseDiscarded :: ReleaseTracker -> Flow ()
notifyReleaseDiscarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*DISCARDED*"]
        _ <- sendSlackRich channel "DISCARDED" colorDefault blocks threadTs
        pure ()

notifyReleaseDeleted :: ReleaseTracker -> Flow ()
notifyReleaseDeleted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*DELETED*"]
        _ <- sendSlackRich channel "Deleted" colorAborted blocks threadTs
        pure ()

notifyReleaseUpdated :: ReleaseTracker -> Text -> Flow ()
notifyReleaseUpdated tracker detail = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock ("*UPDATED*  " <> detail)]
        _ <- sendSlackRich channel ("Updated: " <> detail) colorDefault blocks threadTs
        pure ()

notifyReleaseRestarted :: ReleaseTracker -> Flow ()
notifyReleaseRestarted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*RESTARTED*  — reset to CREATED"]
        _ <- sendSlackRich channel "Restarted" colorCreated blocks threadTs
        pure ()

notifyReleaseFastForwarded :: ReleaseTracker -> Flow ()
notifyReleaseFastForwarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- sendSlackRich channel "Fast Forwarded" colorInProgress blocks threadTs
        pure ()

notifyImmediateReverted :: ReleaseTracker -> Flow ()
notifyImmediateReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks =
                [ sectionBlock "*IMMEDIATE REVERT*"
                , contextBlock ["Image swapped back to `" <> oldVersion tracker <> "` | rollout bypassed"]
                ]
        _ <- sendSlackRich channel "Immediate Revert" colorAborted blocks threadTs
        pure ()

notifyPodsScaledDown :: ReleaseTracker -> Text -> Flow ()
notifyPodsScaledDown tracker oldVer = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock ("Pods scaled down for `" <> oldVer <> "`")]
        _ <- sendSlackRich channel ("Pods scaled down: " <> oldVer) colorDefault blocks threadTs
        pure ()

-- ── VS Edit Notifications ────────────────────────────────────────

notifyVsEditCreated :: Text -> Text -> Text -> Maybe Text -> Flow ()
notifyVsEditCreated trackerId prod svc mCreatedByUser = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        link <- liftIO getDashboardUrl
        let vsLink = "<" <> link <> "/vs-editor/" <> trackerId <> "|" <> prod <> " | " <> svc <> " | VS Edit>"
            createdByUser = maybe "admin" id mCreatedByUser
            blocks =
                [ sectionBlock vsLink
                , contextBlock ["CREATED by *" <> createdByUser <> "*"]
                ]
        mTs <- sendSlackRich channel "VS CREATED" colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs trackerId ts
            Nothing -> pure ()

{- | SYNCHRONOUS (not forked). Same fix as notifyReleaseCreated: every
follow-up notification (Approved/Applied/Discarded/etc.) needs the
thread_ts saved to DB before it runs. Forking this would race the
immediately-following save/approve/apply that the user does.
-}
notifyVsEditLocked :: Text -> Text -> Text -> Text -> Flow ()
notifyVsEditLocked trackerId prod svc lockedByUser = do
    enabled <- isSlackEnabled
    if not enabled
        then logInfoG "[SLACK] Disabled, skipping vs-edit-lock"
        else withChannel prod svc $ \channel -> do
            link <- liftIO getDashboardUrl
            let vsLink = "<" <> link <> "/vs-editor/" <> trackerId <> "|" <> prod <> " | " <> svc <> " | VS Edit>"
                blocks =
                    [ sectionBlock vsLink
                    , contextBlock ["LOCKED by *" <> lockedByUser <> "*"]
                    ]
            mTs <- sendSlackRich channel "VS LOCKED" colorPaused blocks Nothing
            case mTs of
                Just ts -> saveThreadTs trackerId ts
                Nothing -> pure ()

notifyVsEditApplied :: Text -> Text -> Text -> Text -> Flow ()
notifyVsEditApplied trackerId prod svc appliedBy = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *APPLIED*")
                , contextBlock ["APPLIED by " <> appliedBy]
                ]
        _ <- sendSlackRich channel "VS APPLIED" colorCompleted blocks threadTs
        pure ()

notifyVsEditApproved :: Text -> Text -> Text -> Text -> Flow ()
notifyVsEditApproved trackerId prod svc approvedByUser = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("Approved by *" <> approvedByUser <> "*")]
        _ <- sendSlackRich channel "VS Approved" colorApproved blocks threadTs
        pure ()

notifyVsEditDiscarded :: Text -> Text -> Text -> Flow ()
notifyVsEditDiscarded trackerId prod svc = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *DISCARDED*")]
        _ <- sendSlackRich channel "VS DISCARDED" colorDefault blocks threadTs
        pure ()

notifyVsEditReverted :: Text -> Text -> Text -> Flow ()
notifyVsEditReverted trackerId prod svc = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *REVERTED*")]
        _ <- sendSlackRich channel "VS REVERTED" colorReverted blocks threadTs
        pure ()

notifyVsEditUnlocked :: Text -> Text -> Text -> Flow ()
notifyVsEditUnlocked trackerId prod svc = whenSlackEnabled $
    withChannel prod svc $ \channel -> do
        threadTs <- getThreadTs trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *UNLOCKED*")]
        _ <- sendSlackRich channel "VS UNLOCKED" colorDefault blocks threadTs
        pure ()

-- ── ConfigMap Notifications ──────────────────────────────────────

{- | SYNCHRONOUS (not forked) — same reason as notifyReleaseCreated.
Approve / discard / apply will fire immediately after create on the user's
next click; thread_ts must be in DB before they run.
-}
notifyConfigMapCreated :: ReleaseTracker -> Flow ()
notifyConfigMapCreated tracker = do
    enabled <- isSlackEnabled
    if not enabled
        then logInfoG "[SLACK] Disabled, skipping configmap-create"
        else withChannel (appGroup tracker) (service tracker) $ \channel -> do
            let blocks =
                    [ sectionBlock ("*" <> appGroup tracker <> "* | *" <> service tracker <> "* | ConfigMap Release")
                    , sectionBlock (appGroup tracker <> " | " <> createdBy tracker)
                    ]
            mTs <- sendSlackRich channel "ConfigMap CREATED" colorCreated blocks Nothing
            case mTs of
                Just ts -> saveThreadTs (releaseId tracker) ts
                Nothing -> pure ()

notifyConfigMapUpdated :: ReleaseTracker -> Text -> Flow ()
notifyConfigMapUpdated tracker detail = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock ("*" <> appGroup tracker <> "* | ConfigMap " <> detail)]
        _ <- sendSlackRich channel ("ConfigMap " <> detail) colorInProgress blocks threadTs
        pure ()

notifyConfigMapApproved :: ReleaseTracker -> Flow ()
notifyConfigMapApproved tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock ("Approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")]
        _ <- sendSlackRich channel "ConfigMap Approved" colorApproved blocks threadTs
        pure ()

notifyConfigMapInProgress :: ReleaseTracker -> Flow ()
notifyConfigMapInProgress tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*INPROGRESS*  — Applying ConfigMap"]
        _ <- sendSlackRich channel "ConfigMap INPROGRESS" colorInProgress blocks threadTs
        pure ()

notifyConfigMapCompleted :: ReleaseTracker -> Flow ()
notifyConfigMapCompleted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*COMPLETED*"]
        _ <- sendSlackRich channel "ConfigMap COMPLETED" colorCompleted blocks threadTs
        pure ()

notifyConfigMapAborted :: ReleaseTracker -> Flow ()
notifyConfigMapAborted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*ABORTED*"]
        _ <- sendSlackRich channel "ConfigMap ABORTED" colorAborted blocks threadTs
        pure ()

notifyConfigMapPaused :: ReleaseTracker -> Flow ()
notifyConfigMapPaused tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- sendSlackRich channel "ConfigMap PAUSED" colorPaused blocks threadTs
        pure ()

notifyConfigMapResumed :: ReleaseTracker -> Flow ()
notifyConfigMapResumed tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*RESUMED*"]
        _ <- sendSlackRich channel "ConfigMap Resumed" colorInProgress blocks threadTs
        pure ()

notifyConfigMapReverted :: ReleaseTracker -> Flow ()
notifyConfigMapReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["ConfigMap rolled back"]
                ]
        _ <- sendSlackRich channel "ConfigMap REVERTED" colorReverted blocks threadTs
        pure ()

notifyConfigMapDiscarded :: ReleaseTracker -> Flow ()
notifyConfigMapDiscarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*DISCARDED*"]
        _ <- sendSlackRich channel "ConfigMap DISCARDED" colorDefault blocks threadTs
        pure ()

notifyConfigMapFastForwarded :: ReleaseTracker -> Flow ()
notifyConfigMapFastForwarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- sendSlackRich channel "ConfigMap Fast Forwarded" colorInProgress blocks threadTs
        pure ()

notifyGenericThreadMessage :: ReleaseTracker -> Text -> Flow ()
notifyGenericThreadMessage tracker msg = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        let threadTs = getThreadTsFromTracker tracker
            blocks = [sectionBlock msg]
        _ <- sendSlackRich channel msg colorDefault blocks threadTs
        pure ()
