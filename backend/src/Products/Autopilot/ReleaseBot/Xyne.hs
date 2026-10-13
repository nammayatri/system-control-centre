{-# LANGUAGE OverloadedStrings #-}

{- | Xyne (Slack-compatible) client + webhook payload parsing for the release bot.

Wire facts below were confirmed against the live service by Vishwakarma's Xyne
relay (see @vishwakarma/plugins/relays/xyne/plugin.py@):

  * Auth: @Authorization: Bearer <app JWT>@; API-level failures are HTTP 200 with
    @{"ok": false, "error": ...}@, so 'ok' is always checked.
  * Webhooks are signed with a single @x-xyne-signature@ header = hex HMAC-SHA256
    of the raw body (no timestamp, no @v0:@ prefix).
  * The webhook's conversation/message ids are NOT usable as @thread_ts@; a post
    that fails with @thread_not_found@ is retried top-level.
  * Approval buttons are a native "flow" card posted via @chat/postMessage@; a
    click arrives as @actionId = "<verb>:<request id>"@ + @context.userId@.

Env (never DB): @SC_XYNE_BOT_TOKEN@, @SC_XYNE_SIGNING_SECRET@, optional
@SC_XYNE_BASE_URL@ (default the production Slack-compat endpoint). The outbound
token / base URL fall back to @SLACK_BOT_TOKEN@ / @SLACK_API_BASE_URL@ — the creds
the existing system-control-center-bot already posts with — so no new outbound secret
is needed. (The inbound signing secret IS new: it is issued when the app's webhook is set.)
-}
module Products.Autopilot.ReleaseBot.Xyne (
    Mention (..),
    Click (..),
    approveVerb,
    rejectVerb,
    rolloutApproveVerb,
    rolloutRejectVerb,
    postRolloutCard,
    verifySignature,
    signingSecret,
    parseMention,
    parseClick,
    postText,
    postApprovalCard,
    updateCard,
    getUser,
    botUserId,
    mentionedIds,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Core.Http.Client (HttpError (..), HttpReq (..), HttpResponse (..), Method (..), defaultReq, httpRaw)
import Core.Secrets (lookupEnvSecret)
import Core.Types.Time (Seconds (..))
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import System.IO.Unsafe (unsafePerformIO)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V

approveVerb, rejectVerb :: Text
approveVerb = "scc_release_approve"
rejectVerb = "scc_release_reject"

-- | Verbs of the second card: approve (and so start) / discard the created release trackers.
rolloutApproveVerb, rolloutRejectVerb :: Text
rolloutApproveVerb = "scc_rollout_approve"
rolloutRejectVerb = "scc_rollout_reject"

-- ─── Signature ─────────────────────────────────────────────────────

signingSecret :: (MonadIO m) => m (Maybe Text)
signingSecret = lookupEnvSecret "SC_XYNE_SIGNING_SECRET"

{- | Constant-time check of @x-xyne-signature@ against HMAC-SHA256(secret, body).
An empty secret or signature never verifies.
-}
verifySignature :: Text -> BS.ByteString -> Text -> Bool
verifySignature secret body sig
    | T.null secret || T.null sig = False
    | otherwise =
        let mac = hmac (TE.encodeUtf8 secret) body :: HMAC SHA256
            hex = convertToBase Base16 mac :: BS.ByteString
         in constEq hex (TE.encodeUtf8 (T.toLower (T.strip sig)))

-- ─── Inbound payloads ──────────────────────────────────────────────

data Mention = Mention
    { mChannel :: Text
    , mMessageId :: Text
    , mUserId :: Text
    , mSenderName :: Text
    , mSenderEmail :: Text
    , mText :: Text
    , mMentioned :: [Text]
    -- ^ user ids mentioned in the message (from the HTML @data-user-id@ spans)
    }
    deriving (Show, Eq)

data Click = Click
    { cVerb :: Text
    , cRequestId :: Text
    , cUserId :: Text
    , cUserName :: Text
    , cEmail :: Text
    }
    deriving (Show, Eq)

str :: Text -> Value -> Maybe Text
str k (Object o) = case KM.lookup (K.fromText k) o of
    Just (String t) | not (T.null t) -> Just t
    _ -> Nothing
str _ _ = Nothing

obj :: Text -> Value -> Maybe Value
obj k (Object o) = KM.lookup (K.fromText k) o
obj _ _ = Nothing

-- | @APP_MENTIONED@ -> 'Mention'. Anything else (or no text/channel) -> 'Nothing'.
parseMention :: Value -> Maybe Mention
parseMention v = do
    et <- str "eventType" v
    if et /= "APP_MENTIONED" then Nothing else do
        inner <- obj "payload" v
        text <- str "cleanContent" inner
        channel <- str "channelId" inner
        pure
            Mention
                { mChannel = channel
                , mMessageId = fromMaybe "" (str "messageId" inner)
                , mUserId = fromMaybe "" (str "userId" inner)
                , mSenderName = fromMaybe "" (str "senderName" inner)
                , mSenderEmail = fromMaybe "" (str "senderEmail" inner)
                , mText = T.strip text
                , mMentioned = mentionedIds (fromMaybe "" (str "content" inner))
                }

{- | A button click, in either shape Xyne sends: a flow action
(@actionId = "verb:requestId"@, @context.userId@) or a Slack-style interaction
(@actions[0].action_id/value@, @user@). Unknown verbs -> 'Nothing'.
-}
parseClick :: Value -> Maybe Click
parseClick v = flowShape `orElse` interactionShape `orElse` (obj "payload" v >>= parseClick)
  where
    orElse (Just a) _ = Just a
    orElse Nothing b = b
    known verb = verb `elem` [approveVerb, rejectVerb, rolloutApproveVerb, rolloutRejectVerb]
    flowShape = do
        aid <- str "actionId" v
        let (verb, rest) = T.breakOn ":" aid
            rid = T.drop 1 rest
        if known verb && not (T.null rid)
            then
                let ctx = fromMaybe Null (obj "context" v)
                 in Just Click{cVerb = verb, cRequestId = rid, cUserId = fromMaybe "" (str "userId" ctx), cUserName = "", cEmail = ""}
            else Nothing
    interactionShape = do
        Array as <- obj "actions" v
        a <- case V.toList as of (x : _) -> Just x; [] -> Nothing
        verb <- str "action_id" a
        rid <- str "value" a
        if not (known verb) then Nothing else do
            let user = fromMaybe Null (obj "user" v)
                profile = fromMaybe Null (obj "profile" user)
                email = fromMaybe "" (str "email" user `orElse` str "email" profile `orElse` str "userEmail" v `orElse` str "senderEmail" v)
            pure
                Click
                    { cVerb = verb
                    , cRequestId = rid
                    , cUserId = fromMaybe "" (str "id" user `orElse` str "userId" v)
                    , cUserName = fromMaybe "" (str "name" user)
                    , cEmail = email
                    }

-- | @data-user-id="X"@ values in Xyne's mention HTML, in order, de-duplicated.
mentionedIds :: Text -> [Text]
mentionedIds = dedupe . go
  where
    marker = "data-user-id=\""
    go t = case T.breakOn marker t of
        (_, rest) | T.null rest -> []
        (_, rest) ->
            let afterMarker = T.drop (T.length marker) rest
                (val, remaining) = T.breakOn "\"" afterMarker
             in [val | not (T.null val)] ++ go remaining
    dedupe = foldr (\x acc -> x : filter (/= x) acc) []

-- ─── Outbound ──────────────────────────────────────────────────────

firstSecret :: (MonadIO m) => [String] -> m (Maybe Text)
firstSecret [] = pure Nothing
firstSecret (n : ns) = lookupEnvSecret n >>= maybe (firstSecret ns) (pure . Just)

baseUrl :: (MonadIO m) => m Text
baseUrl = do
    m <- firstSecret ["SC_XYNE_BASE_URL", "SLACK_API_BASE_URL"]
    pure (T.dropWhileEnd (== '/') (fromMaybe "https://spaces.xyne.juspay.net/api/apps/slack" m))

nativeBase :: Text -> Text
nativeBase b = fromMaybe b (T.stripSuffix "/slack" b)

call :: (MonadIO m) => Text -> Value -> m (Either Text Value)
call url body = do
    mTok <- firstSecret ["SC_XYNE_BOT_TOKEN", "SLACK_BOT_TOKEN"]
    case mTok of
        Nothing -> pure (Left "no Xyne bot token (SC_XYNE_BOT_TOKEN or SLACK_BOT_TOKEN) on the backend")
        Just tok -> do
            r <-
                liftIO $
                    httpRaw
                        (defaultReq url)
                            { reqMethod = POST
                            , reqHeaders = [("Authorization", "Bearer " <> tok), ("Content-Type", "application/json")]
                            , reqBody = Just (encode body)
                            , reqTimeout = Seconds 15
                            , reqLogTag = "xyne"
                            }
            pure $ case r of
                Left (HttpExceptionError m) -> Left m
                Left e -> Left (T.pack (show e))
                Right resp
                    | respStatus resp >= 300 -> Left ("Xyne HTTP " <> T.pack (show (respStatus resp)) <> ": " <> T.take 200 (TE.decodeUtf8With (\_ _ -> Just '?') (LBS.toStrict (respBody resp))))
                    | otherwise -> Right (fromMaybe Null (decode (respBody resp)))

-- | Slack-compat API call; HTTP 200 with @ok:false@ is an error.
slackCall :: (MonadIO m) => Text -> Value -> m (Either Text Value)
slackCall method body = do
    b <- baseUrl
    r <- call (b <> "/" <> method) body
    pure $ case r of
        Left e -> Left e
        Right v -> case obj "ok" v of
            Just (Bool True) -> Right v
            _ -> Left (fromMaybe "unknown_error" (str "error" v))

-- | Post a plain message; returns the message ts. Retries top-level on @thread_not_found@.
postText :: (MonadIO m) => Text -> Maybe Text -> Text -> m (Either Text Text)
postText channel mThread text = do
    let body :: Maybe Text -> Value
        body t = object (["channel" .= channel, "text" .= text] ++ maybe [] (\x -> ["thread_ts" .= x]) t)
    r <- slackCall "chat.postMessage" (body mThread)
    r' <- case (r, mThread) of
        (Left "thread_not_found", Just _) -> slackCall "chat.postMessage" (body Nothing)
        _ -> pure r
    pure (r' >>= \v -> Right (fromMaybe "" (str "ts" v)))

flowCard :: Text -> [(Text, Text, Bool)] -> Value
flowCard text buttons =
    object
        [ "version" .= ("2.0" :: Text)
        , "screenId" .= ("scc-release-approval" :: Text)
        , "title" .= ("System Control Centre — release approval" :: Text)
        , "components"
            .= ( [object ["id" .= ("t0" :: Text), "type" .= ("text" :: Text), "props" .= object ["content" .= text]]]
                    ++ [ object
                            [ "id" .= ("row0" :: Text)
                            , "type" .= ("row" :: Text)
                            , "style" .= object ["gap" .= ("8px" :: Text)]
                            , "children"
                                .= [ object
                                        [ "id" .= ("btn" <> T.pack (show i))
                                        , "type" .= ("button" :: Text)
                                        , "props"
                                            .= object
                                                [ "label" .= label
                                                , "variant" .= (if destructive then "destructive" else "primary" :: Text)
                                                , "action" .= object ["type" .= ("submit" :: Text), "actionId" .= aid]
                                                ]
                                        ]
                                   | (i, (label, aid, destructive)) <- zip [0 :: Int ..] buttons
                                   ]
                            ]
                       | not (null buttons)
                       ]
               )
        , "state"
            .= object
                [ "values" .= object []
                , "touched" .= object []
                , "errors" .= object []
                , "submitting" .= False
                , "submitted" .= False
                , "history" .= ([] :: [Value])
                , "loadingComponentIds" .= ([] :: [Value])
                ]
        ]

-- | Post the Approve/Reject card; returns the native message id (needed to update it).
postApprovalCard :: (MonadIO m) => Text -> Text -> Text -> m (Either Text Text)
postApprovalCard channel text requestId = do
    b <- baseUrl
    let flow = flowCard text [("Approve & apply", approveVerb <> ":" <> requestId, False), ("Reject", rejectVerb <> ":" <> requestId, True)]
    r <- call (nativeBase b <> "/chat/postMessage") (object ["channelId" .= channel, "text" .= T.take 300 text, "flow" .= flow])
    pure (r >>= \v -> Right (fromMaybe "" (str "messageId" v)))

-- | Approve/Discard card for freshly created release trackers; returns the native message id.
postRolloutCard :: (MonadIO m) => Text -> Text -> Text -> m (Either Text Text)
postRolloutCard channel text requestId = do
    b <- baseUrl
    let flow = flowCard text [("Approve & start rollout", rolloutApproveVerb <> ":" <> requestId, False), ("Discard release", rolloutRejectVerb <> ":" <> requestId, True)]
    r <- call (nativeBase b <> "/chat/postMessage") (object ["channelId" .= channel, "text" .= T.take 300 text, "flow" .= flow])
    pure (r >>= \v -> Right (fromMaybe "" (str "messageId" v)))

-- | Replace a card with plain text (buttons removed) once a decision is final.
updateCard :: (MonadIO m) => Text -> Text -> Text -> m (Either Text ())
updateCard channel messageId text = do
    b <- baseUrl
    r <- call (nativeBase b <> "/chat/updateMessage") (object ["channelId" .= channel, "messageId" .= messageId, "text" .= T.take 300 text, "flowJSON" .= flowCard text []])
    pure (() <$ r)

-- | (display name, email) for a Xyne user id; empty strings when unknown.
getUser :: (MonadIO m) => Text -> m (Text, Text)
getUser uid
    | T.null uid = pure ("", "")
    | otherwise = do
        r <- slackCall "users.info" (object ["user" .= uid])
        pure $ case r of
            Left _ -> ("", "")
            Right v ->
                let u = fromMaybe Null (obj "user" v)
                    profile = fromMaybe Null (obj "profile" u)
                    name = fromMaybe "" (str "real_name" u `orElse'` str "name" u `orElse'` str "display_name" profile)
                 in (name, fromMaybe "" (str "email" profile))
  where
    orElse' (Just a) _ = Just a
    orElse' Nothing b = b


{-# NOINLINE botIdCache #-}
botIdCache :: IORef (Maybe Text)
botIdCache = unsafePerformIO (newIORef Nothing)

{- | This app's own Xyne user id (via @auth.test@), cached after the first success.
'Nothing' when it cannot be determined — callers then do not filter mentions.
-}
botUserId :: (MonadIO m) => m (Maybe Text)
botUserId = do
    cached <- liftIO (readIORef botIdCache)
    case cached of
        Just i -> pure (Just i)
        Nothing -> do
            r <- slackCall "auth.test" (object [])
            case r >>= maybe (Left "no user_id") Right . str "user_id" of
                Right i -> liftIO (writeIORef botIdCache (Just i)) >> pure (Just i)
                Left _ -> pure Nothing
