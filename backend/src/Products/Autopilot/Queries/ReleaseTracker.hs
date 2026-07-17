{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.ReleaseTracker (
    -- * Insert / Update
    insertReleaseTracker,
    conditionalUpdateTracker,
    conditionalUpdateApprove,
    conditionalUpdateTrackerRow,
    claimChangelogSlackForGroup,
    markChangelogSlackSent,
    markChangelogSlackFailed,
    getChangelogSlackState,
    insertReleaseTrackerRow,
    insertReleaseTrackerRowsBatch,
    insertReleaseTrackerRowIfAbsent,

    -- * Queries
    findReleaseTracker,
    findDispatchedReleaseIds,
    findReleaseTrackersByIds,
    findReleaseTrackersByGroupId,
    findMobileGroupTrackersSince,
    GroupedTracker,
    listReleaseEvents,
    listReleaseEventsByCategory,
    listReleaseTrackers,
    listReleaseTrackersByDateRange,
    listReleaseTrackersByDateRangeAndCategory,
    findRunnableReleaseTrackers,
    findActiveTrackersForService,
    findInProgressReleaseTrackers,
    findCleanupScheduledTrackers,
    findAbortingReleaseTrackers,
    findOngoingReleaseTrackers,
    findTrackersWithStatusAndTime,
    findApprovedReleasesWithStatus,
    findReleaseTrackersByCategory,
    findReleaseTrackerByGlobalId,
    findCompletedTrackersForScaleDown,
    findLeakedNewDeploymentTrackers,
    resetStuckScaleDownInProgress,
    findActiveSyncTrackers,
    findEventByLabel,
    sweepStaleDiscardingTrackers,
    sweepAutoCompleteVsTrackers,
    findLastGcltAbortedTracker,

    -- * Events
    insertReleaseEvent,

    -- * Delete
    deleteReleaseTracker,
    deleteReleaseEvents,

    -- * Misc / Update helpers
    updateReleaseTrackerSlackThreadTs,
    touchReleaseHeartbeat,

    -- * Row conversion
    toRow,
    fromRow,
    addMobileLifecycle,

    -- * Parsing / Encoding helpers
    parseReleaseCategory,
    parseReleaseWFStatus,
    parseReleaseStatus,
    parseMode,
    releaseStatusToText,
    modeToText,
    parseDecisionEngineHSStatus,
    encodeJsonText,
    parseJsonTextOr,
    parseJsonTextMaybe,
    reviewInferredOf,

    -- * Internal
    safeHead,
    keepSnapshot,
    TrackerWithTarget,
)
where

import Control.Monad (void)
import Core.DB.Connection (runBeamLogged, runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (FromJSON, ToJSON, Value (..), fromJSON, toJSON)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Text qualified as AesonText
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Lazy qualified as LT
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Database.Beam
import Database.Beam.Postgres ()
import Database.Beam.Postgres.Full (anyConflict, insertReturning, onConflict, onConflictDoNothing, runPgInsertReturningList)
import Database.PostgreSQL.Simple (Only (..), Query, ToRow, execute, execute_, query, withTransaction)
import Database.PostgreSQL.Simple.Types ((:.) (..))
import Debug.Trace qualified as DT
import Products.Autopilot.Mobile.Lifecycle.BuildKind (buildKind, claimsStoreIdentity)
import Products.Autopilot.Mobile.Lifecycle.Phase (Display (..), displayStatusInferred, phaseFromFields, phaseSlug, variantSlug)
import Products.Autopilot.Mobile.Types (MobileBuildContext (..), MobileBuildTargetState (..), MobileBuildWFStatus (..), isFailedMBTerminal, releasesIdentitySlot)
import Products.Autopilot.Types
import Products.Autopilot.Types qualified as NT
import Products.Autopilot.Types.Storage.Schema
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Target.Kubernetes

type TrackerWithTarget = (ReleaseTracker, Maybe TargetState)

insertReleaseTracker :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> m ()
insertReleaseTracker rt mts = withDb $ \db -> do
    now <- getCurrentTime
    let created = fromMaybe now (dateCreated rt)
        row = toRow created now rt mts
    -- Every non-PK column must appear in BOTH the INSERT list AND the DO
    -- UPDATE SET clause, otherwise it silently retains its old value on
    -- conflict and corrupts rollout state. EXCEPTIONS (deliberately absent
    -- from both lists so this writer can never clobber them): the
    -- setPhase-owned lifecycle columns (review_*, rollout_*, store_track,
    -- asc ids, terminal_status), the externally-stamped dispatch_id /
    -- external_run_id / version_code, and the creation-stamped
    -- release_group_id / release_group_label (migration 0042).
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO release_tracker \
                \  ( id, old_version, new_version, app_group, service, priority, env \
                \  , category, status, release_wf_status, mode, release_manager, approved_by \
                \  , is_approved, is_infra_approved, release_tag, schedule_time, start_time \
                \  , end_time, rollout_strategy, rollout_history, release_context, info \
                \  , description, change_log, metadata, global_id, sync_enabled \
                \  , env_override_data, slack_thread_ts, date_created, last_updated ) \
                \VALUES \
                \  ( ?, ?, ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ?, ? \
                \  , ?, ?, ?, ? ) \
                \ON CONFLICT (id) DO UPDATE SET \
                \    old_version       = EXCLUDED.old_version \
                \  , new_version       = EXCLUDED.new_version \
                \  , app_group         = EXCLUDED.app_group \
                \  , service           = EXCLUDED.service \
                \  , priority          = EXCLUDED.priority \
                \  , env               = EXCLUDED.env \
                \  , category          = EXCLUDED.category \
                \  , status            = EXCLUDED.status \
                \  , release_wf_status = EXCLUDED.release_wf_status \
                \  , mode              = EXCLUDED.mode \
                \  , release_manager   = EXCLUDED.release_manager \
                \  , approved_by       = EXCLUDED.approved_by \
                \  , is_approved       = EXCLUDED.is_approved \
                \  , is_infra_approved = EXCLUDED.is_infra_approved \
                \  , release_tag       = EXCLUDED.release_tag \
                \  , schedule_time     = EXCLUDED.schedule_time \
                \  , start_time        = EXCLUDED.start_time \
                \  , end_time          = EXCLUDED.end_time \
                \  , rollout_strategy  = EXCLUDED.rollout_strategy \
                \  , rollout_history   = EXCLUDED.rollout_history \
                \  , release_context   = EXCLUDED.release_context \
                \  , info              = EXCLUDED.info \
                \  , description       = EXCLUDED.description \
                \  , change_log        = EXCLUDED.change_log \
                \  , metadata          = EXCLUDED.metadata \
                \  , global_id         = EXCLUDED.global_id \
                \  , sync_enabled      = EXCLUDED.sync_enabled \
                \  , env_override_data = EXCLUDED.env_override_data \
                \  , slack_thread_ts   = COALESCE(EXCLUDED.slack_thread_ts, release_tracker.slack_thread_ts) \
                \  , date_created      = EXCLUDED.date_created \
                \  , last_updated      = EXCLUDED.last_updated"
                ( (rtId row, rtOldVersion row, rtNewVersion row, rtAppGroup row, rtService row, rtPriority row, rtEnv row)
                    :. (rtCategory row, rtStatus row, rtReleaseWFStatus row, rtMode row, rtCreatedBy row, rtApprovedBy row)
                    :. (rtIsApproved row, rtIsInfraApproved row, rtReleaseTag row, rtScheduleTime row, rtStartTime row)
                    :. (rtEndTime row, rtRolloutStrategy row, rtRolloutHistory row, rtTargetState row, rtInfo row)
                    :. (rtDescription row, rtChangeLog row, rtMetadata row, rtGlobalId row, rtSyncEnabled row)
                    :. (rtEnvOverrideData row, rtSlackThreadTs row, rtCreatedAt row, rtUpdatedAt row)
                )
        pure ()

{- | Atomically update a release tracker only if its current status matches the
expected value (CAS: @UPDATE ... WHERE id = ? AND status = ?@). Returns True if
the update succeeded, False if the status was changed by another thread.

Column-scoped ('casUpdateWorkflowCols'): the former DELETE+re-INSERT rebuilt the
whole row from 'toRow', which blanked every setPhase-owned lifecycle column
(review_*, rollout_*, store_track, terminal_status, asc ids) on the workflow's
completion/abort persist — erasing a release's just-stamped outcome.
-}
conditionalUpdateTracker :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> Text -> m Bool
conditionalUpdateTracker rt mts expectedStatus = do
    now <- liftIO getCurrentTime
    let created = fromMaybe now (dateCreated rt)
        row = toRow created now rt mts
    casUpdateWorkflowCols row "WHERE id = ? AND status = ?" (rtId row, expectedStatus)

{- | Atomic approve. Precondition is @is_approved=false AND status='CREATED'@,
enforced in SQL so concurrent approve handlers can't both win. Column-scoped
like 'conditionalUpdateTracker'.
-}
conditionalUpdateApprove :: (MonadFlow m) => ReleaseTracker -> Maybe TargetState -> m Bool
conditionalUpdateApprove rt mts = do
    now <- liftIO getCurrentTime
    let created = fromMaybe now (dateCreated rt)
        row = toRow created now rt mts
    casUpdateWorkflowCols row "WHERE id = ? AND status = 'CREATED' AND is_approved = false" (Only (rtId row))

{- | Shared CAS executor: ONE atomic UPDATE of the workflow-owned columns, with
the caller's WHERE precondition. Deliberately NOT in the SET list — so their
live values always survive a workflow persist:

 * the 'setPhase'-owned lifecycle columns: @review_*@, @rollout_status@,
   @rollout_percent@, @store_rollout_history@, @store_track@, @asc_version_id@,
   @asc_phased_id@, @terminal_status@;
 * the externally-stamped @dispatch_id@ / @external_run_id@ (the old
   read-then-reinsert "preserved fields", now preserved for free).

@version_code@ IS written: 'toRow' derives it from the target state, including
the failed-terminal identity-slot release (a build aborted before uploading
frees its (version, code) for a rebuild). @slack_thread_ts@ keeps COALESCE
semantics: a Nothing in the row never erases a thread id another path stamped.
-}
casUpdateWorkflowCols :: (ToRow w, MonadFlow m) => ReleaseTrackerRow -> Query -> w -> m Bool
casUpdateWorkflowCols row whereSql whereParams = withDb $ \db ->
    withConn db $ \conn -> do
        n <-
            execute
                conn
                ( "UPDATE release_tracker SET \
                  \  old_version = ?, new_version = ?, app_group = ?, service = ?, priority = ?, env = ? \
                  \ , category = ?, status = ?, release_wf_status = ?, mode = ?, release_manager = ?, approved_by = ? \
                  \ , is_approved = ?, is_infra_approved = ?, release_tag = ?, schedule_time = ?, start_time = ?, end_time = ? \
                  \ , rollout_strategy = ?, rollout_history = ?, release_context = ?, info = ?, description = ?, change_log = ? \
                  \ , metadata = ?, global_id = ?, sync_enabled = ?, env_override_data = ?, slack_thread_ts = COALESCE(?, slack_thread_ts), commit_sha = ? \
                  \ , source_ref = ?, reverts_release_id = ?, ab_validation_status = ?, ab_validation = ?, version_code = ?, date_created = ? \
                  \ , last_updated = ? "
                    <> whereSql
                )
                ( (rtOldVersion row, rtNewVersion row, rtAppGroup row, rtService row, rtPriority row, rtEnv row)
                    :. (rtCategory row, rtStatus row, rtReleaseWFStatus row, rtMode row, rtCreatedBy row, rtApprovedBy row)
                    :. (rtIsApproved row, rtIsInfraApproved row, rtReleaseTag row, rtScheduleTime row, rtStartTime row, rtEndTime row)
                    :. (rtRolloutStrategy row, rtRolloutHistory row, rtTargetState row, rtInfo row, rtDescription row, rtChangeLog row)
                    :. (rtMetadata row, rtGlobalId row, rtSyncEnabled row, rtEnvOverrideData row, rtSlackThreadTs row, rtCommitSha row)
                    :. (rtSourceRef row, rtRevertsReleaseId row, rtAbValidationStatus row, rtAbValidation row, rtVersionCode row, rtCreatedAt row)
                    :. Only (rtUpdatedAt row)
                    :. whereParams
                )
        pure (n > 0)

{- | Like 'conditionalUpdateTracker' but accepts a raw 'ReleaseTrackerRow'.
Returns True if the update succeeded, False if the status was changed by
another thread. Column-scoped: the lifecycle columns keep their live DB
values rather than the possibly-stale values of the read this row came from.
-}
conditionalUpdateTrackerRow :: (MonadFlow m) => ReleaseTrackerRow -> Text -> m Bool
conditionalUpdateTrackerRow row expectedStatus =
    casUpdateWorkflowCols row "WHERE id = ? AND status = ?" (rtId row, expectedStatus)

findReleaseTracker :: (MonadFlow m) => Text -> m (Maybe TrackerWithTarget)
findReleaseTracker rid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtId rt ==. val_ rid)
                        pure rt
    pure $ fmap fromRow (safeHead rows)

{- | Batch variant of 'findReleaseTracker': fetch many trackers by id in one
query. Used by the mobile dispatch handler to avoid an N+1 over releaseIds.
Returns only the ids that exist; the caller diffs to report missing ones.
-}
findReleaseTrackersByIds :: (MonadFlow m) => [Text] -> m [TrackerWithTarget]
findReleaseTrackersByIds [] = pure []
findReleaseTrackersByIds rids = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtId rt `in_` map val_ rids)
                    pure rt
    pure (map fromRow rows)

