{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.Webhooks (
    dispatchTerminalWebhooks,
    fireWebhook,
    releasePlaceholderEnv,
    triggerForStatus,
)
where

import Control.Monad (forM_, unless, void)
import Control.Monad.Catch (catch, throwM)
import Control.Monad.IO.Class (liftIO)
import Core.Environment (Flow, forkFlow)
import Core.Http.Client (
    HttpError (..),
    HttpReq (..),
    HttpResponse (..),
    Method (..),
    defaultReq,
    httpRaw,
 )
import Core.Logging (logErrorG, logInfoG)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Database.PostgreSQL.Simple (SqlError (..))
import GHC.Int (Int32)
import Network.HTTP.Types.URI (urlEncode)
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseEvent)
import Products.Autopilot.Queries.ReleaseWebhook (listWebhooksForRelease)
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..))
import Products.Autopilot.Types.Webhook

evWebhookSent, evWebhookFailed :: Text
evWebhookSent = "WEBHOOK_SENT"
evWebhookFailed = "WEBHOOK_FAILED"

{- | Per-trigger "already dispatched" marker. A release can be terminalized from
more than one place (a runner tick and a user-facing handler racing on the same
abort); a duplicate Slack line is harmless, a duplicate outbound call is not.
-}
dispatchLabel :: WebhookTrigger -> Text
dispatchLabel OnSuccess = "WEBHOOK_DISPATCH_SUCCESS"
dispatchLabel OnFailure = "WEBHOOK_DISPATCH_FAILURE"

defaultTimeout :: Int32
defaultTimeout = 10

-- | 'httpRaw' retries on transport errors and 5xx only; a 4xx is the
-- receiver's answer, not a blip.
defaultRetries :: Int32
defaultRetries = 1

maxRecordedBody :: Int
maxRecordedBody = 512

-- | Must resolve everything 'availablePlaceholders' documents.
releasePlaceholderEnv :: ReleaseTracker -> PlaceholderEnv
releasePlaceholderEnv rt =
    [ ("NEW_VERSION", newVersion rt)
    , ("OLD_VERSION", oldVersion rt)
    ]

{- | The outcome a status reports to a webhook, or 'Nothing' while the release is
still in flight. ABORTING is the abort *request* — the terminal status that
follows is what gets dispatched, so a receiver is never told a release failed
while traffic is still being rolled back.
-}
triggerForStatus :: ReleaseStatus -> Maybe WebhookTrigger
triggerForStatus st = case st of
    COMPLETED -> Just OnSuccess
    ABORTED -> Just OnFailure
    USER_ABORTED -> Just OnFailure
    GCLT_ABORTED -> Just OnFailure
    DISCARDED -> Just OnFailure
    CREATED -> Nothing
    INPROGRESS -> Nothing
    DISCARDING -> Nothing
    PAUSED -> Nothing
    ABORTING -> Nothing
    REVERTING -> Nothing
    REVERTED -> Nothing
    RESTARTING -> Nothing
    LOCKED -> Nothing
    UNLOCKED -> Nothing
    APPLIED -> Nothing

dispatchTerminalWebhooks :: ReleaseTracker -> Flow ()
dispatchTerminalWebhooks tracker =
    maybe (pure ()) (`dispatchReleaseWebhooks` tracker) (triggerForStatus (status tracker))

-- | Fire every hook covering this release's app group + service that opted into
-- @trigger@. Returns immediately; lookup and HTTP happen on a forked thread.
dispatchReleaseWebhooks :: WebhookTrigger -> ReleaseTracker -> Flow ()
dispatchReleaseWebhooks trigger tracker = void $ forkFlow $ do
    hooks <- listWebhooksForRelease (appGroup tracker) (service tracker)
    let matching = filter (triggersOn trigger) hooks
        rid = releaseId tracker
        label = dispatchLabel trigger
    unless (null matching) $ do
        claimed <-
            claimDispatch rid label $
                object ["trigger" .= webhookTriggerToText trigger, "hooks" .= map whName matching]
        if not claimed
            then logInfoG $ "[release-webhook] " <> rid <> " already dispatched " <> label <> ", skipping"
            else do
                logInfoG $
                    "[release-webhook] "
                        <> webhookTriggerToText trigger
                        <> " "
                        <> rid
                        <> ": firing "
                        <> T.pack (show (length matching))
                        <> " hook(s)"
                forM_ matching $ \wh -> do
                    result <- liftIO (fireWebhook (releasePlaceholderEnv tracker) wh)
                    recordOutcome tracker trigger wh result

{- | Claim the right to dispatch, returning 'False' if another writer holds it.
The partial unique index on the marker labels (migration 0050) makes the insert
itself the claim, rather than a read the racing thread could also pass.

The claim is taken /before/ delivery, so this is at-most-once: a crash between
the claim and the HTTP call drops the notification permanently. Deliberate — a
duplicate outbound call is worse here than a missed one.
-}
claimDispatch :: Text -> Text -> Value -> Flow Bool
claimDispatch rid label payload =
    (True <$ insertReleaseEvent rid "BUSINESS" label payload)
        `catch` \e ->
            if sqlState e == "23505" then pure False else throwM (e :: SqlError)

