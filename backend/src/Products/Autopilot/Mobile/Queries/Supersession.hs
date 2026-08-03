{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Slot-supersession rules for the version-keyed mobile release model
(migration 0034). Both rules transition the OTHER production-track versions of an
app to HISTORY when a new version takes a slot, so the live + incoming slots each
hold exactly one version. Pure DB transitions; callers log the returned ids.

  * Rule A — 'supersedePreviousLive': when a version starts rolling out, the
    previously-live version (a different version still rolling / halted) freezes
    at its last % and becomes @rollout_status = 'superseded'@ history.
  * Rule B — 'retireOlderIncoming': when a version enters the incoming slot
    (review / approved / rejected), any OTHER incoming version drops to history.
-}
module Products.Autopilot.Mobile.Queries.Supersession (
    supersedePreviousLive,
    retireOlderIncoming,
    supersedeRebuiltSameVersion,
    convergeMobileSlots,
    bestActiveInternalBuild,
)
where

import Control.Monad (forM_)
import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Int (Int32)
import Data.Text (Text)
import Database.Beam
import Database.Beam.Postgres (Postgres)
import Database.PostgreSQL.Simple (Only (..), query)
import Products.Autopilot.Types.Storage.Schema (
    AutopilotDb (..),
    ReleaseTrackerT (..),
    autopilotDb,
 )

{- | Scope shared by both rules: another production-track MobileBuild BUILD of the
same app, excluding the one taking the slot (by id). Excludes by build id only —
NOT by version name — because builds are identified by (name + build number)
(migration 0035), so a different-code build of the SAME name (e.g. 3.3.16+396
superseding 3.3.16+395) must still be caught.
-}
otherProductionBuild ::
    Text -> Text -> Text -> Text -> ReleaseTrackerT (QExpr Postgres s) -> QExpr Postgres s Bool
otherProductionBuild appGroup surface platform excludeRid rt =
    rtAppGroup rt ==. val_ appGroup
        &&. rtService rt ==. val_ surface
        &&. rtEnv rt ==. val_ platform
        &&. rtCategory rt ==. val_ "MobileBuild"
        &&. rtStoreTrack rt ==. val_ (Just "production")
        &&. rtId rt /=. val_ excludeRid

{- | Rule A. Freeze the previous live version (different version, still rolling out /
halted below 100%) at its last percent and mark it @superseded@ → HISTORY. A
version already at completed/100% is left alone (it drops to history by version
order on its own). Returns the affected release ids for the caller to log.
-}
supersedePreviousLive ::
    (MonadFlow m) => Text -> Text -> Text -> Text -> m [Text]
supersedePreviousLive appGroup surface platform excludeRid = withDb $ \db -> do
    ids <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (otherProductionBuild appGroup surface platform excludeRid rt)
                    guard_
                        ( rtRolloutStatus rt ==. val_ (Just "rolling_out")
                            ||. rtRolloutStatus rt ==. val_ (Just "halted")
                        )
                    pure (rtId rt)
    forM_ ids $ \i ->
        runDB db $
            runUpdate $
                update
                    (releaseTrackers autopilotDb)
                    ( \rt ->
                        mconcat
                            [ rtStatus rt <-. val_ "COMPLETED"
                            , -- keep rollout_percent frozen at its last value for the badge
                              rtRolloutStatus rt <-. val_ (Just "superseded")
                            ]
                    )
                    (\rt -> rtId rt ==. val_ i)
    pure ids

{- | Rule B, version-aware (audit defect 3): drop OTHER incoming builds that are
STRICTLY OLDER than the taker. Ordering is platform-conditional (see
'convergeMobileSlots'): Android compares by CODE alone — the only thing Play
enforces — while iOS compares version first, code within a version. Unknown
codes never retire. Keeps review_status so the history row still reads its
last review state. A newer incoming build is never touched — the promote gate
blocks the taker instead. Returns the affected ids.
-}
retireOlderIncoming ::
    (MonadFlow m) => Text -> Text -> Text -> Text -> Text -> Maybe Int32 -> m [Text]