{- | Of the given ids, those already stamped with a dispatch_id. A second
dispatch call would re-stamp a FRESH group id — splitting the original run
group — so the dispatch handler rejects these up front (the runner picks a
stamped row up on its next tick; there is nothing to retry).
-}
findDispatchedReleaseIds :: (MonadFlow m) => [Text] -> m [Text]
findDispatchedReleaseIds [] = pure []
findDispatchedReleaseIds rids = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                rt <- all_ (releaseTrackers autopilotDb)
                guard_ (rtId rt `in_` map val_ rids)
                guard_ (isJust_ (rtDispatchId rt))
                pure (rtId rt)

{- | All operator-created mobile group rows for the groups LIST: rows with a
group id whose mode is not a store-sync mint (those are one-row pseudo-groups —
design doc §5), and that are either still active (CREATED/INPROGRESS — always
returned regardless of window, or the 24h-cliff bug returns in new clothes) or
created within the @since@ window.
-}
findMobileGroupTrackersSince :: (MonadFlow m) => UTCTime -> m [GroupedTracker]
findMobileGroupTrackersSince since = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\rt -> (asc_ (rtCreatedAt rt), asc_ (rtId rt))) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtCategory rt ==. val_ "MobileBuild")
                        guard_ (isJust_ (rtReleaseGroupId rt))
                        guard_ (not_ (fromMaybe_ (val_ "MANUAL") (rtMode rt) `in_` [val_ "STORE_SYNC", val_ "EXTERNAL_REVIEW"]))
                        guard_
                            ( rtStatus rt
                                `in_` [val_ "CREATED", val_ "INPROGRESS"]
                                ||. rtCreatedAt rt
                                    >=. val_ since
                            )
                        pure rt
    pure (mapMaybe toGrouped rows)

