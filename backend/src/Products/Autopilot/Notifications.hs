{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Slack notification helpers for autopilot release lifecycle.

Thread-aware: the first message (Created) starts a thread,
all subsequent messages (Approved, Progress, Completed, etc.)
reply in that thread using the thread_ts stored in release_tracker.udf3.
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
import Products.Autopilot.RuntimeConfig (isSlackEnabled)
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
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Shared.Types.Storage.Schema (ReleaseConfigT (..))
import System.Environment (lookupEnv)
import Prelude hiding (product)

-- ── Internal helpers ──────────────────────────────────────────────

getSlackToken :: IO (Maybe String)
getSlackToken = lookupEnv "SLACK_BOT_TOKEN"

getSlackChannel :: DBEnv -> Text -> Text -> IO (Maybe Text)
getSlackChannel db prod svc = do
    mCfg <- findServiceByProductAndName db prod svc
    pure $ case mCfg of
        Just cfg -> releaseConfigSlackWebhookUrls cfg
        Nothing -> Nothing

{- | Post a message to Slack. Returns the message ts (thread ID) if successful.
If thread_ts is provided, the message is posted as a reply in that thread.
-}
sendSlackMessage :: Text -> Text -> Maybe Text -> IO (Maybe Text)
sendSlackMessage channel message mThreadTs = do
    mToken <- getSlackToken
    case mToken of
        Nothing -> do
            putStrLn "[SLACK] No SLACK_BOT_TOKEN env var set, skipping"
            pure Nothing
        Just token -> do
            result <- try $ do
                manager <- newManager tlsManagerSettings
                initReq <- parseRequest "https://slack.com/api/chat.postMessage"
                let bodyObj = case mThreadTs of
                        Nothing ->
                            object
                                [ "channel" .= channel
                                , "text" .= message
                                ]
                        Just threadTs ->
                            object
                                [ "channel" .= channel
                                , "text" .= message
                                , "thread_ts" .= threadTs
                                ]
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

-- | Get thread_ts from release tracker's udf3 field
getThreadTs :: ReleaseTracker -> Maybe Text
getThreadTs tracker = udf3 tracker

-- | Save thread_ts to release tracker's udf3 field
saveThreadTs :: DBEnv -> Text -> Text -> IO ()
saveThreadTs db rid ts = RTQ.updateReleaseTrackerField db rid "udf3" ts

-- ── Public notification functions ─────────────────────────────────

-- | Release created — starts a NEW thread
notifyReleaseCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCreated db tracker = whenSlackEnabled db $ do
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg =
                T.unlines
                    [ "*" <> product tracker <> "* | *" <> service tracker <> "* | " <> env tracker <> " Release"
                    , oldVersion tracker <> " → " <> newVersion tracker <> " | " <> createdBy tracker
                    , "Status: *CREATED*"
                    ]
        mTs <- sendSlackMessage channel msg Nothing
        -- Save thread_ts so subsequent messages reply in this thread
        case mTs of
            Just ts -> saveThreadTs db (releaseId tracker) ts
            Nothing -> pure ()

-- | Release approved — replies in thread
notifyReleaseApproved :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseApproved db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* approved by " <> maybe "admin" id (approvedBy tracker)
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release progress — replies in thread
notifyReleaseProgress :: DBEnv -> ReleaseTracker -> Int -> IO ()
notifyReleaseProgress db tracker percentage = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg =
                "*"
                    <> product tracker
                    <> "* | INPROGRESS | "
                    <> T.pack (show percentage)
                    <> " %"
                    <> "\nRouting "
                    <> T.pack (show percentage)
                    <> " % to "
                    <> newVersion tracker
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release completed — replies in thread
notifyReleaseCompleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCompleted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *COMPLETED* | 100 %"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release aborted — replies in thread
notifyReleaseAborted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseAborted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *ABORTED*"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release paused — replies in thread
notifyReleasePaused :: DBEnv -> ReleaseTracker -> IO ()
notifyReleasePaused db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *PAUSED*"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release resumed — replies in thread
notifyReleaseResumed :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseResumed db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *RESUMED*"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release reverted — replies in thread
notifyReleaseReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseReverted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *REVERTED*"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Pods scaled down — replies in thread
notifyPodsScaledDown :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyPodsScaledDown db tracker oldVer = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | Pods scaled down for version: " <> oldVer
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release discarded — replies in thread
notifyReleaseDiscarded :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseDiscarded db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *DISCARDED*"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release deleted — replies in thread
notifyReleaseDeleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseDeleted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *DELETED* | " <> releaseId tracker
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release updated (description, mode, schedule, etc.) — replies in thread
notifyReleaseUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyReleaseUpdated db tracker detail = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | Updated: " <> detail
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release restarted — replies in thread
notifyReleaseRestarted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseRestarted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *RESTARTED* — reset to Created"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Release fast-forwarded — replies in thread
notifyReleaseFastForwarded :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseFastForwarded db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *FAST FORWARDED* — cooloff skipped"
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Immediate revert — replies in thread
notifyImmediateReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyImmediateReverted db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | *IMMEDIATE REVERT* — image swapped back to " <> oldVersion tracker
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | VS edit locked — replies in release thread (if exists) or standalone
notifyVsEditLocked :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditLocked db prod svc lockedByUser = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let msg = "*" <> prod <> "* | *" <> svc <> "* | VS *LOCKED* for editing by " <> lockedByUser
        _ <- sendSlackMessage channel msg Nothing
        pure ()

-- | VS edit applied
notifyVsEditApplied :: DBEnv -> Text -> Text -> Text -> IO ()
notifyVsEditApplied db prod svc appliedBy = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let msg = "*" <> prod <> "* | *" <> svc <> "* | VS changes *APPLIED* by " <> appliedBy
        _ <- sendSlackMessage channel msg Nothing
        pure ()

-- | VS edit reverted
notifyVsEditReverted :: DBEnv -> Text -> Text -> IO ()
notifyVsEditReverted db prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let msg = "*" <> prod <> "* | *" <> svc <> "* | VS changes *REVERTED*"
        _ <- sendSlackMessage channel msg Nothing
        pure ()

-- | VS edit unlocked
notifyVsEditUnlocked :: DBEnv -> Text -> Text -> IO ()
notifyVsEditUnlocked db prod svc = whenSlackEnabled db $
    withChannel db prod svc $ \channel -> do
        let msg = "*" <> prod <> "* | *" <> svc <> "* | VS *UNLOCKED*"
        _ <- sendSlackMessage channel msg Nothing
        pure ()

-- | ConfigMap tracker created — starts thread or standalone
notifyConfigMapCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyConfigMapCreated db tracker = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = T.unlines
                [ "*" <> product tracker <> "* | *" <> service tracker <> "* | ConfigMap Release"
                , "Status: *CREATED* | " <> createdBy tracker
                ]
        mTs <- sendSlackMessage channel msg Nothing
        case mTs of
            Just ts -> saveThreadTs db (releaseId tracker) ts
            Nothing -> pure ()

-- | ConfigMap tracker updated — replies in thread
notifyConfigMapUpdated :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyConfigMapUpdated db tracker detail = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        let msg = "*" <> product tracker <> "* | *" <> service tracker <> "* | ConfigMap " <> detail
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()

-- | Generic message in a release's thread
notifyGenericThreadMessage :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyGenericThreadMessage db tracker msg = whenSlackEnabled db $
    withChannel db (product tracker) (service tracker) $ \channel -> do
        _ <- sendSlackMessage channel msg (getThreadTs tracker)
        pure ()