retireOlderIncoming appGroup surface platform excludeRid takerVersion takerCode =
    withDb $ \db -> withConn db $ \conn ->
        if platform == "android"
            then
                map fromOnly
                    <$> query
                        conn
                        "UPDATE release_tracker rt SET status = 'COMPLETED', rollout_status = 'superseded' \
                        \WHERE rt.category = 'MobileBuild' AND rt.app_group = ? AND rt.service = ? AND rt.env = ? \
                        \  AND rt.store_track = 'production' AND rt.review_status IS NOT NULL \
                        \  AND rt.rollout_status IS NULL AND rt.status = 'INPROGRESS' AND rt.id <> ? \
                        \  AND ?::int IS NOT NULL AND rt.version_code IS NOT NULL \
                        \  AND rt.version_code < ?::int \
                        \RETURNING rt.id"
                        (appGroup, surface, platform, excludeRid, takerCode, takerCode)
            else
                map fromOnly
                    <$> query
                        conn
                        "UPDATE release_tracker rt SET status = 'COMPLETED', rollout_status = 'superseded' \
                        \WHERE rt.category = 'MobileBuild' AND rt.app_group = ? AND rt.service = ? AND rt.env = ? \
                        \  AND rt.store_track = 'production' AND rt.review_status IS NOT NULL \
                        \  AND rt.rollout_status IS NULL AND rt.status = 'INPROGRESS' AND rt.id <> ? \
                        \  AND ( mobile_version_key(rt.new_version) < mobile_version_key(?) \
                        \        OR ( mobile_version_key(rt.new_version) = mobile_version_key(?) \
                        \             AND ?::int IS NOT NULL AND rt.version_code IS NOT NULL \
                        \             AND rt.version_code < ?::int ) ) \
                        \RETURNING rt.id"
                        (appGroup, surface, platform, excludeRid, takerVersion, takerVersion, takerCode, takerCode)

{- | Same-version REBUILD supersession. A rebuild of the live version (same
version string, different build code — e.g. 3.3.107+4 replacing 3.3.107+3)
defeats both existing heals: Rule A skips completed rows, and store-sync's
stale-retire compares versions strictly (@versionOlderThan@ is false for the
same version). The older build's row then reads "Live" forever beside the
real one. Given the store-observed live build code, freeze every OTHER
same-version build (rolling / halted / completed) to @superseded@ history.
NULL-code rows are left alone: a legacy code-less row IS the version's row
(the insert guard treats it as such), so retiring it could orphan the live
version. Returns the affected ids for the caller to log.
-}
supersedeRebuiltSameVersion ::
    (MonadFlow m) => Text -> Text -> Text -> Text -> Int32 -> m [Text]
supersedeRebuiltSameVersion appGroup surface platform version keepCode = withDb $ \db -> do
    ids <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_
                        ( rtAppGroup rt ==. val_ appGroup
                            &&. rtService rt ==. val_ surface
                            &&. rtEnv rt ==. val_ platform
                            &&. rtCategory rt ==. val_ "MobileBuild"
                            &&. rtStoreTrack rt ==. val_ (Just "production")
                        )
                    guard_ (rtNewVersion rt ==. val_ version)
                    guard_ (not_ (isNothing_ (rtVersionCode rt)))
                    guard_ (rtVersionCode rt /=. val_ (Just keepCode))
                    guard_
                        ( rtRolloutStatus rt ==. val_ (Just "rolling_out")
                            ||. rtRolloutStatus rt ==. val_ (Just "halted")
                            ||. rtRolloutStatus rt ==. val_ (Just "completed")
                        )
                    pure (rtId rt)
    forM_ ids $ \i ->
        runDB db $
            runUpdate $
                update
                    (releaseTrackers autopilotDb)
                    ( \rt ->
                        mconcat
                            [ rtStatus rt <-. val_ "COMPLETED"
                            , rtRolloutStatus rt <-. val_ (Just "superseded")
                            ]
                    )
                    (\rt -> rtId rt ==. val_ i)
    pure ids