{- | (release_group_id, release_group_label, row) — the two group columns the
domain 'ReleaseTracker' deliberately doesn't carry.
-}
type GroupedTracker = (Text, Maybe Text, TrackerWithTarget)

toGrouped :: ReleaseTrackerRow -> Maybe GroupedTracker
toGrouped r = (\gid -> (gid, rtReleaseGroupLabel r, fromRow r)) <$> rtReleaseGroupId r

{- | All members of a mobile release group, oldest first (creation order).
Uses the indexed @release_group_id@ column (migration 0042) — the SQL access
path the fleet-release group endpoints build on.
-}
findReleaseTrackersByGroupId :: (MonadFlow m) => Text -> m [GroupedTracker]
findReleaseTrackersByGroupId gid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\rt -> (asc_ (rtCreatedAt rt), asc_ (rtId rt))) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtReleaseGroupId rt ==. val_ (Just gid))
                        pure rt
    pure (mapMaybe toGrouped rows)

{- | Atomically CLAIM the group's "changelog posted to Slack" marker so the
release changelog is posted ONCE per @release_group_id@, not once per app. One
conditional UPDATE stamps @changelog_slack_sent_at@ on every group row, but only
while still NULL — the row write-lock + READ COMMITTED predicate recheck make it
a compare-and-swap. Returns True for the single caller whose UPDATE flipped the
group (rows > 0); every sibling reaching it after the commit matches 0 rows and
returns False. Durable, so the claim also survives a runner restart.
-}
claimChangelogSlackForGroup :: (MonadFlow m) => Text -> m Bool
claimChangelogSlackForGroup gid
    | T.null (T.strip gid) = pure False
    | otherwise = withDb $ \db ->
        withConn db $ \conn -> do
            n <-
                execute
                    conn
                    -- Exactly-once per GROUP, not per row: the second predicate makes a
                    -- group that ALREADY has any stamped row un-re-claimable. Without it,
                    -- a late NULL row (a revert inherits the group_id; its raw-SQL columns
                    -- default NULL) would re-win the claim and re-post the changelog — or,
                    -- on a failed repost, markChangelogSlackFailed would wipe the whole
                    -- group's genuine 'sent' state. A failed send RESETS every row to NULL,
                    -- so retry (next settle / resend) still re-claims correctly.
                    "UPDATE release_tracker SET changelog_slack_sent_at = now() \
                    \WHERE release_group_id = ? AND changelog_slack_sent_at IS NULL \
                    \AND NOT EXISTS (SELECT 1 FROM release_tracker r2 \
                    \WHERE r2.release_group_id = ? AND r2.changelog_slack_sent_at IS NOT NULL)"
                    (gid, gid)
            pure (n > 0)

{- | Record a SUCCESSFUL group changelog-Slack post. The claim already stamped
@changelog_slack_sent_at@; we only clear any prior error so the group reads
"sent" (sent_at set + error NULL).
-}
markChangelogSlackSent :: (MonadFlow m) => Text -> m ()
markChangelogSlackSent gid
    | T.null (T.strip gid) = pure ()
    | otherwise = withDb $ \db ->
        withConn db $ \conn ->
            void $
                execute
                    conn
                    "UPDATE release_tracker SET changelog_slack_error = NULL \
                    \WHERE release_group_id = ?"
                    (Only gid)

{- | Record a FAILED group changelog-Slack post: store the Slack error AND
RELEASE the claim (@changelog_slack_sent_at@ -> NULL) so the next build-settle
or a manual resend can re-win the CAS and retry. Leaves the group in the
"failed" state (sent_at NULL + error set).
-}
markChangelogSlackFailed :: (MonadFlow m) => Text -> Text -> m ()
markChangelogSlackFailed gid err
    | T.null (T.strip gid) = pure ()
    | otherwise = withDb $ \db ->
        withConn db $ \conn ->
            void $
                execute
                    conn
                    "UPDATE release_tracker SET changelog_slack_error = ?, changelog_slack_sent_at = NULL \
                    \WHERE release_group_id = ?"
                    (err, gid)

{- | Read the group's changelog-Slack state for the UI: @(sentAt, error, optedIn)@.
Columns are group-uniform, so MAX picks the (single) non-null value; @optedIn@ is
true iff any member opted into the Slack post (its stored MobileBuildContext
carries a @changelog_summary@ body). The jsonb dig is guarded so a non-JSON /
empty release_context never aborts the read. Returns 'Nothing' for an unknown
group.
-}
getChangelogSlackState :: (MonadFlow m) => Text -> m (Maybe (Maybe UTCTime, Maybe Text, Bool))
getChangelogSlackState gid
    | T.null (T.strip gid) = pure Nothing
    | otherwise = withDb $ \db ->
        withConn db $ \conn -> do
            rows <-
                query
                    conn
                    "SELECT MAX(changelog_slack_sent_at), MAX(changelog_slack_error), \
                    \COALESCE(bool_or( \
                    \  CASE WHEN release_context ~ '^\\s*\\{' \
                    \  THEN (release_context::jsonb #>> '{contents,mbContext,changelog_summary}') IS NOT NULL \
                    \  ELSE false END), false) \
                    \FROM release_tracker WHERE release_group_id = ?"
                    (Only gid)
            pure $ case rows of
                [(mSent, mErr, optedIn)] -> Just (mSent, mErr, optedIn)
                _ -> Nothing

listReleaseEvents :: (MonadFlow m) => Text -> m [ReleaseEvent]
listReleaseEvents rid = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                ev <- all_ (releaseEvents autopilotDb)
                guard_ (reReleaseId ev ==. val_ rid)
                pure ev

-- | Like 'listReleaseEvents' but filters by event category in SQL.
listReleaseEventsByCategory :: (MonadFlow m) => Text -> Text -> m [ReleaseEvent]
listReleaseEventsByCategory rid cat = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                ev <- all_ (releaseEvents autopilotDb)
                guard_ (reReleaseId ev ==. val_ rid)
                guard_ (reCategory ev ==. val_ cat)
                pure ev

listReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
listReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        pure rt
    pure (map fromRow rows)

listReleaseTrackersByDateRange :: (MonadFlow m) => UTCTime -> UTCTime -> m [TrackerWithTarget]
listReleaseTrackersByDateRange fromTime toTime =
    listReleaseTrackersByDateRangeAndCategory fromTime toTime Nothing

