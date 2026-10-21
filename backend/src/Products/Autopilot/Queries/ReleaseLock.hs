{-# LANGUAGE OverloadedStrings #-}

{- | Storage for release locks (@release_lock@, migration 0056).

A lock stops NEW releases for an app group (service = "") or a single service.
Reads are one indexed lookup, cheap enough to run on every release create.
-}
module Products.Autopilot.Queries.ReleaseLock (
    ReleaseLock (..),
    listReleaseLocks,
    findBlockingLock,
    setReleaseLock,
    clearReleaseLock,
)
where

import Control.Monad (void)
import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.PostgreSQL.Simple (execute, query)
import GHC.Generics (Generic)

-- | @service@ is empty for a group-wide lock.
data ReleaseLock = ReleaseLock
    { appGroup :: Text
    , service :: Text
    , reason :: Text
    , lockedBy :: Text
    , lockedAt :: UTCTime
    }
    deriving (Show, Eq, Generic)

instance ToJSON ReleaseLock

fromRow' :: (Text, Text, Text, Text, UTCTime) -> ReleaseLock
fromRow' (g, s, r, b, t) = ReleaseLock g s r b t

-- | Every lock, or just one app group's (group lock plus its service locks).
listReleaseLocks :: (MonadFlow m) => Maybe Text -> m [ReleaseLock]
listReleaseLocks mGroup = withDb $ \db -> withConn db $ \conn ->
    map fromRow'
        <$> case mGroup of
            Nothing ->
                query conn "SELECT app_group, service, reason, locked_by, locked_at FROM release_lock ORDER BY app_group, service" ()
            Just g ->
                query conn "SELECT app_group, service, reason, locked_by, locked_at FROM release_lock WHERE app_group = ? ORDER BY service" [g]

-- | The lock that blocks a new release of (group, service), if any. The group
-- lock wins when both exist so the message names the wider scope.
findBlockingLock :: (MonadFlow m) => Text -> Text -> m (Maybe ReleaseLock)
findBlockingLock g s = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT app_group, service, reason, locked_by, locked_at FROM release_lock \
            \WHERE app_group = ? AND service IN ('', ?) ORDER BY service LIMIT 1"
            (g, s)
    pure $ case rows of
        (r : _) -> Just (fromRow' r)
        [] -> Nothing

-- | Idempotent: re-locking refreshes the reason and holder.
setReleaseLock :: (MonadFlow m) => Text -> Text -> Text -> Text -> m ()
setReleaseLock g s why by = withDb $ \db -> withConn db $ \conn ->
    void $
        execute
            conn
            "INSERT INTO release_lock (app_group, service, reason, locked_by) VALUES (?, ?, ?, ?) \
            \ON CONFLICT (app_group, service) DO UPDATE \
            \SET reason = EXCLUDED.reason, locked_by = EXCLUDED.locked_by, locked_at = now()"
            (g, s, why, by)

clearReleaseLock :: (MonadFlow m) => Text -> Text -> m ()
clearReleaseLock g s = withDb $ \db -> withConn db $ \conn ->
    void $ execute conn "DELETE FROM release_lock WHERE app_group = ? AND service = ?" (g, s)