{- | One-row-per-slot convergence for an app, anchored on the store-observed
live production build (Nothing = no live cell; only same-slot dedupe runs).
Stamps to history: LIVE-slot rows not ahead of live; INCOMING rows not
ahead of live or older than the best incoming (Rule-B shape: status only,
review kept for history; 30-min grace for a just-promoted row); observed
INTERNAL builds below live or older than the newest internal. Never touches
the live build's own rows, NULL-code same-version rows, or mid-build rows.
The SQL mirrors scripts/converge-mobile-slots-inspect.sql — keep in lockstep.

Ordering (2026-08-03 SSOT): LIVE and HELD slots use the RELEASE ordering on
BOTH platforms — version first ('mobile_version_key'), code as the tiebreak
within a version — the same predicate as the promote gate
('releaseOrderBehind'), so a row convergence keeps is always one the gate
would let promote. Code-only comparison was retired for these slots after a
prod incident: a later upload of an OLDER version line (3.0.23+266 beside
live 3.1.0+225) carries the highest code, so code-first kept it "Ready to
promote" forever while the gate refused it. Same-version rebuilds still
resolve by code (the tiebreak). Android INCOMING keeps its code-only compare:
review rows have their own reconcile lifecycle and a promoted taker's Rule-B
retire already handles ordering there.
-}
convergeMobileSlots ::
    (MonadFlow m) =>
    Text ->
    Text ->
    Text ->
    Maybe (Text, Maybe Int32) ->
    m ([Text], [Text], [Text])