{- | Like 'listReleaseTrackersByDateRange' but optionally restricts to a
specific set of categories. When 'mCategoryWhitelist' is 'Nothing' the
default UI exclusions apply (VSEdit + BackendConfig are hidden — they
have their own sections). When a whitelist is provided, ONLY those
categories are returned and the default exclusions are bypassed (so a
caller can explicitly request BackendConfig if needed).
-}
listReleaseTrackersByDateRangeAndCategory ::
    (MonadFlow m) => UTCTime -> UTCTime -> Maybe [Text] -> m [TrackerWithTarget]
listReleaseTrackersByDateRangeAndCategory fromTime toTime mCategoryWhitelist = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtCreatedAt rt >=. val_ fromTime)
                        guard_ (rtCreatedAt rt <=. val_ toTime)
                        case mCategoryWhitelist of
                            Just cats ->
                                guard_ (rtCategory rt `in_` map val_ cats)
                            Nothing -> do
                                -- VS edits and ConfigMap changes have their
                                -- own sections in the UI.
                                guard_ (rtCategory rt /=. val_ "VSEdit")
                                guard_ (rtCategory rt /=. val_ "BackendConfig")
                        pure rt
    pure (map fromRow (hideExternalReviewSnapshots rows))

{- | UI-list dedup: drop a store-sync internal / TestFlight snapshot when an
active EXTERNAL_REVIEW row already represents the same build (same app /
surface / platform / version). Such a build is on a pre-prod track AND in
review on production — store sync records both, but the in-review row is the
one to surface, so the snapshot is the redundant "two rows for one build" the
list was showing. The snapshot stays in the DB (store sync owns it; it
reappears once the review clears) — this only filters the list view.
-}
hideExternalReviewSnapshots :: [ReleaseTrackerRow] -> [ReleaseTrackerRow]
hideExternalReviewSnapshots rows =
    filter (\r -> keepSnapshot inReviewKeys (rtMode r, storeTrackText (rtMetadata r), keyOf r)) rows
  where
    keyOf r = (rtAppGroup r, rtService r, rtEnv r, rtNewVersion r)
    inReviewKeys =
        [ keyOf r
        | r <- rows
        , rtMode r == Just "EXTERNAL_REVIEW"
        , rtStatus r == "INPROGRESS"
        ]

{- | Pure core of 'hideExternalReviewSnapshots': keep a row unless it is a
store-sync internal/TestFlight snapshot whose build identity key already has an
active external-review row. Exposed for unit testing.
-}
keepSnapshot :: (Eq k) => [k] -> (Maybe Text, Maybe Text, k) -> Bool
keepSnapshot inReviewKeys (mode, track, k) =
    not $
        mode == Just "STORE_SYNC"
            && track `elem` [Just "internal", Just "testflight"]
            && k `elem` inReviewKeys

{- | Best-effort @store_track@ from a row's metadata JSON. Local copy to avoid a
circular import with the Mobile.Queries.AppCatalog version.
-}
storeTrackText :: Maybe Text -> Maybe Text
storeTrackText Nothing = Nothing
storeTrackText (Just t) = case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
    Right (Object o) -> case KM.lookup "store_track" o of
        Just (String s) -> Just s
        _ -> Nothing
    _ -> Nothing

{- | Find approved CREATED releases ready to be dispatched.

Backend categories: only CREATED+approved rows. INPROGRESS rows are
recovered via a separate rollback path; the workflow runs to completion
in one runner tick and never needs re-driving.

MobileBuild category: ALSO returns INPROGRESS rows whose mobile workflow
is not yet terminal. The mobile spec is poll-driven (StageWaiting on
ResolveRunId / PollMatrixJobs / ConfirmTag and on stage 2 advisory-lock
contention) — the runner must keep re-driving the workflow on every
tick until the stages reach a terminal MobileBuildWFStatus. The
terminal-mb-status filter is done in Haskell after parsing the
@target_state@ JSON (the column is plain TEXT, not jsonb, so SQL-side
JSON filtering would need a LIKE-on-substring hack). Trackers that
have reached terminal mobile states (MBCompleted / MBAborted /
MBFailed) are skipped — the runner's success / abort branches will
have flipped @release_tracker.status@ to a terminal value already, so
the lifecycle status guard below covers them in the common case; this
filter is a defensive safety net for partial-write scenarios.
-}
findRunnableReleaseTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findRunnableReleaseTrackers now = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_
                            ( rtStatus rt
                                ==. val_ "CREATED"
                                ||. ( rtStatus rt
                                        ==. val_ "INPROGRESS"
                                        &&. rtCategory rt
                                            ==. val_ "MobileBuild"
                                    )
                            )
                        guard_ (rtIsApproved rt ==. val_ (Just True))
                        -- Mobile rows need an explicit dispatch action before the runner
                        -- picks them up. Backend rows have no such field and are eligible
                        -- as soon as approved.
                        guard_
                            ( rtCategory rt
                                /=. val_ "MobileBuild"
                                ||. isJust_ (rtDispatchId rt)
                            )
                        guard_ (isNothing_ (rtScheduleTime rt) ||. rtScheduleTime rt <=. just_ (val_ now))
                        pure rt
    -- Final filter in Haskell: drop INPROGRESS mobile rows whose
    -- mb_wf_status is already terminal (defensive — these rows should
    -- have had their status flipped to a terminal lifecycle value
    -- already, but we don't trust that without the per-row check).
    let parsed = map fromRow rows
        notTerminalMobile (rt, mts) = case (NT.category rt, mts) of
            (MobileBuild, Just (MobileBuildState s)) -> not (mbStatusIsTerminal s)
            (MobileBuild, _) -> True
            _ -> True
    pure (filter notTerminalMobile parsed)
  where
    mbStatusIsTerminal :: MobileBuildTargetState -> Bool
    mbStatusIsTerminal s = case mbWfStatus s of
        MBCompleted -> True
        MBAborted -> True
        MBFailed _ -> True
        _ -> False

{- | Find any non-terminal tracker for (app_group, service). Used by the
same-service concurrency guard at create time. Excludes terminal states
and VS-edit lock rows (LOCKED, UNLOCKED).
-}
findActiveTrackersForService :: (MonadFlow m) => Text -> Text -> m [TrackerWithTarget]
findActiveTrackersForService ag svc = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtAppGroup rt ==. val_ ag)
                        guard_ (rtService rt ==. val_ svc)
                        guard_
                            ( rtStatus rt
                                `in_` [ val_ "CREATED"
                                      , val_ "INPROGRESS"
                                      , val_ "PAUSED"
                                      , val_ "ABORTING"
                                      , val_ "REVERTING"
                                      , val_ "RESTARTING"
                                      ]
                            )
                        pure rt
    pure (map fromRow rows)

-- | INPROGRESS/REVERTING releases not updated since @staleBefore@ — a live workflow thread heartbeats every tick, so only truly-abandoned rows qualify.
findInProgressReleaseTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findInProgressReleaseTrackers staleBefore = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        -- PAUSED is intentional user state — do NOT include it here, or
                        -- a backend restart would silently ABORT user-paused releases.
                        -- Only INPROGRESS/REVERTING need restart recovery (workflow
                        -- thread was lost).
                        guard_ (rtStatus rt `in_` [val_ "INPROGRESS", val_ "REVERTING"])
                        guard_ (rtUpdatedAt rt <. val_ staleBefore)
                        pure rt
    pure (map fromRow rows)

