{-# LANGUAGE LambdaCase #-}

{- | DB access for Devbox Releases (tables from migration 0055).

The rules live in two places on purpose:

  * the database refuses a second ACTIVE release for the same backend branch
    or workspace name (partial unique indexes), so no race can get past it;
  * 'createRelease' checks the per-person limit inside a transaction holding
    an advisory lock on the creator, and checks the branch / name first so the
    caller gets the running release back instead of a bare constraint error.

Updates only move a release forward from the statuses they expect, so a late
poller tick can never revive a stopped release.
-}
module Products.Devbox.Queries (
    createRelease,
    getRelease,
    listReleases,
    filterCounts,
    activeForBranch,
    releaseEvents,
    releaseBuilds,
    pollableReleases,
    insertEvent,
    insertEventOnce,
    setError,
    setRun,
    setStage,
    ReadyInfo (..),
    setReady,
    setFailed,
    setStopping,
    setStopped,
)
where

import Control.Exception qualified as CE
import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Connection, Only (..), Query, SqlError (..), execute, query, query_, withTransaction, (:.) (..))
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Products.Devbox.Types

-- | Columns of devbox_release in 'DevboxRelease' field order.
releaseCols :: Query
releaseCols =
    "id, workspace, status, stage, current_action, \
    \backend_branch, backend_sha, cc_branch, cc_sha, frontend_branch, frontend_sha, \
    \build_android, build_ios, data_source, data_version, \
    \devbox_name, devbox_host, devbox_user, backend_url, cc_url, \
    \gh_run_id, gh_run_url, error, created_by, stopped_by, stop_reason, \
    \created_at, updated_at, ready_at, expires_at, stopped_at"

activeArr :: PGArray Text
activeArr = PGArray activeStatuses

{- | Create a release, or say why not. @maxActive@ and @lifetimeDays@ come from
server_config (devbox_max_active_per_user / devbox_lifetime_days).
-}
createRelease :: (MonadFlow m) => Int -> Int -> NewRelease -> m (Either CreateError DevboxRelease)
createRelease maxActive lifetimeDays nr =
    withDb $ \db -> withConn db $ \conn -> do
        r <- CE.try (withTransaction conn (txn conn))
        case r of
            Right x -> pure x
            -- Lost a race to another create between our check and our insert:
            -- the unique index refused it; report the release that won.
            Left e
                | sqlState e == "23505" ->
                    clash conn >>= maybe (CE.throwIO e) (pure . Left)
                | otherwise -> CE.throwIO e
  where
    txn conn = do
        _ <-
            query conn "SELECT 1 FROM (SELECT pg_advisory_xact_lock(hashtext(?))) l" (Only ("devbox:" <> nrCreatedBy nr)) ::
                IO [Only Int]
        mine <-
            query conn "SELECT count(*) FROM devbox_release WHERE created_by = ? AND status = ANY(?)" (nrCreatedBy nr, activeArr)
        if countOf mine >= fromIntegral maxActive
            then pure (Left (TooManyActive maxActive))
            else
                clash conn >>= \case
                    Just err -> pure (Left err)
                    Nothing -> do
                        rows <-
                            query
                                conn
                                ( "INSERT INTO devbox_release \
                                  \  (id, workspace, backend_branch, backend_sha, cc_branch, cc_sha, \
                                  \   frontend_branch, frontend_sha, build_android, build_ios, \
                                  \   data_source, data_version, created_by, expires_at) \
                                  \VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, now() + make_interval(days => ?)) \
                                  \RETURNING "
                                    <> releaseCols
                                )
                                ( ( nrId nr
                                  , nrWorkspace nr
                                  , nrBackendBranch nr
                                  , nrBackendSha nr
                                  , nrCcBranch nr
                                  , nrCcSha nr
                                  , nrFrontendBranch nr
                                  , nrFrontendSha nr
                                  , nrBuildAndroid nr
                                  , nrBuildIos nr
                                  )
                                    :. (nrDataSource nr, nrDataVersion nr, nrCreatedBy nr, lifetimeDays)
                                )
                        case rows of
                            [x] -> pure (Right x)
                            _ -> CE.throwIO (userError "devbox_release insert returned no row")
    clash conn = do
        byBranch <- activeWhere conn "backend_branch" (nrBackendBranch nr)
        case byBranch of
            (x : _) -> pure (Just (BranchActive x))
            [] -> do
                byName <- activeWhere conn "workspace" (nrWorkspace nr)
                pure $ case byName of
                    (x : _) -> Just (WorkspaceActive x)
                    [] -> Nothing
    countOf :: [Only Int64] -> Int64
    countOf = \case
        (Only n : _) -> n
        [] -> 0

