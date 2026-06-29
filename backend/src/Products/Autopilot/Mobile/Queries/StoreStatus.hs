{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Queries for the @store_status@ cache (migration 0030) — the per-track live
store-state table behind the App Release Monitoring dashboard.

The on-demand refresh writes via 'upsertStoreStatus'; the monitor reads the whole
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
    setProductionRolloutStatus,
    setProductionReleased,
    setProductionReviewStatus,
    listStoreStatus,
    secondsSinceLastSync,
    latestShippedVersionsPerApp,
    findStoreTracksForApp,
    findProductionStoreCell,
    findProductionLiveCell,
    productionVersionsByApp,
    ActiveMobileState (..),
    findActiveMobileState,
) where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Database.Beam
import Database.PostgreSQL.Simple (Only (..), execute, query, query_)
import Database.PostgreSQL.Simple.Types ((:.) (..))
import Products.Autopilot.Mobile.Types.Storage (StoreStatus, StoreStatusT)
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

{- | Optimistically reflect a just-applied production rollout state into the
@store_status@ cache (the App Monitor's source) so the monitor matches the release
list right after a rollout action — without spending a Play/ASC edit to re-read.

Targets only the production track and only the rollout-relevant columns (version,
%, status), preserving the review overlay and notes. @status@ carries the value the
next sync would compute — @"inProgress"@ while ramping/resumed, @"halted"@ while
paused — so the monitor badge derives the same label ("Rolling out X%" / "Halted @
X%") immediately. A no-op if the app has no production row yet (the next real store
refresh fills it). The Phase-7 reconciler reconciles it to the true live value on the
next refresh.
-}
setProductionRolloutStatus :: (MonadFlow m) => Int32 -> Text -> Text -> Maybe Int32 -> Text -> Double -> m ()
setProductionRolloutStatus aid platform version mCode status pct = withDb $ \db -> withConn db $ \conn -> do
    _ <-
        execute
            conn
            "UPDATE store_status SET rollout_percent = ?, status = ?, \
            \  version_name = ?, version_code = ? \
            \ WHERE app_catalog_id = ? AND platform = ? AND track = 'production'"
            (pct, status, version, mCode, aid, platform)
    pure ()

{- | Mirror a COMPLETED production release (100%, fully live) onto the production
row AND clear the review overlay — matching what the next sync computes once the
release leaves @INPROGRESS@ ('findActiveMobileState' → Nothing, so review_status
falls away and the cell reads "Live · 100%" instead of a stale "Approved · held").
Used by @/rollout/release-all@, @/rollout/set@ at 100, and a non-phased iOS release.
-}
setProductionReleased :: (MonadFlow m) => Int32 -> Text -> Text -> Maybe Int32 -> m ()
setProductionReleased aid platform version mCode = withDb $ \db -> withConn db $ \conn -> do
    _ <-
        execute
            conn
            "UPDATE store_status SET rollout_percent = 100, status = 'completed', \
            \  review_status = NULL, version_name = ?, version_code = ? \
            \ WHERE app_catalog_id = ? AND platform = ? AND track = 'production'"
            (version, mCode, aid, platform)
    pure ()

{- | Mirror a production review state (submit / approve / reject) onto the production
row — the same overlay 'findActiveMobileState' applies on the next sync, shown now so
the App Monitor reflects a promote / mark-approved / mark-rejected immediately.
'Nothing' clears the overlay. Touches only @review_status@, leaving the live version
and rollout columns intact.
-}
setProductionReviewStatus :: (MonadFlow m) => Int32 -> Text -> Maybe Text -> m ()
setProductionReviewStatus aid platform mReview = withDb $ \db -> withConn db $ \conn -> do
    _ <-
        execute
            conn
            "UPDATE store_status SET review_status = ? \
            \ WHERE app_catalog_id = ? AND platform = ? AND track = 'production'"
            (mReview, aid, platform)
    pure ()

-- | All cached rows (~40). The monitor groups these by app_catalog_id in Haskell.
listStoreStatus :: (MonadFlow m) => m [StoreStatus]
listStoreStatus = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select (all_ (storeStatuses autopilotDb))

{- | Seconds since this app's most recent track was synced (the freshest
@synced_at@ across its @store_status@ rows). 'Nothing' when the app has no cached
row yet (never synced). Backs the on-demand refresh cooldown: a Play track read
costs a daily-quota'd edit, so a manual ↻ within the cooldown serves cache
instead of re-polling.
-}
secondsSinceLastSync :: (MonadFlow m) => Int32 -> m (Maybe Double)
secondsSinceLastSync aid = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT EXTRACT(EPOCH FROM (now() - max(synced_at)))::double precision \
            \ FROM store_status WHERE app_catalog_id = ?"
            (Only aid)
    pure $ case rows of
        (Only ms : _) -> ms
        [] -> Nothing