-- | Bumps @last_updated@ only, as a liveness ping — 'conditionalUpdateTracker' can go silent for a whole cooloff.
touchReleaseHeartbeat :: (MonadFlow m) => Text -> m ()
touchReleaseHeartbeat rid = withDb $ \db ->
    withConn db $ \conn -> do
        now <- liftIO getCurrentTime
        _ <-
            execute
                conn
                "UPDATE release_tracker SET last_updated = ? \
                \WHERE id = ? AND status = 'INPROGRESS'"
                (now, rid)
        pure ()

findCleanupScheduledTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findCleanupScheduledTrackers now = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` [val_ "COMPLETED", val_ "ABORTED", val_ "USER_ABORTED"])
                        pure rt
    let parsed = map fromRow rows
        isDue (_, mts) =
            case mts of
                Just (K8sState k8s) ->
                    let ctx = context k8s
                     in case podsScaleDownTimestamp ctx of
                            Just t -> t <= now && podsScaleDownStatus ctx == Just ScaleDownScheduled
                            Nothing ->
                                case cleanupAt ctx of
                                    Just t -> t <= now && cleanupStatus ctx == Just "SCALE_DOWN_SCHEDULED"
                                    Nothing -> False
                _ -> False
    pure (filter isDue parsed)

{- | Find terminal-state trackers whose NEW deployment leaked because the
abort/cleanup path never reached the scale-down step (process kill, OOM,
kubectl failure, etc).

Eligibility: status IN (ABORTED, USER_ABORTED, DISCARDED), release_context
has @cleanupTargetDeployment@ set, @cleanupStatus == "SCALE_DOWN_SCHEDULED"@,
@cleanupAt <= now@ (unset = overdue).
-}
findLeakedNewDeploymentTrackers :: (MonadFlow m) => UTCTime -> m [TrackerWithTarget]
findLeakedNewDeploymentTrackers now = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` [val_ "ABORTED", val_ "USER_ABORTED", val_ "DISCARDED"])
                        pure rt
    let parsed = map fromRow rows
        isDue (_, mts) = case mts of
            Just (K8sState k8s) ->
                let ctx = context k8s
                 in case (cleanupTargetDeployment ctx, cleanupStatus ctx) of
                        (Just dep, Just "SCALE_DOWN_SCHEDULED") | not (T.null dep) ->
                            case cleanupAt ctx of
                                Just t -> t <= now
                                Nothing -> True
                        _ -> False
            _ -> False
    pure (filter isDue parsed)

{- | Reset terminal-state trackers stuck in @SCALE_DOWN_INPROGRESS@
(worker crashed mid-flight) back to @SCALE_DOWN_SCHEDULED@. Call at
startup before the poll loop. Returns the number of trackers reset.
-}
resetStuckScaleDownInProgress :: (MonadFlow m) => m Int
resetStuckScaleDownInProgress = withDb $ \db ->
    withConn db $ \conn -> do
        n <-
            execute_
                conn
                "UPDATE release_tracker \
                \SET release_context = REPLACE(release_context, '\"SCALE_DOWN_INPROGRESS\"', '\"SCALE_DOWN_SCHEDULED\"') \
                \WHERE status IN ('ABORTED','USER_ABORTED','DISCARDED','COMPLETED') \
                \  AND release_context LIKE '%SCALE_DOWN_INPROGRESS%'"
        pure (fromIntegral n)

findAbortingReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
findAbortingReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt ==. val_ "ABORTING")
                        pure rt
    pure (map fromRow rows)

findOngoingReleaseTrackers :: (MonadFlow m) => m [TrackerWithTarget]
findOngoingReleaseTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` [val_ "INPROGRESS", val_ "PAUSED", val_ "ABORTING", val_ "REVERTING", val_ "RESTARTING"])
                        pure rt
    pure (map fromRow rows)

findTrackersWithStatusAndTime :: (MonadFlow m) => [Text] -> UTCTime -> m [TrackerWithTarget]
findTrackersWithStatusAndTime statusList ts = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` map val_ statusList)
                        guard_ (rtUpdatedAt rt <=. val_ ts)
                        pure rt
    pure (map fromRow rows)

findApprovedReleasesWithStatus :: (MonadFlow m) => [Text] -> m [TrackerWithTarget]
findApprovedReleasesWithStatus statusList = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt `in_` map val_ statusList)
                        guard_ (rtIsApproved rt ==. val_ (Just True))
                        pure rt
    pure (map fromRow rows)

findReleaseTrackersByCategory :: (MonadFlow m) => Text -> UTCTime -> UTCTime -> m [TrackerWithTarget]
findReleaseTrackersByCategory cat from to = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtCategory rt ==. val_ cat)
                        guard_ (rtCreatedAt rt >=. val_ from)
                        guard_ (rtCreatedAt rt <=. val_ to)
                        pure rt
    pure (map fromRow rows)

insertReleaseEvent :: (MonadFlow m) => Text -> Text -> Text -> Value -> m ()
insertReleaseEvent rid category label payload = withDb $ \db -> do
    now <- getCurrentTime
    runDB db $
        runInsert $
            insert (releaseEvents autopilotDb) $
                insertExpressions
                    [ ReleaseEventT
                        { reId = default_
                        , reReleaseId = val_ rid
                        , reCategory = val_ category
                        , reLabel = val_ label
                        , rePayload = val_ payload
                        , reCreatedAt = val_ now
                        }
                    ]

