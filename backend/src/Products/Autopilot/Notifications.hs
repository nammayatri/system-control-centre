{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Slack notifications for autopilot release lifecycle.

Thread-aware: CREATED starts a thread; later messages reply in it using the
thread_ts stored in release_tracker.slack_thread_ts. Sent via 'forkFlow' so
HTTP handlers don't block on Slack, except the create messages which must
save thread_ts before a follow-up notification can race them.
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
    notifyDecisionThreadMessage,
    sendMobileChangelogSlack,
    chunkForSlack,
)
where

import Control.Monad (void)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, forkFlow)
import Core.Http.Client (HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Logging (logErrorG, logInfoG, logWarningG)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Products.Autopilot.Queries.ProductService (findProductByName, getSlackChannelDirect)
import qualified Products.Autopilot.Queries.ReleaseTracker as RTQ
import Products.Autopilot.RuntimeConfig (getDecisionNotificationDedupMinutes, isSlackEnabled)
import Products.Autopilot.Sync (triggerSyncIfEnabled)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Products.Autopilot.Types.Storage.Schema (rePayload)
import Products.Autopilot.Types.Target (TargetState)
import System.Environment (lookupEnv)
import Prelude

colorCreated, colorApproved, colorInProgress, colorCompleted :: Text
colorAborted, colorPaused, colorReverted, colorDefault :: Text
colorCreated = "#2563eb"
colorApproved = "#0891b2"
colorInProgress = "#d97706"
colorCompleted = "#16a34a"
colorAborted = "#dc2626"
colorPaused = "#6366f1"
colorReverted = "#7c3aed"
colorDefault = "#71717a"

getSlackToken :: IO (Maybe String)
getSlackToken = lookupEnv "SLACK_BOT_TOKEN"

getDashboardUrl :: IO Text
getDashboardUrl = do
    mUrl <- lookupEnv "DASHBOARD_URL"
    pure $ T.pack $ maybe "http://localhost:5173" id mUrl

-- | One Slack channel per app group covers releases, configmaps and VS edits.
getSlackChannel :: Text -> Flow (Maybe Text)
getSlackChannel prod = do
    mProd <- findProductByName prod
    pure (mProd >>= getSlackChannelDirect)

truncateT :: Int -> Text -> Text
truncateT n t
    | T.length t <= n = t
    | otherwise = T.take n t <> "..."

-- | Post a Block Kit message; returns the message ts (thread ID) on success.
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
                        , -- 5s cap so the synchronous create paths can never
                          -- wedge an HTTP handler waiting on Slack.
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
                        -- chat.postMessage returns HTTP 200 even on logical
                        -- failures (e.g. not_in_channel / channel_not_found):
                        -- {"ok":false,"error":"..."}. A real success carries a
                        -- "ts". So a present "ts" — not the 2xx status — is the
                        -- only reliable success signal.
                        let mObj = case decode b :: Maybe Value of
                                Just (Object obj) -> Just obj
                                _ -> Nothing
                            strField k = case mObj >>= KM.lookup (K.fromText k) of
                                Just (String t) -> Just t
                                _ -> Nothing
                            mTs = strField "ts"
                        case mTs of
                            Just ts -> do
                                logInfoG $ "[SLACK] Sent to #" <> channel <> " (ts=" <> ts <> ")"
                                pure (Just ts)
                            Nothing -> do
                                -- ok:false (or an unexpected body) — surface
                                -- Slack's error so this never looks like a send.
                                let err = fromMaybe "unknown" (strField "error")
                                logWarningG $
                                    "[SLACK] postMessage NOT sent to #"
                                        <> channel
                                        <> " (ok=false, error="
                                        <> err
                                        <> "): "
                                        <> truncateT 200 (TL.toStrict (TLE.decodeUtf8 b))
                                pure Nothing

sectionBlock :: Text -> Value
sectionBlock txt =
    object
        [ "type" .= ("section" :: Text)
        , "text" .= object ["type" .= ("mrkdwn" :: Text), "text" .= txt]
        ]

contextBlock :: [Text] -> Value
contextBlock items =
    object
        [ "type" .= ("context" :: Text)
        , "elements" .= map (\t -> object ["type" .= ("mrkdwn" :: Text), "text" .= t]) items
        ]

{- | Split changelog text into Slack-safe section chunks. Packs whole lines into
chunks of <= ~2900 chars (Slack's per-section text limit is 3000) and caps the
number of chunks so a runaway summary can't blow past Slack's 50-block limit;
a "truncated" notice is appended when the cap is hit. A single over-long line is
hard-split so it never exceeds the section limit.
-}
chunkForSlack :: Text -> [Text]
chunkForSlack input =
    let maxChunk = 2900 :: Int
        maxChunks = 12 :: Int
        -- hard-split a single line that is itself longer than maxChunk
        splitLong :: Text -> [Text]
        splitLong l
            | T.length l <= maxChunk = [l]
            | otherwise = let (h, t) = T.splitAt maxChunk l in h : splitLong t
        pack :: [Text] -> Text -> [Text] -> [Text]
        pack acc cur [] = reverse (if T.null cur then acc else cur : acc)
        pack acc cur (l : ls)
            | T.null cur = pack acc l ls
            | T.length cur + 1 + T.length l <= maxChunk = pack acc (cur <> "\n" <> l) ls
            | otherwise = pack (cur : acc) l ls
        ls = concatMap splitLong (T.lines input)
        chunks = pack [] "" ls
     in if length chunks <= maxChunks
            then chunks
            else take maxChunks chunks <> ["_…changelog truncated._"]

{- | Post a mobile release changelog to a Slack channel as a TOP-LEVEL message
(not threaded). Header line + chunked body. Returns whether a message was sent.
Reuses 'sendSlackRich'; the channel is resolved by the caller via
'getMobileSlackChannel'.
-}
sendMobileChangelogSlack :: Text -> Text -> Text -> Text -> Text -> Flow Bool
sendMobileChangelogSlack channel app surface versionLabel summaryLong = do
    let surfaceSuffix = if T.null (T.strip surface) then "" else " (" <> surface <> ")"
        header = ":rocket: *" <> app <> "*" <> surfaceSuffix <> " — " <> versionLabel
        bodyChunks = case chunkForSlack (T.strip summaryLong) of
            [] -> ["_No changelog summary._"]
            cs -> cs
        blocks = sectionBlock header : map sectionBlock bodyChunks
        fallback = app <> surfaceSuffix <> " — " <> versionLabel
    mTs <- sendSlackRich channel fallback colorCreated blocks Nothing
    case mTs of
        Just _ -> pure True
        Nothing -> pure False

-- | Run the notification body async iff Slack is enabled.
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

-- | Read thread_ts fresh from DB (for callers without a ReleaseTracker in hand).
getThreadTs :: Text -> Flow (Maybe Text)
getThreadTs rid = do
    m <- RTQ.findReleaseTracker rid
    case m of
        Just (tracker, _) -> pure (slackThreadTs tracker)
        Nothing -> pure Nothing

{- | Resolve thread_ts with a single DB fallback. Guards the race where an
Approve hits before the async create-Slack POST has saved thread_ts; an
in-memory-stale Nothing would otherwise post a new top-level message.
-}
resolveThreadTs :: ReleaseTracker -> Flow (Maybe Text)
resolveThreadTs tracker = case slackThreadTs tracker of
    Just ts -> pure (Just ts)
    Nothing -> getThreadTs (releaseId tracker)

saveThreadTs :: Text -> Text -> Flow ()
saveThreadTs = RTQ.updateReleaseTrackerSlackThreadTs

releaseLink :: ReleaseTracker -> IO Text
releaseLink t = do
    base <- getDashboardUrl
    let url = base <> "/releases/" <> releaseId t
    pure $ "<" <> url <> "|" <> appGroup t <> " | " <> service t <> " | " <> env t <> " Release>"

versionLine :: ReleaseTracker -> Text
versionLine t = oldVersion t <> " → " <> newVersion t <> " | " <> createdBy t

{- | Send the CREATED Slack message SYNCHRONOUSLY. Every subsequent
notification threads under this message via thread_ts, so we must block
the create handler on this ~200-500ms POST to guarantee thread_ts is in
the DB before an immediate Approve can race it. All other notify*
functions remain async via whenSlackEnabled.
-}
notifyReleaseCreated :: ReleaseTracker -> Flow ()
notifyReleaseCreated tracker = do
    enabled <- isSlackEnabled
    if not enabled
        then logInfoG "[SLACK] Disabled, skipping create"
        else withChannel (appGroup tracker) (service tracker) $ \channel -> do
            link <- liftIO $ releaseLink tracker
            let clBlocks = case changeLog tracker of
                    Just cl | not (T.null (T.strip cl)) -> [contextBlock [cl]]
                    _ -> []
                blocks = [sectionBlock link, sectionBlock (versionLine tracker)] <> clBlocks
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
        threadTs <- resolveThreadTs tracker
        let pct = T.pack (show percentage)
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
            threadTs <- resolveThreadTs tracker
            let blocks =
                    [ sectionBlock "*COMPLETED*  100%"
                    , contextBlock ["All traffic on `" <> newVersion tracker <> "`"]
                    ]
            _ <- sendSlackRich channel "COMPLETED" colorCompleted blocks threadTs
            pure ()
    triggerSyncIfEnabled tracker mts

notifyReleaseAborted :: ReleaseTracker -> Flow ()
notifyReleaseAborted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks =
                [ sectionBlock "*ABORTED*"
                , contextBlock ["Traffic restored to `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "ABORTED" colorAborted blocks threadTs
        pure ()

notifyReleasePaused :: ReleaseTracker -> Flow ()
notifyReleasePaused tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- sendSlackRich channel "PAUSED" colorPaused blocks threadTs
        pure ()

notifyReleaseResumed :: ReleaseTracker -> Flow ()
notifyReleaseResumed tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*RESUMED*"]
        _ <- sendSlackRich channel "Resumed" colorInProgress blocks threadTs
        pure ()

notifyReleaseReverted :: ReleaseTracker -> Flow ()
notifyReleaseReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        -- Fires on the REVERT tracker, whose versions are swapped vs the
        -- original (Actions/Release.hs). The rollback target is newVersion,
        -- not oldVersion — reading oldVersion here misreports the target.
        let blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["Rolled back to `" <> newVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "REVERTED" colorReverted blocks threadTs
        pure ()

notifyReleaseDiscarded :: ReleaseTracker -> Flow ()
notifyReleaseDiscarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*DISCARDED*"]
        _ <- sendSlackRich channel "DISCARDED" colorDefault blocks threadTs
        pure ()

notifyReleaseDeleted :: ReleaseTracker -> Flow ()
notifyReleaseDeleted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*DELETED*"]
        _ <- sendSlackRich channel "Deleted" colorAborted blocks threadTs
        pure ()

notifyReleaseUpdated :: ReleaseTracker -> Text -> Flow ()
notifyReleaseUpdated tracker detail = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock ("*UPDATED*  " <> detail)]
        _ <- sendSlackRich channel ("Updated: " <> detail) colorDefault blocks threadTs
        pure ()

notifyReleaseRestarted :: ReleaseTracker -> Flow ()
notifyReleaseRestarted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*RESTARTED*  — reset to CREATED"]
        _ <- sendSlackRich channel "Restarted" colorCreated blocks threadTs
        pure ()

notifyReleaseFastForwarded :: ReleaseTracker -> Flow ()
notifyReleaseFastForwarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- sendSlackRich channel "Fast Forwarded" colorInProgress blocks threadTs
        pure ()

notifyImmediateReverted :: ReleaseTracker -> Flow ()
notifyImmediateReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks =
                [ sectionBlock "*IMMEDIATE REVERT*"
                , contextBlock ["Image swapped back to `" <> oldVersion tracker <> "` | rollout bypassed"]
                ]
        _ <- sendSlackRich channel "Immediate Revert" colorAborted blocks threadTs
        pure ()

notifyPodsScaledDown :: ReleaseTracker -> Text -> Flow ()
notifyPodsScaledDown tracker oldVer = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock ("Pods scaled down for `" <> oldVer <> "`")]
        _ <- sendSlackRich channel ("Pods scaled down: " <> oldVer) colorDefault blocks threadTs
        pure ()

-- | Synchronous — see notifyReleaseCreated for the thread_ts rationale.
notifyVsEditCreated :: Text -> Text -> Text -> Maybe Text -> Flow ()
notifyVsEditCreated trackerId prod svc mCreatedByUser = do
    enabled <- isSlackEnabled
    if not enabled
        then logInfoG "[SLACK] Disabled, skipping vs-edit-create"
        else withChannel prod svc $ \channel -> do
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

-- | Synchronous — see notifyReleaseCreated for the thread_ts rationale.
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

-- | Synchronous — see notifyReleaseCreated for the thread_ts rationale.
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
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*RESUMED*"]
        _ <- sendSlackRich channel "ConfigMap Resumed" colorInProgress blocks threadTs
        pure ()

notifyConfigMapReverted :: ReleaseTracker -> Flow ()
notifyConfigMapReverted tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["ConfigMap rolled back"]
                ]
        _ <- sendSlackRich channel "ConfigMap REVERTED" colorReverted blocks threadTs
        pure ()

notifyConfigMapDiscarded :: ReleaseTracker -> Flow ()
notifyConfigMapDiscarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*DISCARDED*"]
        _ <- sendSlackRich channel "ConfigMap DISCARDED" colorDefault blocks threadTs
        pure ()

notifyConfigMapFastForwarded :: ReleaseTracker -> Flow ()
notifyConfigMapFastForwarded tracker = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- sendSlackRich channel "ConfigMap Fast Forwarded" colorInProgress blocks threadTs
        pure ()

notifyGenericThreadMessage :: ReleaseTracker -> Text -> Flow ()
notifyGenericThreadMessage tracker msg = whenSlackEnabled $
    withChannel (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- resolveThreadTs tracker
        let blocks = [sectionBlock msg]
        _ <- sendSlackRich channel msg colorDefault blocks threadTs
        pure ()

{- | Decision-engine notification with two-layer dedup:
  (a) exact-tuple (decisionType, decisionValue, reason) match against the
      last DECISION_NOTIFIED event — suppresses stuck-state spam.
  (b) time window (@decision_notification_dedup_minutes@) — suppresses
      flapping Continue→Wait→Continue floods even when the tuple changes.
Returns True if the message was sent.
-}
notifyDecisionThreadMessage :: ReleaseTracker -> Text -> Text -> Maybe Text -> Text -> Flow Bool
notifyDecisionThreadMessage tracker decisionType decisionValue reason msg = do
    let dedupKey = decisionType <> "|" <> decisionValue <> "|" <> fromMaybe "" reason
    mPrev <- RTQ.findEventByLabel (releaseId tracker) "DECISION_NOTIFIED"
    windowMins <- getDecisionNotificationDedupMinutes
    now <- liftIO getCurrentTime
    let (prevKey, prevTs) = case mPrev of
            Just e -> case rePayload e of
                Object o ->
                    let k = case KM.lookup (K.fromText "key") o of
                            Just (String s) -> s
                            _ -> ""
                        t = case KM.lookup (K.fromText "ts") o of
                            Just (String s) -> Just s
                            _ -> Nothing
                     in (k, t)
                String s -> (s, Nothing)
                _ -> ("", Nothing)
            Nothing -> ("", Nothing)
        prevTime = prevTs >>= parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . T.unpack
        withinWindow = case prevTime of
            Just t -> diffUTCTime now t < fromIntegral (windowMins * 60)
            Nothing -> False
    if prevKey == dedupKey
        then do
            logInfoG $
                "[NOTIFY] decision dedup (same tuple): "
                    <> dedupKey
                    <> " for "
                    <> releaseId tracker
            pure False
        else
            if withinWindow
                then do
                    logInfoG $
                        "[NOTIFY] decision dedup (time window "
                            <> T.pack (show windowMins)
                            <> "min): suppressing "
                            <> dedupKey
                            <> " for "
                            <> releaseId tracker
                    pure False
                else do
                    let payload =
                            object
                                [ "key" .= dedupKey
                                , "ts" .= T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" now)
                                ]
                    RTQ.insertReleaseEvent (releaseId tracker) "BUSINESS" "DECISION_NOTIFIED" payload
                    notifyGenericThreadMessage tracker msg
                    pure True
