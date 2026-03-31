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
    notifyVsEditLocked,
    notifyVsEditApplied,
    notifyVsEditReverted,
    notifyVsEditUnlocked,
    notifyConfigMapCreated,
    notifyConfigMapUpdated,
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
import Network.HTTP.Client (RequestBody (..), httpLbs, method, newManager, parseRequest, requestBody, requestHeaders, responseBody)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Products.Autopilot.Queries.ProductService (findServiceByProductAndName)
import qualified Products.Autopilot.Queries.ReleaseTracker as RTQ
import Products.Autopilot.RuntimeConfig (isSlackEnabled)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Shared.Types.Storage.Schema (ReleaseConfigT (..))
import System.Environment (lookupEnv)
import Prelude hiding (product)

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

-- | Build a clickable link to a release in the dashboard
releaseLink :: Text -> Text -> IO Text
releaseLink rid label = do
    base <- getDashboardUrl
    pure $ "<" <> base <> "/releases/_/" <> rid <> "|" <> label <> ">"

getSlackChannel :: DBEnv -> Text -> Text -> IO (Maybe Text)
getSlackChannel db prod svc = do
    mCfg <- findServiceByProductAndName db prod svc
    pure $ case mCfg of
        Just cfg -> releaseConfigSlackWebhookUrls cfg
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

getThreadTs :: ReleaseTracker -> Maybe Text
getThreadTs tracker = udf3 tracker

saveThreadTs :: DBEnv -> Text -> Text -> IO ()
saveThreadTs db rid ts = RTQ.updateReleaseTrackerField db rid "udf3" ts

-- | Header line for release: PRODUCT | SERVICE | ENV Release
releaseHeader :: ReleaseTracker -> Text
releaseHeader t = "*" <> product t <> "* | *" <> service t <> "* | " <> env t <> " Release"

-- | Version line: PRODUCT | oldVer -> newVer | manager | newVer
releaseVersionLine :: ReleaseTracker -> Text
releaseVersionLine t =
    product t <> " | " <> oldVersion t <> " -> " <> newVersion t <> " | " <> createdBy t <> " | " <> newVersion t

-- ── Public notification functions ─────────────────────────────────

-- | Release created — starts a NEW thread with rich format
notifyReleaseCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCreated db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        link <- releaseLink (releaseId tracker) "View Release"
        let blocks =
                [ sectionBlock (releaseHeader tracker)
                , sectionBlock (releaseVersionLine tracker)
                , contextBlock ["`CREATED`", link]
                ]
            fallback = product tracker <> " | " <> service tracker <> " | CREATED"
        mTs <- sendSlackRich channel fallback colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs db (releaseId tracker) ts
            Nothing -> pure ()

-- | Release approved — thread reply
notifyReleaseApproved :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseApproved db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        link <- releaseLink (releaseId tracker) "View"
        let blocks =
                [ sectionBlock (product tracker <> " | " <> service tracker <> " approved by *" <> maybe "admin" id (approvedBy tracker) <> "*")
                , contextBlock ["`APPROVED`", link]
                ]
        _ <- sendSlackRich channel "Approved" colorApproved blocks (getThreadTs tracker)
        pure ()

-- | Release progress — thread reply with percentage
notifyReleaseProgress :: DBEnv -> ReleaseTracker -> Int -> IO ()
notifyReleaseProgress db tracker percentage = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let pct = T.pack (show percentage)
            blocks =
                [ sectionBlock ("*" <> product tracker <> "* | INPROGRESS | " <> pct <> "%\nRouting " <> pct <> "% traffic to " <> newVersion tracker)
                , contextBlock ["`INPROGRESS " <> pct <> "%`"]
                ]
        _ <- sendSlackRich channel ("InProgress " <> pct <> "%") colorInProgress blocks (getThreadTs tracker)
        pure ()

-- | Release completed — thread reply
notifyReleaseCompleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCompleted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | 100% on " <> newVersion tracker)
                , contextBlock ["`COMPLETED`"]
                ]
        _ <- sendSlackRich channel "Completed" colorCompleted blocks (getThreadTs tracker)
        pure ()

-- | Release aborted — thread reply
notifyReleaseAborted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseAborted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Release aborted")
                , contextBlock ["`ABORTED`"]
                ]
        _ <- sendSlackRich channel "Aborted" colorAborted blocks (getThreadTs tracker)
        pure ()

-- | Release paused — thread reply
notifyReleasePaused :: DBEnv -> ReleaseTracker -> IO ()
notifyReleasePaused db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Release paused")
                , contextBlock ["`PAUSED`"]
                ]
        _ <- sendSlackRich channel "Paused" colorPaused blocks (getThreadTs tracker)
        pure ()

-- | Release resumed — thread reply
notifyReleaseResumed :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseResumed db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Release resumed")
                , contextBlock ["`RESUMED`"]
                ]
        _ <- sendSlackRich channel "Resumed" colorInProgress blocks (getThreadTs tracker)
        pure ()