toRow :: UTCTime -> UTCTime -> ReleaseTracker -> Maybe TargetState -> ReleaseTrackerRow
toRow createdAt updatedAt ReleaseTracker{..} mts =
    ReleaseTrackerT
        { rtId = releaseId
        , rtOldVersion = oldVersion
        , rtNewVersion = newVersion
        , rtAppGroup = appGroup
        , rtService = service
        , rtPriority = priority
        , rtEnv = env
        , rtCategory = T.pack (show category)
        , rtStatus = releaseStatusToText status
        , rtReleaseWFStatus = T.pack (show releaseWFStatus)
        , rtMode = Just (modeToText mode)
        , rtCreatedBy = createdBy
        , rtApprovedBy = approvedBy
        , rtIsApproved = Just isApproved
        , rtIsInfraApproved = Just isInfraApproved
        , rtReleaseTag = Just (fromMaybe releaseId releaseTag)
        , rtScheduleTime = scheduleTime
        , rtStartTime = startTime
        , rtEndTime = endTime
        , rtRolloutStrategy = Just (encodeJsonText rolloutStrategy)
        , rtRolloutHistory = Just (encodeJsonText rolloutHistory)
        , rtTargetState = fmap encodeJsonText mts
        , rtInfo = info
        , rtDescription = description
        , rtChangeLog = changeLog
        , rtMetadata = fmap encodeJsonText metadata
        , rtGlobalId = globalId
        , rtSyncEnabled = syncEnabled
        , rtEnvOverrideData = envOverrideData
        , rtSlackThreadTs = slackThreadTs
        , rtDispatchId = Nothing
        , rtExternalRunId = Nothing
        , rtCommitSha = commitSha
        , rtSourceRef = sourceRef
        , rtRevertsReleaseId = revertsReleaseId
        , rtAbValidationStatus = abValidationStatus
        , rtAbValidation = fmap encodeJsonText abValidation
        , rtReviewStatus = Nothing
        , rtReviewSubmittedAt = Nothing
        , rtReviewDecidedAt = Nothing
        , rtReviewRejectReason = Nothing
        , rtRolloutStatus = Nothing
        , rtRolloutPercent = Nothing
        , rtStoreRolloutHistory = Nothing
        , rtAscVersionId = Nothing
        , rtAscPhasedId = Nothing
        , rtStoreTrack = Nothing
        , -- Identity: a store build holds its (version, code) slot unless it ended WITHOUT
          -- uploading an artifact — then NULL the column so (version, code) can be rebuilt.
          -- A built-then-aborted build keeps its slot (it's on the store — tag pushed).
          rtVersionCode = case mts of
            Just (MobileBuildState s)
                | claimsStoreIdentity (mbContext s) && not (slotReleased s) ->
                    mbcVersionCode (mbContext s)
            _ -> Nothing
        , rtTerminalStatus = Nothing
        , -- Creation-stamped (mkMobileTrackerRow); this row only feeds the raw-SQL
          -- writers above, whose column lists exclude both — never written here.
          rtReleaseGroupId = Nothing
        , rtReleaseGroupLabel = Nothing
        , rtCreatedAt = createdAt
        , rtUpdatedAt = updatedAt
        }
  where
    -- Discard / abort flip only the tracker status column, so the wf-status-based
    -- 'releasesIdentitySlot' never sees them and the slot stayed stuck. A never-shipped
    -- terminal status frees it too, gated on "no artifact (tag) uploaded" so a
    -- built-then-aborted build (already on the store) still keeps its slot.
    neverShippedStatus =
        releaseStatusToText status `elem` ["DISCARDED", "ABORTED", "USER_ABORTED"]
    slotReleased s =
        releasesIdentitySlot s
            || (neverShippedStatus && isNothing (mbcTagPushed (mbContext s)))

fromRow :: ReleaseTrackerRow -> TrackerWithTarget
fromRow ReleaseTrackerT{..} =
    let mTargetState = case parseJsonTextMaybe rtTargetState :: Maybe Value of
            Nothing -> Nothing
            Just v -> case fromJSON v :: Aeson.Result TargetState of
                Aeson.Success ts -> Just ts
                Aeson.Error _ -> Nothing
        -- Target context surfaced as JSON so the frontend can render cluster /
        -- namespace / scale-down status (K8s) or filter by release_group_id
        -- (mobile) without reparsing the whole target state.
        mReleaseContext = case mTargetState of
            Just (K8sState k8s) -> Just (toJSON (context k8s))
            -- Surface mbContext for the FE, plus mb_wf_status — which lives one level
            -- up in the MobileBuildState — so the releases list/detail can derive the
            -- promote→rollout lifecycle stage (ready-to-promote / in-review /
            -- rolling-out) without an extra /rollout call. The bare-tag rendering
            -- matches the rollout endpoint's rdMbStatus (tshow (mbWfStatus …)).
            Just (MobileBuildState mb) ->
                let ph = phaseFromFields (buildKind (mbContext mb)) (mbWfStatus mb) rtReviewStatus rtRolloutStatus rtRolloutPercent rtStoreTrack
                    disp = displayStatusInferred (reviewInferredOf (parseJsonTextMaybe rtMetadata)) ph
                 in Just (addMobileLifecycle (T.pack (show (mbWfStatus mb))) rtRolloutStatus rtRolloutPercent rtStoreTrack (dLabel disp) (variantSlug (dVariant disp)) (phaseSlug ph) rtDispatchId (toJSON (mbContext mb)))
            _ -> Nothing
        tracker =
            ReleaseTracker
                { releaseId = rtId
                , appGroup = rtAppGroup
                , service = rtService
                , env = rtEnv
                , category = parseReleaseCategory rtCategory
                , status = parseReleaseStatus rtStatus
                , releaseWFStatus = parseReleaseWFStatus rtReleaseWFStatus
                , mode = parseMode rtMode
                , createdBy = rtCreatedBy
                , approvedBy = rtApprovedBy
                , isApproved = fromMaybe False rtIsApproved
                , isInfraApproved = fromMaybe False rtIsInfraApproved
                , releaseTag = rtReleaseTag
                , dateCreated = Just rtCreatedAt
                , lastUpdated = Just rtUpdatedAt
                , scheduleTime = rtScheduleTime
                , startTime = rtStartTime
                , endTime = rtEndTime
                , rolloutStrategy = parseJsonTextOr [] rtRolloutStrategy
                , rolloutHistory = parseJsonTextOr [] rtRolloutHistory
                , oldVersion = rtOldVersion
                , newVersion = rtNewVersion
                , versionCode = rtVersionCode
                , reviewStatus = rtReviewStatus
                , info = rtInfo
                , description = rtDescription
                , changeLog = rtChangeLog
                , metadata = parseJsonTextMaybe rtMetadata
                , priority = rtPriority
                , globalId = rtGlobalId
                , syncEnabled = rtSyncEnabled
                , envOverrideData = rtEnvOverrideData
                , slackThreadTs = rtSlackThreadTs
                , releaseContext = mReleaseContext
                , sourceRef = rtSourceRef
                , commitSha = rtCommitSha
                , revertsReleaseId = rtRevertsReleaseId
                , abValidationStatus = rtAbValidationStatus
                , abValidation = parseJsonTextMaybe rtAbValidation
                }
     in (tracker, mTargetState)

{- | Inject the mobile lifecycle fields the FE derives a list row's stage from —
@mb_wf_status@ (one level up in MobileBuildState) plus the authoritative
@rollout_status@ / @rollout_percent@ COLUMNS — into the flattened mbContext JSON.
This lets the releases list/detail read the live rollout % straight off the row
(the same source the rollout endpoint uses), instead of a stale metadata mirror.
No-op if the value isn't an object.
-}
addMobileLifecycle :: Text -> Maybe Text -> Maybe Double -> Maybe Text -> Text -> Text -> Text -> Maybe Text -> Value -> Value
addMobileLifecycle st mRolloutStatus mRolloutPct mStoreTrack dispLabel dispVariant dispPhase mDispatchId (Object o) =
    Object
        . KM.insert "mb_wf_status" (toJSON st)
        . KM.insert "rollout_status" (toJSON mRolloutStatus)
        . KM.insert "rollout_percent" (toJSON mRolloutPct)
        -- Authoritative track column (migration 0034) — the FE prefers this over the
        -- metadata mirror, so a converged in-review row reads "production", not a stale
        -- "internal" left in metadata.
        . KM.insert "store_track" (toJSON mStoreTrack)
        -- Canonical backend displayStatus (label/variant) + machine phase tag, so the
        -- list renders the badge without re-deriving it.
        . KM.insert "display_label" (toJSON dispLabel)
        . KM.insert "display_variant" (toJSON dispVariant)
        . KM.insert "display_phase" (toJSON dispPhase)
        -- Dispatch-group id: rows dispatched together share one GH run — the group
        -- page renders its "shared run" chip off this. Insert only when known, so a
        -- re-application over already-built JSON (injectStoreState) can't clobber it.
        . maybe id (\d -> KM.insert "dispatch_id" (toJSON d)) mDispatchId
        $ o
addMobileLifecycle _ _ _ _ _ _ _ _ v = v

{- | Whether metadata flags the review verdict as track-INFERRED (Android
out-of-band detection, Google exposes no review state) rather than
authoritative — softens "In review" to "Pending review" in the deriver.
-}
reviewInferredOf :: Maybe Value -> Bool
reviewInferredOf (Just (Object o)) = KM.lookup "review_inferred" o == Just (Bool True)
reviewInferredOf _ = False

parseReleaseCategory :: Text -> ReleaseCategory
parseReleaseCategory t =
    case T.toUpper t of
        "BACKENDSERVICE" -> BackendService
        "BACKENDSCHEDULER" -> BackendScheduler
        "BACKENDCONFIG" -> BackendConfig
        "VSEDIT" -> VSEdit
        "MOBILEBUILD" -> MobileBuild
        -- Unknown values (including legacy categories) log a warning instead
        -- of being silently swallowed.
        _ ->
            DT.trace
                ("[parseReleaseCategory] WARNING: unknown category " <> show t <> ", defaulting to BackendService")
                BackendService

-- | Parse ReleaseWFStatus from DB text. Explicit case so unknown values warn.
parseReleaseWFStatus :: Text -> ReleaseWFStatus
parseReleaseWFStatus t =
    case T.toUpper t of
        "INIT" -> INIT
        "PREPARING" -> PREPARING
        "DEPLOYING" -> DEPLOYING
        "MONITORING" -> MONITORING
        "FINALIZING" -> FINALIZING
        "DONE" -> DONE
        "ROLLING_BACK" -> ROLLING_BACK
        _ ->
            DT.trace
                ("[parseReleaseWFStatus] WARNING: unknown status " <> show t <> ", defaulting to INIT")
                INIT

-- | Re-export of 'parseReleaseStatusText' so DB + JSON share one lookup.
parseReleaseStatus :: Text -> ReleaseStatus
parseReleaseStatus = parseReleaseStatusText

parseMode :: Maybe Text -> Mode
parseMode Nothing = AUTO
parseMode (Just t) =
    case T.toUpper t of
        "MANUAL" -> MANUAL
        "AUTO" -> AUTO
        _ ->
            DT.trace
                ("[parseMode] WARNING: unknown mode " <> show t <> ", defaulting to AUTO")
                AUTO

releaseStatusToText :: ReleaseStatus -> Text
releaseStatusToText = releaseStatusText

modeToText :: Mode -> Text
modeToText = T.pack . show

parseDecisionEngineHSStatus :: Maybe Text -> DecisionEngineHSStatus
parseDecisionEngineHSStatus Nothing = Uninitiated
parseDecisionEngineHSStatus (Just t) =
    case T.toUpper t of
        "UNINITIATED" -> Uninitiated
        "CONFIG_FOUND" -> ConfigFound
        "CONFIGFOUND" -> ConfigFound
        "STARTED" -> Started
        "RUNNING" -> Running
        "STOPPED" -> Stopped
        "AB_HS_EXCEPTION" -> AbHsException
        "ABHSEXCEPTION" -> AbHsException
        _ ->
            DT.trace
                ("[parseDecisionEngineHSStatus] WARNING: unknown status " <> show t <> ", defaulting to Uninitiated")
                Uninitiated

-- target_state is a 'text' column (not jsonb) so we encode/decode JSON
-- manually; a jsonb migration would let this go away.
encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText = LT.toStrict . AesonText.encodeToLazyText

parseJsonTextOr :: (FromJSON a) => a -> Maybe Text -> a
parseJsonTextOr fallback Nothing = fallback
parseJsonTextOr fallback (Just t) =
    case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Left _ -> fallback
        Right a -> a

parseJsonTextMaybe :: (FromJSON a) => Maybe Text -> Maybe a
parseJsonTextMaybe Nothing = Nothing
parseJsonTextMaybe (Just t) =
    case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Left _ -> Nothing
        Right a -> Just a

findReleaseTrackerByGlobalId :: (MonadFlow m) => Text -> m (Maybe TrackerWithTarget)
findReleaseTrackerByGlobalId gid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtGlobalId rt ==. val_ (Just gid))
                        pure rt
    pure $ fmap fromRow (safeHead rows)