convergeMobileSlots appGroup surface platform mAnchor = withDb $ \db -> withConn db $ \conn -> do
    let mV = fst <$> mAnchor
        mC = snd =<< mAnchor
        paramsV = (appGroup, surface, platform, mV, mV, mV, mC, mC)
    live <- map fromOnly <$> query conn liveSql paramsV
    incoming <-
        if platform == "android"
            then map fromOnly <$> query conn incomingSqlCode (appGroup, surface, platform, mC, mC)
            else map fromOnly <$> query conn incomingSql paramsV
    held <- map fromOnly <$> query conn internalSql paramsV
    pure (live, incoming, held)
  where
    incomingSqlCode =
        "WITH incoming AS ( \
        \  SELECT id, version_code \
        \  FROM release_tracker \
        \  WHERE category = 'MobileBuild' AND app_group = ? AND service = ? AND env = ? \
        \    AND store_track = 'production' AND review_status IS NOT NULL \
        \    AND rollout_status IS NULL AND status IN ('INPROGRESS','COMPLETED') \
        \    AND last_updated < now() - interval '30 minutes' \
        \    AND version_code IS NOT NULL ), \
        \best AS ( SELECT version_code AS bcode FROM incoming \
        \          ORDER BY version_code DESC LIMIT 1 ) \
        \UPDATE release_tracker rt SET status = 'COMPLETED', rollout_status = 'superseded' \
        \FROM incoming i LEFT JOIN best b ON TRUE \
        \WHERE rt.id = i.id \
        \  AND ( ( ?::int IS NOT NULL AND i.version_code <= ?::int ) \
        \     OR i.version_code < b.bcode ) \
        \RETURNING rt.id"
    liveSql =
        "UPDATE release_tracker rt SET status = 'COMPLETED', rollout_status = 'superseded' \
        \WHERE rt.category = 'MobileBuild' AND rt.app_group = ? AND rt.service = ? AND rt.env = ? \
        \  AND rt.store_track = 'production' \
        \  AND ( rt.rollout_status IN ('rolling_out','halted','completed') \
        \        OR ( rt.rollout_status IS NULL AND rt.review_status IS NULL \
        \             AND rt.status = 'COMPLETED' ) ) \
        \  AND ?::text IS NOT NULL \
        \  AND ( mobile_version_key(rt.new_version) < mobile_version_key(?::text) \
        \        OR ( mobile_version_key(rt.new_version) = mobile_version_key(?::text) \
        \             AND ?::int IS NOT NULL AND rt.version_code IS NOT NULL \
        \             AND rt.version_code < ?::int ) ) \
        \RETURNING rt.id"
    incomingSql =
        "WITH incoming AS ( \
        \  SELECT id, mobile_version_key(new_version) AS vkey, version_code \
        \  FROM release_tracker \
        \  WHERE category = 'MobileBuild' AND app_group = ? AND service = ? AND env = ? \
        \    AND store_track = 'production' AND review_status IS NOT NULL \
        \    AND rollout_status IS NULL AND status IN ('INPROGRESS','COMPLETED') \
        \    AND last_updated < now() - interval '30 minutes' ), \
        \best AS ( SELECT vkey AS bkey, version_code AS bcode FROM incoming \
        \          ORDER BY vkey DESC, version_code DESC NULLS LAST LIMIT 1 ) \
        \UPDATE release_tracker rt SET status = 'COMPLETED', rollout_status = 'superseded' \
        \FROM incoming i LEFT JOIN best b ON TRUE \
        \WHERE rt.id = i.id \
        \  AND ( ( ?::text IS NOT NULL \
        \          AND ( i.vkey < mobile_version_key(?::text) \
        \                OR ( i.vkey = mobile_version_key(?::text) \
        \                     AND ?::int IS NOT NULL AND i.version_code IS NOT NULL \
        \                     AND i.version_code <= ?::int ) ) ) \
        \     OR i.vkey < b.bkey \
        \     OR ( i.vkey = b.bkey AND i.version_code IS NOT NULL AND b.bcode IS NOT NULL \
        \          AND i.version_code < b.bcode ) ) \
        \RETURNING rt.id"
    internalSql =
        "WITH held AS ( \
        \  SELECT id, mobile_version_key(new_version) AS vkey, version_code \
        \  FROM release_tracker \
        \  WHERE category = 'MobileBuild' AND app_group = ? AND service = ? AND env = ? \
        \    AND store_track IN ('internal','testflight') AND review_status IS NULL \
        \    AND rollout_status IS NULL AND status IN ('INPROGRESS','COMPLETED') \
        \    AND version_code IS NOT NULL ), \
        \best AS ( SELECT vkey AS bkey, version_code AS bcode FROM held \
        \          ORDER BY vkey DESC, version_code DESC LIMIT 1 ) \
        \UPDATE release_tracker rt SET status = 'COMPLETED', rollout_status = 'superseded' \
        \FROM held h LEFT JOIN best b ON TRUE \
        \WHERE rt.id = h.id \
        \  AND ( ( ?::text IS NOT NULL \
        \          AND ( h.vkey < mobile_version_key(?::text) \
        \                OR ( h.vkey = mobile_version_key(?::text) \
        \                     AND ?::int IS NOT NULL AND h.version_code < ?::int ) ) ) \
        \     OR h.vkey < b.bkey \
        \     OR ( h.vkey = b.bkey AND h.version_code < b.bcode ) ) \
        \RETURNING rt.id"

{- | The surviving best store-observed internal/TestFlight build (version-first,
then code) — the anchor the convergence hands to Rule C so stale SCC-built
(store_track NULL) landed rows retire on sync, not only at promote time.
-}
bestActiveInternalBuild ::
    (MonadFlow m) => Text -> Text -> Text -> m (Maybe (Text, Int32))
bestActiveInternalBuild appGroup surface platform = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            ( "SELECT id, version_code FROM release_tracker \
              \WHERE category = 'MobileBuild' AND app_group = ? AND service = ? AND env = ? \
              \  AND store_track IN ('internal','testflight') AND review_status IS NULL \
              \  AND rollout_status IS NULL AND status IN ('INPROGRESS','COMPLETED') \
              \  AND version_code IS NOT NULL "
                -- SSOT release ordering (both platforms): version first, code tiebreak
                -- — same predicate the promote gate and slot convergence use.
                <> "ORDER BY mobile_version_key(new_version) DESC, version_code DESC LIMIT 1"
            )
            (appGroup, surface, platform)
    pure $ case rows of
        [(rid, code)] -> Just (rid, code)
        _ -> Nothing
