{-# LANGUAGE OverloadedStrings #-}

{- | DB access for the Airborne OTA product. The app list is driven live off
airborne (no local mapping table), so the only persistence here is the
per-mutation audit trail, keyed on the airborne @(org, app)@ identity.
-}
module Products.AirborneOta.Queries (
    insertAirborneEvent,
    AirborneEventRow (..),
    listAirborneEvents,
)
where

import Control.Monad (void)
import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (execute, query, (:.) (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)

{- | Audit one proxied mutation: SCC actor, target app (org + app, split from
the @org~app@ ref), action, upstream endpoint, request body, upstream status
+ x-request-id (for correlating with airborne/CDN logs).
-}
insertAirborneEvent ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    Text ->
    Maybe Value ->
    Int ->
    Maybe Text ->
    m ()
insertAirborneEvent actor appRef action endpoint mReq status mReqId =
    withDb $ \db -> withConn db $ \conn ->
        void $
            execute
                conn
                "INSERT INTO airborne_events \
                \  (actor, airborne_org, airborne_app, action, endpoint, request, upstream_status, upstream_request_id) \
                \VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                (actor, org, app, action, endpoint, mReq, status, mReqId)
  where
    (org, app) = case T.breakOn "~" appRef of
        (o, rest) | not (T.null rest) -> (o, T.drop 1 rest)
        _ -> ("", appRef)

{- | One audit row, plus the total size of the filtered set (via a window
count) so the envelope's total needs no second query.
-}
data AirborneEventRow = AirborneEventRow
    { aeId :: Int64
    , aeActor :: Text
    , aeOrg :: Maybe Text
    , aeApp :: Maybe Text
    , aeAction :: Text
    , aeEndpoint :: Text
    , aeRequest :: Maybe Value
    , aeUpstreamStatus :: Maybe Int
    , aeUpstreamRequestId :: Maybe Text
    , aeCreatedAt :: UTCTime
    , aeTotal :: Int64
    }

instance FromRow AirborneEventRow where
    fromRow =
        AirborneEventRow
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

{- | Audit rows, newest first. 'Nothing' for the app ref means fleet-wide —
the CALLER is responsible for gating that (product-level check), since a
per-app grant must not read another app's trail.

Ordered by @(created_at, id)@ because @created_at@ alone is not unique: a bare
timestamp sort makes LIMIT/OFFSET paging skip and repeat rows.
-}
listAirborneEvents ::
    (MonadFlow m) =>
    -- | app ref @\<org\>~\<app\>@; Nothing = all apps
    Maybe Text ->
    -- | action filter
    Maybe Text ->
    -- | page, 1-based (pre-validated)
    Int ->
    -- | page size (pre-clamped)
    Int ->
    m [AirborneEventRow]
listAirborneEvents mAppRef mAction page count =
    withDb $ \db -> withConn db $ \conn ->
        query
            conn
            "SELECT id, actor, airborne_org, airborne_app, action, endpoint, request, \
            \       upstream_status, upstream_request_id, created_at, count(*) OVER () \
            \FROM airborne_events \
            \WHERE (?::text IS NULL OR airborne_org = ?) \
            \  AND (?::text IS NULL OR airborne_app = ?) \
            \  AND (?::text IS NULL OR action = ?) \
            \ORDER BY created_at DESC, id DESC \
            \LIMIT ? OFFSET ?"
            ((org, org, app, app) :. (mAction, mAction, count, (page - 1) * count))
  where
    (org, app) = case mAppRef of
        Nothing -> (Nothing, Nothing)
        Just ref -> case T.breakOn "~" ref of
            (o, rest) | not (T.null rest) -> (Just o, Just (T.drop 1 rest))
            _ -> (Just "", Just ref)
