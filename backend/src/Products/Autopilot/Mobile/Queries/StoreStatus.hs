{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Queries for the @store_status@ cache (migration 0030) — the per-track live
store-state table behind the App Release Monitoring dashboard.

The poller / refresh writes via 'upsertStoreStatus'; the monitor reads the whole
table in one shot via 'listStoreStatus'. Two small @release_tracker@ reads enrich
the cache: 'latestShippedVersionsPerApp' (the last SCC-shipped version, for drift)
and 'findActiveMobileState' (an active review/rollout to overlay on the live
production cell — Play never exposes review state, so this is the only way an
Android "in review" surfaces). Polymorphic in 'MonadFlow' per the codebase
convention.
-}
module Products.Autopilot.Mobile.Queries.StoreStatus (
    StoreStatusUpsert (..),
    upsertStoreStatus,
    listStoreStatus,
    latestShippedVersionsPerApp,
    ActiveMobileState (..),
    findActiveMobileState,
) where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Database.Beam
import Database.PostgreSQL.Simple (execute, query, query_)
import Database.PostgreSQL.Simple.Types ((:.) (..))
import Products.Autopilot.Mobile.Types.Storage (StoreStatus, StoreStatusT (..))
import Products.Autopilot.Types.Storage.Schema (AutopilotDb (..), autopilotDb)

-- | Fields written on a poll. @synced_at@ is stamped @now()@ by the upsert.
data StoreStatusUpsert = StoreStatusUpsert
    { ssuAppCatalogId :: Int32
    , ssuPlatform :: Text
    , ssuTrack :: Text
    , ssuVersionName :: Maybe Text
    , ssuVersionCode :: Maybe Int32
    , ssuStatus :: Maybe Text
    , ssuRolloutPercent :: Maybe Double
    , ssuReviewStatus :: Maybe Text
    , ssuReleaseNotes :: Maybe Text
    , ssuExpectedVersion :: Maybe Text
    }

{- | Upsert one track's live state. ON CONFLICT (app_catalog_id, platform, track)
overwrites every value column and re-stamps @synced_at@, so a re-poll always
reflects the latest store read. Raw SQL keeps the multi-column DO UPDATE readable
(the 10 params are split with @(:.)@ to stay within tuple ToRow limits).
-}
upsertStoreStatus :: (MonadFlow m) => StoreStatusUpsert -> m ()
upsertStoreStatus u = withDb $ \db -> withConn db $ \conn -> do
    _ <-
        execute
            conn
            "INSERT INTO store_status \
            \ (app_catalog_id, platform, track, version_name, version_code, status, \
            \  rollout_percent, review_status, release_notes, expected_version, synced_at) \
            \ VALUES (?,?,?,?,?,?,?,?,?,?, now()) \
            \ ON CONFLICT (app_catalog_id, platform, track) DO UPDATE SET \
            \  version_name = EXCLUDED.version_name, \
            \  version_code = EXCLUDED.version_code, \
            \  status = EXCLUDED.status, \
            \  rollout_percent = EXCLUDED.rollout_percent, \
            \  review_status = EXCLUDED.review_status, \
            \  release_notes = EXCLUDED.release_notes, \
            \  expected_version = EXCLUDED.expected_version, \
            \  synced_at = now()"
            ( (ssuAppCatalogId u, ssuPlatform u, ssuTrack u, ssuVersionName u, ssuVersionCode u, ssuStatus u)
                :. (ssuRolloutPercent u, ssuReviewStatus u, ssuReleaseNotes u, ssuExpectedVersion u)
            )
    pure ()

-- | All cached rows (~40). The monitor groups these by app_catalog_id in Haskell.
listStoreStatus :: (MonadFlow m) => m [StoreStatus]
listStoreStatus = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select (all_ (storeStatuses autopilotDb))

{- | The last version SCC itself shipped, per @(app_group, service, env)@ — i.e.
the newest @MobileBuild@ release NOT created by store-sync. Stamped into
@expected_version@ so the monitor can flag a live store version SCC didn't ship
as out-of-band drift. Excluding store-sync rows avoids flagging our own imports
(edge case #7). 'Nothing' for an app SCC has never released → no drift claim.
-}
latestShippedVersionsPerApp :: (MonadFlow m) => m (Map.Map (Text, Text, Text) Text)
latestShippedVersionsPerApp = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query_
            conn
            "SELECT app_group, service, env, new_version \
            \ FROM release_tracker \
            \ WHERE category = 'MobileBuild' AND release_manager <> 'store-sync' \
            \ ORDER BY date_created DESC"
    -- Input is newest-first; on a key collision keep the value already inserted
    -- (the newer row) and drop the later (older) one.
    pure $ Map.fromListWith (\_older keep -> keep) [((ag, svc, env), ver) | (ag, svc, env, ver) <- rows]

{- | The review / rollout state of the most recent ACTIVE (@INPROGRESS@)
@MobileBuild@ release for an app, overlaid onto the live production cell. This is
how an Android "in review" reaches the monitor at all (the Play track is opaque),
and how an iOS phased % shows before the next reconcile. 'Nothing' when nothing
is in flight → the cell shows pure live store state.
-}
data ActiveMobileState = ActiveMobileState
    { amsReviewStatus :: Maybe Text
    , amsRolloutStatus :: Maybe Text
    , amsRolloutPercent :: Maybe Double
    }

findActiveMobileState :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe ActiveMobileState)
findActiveMobileState ag svc env = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT review_status, rollout_status, rollout_percent \
            \ FROM release_tracker \
            \ WHERE category = 'MobileBuild' AND status = 'INPROGRESS' \
            \   AND app_group = ? AND service = ? AND env = ? \
            \ ORDER BY date_created DESC LIMIT 1"
            (ag, svc, env)
    pure $ case rows of
        ((rs, rost, rp) : _) -> Just (ActiveMobileState rs rost rp)
        [] -> Nothing