deleteReleaseTracker :: (MonadFlow m) => Text -> m ()
deleteReleaseTracker rid = withDb $ \db -> withConn db $ \conn -> do
    _ <- execute conn "DELETE FROM release_tracker WHERE id = ?" (Only rid)
    pure ()

deleteReleaseEvents :: (MonadFlow m) => Text -> m ()
deleteReleaseEvents rid = withDb $ \db -> withConn db $ \conn -> do
    _ <- execute conn "DELETE FROM release_events WHERE re_release_id = ?" (Only rid)
    pure ()

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

{- | Find completed/aborted trackers whose old deployment is due for
scale-down. Eligibility: terminal status, @end_time + delayHours < now@,
old_version looks real, and @podsScaleDownStatus == ScaleDownScheduled@.
-}
findCompletedTrackersForScaleDown :: (MonadFlow m) => UTCTime -> Double -> m [TrackerWithTarget]
findCompletedTrackersForScaleDown now delayHours = withDb $ \db -> do
    -- Push end_time cutoff into SQL; target_state JSON filtering stays in Haskell.
    let cutoff = addUTCTime (realToFrac (negate (delayHours * 3600)) :: NominalDiffTime) now
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        -- Status filter is broad; the SCALE_DOWN_SCHEDULED
                        -- predicate below is the real gate. Flag is only set
                        -- on success/revert paths, so aborts stay excluded.
                        guard_ (rtStatus rt `in_` [val_ "COMPLETED", val_ "ABORTED", val_ "USER_ABORTED"])
                        guard_ (rtEndTime rt <=. just_ (val_ cutoff))
                        pure rt
    let parsed = map fromRow rows
        -- Require an explicit SCALE_DOWN_SCHEDULED flag. Anything else
        -- (including ScaleDownInProgress/Completed) is excluded. Without
        -- this gate, an aborted release would have its OLD deployment
        -- scaled down ~3 minutes after the abort, wiping out the live
        -- serving version.
        isEligible (tracker, mts) =
            let oldVer = NT.oldVersion tracker
                hasOldVersion = not (T.null oldVer) && T.toLower oldVer /= "unknown" && oldVer /= "new"
                isScheduled = case mts of
                    Just (K8sState k8s) -> podsScaleDownStatus (context k8s) == Just ScaleDownScheduled
                    _ -> False
             in hasOldVersion && isScheduled
    pure (filter isEligible parsed)

{- | Store the Slack thread_ts write-once: the @slack_thread_ts IS NULL@
guard makes the UPDATE atomic under MVCC, so concurrent notifications
can't race-overwrite each other's thread ids. Best-effort; callers don't
need to check the row count.
-}
updateReleaseTrackerSlackThreadTs :: (MonadFlow m) => Text -> Text -> m ()
updateReleaseTrackerSlackThreadTs rid value = withDb $ \db ->
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                "UPDATE release_tracker SET slack_thread_ts = ? \
                \WHERE id = ? AND slack_thread_ts IS NULL"
                (value, rid)
        pure ()

