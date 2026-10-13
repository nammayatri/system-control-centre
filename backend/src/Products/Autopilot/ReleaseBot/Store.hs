{-# LANGUAGE OverloadedStrings #-}

{- | Persistence for release-bot requests (@release_request@, migration 0053).

Hot columns (state, expiry, dedupe key) are real columns; everything else is in
the JSONB @data@ column. All state transitions are compare-and-set on @state@
and all partial updates are @data = data || patch@, so the webhook handler, the
approval click and the worker can never overwrite each other.
-}
module Products.Autopilot.ReleaseBot.Store (
    Req (..),
    terminalStates,
    insertRequest,
    getRequest,
    patchRequest,
    transition,
    claimDecision,
    claimFlag,
    listActive,
    dField,
    dText,
    dTexts,
) where

import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import qualified Data.Vector as V
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Database.PostgreSQL.Simple.Types (In (..))

data Req = Req
    { rqId :: Text
    , rqState :: Text
    , rqChannel :: Maybe Text
    , rqRequester :: Maybe Text
    , rqExpiresAt :: Maybe UTCTime
    , rqData :: Value
    }
    deriving (Show)

terminalStates :: [Text]
terminalStates = ["COMPLETED", "REJECTED", "EXPIRED", "FAILED", "DENIED", "INFO_ONLY"]

type Row = (Text, Text, Maybe Text, Maybe Text, Maybe UTCTime, Value)

fromRow :: Row -> Req
fromRow (i, s, c, e, x, d) = Req i s c e x d

{- | Insert a new request. 'False' when @xyne_message_id@ was already seen (a
webhook retry) — the caller must then do nothing.
-}
insertRequest :: (MonadFlow m) => Text -> Text -> Maybe Text -> Text -> Text -> UTCTime -> Value -> m Bool
insertRequest rid st msgId channel email expires dat = withDb $ \db -> withConn db $ \c -> do
    n <-
        execute
            c
            "INSERT INTO release_request (id, state, xyne_message_id, xyne_channel, requester_email, expires_at, data) \
            \VALUES (?, ?, ?, ?, ?, ?, ?::jsonb) ON CONFLICT DO NOTHING"
            (rid, st, msgId, channel, email, expires, dat)
    pure (n > 0)

getRequest :: (MonadFlow m) => Text -> m (Maybe Req)
getRequest rid = withDb $ \db -> withConn db $ \c -> do
    rows <-
        query
            c
            "SELECT id, state, xyne_channel, requester_email, expires_at, data FROM release_request WHERE id = ?"
            (Only rid)
    pure (fromRow <$> headMay rows)

-- | Merge @patch@ (a JSON object) into @data@.
patchRequest :: (MonadFlow m) => Text -> Value -> m ()
patchRequest rid patch = withDb $ \db -> withConn db $ \c -> do
    _ <- execute c "UPDATE release_request SET data = data || ?::jsonb, updated_at = now() WHERE id = ?" (patch, rid)
    pure ()

-- | CAS state change. 'False' when the row was not in @from@ (someone else moved it).
transition :: (MonadFlow m) => Text -> Text -> Text -> Value -> m Bool
transition rid from to patch = withDb $ \db -> withConn db $ \c -> do
    n <-
        execute
            c
            "UPDATE release_request SET state = ?, data = data || ?::jsonb, updated_at = now() WHERE id = ? AND state = ?"
            (to, patch, rid, from)
    pure (n > 0)

{- | Atomically move AWAITING_APPROVAL -> @to@ (APPROVED / REJECTED) iff it has not
expired. Exactly one concurrent clicker wins; 'Nothing' for everyone else.
-}
claimDecision :: (MonadFlow m) => Text -> Text -> Value -> m (Maybe Req)
claimDecision rid to patch = withDb $ \db -> withConn db $ \c -> do
    rows <-
        query
            c
            "UPDATE release_request SET state = ?, data = data || ?::jsonb, updated_at = now() \
            \WHERE id = ? AND state = 'AWAITING_APPROVAL' AND (expires_at IS NULL OR expires_at > now()) \
            \RETURNING id, state, xyne_channel, requester_email, expires_at, data"
            (to, patch, rid)
    pure (fromRow <$> headMay rows)

{- | Once-only latch: sets @data.<flag> = true@ and returns 'True' only for the single
caller that flipped it. Used so replicated workers send each notification once.
-}
claimFlag :: (MonadFlow m) => Text -> Text -> m Bool
claimFlag rid flag = withDb $ \db -> withConn db $ \c -> do
    n <-
        execute
            c
            "UPDATE release_request SET data = jsonb_set(data, ARRAY[?], 'true'::jsonb), updated_at = now() \
            \WHERE id = ? AND NOT jsonb_exists(data, ?)"
            (flag, rid, flag)
    pure (n > 0)

listActive :: (MonadFlow m) => m [Req]
listActive = withDb $ \db -> withConn db $ \c -> do
    rows <-
        query
            c
            "SELECT id, state, xyne_channel, requester_email, expires_at, data FROM release_request \
            \WHERE state NOT IN ? ORDER BY created_at LIMIT 200"
            (Only (In terminalStates))
    pure (map fromRow rows)

-- ─── tiny JSON accessors over the data blob ────────────────────────

dField :: Text -> Value -> Maybe Value
dField k (Object o) = KM.lookup (K.fromText k) o
dField _ _ = Nothing

dText :: Text -> Value -> Maybe Text
dText k v = case dField k v of
    Just (String t) | not (T.null t) -> Just t
    _ -> Nothing

dTexts :: Text -> Value -> [Text]
dTexts k v = case dField k v of
    Just (Array a) -> [t | String t <- V.toList a]
    _ -> []

headMay :: [a] -> Maybe a
headMay (x : _) = Just x
headMay [] = Nothing