-- | Release reverted — thread reply
notifyReleaseReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseReverted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Reverted to " <> oldVersion tracker)
                , contextBlock ["`REVERTED`"]
                ]
        _ <- sendSlackRich channel "Reverted" colorReverted blocks (getThreadTs tracker)
        pure ()

-- | Release discarded — thread reply
notifyReleaseDiscarded :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseDiscarded db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Release discarded")
                , contextBlock ["`DISCARDED`"]
                ]
        _ <- sendSlackRich channel "Discarded" colorDefault blocks (getThreadTs tracker)
        pure ()

-- | Release deleted — thread reply
notifyReleaseDeleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseDeleted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Release deleted")
                , contextBlock ["`DELETED`", releaseId tracker]
                ]
        _ <- sendSlackRich channel "Deleted" colorAborted blocks (getThreadTs tracker)
        pure ()

-- | Release updated — thread reply
notifyReleaseUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyReleaseUpdated db tracker detail = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | " <> detail)
                , contextBlock ["`UPDATED`"]
                ]
        _ <- sendSlackRich channel ("Updated: " <> detail) colorDefault blocks (getThreadTs tracker)
        pure ()

-- | Release restarted — thread reply
notifyReleaseRestarted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseRestarted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Release restarted, reset to Created")
                , contextBlock ["`RESTARTED`"]
                ]
        _ <- sendSlackRich channel "Restarted" colorCreated blocks (getThreadTs tracker)
        pure ()

-- | Release fast-forwarded — thread reply
notifyReleaseFastForwarded :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseFastForwarded db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Cooloff skipped, advancing to next stage")
                , contextBlock ["`FAST FORWARDED`"]
                ]
        _ <- sendSlackRich channel "Fast Forwarded" colorInProgress blocks (getThreadTs tracker)
        pure ()

-- | Immediate revert — thread reply
notifyImmediateReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyImmediateReverted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | Immediate revert to " <> oldVersion tracker)
                , contextBlock ["`IMMEDIATE REVERT`", "Image swapped, rollout bypassed"]
                ]
        _ <- sendSlackRich channel "Immediate Revert" colorAborted blocks (getThreadTs tracker)
        pure ()

-- | Pods scaled down — thread reply
notifyPodsScaledDown :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyPodsScaledDown db tracker oldVer = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | Pods scaled down for version: " <> oldVer)
                , contextBlock ["`SCALE DOWN`"]
                ]
        _ <- sendSlackRich channel ("Pods scaled down: " <> oldVer) colorDefault blocks (getThreadTs tracker)
        pure ()

-- ── VS Edit Notifications ────────────────────────────────────────

notifyVsEditLocked :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditLocked db prod svc lockedByUser = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS locked for editing by *" <> lockedByUser <> "*")
                , contextBlock ["`VS LOCKED`"]
                ]
        _ <- sendSlackRich channel "VS Locked" colorPaused blocks Nothing
        pure ()

notifyVsEditApplied :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditApplied db prod svc appliedBy = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS changes applied by *" <> appliedBy <> "*")
                , contextBlock ["`VS APPLIED`"]
                ]
        _ <- sendSlackRich channel "VS Applied" colorCompleted blocks Nothing
        pure ()

notifyVsEditReverted :: DBEnv -> Text -> Text -> IO ()
notifyVsEditReverted db prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS changes reverted")
                , contextBlock ["`VS REVERTED`"]
                ]
        _ <- sendSlackRich channel "VS Reverted" colorReverted blocks Nothing
        pure ()

notifyVsEditUnlocked :: DBEnv -> Text -> Text -> IO ()
notifyVsEditUnlocked db prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> prod <> "* | *" <> svc <> "* | VS unlocked")
                , contextBlock ["`VS UNLOCKED`"]
                ]
        _ <- sendSlackRich channel "VS Unlocked" colorDefault blocks Nothing
        pure ()

-- ── ConfigMap Notifications ──────────────────────────────────────

notifyConfigMapCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapCreated db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | ConfigMap Release")
                , sectionBlock (product tracker <> " | " <> createdBy tracker)
                , contextBlock ["`CM CREATED`"]
                ]
        mTs <- sendSlackRich channel "ConfigMap Created" colorCreated blocks Nothing
        case mTs of
            Just ts -> saveThreadTs db (releaseId tracker) ts
            Nothing -> pure ()

notifyConfigMapUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyConfigMapUpdated db tracker detail = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks =
                [ sectionBlock ("*" <> product tracker <> "* | *" <> service tracker <> "* | ConfigMap " <> detail)
                , contextBlock ["`CM UPDATED`"]
                ]
        _ <- sendSlackRich channel ("ConfigMap " <> detail) colorInProgress blocks (getThreadTs tracker)
        pure ()

-- | Generic message in a release's thread
notifyGenericThreadMessage :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyGenericThreadMessage db tracker msg = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let blocks = [sectionBlock msg]
        _ <- sendSlackRich channel msg colorDefault blocks (getThreadTs tracker)
        pure ()