insertReleaseTrackerRow :: (MonadFlow m) => ReleaseTrackerRow -> m ()
insertReleaseTrackerRow row = withDb $ \db ->
    withConn db $ \conn ->
        withTransaction conn $ do
            -- Preserve slack_thread_ts when the caller's row is a stale
            -- snapshot (e.g. VS-edit retry / discard-sweep recreation).
            existingTs <-
                query
                    conn
                    "SELECT slack_thread_ts FROM release_tracker WHERE id = ?"
                    (Only (rtId row))
            let preservedTs = case existingTs of
                    [Only (Just ts)] -> Just ts
                    _ -> rtSlackThreadTs row
                mergedRow = row{rtSlackThreadTs = preservedTs}
            _ <- execute conn "DELETE FROM release_tracker WHERE id = ?" (Only (rtId row))
            runBeamLogged conn $ runInsert $ insert (releaseTrackers autopilotDb) $ insertValues [mergedRow]

{- | Insert several tracker rows in a SINGLE transaction — either all rows
commit or none do. Used by the mobile create endpoint so a batch of N release
rows (one per selected app, sharing a @release_group_id@) is all-or-nothing.

Unlike 'insertReleaseTrackerRow' this does no per-row DELETE / slack_thread_ts
preservation: callers use it only for freshly-minted ids (no existing row to
merge). Empty input is a no-op.
-}
insertReleaseTrackerRowsBatch :: (MonadFlow m) => [ReleaseTrackerRow] -> m ()
insertReleaseTrackerRowsBatch [] = pure ()
insertReleaseTrackerRowsBatch rows = withDb $ \db ->
    withConn db $ \conn ->
        withTransaction conn $
            runBeamLogged conn $
                runInsert $
                    insert (releaseTrackers autopilotDb) $
                        insertValues rows

{- | Insert a tracker row unless it violates a unique constraint
(@INSERT … ON CONFLICT DO NOTHING@). Returns 'True' if a row was inserted,
'False' if a conflicting row already existed.

Used by store sync so two concurrent passes / SCC replicas can't create
duplicate synthetic rows for the same app + version — guarded by the
@uq_release_tracker_store_sync@ partial index (migration 0021). Unlike
'insertReleaseTrackerRow' it does no DELETE-by-id (callers use fresh ids).
-}
insertReleaseTrackerRowIfAbsent :: (MonadFlow m) => ReleaseTrackerRow -> m Bool
insertReleaseTrackerRowIfAbsent row = withDb $ \db ->
    withConn db $ \conn ->
        withTransaction conn $ do
            inserted <-
                runBeamLogged conn $
                    runPgInsertReturningList $
                        insertReturning
                            (releaseTrackers autopilotDb)
                            (insertValues [row])
                            (onConflict anyConflict onConflictDoNothing)
                            (Just rtId)
            pure (not (null inserted))

findActiveSyncTrackers :: (MonadFlow m) => m [ReleaseTracker]
findActiveSyncTrackers = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (asc_ . rtCreatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtSyncEnabled rt ==. val_ (Just "true"))
                        guard_ (rtStatus rt ==. val_ "COMPLETED")
                        pure rt
    pure (map (fst . fromRow) rows)

{- | Force-flip trackers stuck in DISCARDING longer than @ageMinutes@ to
DISCARDED. Grace period absorbs in-flight kubectl calls before declaring
them dead. Returns the number of trackers flipped.
-}
sweepStaleDiscardingTrackers :: (MonadFlow m) => Int -> m Int
sweepStaleDiscardingTrackers ageMinutes = withDb $ \db -> do
    now <- liftIO getCurrentTime
    let cutoff = addUTCTime (negate (fromIntegral (ageMinutes * 60) :: NominalDiffTime)) now
    -- Two-step SELECT-then-UPDATE because Beam's runUpdate has no row count.
    stuckIds <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtStatus rt ==. val_ "DISCARDING")
                    guard_ (rtUpdatedAt rt <=. val_ cutoff)
                    pure (rtId rt)
    if null stuckIds
        then pure 0
        else do
            runDB db $
                runUpdate $
                    update
                        (releaseTrackers autopilotDb)
                        ( \rt ->
                            mconcat
                                [ rtStatus rt <-. val_ "DISCARDED"
                                , rtEndTime rt <-. val_ (Just now)
                                , rtUpdatedAt rt <-. val_ now
                                ]
                        )
                        ( \rt ->
                            rtStatus rt
                                ==. val_ "DISCARDING"
                                &&. rtUpdatedAt rt
                                    <=. val_ cutoff
                        )
            pure (length stuckIds)

{- | Auto-flip VS-edit trackers stuck in APPLIED to COMPLETED after
@ageMinutes@. Without this they hang forever in the operator UI's
in-flight view. Returns the count flipped.
-}
sweepAutoCompleteVsTrackers :: (MonadFlow m) => Int -> m Int
sweepAutoCompleteVsTrackers ageMinutes = withDb $ \db -> do
    now <- liftIO getCurrentTime
    let cutoff = addUTCTime (negate (fromIntegral (ageMinutes * 60) :: NominalDiffTime)) now
    stuckIds <-
        runDB db $
            runSelectReturningList $
                select $ do
                    rt <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtCategory rt ==. val_ "VSEdit")
                    guard_ (rtStatus rt ==. val_ "APPLIED")
                    guard_ (rtUpdatedAt rt <=. val_ cutoff)
                    pure (rtId rt)
    if null stuckIds
        then pure 0
        else do
            runDB db $
                runUpdate $
                    update
                        (releaseTrackers autopilotDb)
                        ( \rt ->
                            mconcat
                                [ rtStatus rt <-. val_ "COMPLETED"
                                , rtEndTime rt <-. val_ (Just now)
                                , rtUpdatedAt rt <-. val_ now
                                ]
                        )
                        ( \rt ->
                            rtCategory rt
                                ==. val_ "VSEdit"
                                &&. rtStatus rt
                                    ==. val_ "APPLIED"
                                &&. rtUpdatedAt rt
                                    <=. val_ cutoff
                        )
            pure (length stuckIds)

{- | Most recent GCLT_ABORTED tracker for (app_group, service, env).
Used by createReleaseH to block new releases on services whose previous
release was killed by the global changelog tracker until an operator
explicitly resolves it.
-}
findLastGcltAbortedTracker :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe ReleaseTracker)
findLastGcltAbortedTracker ag svc envT = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    limit_ 1 $
                        orderBy_ (desc_ . rtUpdatedAt) $ do
                            rt <- all_ (releaseTrackers autopilotDb)
                            guard_ (rtAppGroup rt ==. val_ ag)
                            guard_ (rtService rt ==. val_ svc)
                            guard_ (rtEnv rt ==. val_ envT)
                            guard_ (rtStatus rt ==. val_ "GCLT_ABORTED")
                            pure rt
    pure (fmap (fst . fromRow) (safeHead rows))

-- | Most recent release event for (release, label); used by SyncWatcher.
findEventByLabel :: (MonadFlow m) => Text -> Text -> m (Maybe ReleaseEvent)
findEventByLabel rid lbl = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    limit_ 1 $
                        orderBy_ (desc_ . reCreatedAt) $ do
                            ev <- all_ (releaseEvents autopilotDb)
                            guard_ (reReleaseId ev ==. val_ rid)
                            guard_ (reLabel ev ==. val_ lbl)
                            pure ev
    pure (safeHead rows)
