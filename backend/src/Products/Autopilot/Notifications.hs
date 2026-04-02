{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Slack notification helpers for autopilot release lifecycle.

Thread-aware: the first message (Created) starts a thread,
all subsequent messages (Approved, Progress, Completed, etc.)
reply in that thread using the thread_ts stored in release_tracker.udf3.

Uses Slack Block Kit with colored attachments for rich formatting.
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
import Core.Environment (DBEnv)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client (RequestBody (..), httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody, responseTimeout, responseTimeoutMicro)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Products.Autopilot.Queries.ProductService (findServiceByProductAndName, getSlackChannelDirect)
import qualified Products.Autopilot.Queries.ReleaseTracker as RTQ
import Products.Autopilot.RuntimeConfig (isSlackEnabled)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import System.Environment (lookupEnv)
import Prelude

-- ── Colors ───────────────────────────────────────────────────────

colorCreated, colorApproved, colorInProgress, colorCompleted :: Text
colorAborted, colorPaused, colorReverted, colorDefault :: Text
colorCreated = "#2563eb"     -- blue
colorApproved = "#0891b2"    -- cyan
colorInProgress = "#d97706"  -- amber
colorCompleted = "#16a34a"   -- green
colorAborted = "#dc2626"     -- red
colorPaused = "#6366f1"      -- indigo
colorReverted = "#7c3aed"    -- violet
colorDefault = "#71717a"     -- zinc

-- ── Internal helpers ──────────────────────────────────────────────

getSlackToken :: IO (Maybe String)
getSlackToken = lookupEnv "SLACK_BOT_TOKEN"

getDashboardUrl :: IO Text
getDashboardUrl = do
    mUrl <- lookupEnv "DASHBOARD_URL"
    pure $ T.pack $ maybe "http://localhost:5173" id mUrl


getSlackChannel :: DBEnv -> Text -> Text -> IO (Maybe Text)
getSlackChannel db prod svc = do
    mCfg <- findServiceByProductAndName db prod svc
    pure $ case mCfg of
        Just cfg -> getSlackChannelDirect cfg
        Nothing -> Nothing

{- | Post a rich message to Slack using Block Kit attachments.
Returns the message ts (thread ID) if successful.
-}
sendSlackRich :: Text -> Text -> Text -> [Value] -> Maybe Text -> IO (Maybe Text)
sendSlackRich channel fallbackText color blocks mThreadTs = do
    mToken <- getSlackToken
    case mToken of
        Nothing -> do
            putStrLn "[SLACK] No SLACK_BOT_TOKEN env var set, skipping"
            pure Nothing
        Just token -> do
            result <- try $ do
                manager <- newManager tlsManagerSettings
                initReq <- parseRequest "https://slack.com/api/chat.postMessage"
                let attachment =
                        object
                            [ "color" .= color
                            , "blocks" .= blocks
                            ]
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
                            , responseTimeout = responseTimeoutMicro 10000000  -- 10 second timeout
                            }
                resp <- httpLbs req manager
                let mTs = do
                        val <- decode (responseBody resp) :: Maybe Value
                        case val of
                            Object obj -> case KM.lookup (K.fromText "ts") obj of
                                Just (String ts) -> Just ts
                                _ -> Nothing
                            _ -> Nothing
                putStrLn $ "[SLACK] Sent to #" <> T.unpack channel <> maybe "" (\ts -> " (ts=" <> T.unpack ts <> ")") mTs
                pure mTs
            case result of
                Left (err :: SomeException) -> do
                    putStrLn $ "[SLACK] Error: " <> show err
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

whenSlackEnabled :: DBEnv -> IO () -> IO ()
whenSlackEnabled db action = do
    enabled <- isSlackEnabled db
    if enabled
        then action
        else putStrLn "[SLACK] Disabled, skipping"

withChannel :: DBEnv -> Text -> Text -> (Text -> IO ()) -> IO ()
withChannel db prod svc f = do
    mCh <- getSlackChannel db prod svc
    case mCh of
        Nothing -> putStrLn $ "[SLACK] No channel for " <> T.unpack prod <> "/" <> T.unpack svc
        Just ch -> f ch

-- | Read thread_ts fresh from DB every time (avoids stale in-memory tracker).
-- The runner/workflow may hold an old copy of the tracker whose udf3 is Nothing
-- because saveThreadTs only writes to DB.
getThreadTs :: DBEnv -> Text -> IO (Maybe Text)
getThreadTs db rid = do
    m <- RTQ.findReleaseTracker db rid
    case m of
        Just (tracker, _) -> pure (udf3 tracker)
        Nothing -> pure Nothing

saveThreadTs :: DBEnv -> Text -> Text -> IO ()
saveThreadTs db rid ts = RTQ.updateReleaseTrackerUdf3 db rid ts

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

-- | Release created — starts a NEW thread (header link + version)
notifyReleaseCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCreated db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        link <- releaseLink tracker
        let blocks =
                [ sectionBlock link
                , sectionBlock (versionLine tracker)
                ]
        mTs <- sendSlackRich channel (appGroup tracker <> " | " <> service tracker) colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs db (releaseId tracker) ts
            Nothing -> pure ()

