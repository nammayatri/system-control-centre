{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Slack notification helpers for autopilot release lifecycle.
--
-- Every public function is safe to call from any workflow step:
-- * Checks 'isSlackEnabled' from server_config
-- * Resolves the Slack channel from release_config.slack_webhook_urls
-- * Wraps the HTTP call in try/catch so Slack failures never crash a release
module NammaAP.Products.Autopilot.Notifications
  ( notifyReleaseCreated
  , notifyReleaseApproved
  , notifyReleaseProgress
  , notifyReleaseCompleted
  , notifyReleaseAborted
  , notifyReleasePaused
  , notifyReleaseResumed
  , notifyReleaseReverted
  , notifyPodsScaledDown
  ) where

import Prelude hiding (product)
import Control.Exception (SomeException, try)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Aeson (object, (.=), encode)
import Network.HTTP.Client (newManager, httpLbs, parseRequest, method, requestHeaders, requestBody, RequestBody(..))
import Network.HTTP.Client.TLS (tlsManagerSettings)
import System.Environment (lookupEnv)

import NammaAP.Core.Environment (DBEnv)
import NammaAP.Core.Config.Runtime (isSlackEnabled)
import NammaAP.Products.Autopilot.Types.Release (ReleaseTracker(..))
import NammaAP.Products.Autopilot.Queries.ProductService (findServiceByProductAndName)
import NammaAP.Shared.Types.Storage.Schema (ReleaseConfigT(..))

-- ── Internal helpers ──────────────────────────────────────────────

-- | Read SLACK_BOT_TOKEN from environment.
getSlackToken :: IO (Maybe String)
getSlackToken = lookupEnv "SLACK_BOT_TOKEN"

-- | Resolve the Slack channel for a product+service from release_config.slack_webhook_urls.
getSlackChannel :: DBEnv -> Text -> Text -> IO (Maybe Text)
getSlackChannel db prod svc = do
  mCfg <- findServiceByProductAndName db prod svc
  pure $ case mCfg of
    Just cfg -> releaseConfigSlackWebhookUrls cfg
    Nothing  -> Nothing

-- | Post a message to the Slack API (chat.postMessage).
--
-- Silently logs and returns on any failure.
sendSlackMessage :: Text -> Text -> IO ()
sendSlackMessage channel message = do
  mToken <- getSlackToken
  case mToken of
    Nothing -> putStrLn "[SLACK] No SLACK_BOT_TOKEN env var set, skipping notification"
    Just token -> do
      result <- try $ do
        manager <- newManager tlsManagerSettings
        initReq <- parseRequest "https://slack.com/api/chat.postMessage"
        let body = encode $ object
              [ "channel" .= channel
              , "text"    .= message
              ]
            req = initReq
              { method = "POST"
              , requestHeaders =
                  [ ("Authorization", "Bearer " <> TE.encodeUtf8 (T.pack token))
                  , ("Content-Type", "application/json; charset=utf-8")
                  ]
              , requestBody = RequestBodyLBS body
              }
        _resp <- httpLbs req manager
        putStrLn $ "[SLACK] Sent to #" <> T.unpack channel
      case result of
        Left (err :: SomeException) ->
          putStrLn $ "[SLACK] Error sending message: " <> show err
        Right _ -> pure ()

-- | Guard: only run the action when Slack is enabled in server_config.
whenSlackEnabled :: DBEnv -> IO () -> IO ()
whenSlackEnabled db action = do
  enabled <- isSlackEnabled db
  if enabled
    then action
    else putStrLn "[SLACK] Slack notifications disabled, skipping"

-- | Convenience: resolve channel then send, with full guards.
withChannel :: DBEnv -> Text -> Text -> (Text -> IO ()) -> IO ()
withChannel db prod svc f = do
  mCh <- getSlackChannel db prod svc
  case mCh of
    Nothing -> putStrLn $ "[SLACK] No channel configured for " <> T.unpack prod <> "/" <> T.unpack svc
    Just ch -> f ch

-- ── Public notification functions ─────────────────────────────────

-- | Release created notification.
notifyReleaseCreated :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCreated db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel -> do
    let msg = T.unlines
          [ "*" <> product tracker <> "* | *" <> service tracker <> "* | " <> env tracker <> " Release"
          , oldVersion tracker <> " -> " <> newVersion tracker <> " | " <> createdBy tracker
          , "Status: *CREATED*"
          ]
    sendSlackMessage channel msg

-- | Release approved notification.
notifyReleaseApproved :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseApproved db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel -> do
    let approver = maybe "unknown" id (approvedBy tracker)
        msg = "*" <> product tracker <> "* | *" <> service tracker <> "* approved by " <> approver
    sendSlackMessage channel msg

-- | Release progress (percentage update during rollout).
notifyReleaseProgress :: DBEnv -> ReleaseTracker -> Int -> IO ()
notifyReleaseProgress db tracker percentage = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel -> do
    let pct = T.pack (show percentage)
        msg = T.unlines
          [ "*" <> product tracker <> "* | INPROGRESS | " <> pct <> " %"
          , "Routing " <> pct <> " % to " <> newVersion tracker
          ]
    sendSlackMessage channel msg

-- | Release completed notification.
notifyReleaseCompleted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseCompleted db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel ->
    sendSlackMessage channel $ "*" <> product tracker <> "* | COMPLETED | 100 %"

-- | Release aborted notification.
notifyReleaseAborted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseAborted db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel ->
    sendSlackMessage channel $ "*" <> product tracker <> "* | *" <> service tracker <> "* | ABORTED"

-- | Release paused notification.
notifyReleasePaused :: DBEnv -> ReleaseTracker -> IO ()
notifyReleasePaused db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel ->
    sendSlackMessage channel $ "*" <> product tracker <> "* | *" <> service tracker <> "* | PAUSED"

-- | Release resumed notification.
notifyReleaseResumed :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseResumed db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel ->
    sendSlackMessage channel $ "*" <> product tracker <> "* | *" <> service tracker <> "* | RESUMED"

-- | Release reverted notification.
notifyReleaseReverted :: DBEnv -> ReleaseTracker -> IO ()
notifyReleaseReverted db tracker = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel ->
    sendSlackMessage channel $ "*" <> product tracker <> "* | *" <> service tracker <> "* | REVERTED"

-- | Pods scaled down notification.
notifyPodsScaledDown :: DBEnv -> ReleaseTracker -> Text -> IO ()
notifyPodsScaledDown db tracker oldVer = whenSlackEnabled db $
  withChannel db (product tracker) (service tracker) $ \channel ->
    sendSlackMessage channel $ "*" <> product tracker <> "* | Pods scaled down for version: " <> oldVer
