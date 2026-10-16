{-# LANGUAGE OverloadedStrings #-}

{- | The no-VPN, read-only review page link of a release-bot request. Shared by the bot's own
messages and by the tracker notifications, which show it instead of the (VPN-only) SCC page for
trackers the bot created.
-}
module Products.Autopilot.ReleaseBot.PublicLink (
    linkToken,
    publicRequestLink,
    requestIdOfGlobalId,
) where

import Control.Monad.IO.Class (MonadIO)
import Core.Secrets (lookupEnvSecret)
import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- | Hex HMAC-SHA256 of the request id; the capability in the no-VPN link.
linkToken :: Text -> Text -> Text
linkToken secret rid =
    let mac = hmac (TE.encodeUtf8 secret) (TE.encodeUtf8 rid) :: HMAC SHA256
     in TE.decodeUtf8 (convertToBase Base16 mac :: BS.ByteString)

publicRequestLink :: (MonadIO m) => Text -> m (Maybe Text)
publicRequestLink rid = do
    base <- lookupEnvSecret "SC_PUBLIC_BASE_URL"
    sec <- lookupEnvSecret "SC_RELEASE_BOT_LINK_SECRET"
    pure $ case (base, sec) of
        (Just b, Just s) -> Just (T.dropWhileEnd (== '/') b <> "/r/" <> rid <> "?t=" <> linkToken s rid)
        _ -> Nothing

{- | Trackers created by the bot carry @<request uuid>-<service>@ as their global id.
Anything else (hand-made trackers) is not a bot tracker.
-}
requestIdOfGlobalId :: Text -> Maybe Text
requestIdOfGlobalId g =
    let (rid, rest) = T.splitAt 36 g
     in if T.length rid == 36 && T.length (T.filter (== '-') rid) == 4 && "-" `T.isPrefixOf` rest && T.length rest > 1
            then Just rid
            else Nothing
