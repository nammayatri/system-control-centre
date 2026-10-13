{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

{- | HTTP surface of the release bot. Mounted as a suffix of 'CoreAPI'.

None of these routes use the SCC login ('Protected'): they are called by Xyne or
opened from a Xyne link, so each carries its own credential —

  * @POST \/xyne\/events@, @POST \/xyne\/interactions@: HMAC-SHA256 of the RAW body
    in @x-xyne-signature@ (so the body is taken as bytes, not pre-parsed JSON).
    Missing\/invalid signature -> 401, before the body is even parsed.
  * @GET \/public\/release-requests\/:id?t=@: the request's HMAC link token; reads
    only the redacted, read-only review view. Safe to expose without VPN; expose
    ONLY this path (and the two webhooks) publicly.

Every route 404s while @SC_RELEASE_BOT_ENABLED@ is off.
-}
module Products.Autopilot.ReleaseBot.Routes (ReleaseBotAPI, releaseBotServer, decodeWebhookBody) where

import Control.Monad (unless)
import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import qualified Core.AppError as E
import Core.Environment (Flow, forkFlow)
import Data.Aeson (Value (..), decodeStrict, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Text (Text)
import Network.HTTP.Types.URI (urlDecode)
import Products.Autopilot.ReleaseBot.Flow
import qualified Products.Autopilot.ReleaseBot.Xyne as X
import Servant

data RawJSON
data RawForm

instance Accept RawJSON where
    contentType _ = "application/json"
instance Accept RawForm where
    contentType _ = "application/x-www-form-urlencoded"

instance MimeUnrender RawJSON BS.ByteString where
    mimeUnrender _ = Right . LBS.toStrict
instance MimeUnrender RawForm BS.ByteString where
    mimeUnrender _ = Right . LBS.toStrict

type ReleaseBotAPI =
    "xyne" :> "events" :> Header "x-xyne-signature" Text :> ReqBody '[RawJSON, RawForm] BS.ByteString :> Post '[JSON] Value
        :<|> "xyne" :> "interactions" :> Header "x-xyne-signature" Text :> ReqBody '[RawJSON, RawForm] BS.ByteString :> Post '[JSON] Value
        :<|> "public" :> "release-requests" :> Capture "id" Text :> QueryParam "t" Text :> Get '[JSON] Value

releaseBotServer :: ServerT ReleaseBotAPI Flow
releaseBotServer = eventsH :<|> eventsH :<|> publicH

requireEnabled :: Flow ()
requireEnabled = do
    on <- botEnabled
    unless on (throwM (NotFound "not found"))

-- | @payload=<urlencoded json>@ (interactions) or plain JSON.
decodeWebhookBody :: BS.ByteString -> Maybe Value
decodeWebhookBody raw
    | "payload=" `BS.isPrefixOf` raw =
        decodeStrict (urlDecode True (BS.drop (BS.length "payload=") raw))
    | otherwise = decodeStrict raw

eventsH :: Maybe Text -> BS.ByteString -> Flow Value
eventsH msig raw = do
    requireEnabled
    secret <- X.signingSecret
    case secret of
        Just s | X.verifySignature s raw (maybe "" id msig) -> pure ()
        _ -> throwM (E.Unauthorized "invalid signature")
    payload <- maybe (throwM (BadRequest "invalid JSON")) pure (decodeWebhookBody raw)
    case X.parseClick payload of
        Just click -> handleClick click
        Nothing -> case X.parseMention payload of
            Just m -> do
                _ <- forkFlow (handleMention m)
                pure (object ["status" .= ("accepted" :: Text)])
            Nothing -> pure (object ["status" .= ("ignored" :: Text)])

publicH :: Text -> Maybe Text -> Flow Value
publicH rid mt = do
    requireEnabled
    r <- publicRequestView rid mt
    maybe (throwM (NotFound "not found")) pure r