-- | Put "did it go out?" on the release timeline, next to the rest of its history.
recordOutcome :: ReleaseTracker -> WebhookTrigger -> ReleaseWebhook -> WebhookTestResult -> Flow ()
recordOutcome tracker trigger wh result = do
    let payload =
            object
                [ "webhook" .= whName wh
                , "trigger" .= webhookTriggerToText trigger
                , "method" .= wtrRequestMethod result
                , "url" .= wtrRequestUrl result
                , "status" .= wtrResponseStatus result
                , "error" .= wtrError result
                ]
    if wtrOk result
        then do
            logInfoG $
                "[release-webhook] "
                    <> whName wh
                    <> " -> HTTP "
                    <> maybe "?" (T.pack . show) (wtrResponseStatus result)
            insertReleaseEvent (releaseId tracker) "BUSINESS" evWebhookSent payload
        else do
            logErrorG $
                "[release-webhook] "
                    <> whName wh
                    <> " failed: "
                    <> fromMaybe "unknown error" (wtrError result)
            insertReleaseEvent (releaseId tracker) "BUSINESS" evWebhookFailed payload

-- | Never throws — transport failures come back as a failed result. 2xx/3xx is
-- delivered, 4xx/5xx is not.
fireWebhook :: PlaceholderEnv -> ReleaseWebhook -> IO WebhookTestResult
fireWebhook env wh = do
    let render = renderTemplate env
        url = buildUrl env wh
        hdrs = [(render (kvKey kv), render (kvValue kv)) | kv <- whHeaders wh, not (T.null (T.strip (kvKey kv)))]
        rawBody = fmap render (whBody wh)
        hasBody = maybe False (not . T.null . T.strip) rawBody
        -- Most receivers reject a body with no Content-Type.
        hdrsWithCt
            | hasBody && not (any (isHeader "content-type") hdrs) = hdrs <> [("Content-Type", "application/json")]
            | otherwise = hdrs
        req =
            (defaultReq url)
                { reqMethod = toHttpMethod (whMethod wh)
                , reqHeaders = hdrsWithCt
                , reqBody = if hasBody then LBS.fromStrict . TE.encodeUtf8 <$> rawBody else Nothing
                , reqTimeout = Seconds (fromIntegral (fromMaybe defaultTimeout (whTimeoutSeconds wh)))
                , reqRetries = fromIntegral (max 0 (fromMaybe defaultRetries (whRetries wh)))
                , reqLogTag = "release-webhook"
                }
    outcome <- httpRaw req
    pure $ case outcome of
        Left err ->
            (emptyResult url){wtrOk = False, wtrError = Just (describeError err)}
        Right resp ->
            (emptyResult url)
                { wtrOk = respStatus resp >= 200 && respStatus resp < 400
                , wtrResponseStatus = Just (respStatus resp)
                , wtrResponseBody = Just (truncateBody (respBody resp))
                , wtrError =
                    if respStatus resp >= 400
                        then Just ("HTTP " <> T.pack (show (respStatus resp)))
                        else Nothing
                }
  where
    emptyResult u =
        WebhookTestResult
            { wtrOk = False
            , wtrRequestMethod = webhookMethodToText (whMethod wh)
            , wtrRequestUrl = u
            , wtrResponseStatus = Nothing
            , wtrResponseBody = Nothing
            , wtrError = Nothing
            }
    isHeader n (k, _) = T.toLower k == n

-- | Query params are encoded AFTER substitution, so a version containing @+@ or
-- a space still yields a valid URL.
buildUrl :: PlaceholderEnv -> ReleaseWebhook -> Text
buildUrl env wh
    | null pairs = base
    | otherwise = base <> separator <> T.intercalate "&" pairs
  where
    base = renderTemplate env (whUrl wh)
    separator = if "?" `T.isInfixOf` base then "&" else "?"
    pairs =
        [ enc (renderTemplate env (kvKey kv)) <> "=" <> enc (renderTemplate env (kvValue kv))
        | kv <- whQueryParams wh
        , not (T.null (T.strip (kvKey kv)))
        ]
    enc = TE.decodeUtf8With TEE.lenientDecode . urlEncode True . TE.encodeUtf8

toHttpMethod :: WebhookMethod -> Method
toHttpMethod WH_GET = GET
toHttpMethod WH_POST = POST
toHttpMethod WH_PUT = PUT
toHttpMethod WH_PATCH = PATCH
toHttpMethod WH_DELETE = DELETE

describeError :: HttpError -> Text
describeError (HttpExceptionError t) = t
describeError (HttpStatusError s b) = "HTTP " <> T.pack (show s) <> ": " <> truncateBody b
describeError (HttpDecodeError e) = "decode error: " <> T.pack e

truncateBody :: LBS.ByteString -> Text
truncateBody lbs =
    let t = TE.decodeUtf8With TEE.lenientDecode (LBS.toStrict (LBS.take (fromIntegral maxRecordedBody + 1) lbs))
     in if T.length t > maxRecordedBody then T.take maxRecordedBody t <> "..." else t