{- | The last version SCC itself shipped, per @(app_group, service, env)@ — i.e.
the newest @MobileBuild@ release NOT created by store-sync. Stamped into
@expected_version@ so the monitor can flag a live store version SCC didn't ship
as out-of-band drift. Excluding store-sync rows avoids flagging our own imports
(edge case #7). 'Nothing' for an app SCC has never released → no drift claim.
-}
{- | An app's synced store cells as @(track, version_name, version_code)@, restricted
to cells that carry a version. The changelog-base resolver reads this — the same
@store_status@ cache the monitor reads — so the base diff sources its prod/internal
version from one place instead of a duplicate metadata snapshot.
-}
findStoreTracksForApp :: (MonadFlow m) => Int32 -> m [(Text, Text, Maybe Int32)]
findStoreTracksForApp aid = withDb $ \db -> withConn db $ \conn ->
    query
        conn
        "SELECT track, version_name, version_code FROM store_status \
        \ WHERE app_catalog_id = ? AND version_name IS NOT NULL"
        (Only aid)

{- | The production track's currently-synced @(version_name, version_code)@ for an app
from the @store_status@ cache, or 'Nothing' when production hasn't been synced. Either
field may be NULL. Used by the promote guard to reject re-promoting a build that is
already live on production.
-}
findProductionStoreCell :: (MonadFlow m) => Int32 -> Text -> m (Maybe (Maybe Text, Maybe Int32))
findProductionStoreCell appCatalogId platform = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT version_name, version_code FROM store_status \
            \ WHERE app_catalog_id = ? AND platform = ? AND track = 'production' LIMIT 1"
            (appCatalogId, platform)
    pure $ case rows of
        (r : _) -> Just r
        [] -> Nothing

{- | The production track's serving release as @(version_name, version_code, status,
rollout_percent)@ — the publish gate's "is this build actually live" source. Builds on the
fact that @androidSnapToUpsert@ only writes a @rollout_percent@ when the fraction is at/above
the 1% floor (a real ramp), and stamps @status='completed'@ for a fully-live version: so a
version that is parked below 1% (held/staged) has a NULL @rollout_percent@ and a non-completed
@status@. 'liveOnProduction' reads this to require a serving release (completed OR ramping
>1%), not merely a version present on the track. 'Nothing' when production hasn't synced.
-}
findProductionLiveCell ::
    (MonadFlow m) => Int32 -> Text -> m (Maybe (Maybe Text, Maybe Int32, Maybe Text, Maybe Double))
findProductionLiveCell appCatalogId platform = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT version_name, version_code, status, rollout_percent FROM store_status \
            \ WHERE app_catalog_id = ? AND platform = ? AND track = 'production' LIMIT 1"
            (appCatalogId, platform)
    pure $ case rows of
        (r : _) -> Just r
        [] -> Nothing

{- | Production-track @(version_name, version_code)@ per app @(app_group, service, env)@ from
the store_status cache (joined to app_catalog for the name/surface/platform the release rows
key on). Powers the release list's per-row @promotable@ flag — which compares by version
THEN code — without an N+1 store read. Only cells with a known version are included; the code
may still be NULL.
-}
productionVersionsByApp :: (MonadFlow m) => m (Map.Map (Text, Text, Text) (Text, Maybe Int32))
productionVersionsByApp = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query_
            conn
            "SELECT a.name, a.surface, a.platform, ss.version_name, ss.version_code \
            \ FROM store_status ss JOIN app_catalog a ON a.id = ss.app_catalog_id \
            \ WHERE ss.track = 'production' AND ss.version_name IS NOT NULL"
    pure $ Map.fromList [((n, s, p), (vn, vc)) | (n, s, p, vn, vc) <- rows]

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

{- | The review / rollout state of the ACTIVE (@INPROGRESS@) @MobileBuild@ release
for an app AT A SPECIFIC VERSION, overlaid onto the live production cell. This is
how an Android "in review" reaches the monitor at all (the Play track is opaque),
and how an iOS phased % shows before the next reconcile.

Scoped to @version@ — the version actually shown on the production cell — so a
DIFFERENT in-flight version (e.g. a freshly-submitted review build while an older
version is still rolling out) can't bleed its "in review" onto the live version's
cell. 'Nothing' when that version has nothing in flight → the cell shows pure live
store state.
-}
data ActiveMobileState = ActiveMobileState
    { amsReviewStatus :: Maybe Text
    , amsRolloutStatus :: Maybe Text
    , amsRolloutPercent :: Maybe Double
    }

findActiveMobileState :: (MonadFlow m) => Text -> Text -> Text -> Text -> m (Maybe ActiveMobileState)
findActiveMobileState ag svc env version = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT review_status, rollout_status, rollout_percent \
            \ FROM release_tracker \
            \ WHERE category = 'MobileBuild' AND status = 'INPROGRESS' \
            \   AND app_group = ? AND service = ? AND env = ? AND new_version = ? \
            \ ORDER BY date_created DESC LIMIT 1"
            (ag, svc, env, version)
    pure $ case rows of
        ((rs, rost, rp) : _) -> Just (ActiveMobileState rs rost rp)
        [] -> Nothing