-- | Release approved
notifyReleaseApproved :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseApproved db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock ("Approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")]
        _ <- sendSlackRich channel "Approved" colorApproved blocks threadTs
        pure ()

-- | Release progress with rollout percentage
notifyReleaseProgress :: DBEnv -> ReleaseTracker -> Int -> IO ()
notifyReleaseProgress db tracker percentage = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let pct = T.pack (show percentage)
            blocks =
                [ sectionBlock ("*INPROGRESS*  " <> pct <> "%")
                , contextBlock ["Routing " <> pct <> "% traffic to `" <> newVersion tracker <> "` | " <> T.pack (show (100 - percentage)) <> "% on `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel ("InProgress " <> pct <> "%") colorInProgress blocks threadTs
        pure ()

-- | Release completed
notifyReleaseCompleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCompleted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks =
                [ sectionBlock "*COMPLETED*  100%"
                , contextBlock ["All traffic on `" <> newVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "Completed" colorCompleted blocks threadTs
        pure ()

-- | Release aborted
notifyReleaseAborted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseAborted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks =
                [ sectionBlock "*ABORTED*"
                , contextBlock ["Traffic restored to `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "Aborted" colorAborted blocks threadTs
        pure ()

-- | Release paused
notifyReleasePaused :: DBEnv -> ReleaseTracker -> IO ()
notifyReleasePaused db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- sendSlackRich channel "Paused" colorPaused blocks threadTs
        pure ()

-- | Release resumed
notifyReleaseResumed :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseResumed db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*RESUMED*"]
        _ <- sendSlackRich channel "Resumed" colorInProgress blocks threadTs
        pure ()

-- | Release reverted
notifyReleaseReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseReverted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["Rolled back to `" <> oldVersion tracker <> "`"]
                ]
        _ <- sendSlackRich channel "Reverted" colorReverted blocks threadTs
        pure ()

-- | Release discarded
notifyReleaseDiscarded :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseDiscarded db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*DISCARDED*"]
        _ <- sendSlackRich channel "Discarded" colorDefault blocks threadTs
        pure ()

-- | Release deleted
notifyReleaseDeleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseDeleted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*DELETED*"]
        _ <- sendSlackRich channel "Deleted" colorAborted blocks threadTs
        pure ()

-- | Release updated
notifyReleaseUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyReleaseUpdated db tracker detail = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock ("*UPDATED*  " <> detail)]
        _ <- sendSlackRich channel ("Updated: " <> detail) colorDefault blocks threadTs
        pure ()

-- | Release restarted
notifyReleaseRestarted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseRestarted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*RESTARTED*  — reset to Created"]
        _ <- sendSlackRich channel "Restarted" colorCreated blocks threadTs
        pure ()

-- | Release fast-forwarded
notifyReleaseFastForwarded :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseFastForwarded db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- sendSlackRich channel "Fast Forwarded" colorInProgress blocks threadTs
        pure ()

-- | Immediate revert
notifyImmediateReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyImmediateReverted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks =
                [ sectionBlock "*IMMEDIATE REVERT*"
                , contextBlock ["Image swapped back to `" <> oldVersion tracker <> "` | rollout bypassed"]
                ]
        _ <- sendSlackRich channel "Immediate Revert" colorAborted blocks threadTs
        pure ()

-- | Pods scaled down
notifyPodsScaledDown :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyPodsScaledDown db tracker oldVer = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock ("Pods scaled down for `" <> oldVer <> "`")]
        _ <- sendSlackRich channel ("Pods scaled down: " <> oldVer) colorDefault blocks threadTs
        pure ()

-- ── VS Edit Notifications (with color) ──────────────────────────

-- | VS created — starts a new thread (for non-lock create flow)
notifyVsEditCreated :: DBEnv -> Text -> Text -> Text -> Maybe Text -> IO ()
notifyVsEditCreated db trackerId prod svc mCreatedByUser = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        link <- getDashboardUrl
        let vsLink = "<" <> link <> "/vs-editor/" <> trackerId <> "|" <> prod <> " | " <> svc <> " | VS Edit>"
            createdByUser = maybe "admin" id mCreatedByUser
            blocks =
                [ sectionBlock vsLink
                , contextBlock ["Created by *" <> createdByUser <> "*"]
                ]
        mTs <- sendSlackRich channel "VS Created" colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs db trackerId ts
            Nothing -> pure ()

-- | VS locked — starts a new thread (like release created)
notifyVsEditLocked :: DBEnv -> Text -> Text -> Text -> Text -> IO ()
notifyVsEditLocked db trackerId prod svc lockedByUser = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        link <- getDashboardUrl
        let vsLink = "<" <> link <> "/vs-editor/" <> trackerId <> "|" <> prod <> " | " <> svc <> " | VS Edit>"
            blocks =
                [ sectionBlock vsLink
                , contextBlock ["Locked by *" <> lockedByUser <> "*"]
                ]
        mTs <- sendSlackRich channel "VS Locked" colorPaused blocks Nothing
        case mTs of
            Just ts -> saveThreadTs db trackerId ts
            Nothing -> pure ()

-- | VS applied — thread reply
notifyVsEditApplied :: DBEnv -> Text -> Text -> Text -> Text -> IO ()
notifyVsEditApplied db trackerId prod svc appliedBy = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        threadTs <- getThreadTs db trackerId
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *APPLIED*")
                , contextBlock ["Applied by " <> appliedBy]
                ]
        _ <- sendSlackRich channel "VS Applied" colorCompleted blocks threadTs
        pure ()

-- | VS approved — thread reply
notifyVsEditApproved :: DBEnv -> Text -> Text -> Text -> Text -> IO ()
notifyVsEditApproved db trackerId prod svc approvedByUser = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        threadTs <- getThreadTs db trackerId
        let blocks = [sectionBlock ("Approved by *" <> approvedByUser <> "*")]
        _ <- sendSlackRich channel "VS Approved" colorApproved blocks threadTs
        pure ()

-- | VS discarded — thread reply
notifyVsEditDiscarded :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditDiscarded db trackerId prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        threadTs <- getThreadTs db trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *DISCARDED*")]
        _ <- sendSlackRich channel "VS Discarded" colorDefault blocks threadTs
        pure ()

-- | VS reverted — thread reply
notifyVsEditReverted :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditReverted db trackerId prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        threadTs <- getThreadTs db trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *REVERTED*")]
        _ <- sendSlackRich channel "VS Reverted" colorReverted blocks threadTs
        pure ()

-- | VS unlocked — thread reply
notifyVsEditUnlocked :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditUnlocked db trackerId prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        threadTs <- getThreadTs db trackerId
        let blocks = [sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS *UNLOCKED*")]
        _ <- sendSlackRich channel "VS Unlocked" colorDefault blocks threadTs
        pure ()

-- ── ConfigMap Notifications ──────────────────────────────────────

notifyConfigMapCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapCreated db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> appGroup tracker <> "* | *" <> service tracker <> "* | ConfigMap Release")
                , sectionBlock (appGroup tracker <> " | " <> createdBy tracker)
                ]
        mTs <- sendSlackRich channel "ConfigMap Created" colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs db (releaseId tracker) ts
            Nothing -> pure ()

notifyConfigMapUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyConfigMapUpdated db tracker detail = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock ("*" <> appGroup tracker <> "* | ConfigMap " <> detail)]
        _ <- sendSlackRich channel ("ConfigMap " <> detail) colorInProgress blocks threadTs
        pure ()

