{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

{- | DB access for @ota_push@ / @ota_release_link@
(docs\/OTA_MOBILE_RELEASE_INTEGRATION.md §5.5).

UUID columns are cast to\/from TEXT at the SQL boundary — the Haskell rows
carry them as 'Text' ('Products.Autopilot.Mobile.Types.Ota'). The FromRow
instances live here (not in Types.Ota) so the types module stays SQL-free.
-}
module Products.Autopilot.Mobile.Queries.OtaPush (
    insertOtaPushes,
    listOtaPushesForGroup,
    findOtaPushById,
    findActivePush,
    listActivePushRows,
    listUnresolvedPushes,
    updateOtaPushRun,
    markOtaPushStatus,
    markBatchFailed,
    setResolvedPackage,
    insertOtaReleaseLink,
    listLinksForRefs,
    findLinkByRef,
    findPushCommitsByRefVersions,
    backfillTrackerCommitSha,
    getTrackerRolloutMeta,
    setTrackerSourceRef,
) where

import Control.Monad (void)
import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple (In (..), Only (..), Query, execute, query, query_, (:.) (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..))
import Products.Autopilot.Mobile.Types.Ota (OtaLink (..), OtaPush (..))

-- 20 columns: split with :. (postgresql-simple tuples cap at 10).
instance FromRow OtaPush where
    fromRow = do
        (i, gid, app, plat, ref, env, bump, st, src, batch)
            :. (runId, sha, basePkg, pkg, finalV, via, err, by, at, upd) <-
            fromRow
        pure (OtaPush i gid app plat ref env bump st src batch runId sha basePkg pkg finalV via err by at upd)

pushCols :: Query
pushCols =
    "id::text, mobile_release_group_id, app_name, platform, airborne_app_ref, env, \
    \requested_bump, status, source_ref, dispatch_batch_id::text, external_run_id, \
    \commit_sha, baseline_package_version, package_version, final_version, \
    \resolved_via, error, dispatched_by, dispatched_at, updated_at"

selectPush :: Query
selectPush = "SELECT " <> pushCols <> " FROM ota_push "

{- | Insert one expectation row per (app, platform); returns the inserted rows.
Caller supplies the shared @dispatch_batch_id@ (a fresh UUID as Text).
-}
insertOtaPushes ::
    (MonadFlow m) =>
    Text -> -- group id
    Text -> -- source_ref
    Text -> -- dispatch_batch_id
    Text -> -- env ("Production")
    Text -> -- requested bump
    Text -> -- dispatched_by (actor email)
    [(Text, Text, Text, Maybe Int)] -> -- (app_name, platform, airborne_app_ref, baseline)
    m [OtaPush]
insertOtaPushes gid srcRef batchId env bump actor targets =
    withDb $ \db -> withConn db $ \conn ->
        concat
            <$> mapM
                ( \(app, plat, ref, baseline) ->
                    query
                        conn
                        ( "INSERT INTO ota_push \
                          \  (mobile_release_group_id, app_name, platform, airborne_app_ref, env, \
                          \   requested_bump, status, source_ref, dispatch_batch_id, \
                          \   baseline_package_version, dispatched_by) \
                          \VALUES (?, ?, ?, ?, ?, ?, 'DISPATCHED', ?, ?::uuid, ?, ?) \
                          \RETURNING "
                            <> pushCols
                        )
                        (gid, app, plat, ref, env, bump, srcRef, batchId, baseline, actor)
                )
                targets

listOtaPushesForGroup :: (MonadFlow m) => Text -> m [OtaPush]
listOtaPushesForGroup gid =
    withDb $ \db -> withConn db $ \conn ->
        query
            conn
            (selectPush <> "WHERE mobile_release_group_id = ? ORDER BY dispatched_at DESC, app_name, platform")
            (Only gid)

findOtaPushById :: (MonadFlow m) => Text -> m (Maybe OtaPush)
findOtaPushById pid =
    withDb $ \db -> withConn db $ \conn ->
        listToMaybe
            <$> query conn (selectPush <> "WHERE id = ?::uuid") (Only pid)

{- | The globally-active (non-terminal) push batch, if any (Decision D).
Returns the newest active row — enough to identify the owner.
-}
findActivePush :: (MonadFlow m) => m (Maybe OtaPush)
findActivePush =
    withDb $ \db -> withConn db $ \conn ->
        listToMaybe
            <$> query_
                conn
                (selectPush <> "WHERE status IN ('DISPATCHED','RUNNING') ORDER BY dispatched_at DESC LIMIT 1")

-- | All non-terminal rows (the convergence work-list), oldest batch first.
listActivePushRows :: (MonadFlow m) => m [OtaPush]
listActivePushRows =
    withDb $ \db -> withConn db $ \conn ->
        query_
            conn
            (selectPush <> "WHERE status IN ('DISPATCHED','RUNNING') ORDER BY dispatched_at ASC")

{- | Bundle-pushed rows whose package never resolved (Decision E last resort):
retried by convergence on later GETs until tag\/baseline\/manual succeeds.
-}
listUnresolvedPushes :: (MonadFlow m) => m [OtaPush]
listUnresolvedPushes =
    withDb $ \db -> withConn db $ \conn ->
        query_
            conn
            (selectPush <> "WHERE status = 'BUNDLE_PUSHED' AND package_version IS NULL ORDER BY dispatched_at ASC")

-- | Stamp run id + commit sha on every row of a batch → RUNNING.
updateOtaPushRun :: (MonadFlow m) => Text -> Int64 -> Text -> m ()
updateOtaPushRun batchId runId sha =
    withDb $ \db -> withConn db $ \conn ->
        void $
            execute
                conn
                "UPDATE ota_push SET external_run_id = ?, commit_sha = ?, status = 'RUNNING', updated_at = now() \
                \WHERE dispatch_batch_id = ?::uuid AND status = 'DISPATCHED'"
                (runId, sha, batchId)

-- | Set status (+ optional error) on one row.
markOtaPushStatus :: (MonadFlow m) => Text -> Text -> Maybe Text -> m ()
markOtaPushStatus pid st mErr =
    withDb $ \db -> withConn db $ \conn ->
        void $
            execute
                conn
                "UPDATE ota_push SET status = ?, error = COALESCE(?, error), updated_at = now() WHERE id = ?::uuid"
                (st, mErr, pid)

-- | Fail every non-terminal row of a batch (dispatch failure, cancelled run).
markBatchFailed :: (MonadFlow m) => Text -> Text -> m ()
markBatchFailed batchId err =
    withDb $ \db -> withConn db $ \conn ->
        void $
            execute
                conn
                "UPDATE ota_push SET status = 'FAILED', error = ?, updated_at = now() \
                \WHERE dispatch_batch_id = ?::uuid AND status IN ('DISPATCHED','RUNNING')"
                (err, batchId)

setResolvedPackage :: (MonadFlow m) => Text -> Int -> Maybe Text -> Text -> m ()
setResolvedPackage pid pkgVersion mFinalVersion via =
    withDb $ \db -> withConn db $ \conn ->
        void $
            execute
                conn
                "UPDATE ota_push SET package_version = ?, final_version = COALESCE(?, final_version), \
                \resolved_via = ?, status = 'BUNDLE_PUSHED', updated_at = now() WHERE id = ?::uuid"
                (pkgVersion, mFinalVersion, via, pid)

-- ─── Release links ─────────────────────────────────────────────────

{- | Group + source_ref live ON the link (0049) — push-born and package-born
releases read identically. Label lookup stays best-effort (groups have no
table of their own).
-}
selectLink :: Query
selectLink =
    "SELECT l.id::text, COALESCE(l.ota_push_id::text, ''), l.airborne_app_ref, l.airborne_release_id, \
    \l.package_version, l.dimensions, l.created_by, l.created_at, \
    \COALESCE(l.mobile_release_group_id, ''), rg.label, COALESCE(l.source_ref, '') \
    \FROM ota_release_link l \
    \LEFT JOIN LATERAL ( \
    \  SELECT release_group_label AS label FROM release_tracker \
    \  WHERE release_group_id = l.mobile_release_group_id \
    \    AND release_group_label IS NOT NULL LIMIT 1 \
    \) rg ON TRUE "

instance FromRow OtaLink where
    fromRow = do
        (i, pushId, ref, rid, pkg, dims, by, at, gid, label) :. Only src <- fromRow
        pure (OtaLink i pushId ref rid pkg dims by at gid label src)

insertOtaReleaseLink ::
    (MonadFlow m) =>
    Maybe Text -> -- push id (Nothing = released straight from a package)
    Text -> -- airborne_app_ref
    Text -> -- airborne_release_id
    Int -> -- package_version
    Maybe Value -> -- dimensions snapshot
    Text -> -- created_by
    Text -> -- mobile_release_group_id
    Maybe Text -> -- source_ref (branch provenance, when known)
    m Text
insertOtaReleaseLink mPushId ref releaseId pkgVersion dims actor gid mSrcRef =
    withDb $ \db -> withConn db $ \conn -> do
        rows <-
            query
                conn
                "INSERT INTO ota_release_link \
                \  (ota_push_id, airborne_app_ref, airborne_release_id, package_version, dimensions, created_by, mobile_release_group_id, source_ref) \
                \VALUES (?::uuid, ?, ?, ?, ?, ?, ?, ?) \
                \ON CONFLICT (airborne_app_ref, airborne_release_id) DO UPDATE SET created_by = EXCLUDED.created_by \
                \RETURNING id::text"
                (mPushId, ref, releaseId, pkgVersion, dims, actor, gid, mSrcRef)
        pure $ case rows of
            (Only lid : _) -> lid
            [] -> ""

-- | Global provenance: every SCC-created link for any of the given refs.
listLinksForRefs :: (MonadFlow m) => [Text] -> m [OtaLink]
listLinksForRefs [] = pure []
listLinksForRefs refs =
    withDb $ \db -> withConn db $ \conn ->
        query
            conn
            (selectLink <> "WHERE l.airborne_app_ref IN ? ORDER BY l.created_at DESC")
            (Only (In refs))

findLinkByRef :: (MonadFlow m) => Text -> Text -> m (Maybe OtaLink)
findLinkByRef ref releaseId =
    withDb $ \db -> withConn db $ \conn ->
        listToMaybe
            <$> query
                conn
                (selectLink <> "WHERE l.airborne_app_ref = ? AND l.airborne_release_id = ?")
                (ref, releaseId)




-- ─── Provenance readers/writers over EXISTING tables (doc §11b) ────

{- | Commits of SCC-pushed packages — the activity log doubles as the
provenance source for everything SCC built itself (no extra storage).
-}
findPushCommitsByRefVersions :: (MonadFlow m) => Text -> [Int] -> m [(Int, Text)]
findPushCommitsByRefVersions _ [] = pure []
findPushCommitsByRefVersions ref versions =
    withDb $ \db -> withConn db $ \conn ->
        query
            conn
            "SELECT package_version, commit_sha FROM ota_push \
            \WHERE airborne_app_ref = ? AND package_version IN ? AND commit_sha IS NOT NULL \
            \ORDER BY dispatched_at DESC"
            (ref, In versions)

{- | A store-sync row anchored via its native build tag gets its true commit
written home — only when the column is still NULL (never clobber SCC builds).
-}
backfillTrackerCommitSha :: (MonadFlow m) => Text -> Text -> m ()
backfillTrackerCommitSha releaseId sha =
    withDb $ \db -> withConn db $ \conn ->
        void $
            execute
                conn
                "UPDATE release_tracker SET commit_sha = ? WHERE id = ? AND commit_sha IS NULL"
                (sha, releaseId)

{- | Branch-picker adoption (doc §11b): the USER picked a branch that provably
contains the row's anchor commit; record it so the row becomes pushable.
Only fills a NULL source_ref — SCC-built rows are never rewritten.
-}
-- | (rollout_status, review_status) of one row — neither is in the domain
-- projection; the push gate reads them (superseded / in-review handling).
getTrackerRolloutMeta :: (MonadFlow m) => Text -> m (Maybe Text, Maybe Text)
getTrackerRolloutMeta releaseId =
    withDb $ \db -> withConn db $ \conn -> do
        rows <- query conn "SELECT rollout_status, review_status FROM release_tracker WHERE id = ?" (Only releaseId)
        pure $ case rows of
            [(ms, mr)] -> (ms, mr)
            _ -> (Nothing, Nothing)

setTrackerSourceRef :: (MonadFlow m) => Text -> Text -> m Bool
setTrackerSourceRef releaseId branch =
    withDb $ \db -> withConn db $ \conn -> do
        n <-
            execute
                conn
                "UPDATE release_tracker SET source_ref = ? WHERE id = ? AND source_ref IS NULL"
                (branch, releaseId)
        pure (n > 0)