-- | Active releases where @col = value@ (col is one of our own column names).
activeWhere :: Connection -> Query -> Text -> IO [DevboxRelease]
activeWhere conn col value =
    query
        conn
        ("SELECT " <> releaseCols <> " FROM devbox_release WHERE " <> col <> " = ? AND status = ANY(?)")
        (value, activeArr)

getRelease :: (MonadFlow m) => Text -> m (Maybe DevboxRelease)
getRelease rid =
    withDb $ \db -> withConn db $ \conn -> do
        rows <- query conn ("SELECT " <> releaseCols <> " FROM devbox_release WHERE id = ?") (Only rid)
        pure $ case rows of
            (x : _) -> Just x
            [] -> Nothing

{- | One page of the list, newest first, plus the size of the filtered set.
@search@ matches the workspace name, the backend branch or the creator.
Ordered by (created_at, id): created_at alone is not unique, and LIMIT/OFFSET
paging over a non-unique order skips and repeats rows.
-}
listReleases :: (MonadFlow m) => StatusFilter -> Maybe Text -> Int -> Int -> m ([DevboxRelease], Int64)
listReleases sf search page count =
    withDb $ \db -> withConn db $ \conn -> do
        let statuses = PGArray <$> statusFilterStatuses sf
            pat = (\s -> "%" <> s <> "%") <$> search
            wher =
                " FROM devbox_release \
                \WHERE (?::text[] IS NULL OR status = ANY(?)) \
                \  AND (?::text IS NULL OR workspace ILIKE ? OR backend_branch ILIKE ? OR created_by ILIKE ?)"
            params = (statuses, statuses, pat, pat, pat, pat)
        rows <-
            query
                conn
                ("SELECT " <> releaseCols <> wher <> " ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?")
                (params :. (count, (page - 1) * count))
        total <- query conn ("SELECT count(*)" <> wher) params
        pure (rows, case total of (Only n : _) -> n; [] -> 0)

-- | The number on each filter chip, in one pass over the table.
filterCounts :: (MonadFlow m) => m FilterCounts
filterCounts =
    withDb $ \db -> withConn db $ \conn -> do
        rows <-
            query_
                conn
                "SELECT count(*), \
                \       count(*) FILTER (WHERE status = 'READY'), \
                \       count(*) FILTER (WHERE status IN ('QUEUED', 'RUNNING', 'STOPPING')), \
                \       count(*) FILTER (WHERE status IN ('STOPPED', 'FAILED')) \
                \FROM devbox_release"
        pure $ case rows of
            (c : _) -> c
            [] -> FilterCounts 0 0 0 0