notifyConfigMapApproved :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapApproved db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock ("Approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")]
        _ <- sendSlackRich channel "ConfigMap Approved" colorApproved blocks threadTs
        pure ()

notifyConfigMapInProgress :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapInProgress db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*INPROGRESS*  — Applying ConfigMap"]
        _ <- sendSlackRich channel "ConfigMap InProgress" colorInProgress blocks threadTs
        pure ()

notifyConfigMapCompleted :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapCompleted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*COMPLETED*"]
        _ <- sendSlackRich channel "ConfigMap Completed" colorCompleted blocks threadTs
        pure ()

notifyConfigMapAborted :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapAborted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*ABORTED*"]
        _ <- sendSlackRich channel "ConfigMap Aborted" colorAborted blocks threadTs
        pure ()

notifyConfigMapPaused :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapPaused db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*PAUSED*  — cooloff in progress"]
        _ <- sendSlackRich channel "ConfigMap Paused" colorPaused blocks threadTs
        pure ()

notifyConfigMapResumed :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapResumed db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*RESUMED*"]
        _ <- sendSlackRich channel "ConfigMap Resumed" colorInProgress blocks threadTs
        pure ()

notifyConfigMapReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapReverted db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks =
                [ sectionBlock "*REVERTED*"
                , contextBlock ["ConfigMap rolled back"]
                ]
        _ <- sendSlackRich channel "ConfigMap Reverted" colorReverted blocks threadTs
        pure ()

notifyConfigMapDiscarded :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapDiscarded db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*DISCARDED*"]
        _ <- sendSlackRich channel "ConfigMap Discarded" colorDefault blocks threadTs
        pure ()

notifyConfigMapFastForwarded :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapFastForwarded db tracker = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock "*FAST FORWARDED*  — advancing to next stage"]
        _ <- sendSlackRich channel "ConfigMap Fast Forwarded" colorInProgress blocks threadTs
        pure ()

-- | Generic message in a release's thread
notifyGenericThreadMessage :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyGenericThreadMessage db tracker msg = whenSlackEnabled db $
    withChannel db (appGroup tracker) (service tracker) $ \channel -> do
        threadTs <- getThreadTs db (releaseId tracker)
        let blocks = [sectionBlock msg]
        _ <- sendSlackRich channel msg colorDefault blocks threadTs
        pure ()