-- | The active release for a backend branch, if any (the form's "already running" banner).
activeForBranch :: (MonadFlow m) => Text -> m (Maybe DevboxRelease)
activeForBranch branch =
    withDb $ \db -> withConn db $ \conn -> do
        rows <- activeWhere conn "backend_branch" branch
        pure $ case rows of
            (x : _) -> Just x
            [] -> Nothing

releaseEvents :: (MonadFlow m) => Text -> m [DevboxEvent]
releaseEvents rid =
    withDb $ \db -> withConn db $ \conn ->
        query
            conn
            "SELECT id, release_id, stage, label, payload, gh_step_url, created_at \
            \FROM devbox_release_event WHERE release_id = ? ORDER BY created_at, id"
            (Only rid)

releaseBuilds :: (MonadFlow m) => Text -> m [DevboxBuild]
releaseBuilds rid =
    withDb $ \db -> withConn db $ \conn ->
        query
            conn
            "SELECT id, release_id, platform, status, gh_run_id, gh_run_url, download_url, \
            \       build_number, error, created_at, updated_at \
            \FROM devbox_release_build WHERE release_id = ? ORDER BY platform"
            (Only rid)

-- | Releases with a GitHub run to follow (the poller's work list).
pollableReleases :: (MonadFlow m) => m [DevboxRelease]
pollableReleases =
    withDb $ \db -> withConn db $ \conn ->
        query_
            conn
            ( "SELECT "
                <> releaseCols
                <> " FROM devbox_release WHERE status IN ('QUEUED', 'RUNNING', 'STOPPING') AND gh_run_id IS NOT NULL \
                   \ORDER BY created_at"
            )

-- | Record one event (a stage started / done / skipped / failed, or info).
insertEvent :: (MonadFlow m) => Text -> Text -> Text -> Value -> Maybe Text -> m ()
insertEvent rid stage label payload stepUrl =
    withDb $ \db -> withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO devbox_release_event (release_id, stage, label, payload, gh_step_url) VALUES (?, ?, ?, ?, ?)"
                (rid, stage, label, payload, stepUrl)
        pure ()

{- | Record an event from a GitHub run at most once: the poller sees the same
finished step on every tick (and on every SCC replica), so it is keyed on
release + stage + label + the run id stored in @payload.run@.
-}
insertEventOnce :: (MonadFlow m) => Text -> Text -> Text -> Int64 -> Value -> Maybe Text -> m ()
insertEventOnce rid stage label runId payload stepUrl =
    withDb $ \db -> withConn db $ \conn -> do
        _ <-
            execute
                conn
                "INSERT INTO devbox_release_event (release_id, stage, label, payload, gh_step_url) \
                \SELECT ?, ?, ?, ?::jsonb || jsonb_build_object('run', ?::bigint), ? \
                \WHERE NOT EXISTS ( \
                \  SELECT 1 FROM devbox_release_event \
                \  WHERE release_id = ? AND stage = ? AND label = ? AND payload->>'run' = ?::text)"
                ((rid, stage, label, payload, runId, stepUrl) :. (rid, stage, label, runId))
        pure ()

-- | Note a problem on the release without changing its status (e.g. a stop run that failed).
setError :: (MonadFlow m) => Text -> Text -> m Bool
setError rid err =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute conn "UPDATE devbox_release SET error = ?, updated_at = now() WHERE id = ?" (err, rid)

-- | Remember the GitHub run of the current action (the logs button), and which action it is.
setRun :: (MonadFlow m) => Text -> Text -> Int64 -> Maybe Text -> m Bool
setRun rid action runId runUrl =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute
                conn
                "UPDATE devbox_release SET current_action = ?, gh_run_id = ?, gh_run_url = ?, updated_at = now() WHERE id = ?"
                (action, runId, runUrl, rid)

-- | The run reached a stage. A queued release becomes RUNNING.
setStage :: (MonadFlow m) => Text -> Text -> m Bool
setStage rid stage =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute
                conn
                "UPDATE devbox_release \
                \SET stage = ?, status = CASE WHEN status = 'QUEUED' THEN 'RUNNING' ELSE status END, updated_at = now() \
                \WHERE id = ? AND status IN ('QUEUED', 'RUNNING')"
                (stage, rid)

-- | What DEVBOX_RESULT says about a finished spawn.
data ReadyInfo = ReadyInfo
    { riDevboxName :: Maybe Text
    , riDevboxHost :: Maybe Text
    , riDevboxUser :: Maybe Text
    , riBackendUrl :: Maybe Text
    , riCcUrl :: Maybe Text
    , riDataVersion :: Maybe Text
    }
    deriving (Show)

-- | The spawn run finished: the release is READY with its URLs.
setReady :: (MonadFlow m) => Text -> ReadyInfo -> m Bool
setReady rid ri =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute
                conn
                "UPDATE devbox_release \
                \SET status = 'READY', stage = 'ready', ready_at = now(), updated_at = now(), error = NULL, \
                \    devbox_name = ?, devbox_host = ?, devbox_user = ?, backend_url = ?, cc_url = ?, \
                \    data_version = COALESCE(?, data_version) \
                \WHERE id = ? AND status IN ('QUEUED', 'RUNNING')"
                (riDevboxName ri, riDevboxHost ri, riDevboxUser ri, riBackendUrl ri, riCcUrl ri, riDataVersion ri, rid)

{- | The spawn run failed at its current stage. The workspace is left on the
dev-box for a look (Stop removes it), so the devbox fields are kept.
-}
setFailed :: (MonadFlow m) => Text -> Text -> m Bool
setFailed rid err =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute
                conn
                "UPDATE devbox_release SET status = 'FAILED', error = ?, updated_at = now() \
                \WHERE id = ? AND status IN ('QUEUED', 'RUNNING')"
                (err, rid)

-- | Stop was asked for (by a person, or 'system' on expiry). False if it was already stopping or stopped.
setStopping :: (MonadFlow m) => Text -> Text -> m Bool
setStopping rid actor =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute
                conn
                "UPDATE devbox_release \
                \SET status = 'STOPPING', current_action = 'stop', stopped_by = ?, updated_at = now() \
                \WHERE id = ? AND status IN ('QUEUED', 'RUNNING', 'READY', 'FAILED')"
                (actor, rid)

-- | The workspace is gone. @reason@ is user / expired / failed.
setStopped :: (MonadFlow m) => Text -> Text -> m Bool
setStopped rid reason =
    changed $
        withDb $ \db -> withConn db $ \conn ->
            execute
                conn
                "UPDATE devbox_release \
                \SET status = 'STOPPED', stop_reason = ?, stopped_at = now(), updated_at = now() \
                \WHERE id = ? AND status <> 'STOPPED'"
                (reason, rid)

changed :: (Functor m) => m Int64 -> m Bool
changed = fmap (> 0)
