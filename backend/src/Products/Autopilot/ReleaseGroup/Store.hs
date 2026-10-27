{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | SQL for release bundles and grouped runs (migration 0057).
module Products.Autopilot.ReleaseGroup.Store (
    listBundles,
    getBundle,
    insertBundle,
    updateBundle,
    archiveBundle,
    serviceIsBundled,
    NewStep (..),
    insertRun,
    getRun,
    listRuns,
    runForRelease,
    activeRuns,
    transitionRun,
    setRunApprover,
    setStepState,
    claimStep,
    skipStarted,
)
where

import Control.Monad (forM, void)
import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime)
import Database.PostgreSQL.Simple (Connection, Only (..), Query, execute, query, withTransaction)
import Database.PostgreSQL.Simple.Types (In (..))
import Products.Autopilot.ReleaseGroup.Types

type BundleRow = (Text, Text, Text, Text, Bool, Text, UTCTime, UTCTime)

bundleCols :: Query
bundleCols = "id, name, description, definition, archived, created_by, created_at, updated_at"

toBundle :: BundleRow -> Maybe Bundle
toBundle (i, n, d, def, arch, by, c, u) = do
    stgs <- A.decodeStrict (TE.encodeUtf8 def)
    pure (Bundle i n d stgs arch by c u)

encodeStages :: [StageDef] -> Text
encodeStages = TE.decodeUtf8 . BL.toStrict . A.encode

-- | Archived bundles are hidden unless asked for.
listBundles :: (MonadFlow m) => Bool -> m [Bundle]
listBundles includeArchived = withDb $ \db -> withConn db $ \conn ->
    mapMaybe toBundle
        <$> query
            conn
            ( "SELECT "
                <> bundleCols
                <> " FROM release_bundle WHERE (? OR NOT archived) ORDER BY name"
            )
            (Only includeArchived)

getBundle :: (MonadFlow m) => Text -> m (Maybe Bundle)
getBundle bid = withDb $ \db -> withConn db $ \conn -> do
    rows <- query conn ("SELECT " <> bundleCols <> " FROM release_bundle WHERE id = ?") (Only bid)
    pure $ case rows of
        (r : _) -> toBundle r
        [] -> Nothing

-- | False when the name is already taken.
insertBundle :: (MonadFlow m) => Text -> Text -> Text -> [StageDef] -> Text -> m Bool
insertBundle bid nm desc stgs by = withDb $ \db -> withConn db $ \conn ->
    (> 0)
        <$> execute
            conn
            "INSERT INTO release_bundle (id, name, description, definition, created_by) \
            \VALUES (?, ?, ?, ?, ?) ON CONFLICT (name) DO NOTHING"
            (bid, nm, desc, encodeStages stgs, by)

-- | False when the bundle is missing or the new name collides with another.
updateBundle :: (MonadFlow m) => Text -> Text -> Text -> [StageDef] -> m Bool
updateBundle bid nm desc stgs = withDb $ \db -> withConn db $ \conn ->
    (> 0)
        <$> execute
            conn
            "UPDATE release_bundle SET name = ?, description = ?, definition = ?, updated_at = now() \
            \WHERE id = ? AND NOT EXISTS (SELECT 1 FROM release_bundle WHERE name = ? AND id <> ?)"
            (nm, desc, encodeStages stgs, bid, nm, bid)

archiveBundle :: (MonadFlow m) => Text -> Bool -> m ()
archiveBundle bid flag = withDb $ \db -> withConn db $ \conn ->
    void $ execute conn "UPDATE release_bundle SET archived = ?, updated_at = now() WHERE id = ?" (flag, bid)

-- | True when any live bundle contains this service. Used to decide whether a
-- standalone release needs the extra permission; services in no bundle are
-- unaffected.
serviceIsBundled :: (MonadFlow m) => Text -> Text -> m Bool
serviceIsBundled g s = do
    bundles <- listBundles False
    pure $ any (\b -> any (\stg -> any (\st -> st.appGroup == g && st.service == s) stg.steps) b.stages) bundles

-- | One tracker already created for a bundle step.
data NewStep = NewStep
    { stageIdx :: Int
    , stepIdx :: Int
    , stageName :: Text
    , stageMode :: StageMode
    , appGroup :: Text
    , service :: Text
    , releaseId :: Text
    }

insertRun :: (MonadFlow m) => Text -> Bundle -> Text -> Text -> Text -> [NewStep] -> m ()
insertRun rid b envName desc by newSteps = withDb $ \db -> withConn db $ \conn ->
    withTransaction conn $ do
        _ <-
            execute
                conn
                "INSERT INTO release_group_run (id, bundle_id, bundle_name, env, description, state, created_by) \
                \VALUES (?, ?, ?, ?, ?, 'PENDING_APPROVAL', ?)"
                (rid, b.bundleId, b.name, envName, desc, by)
        mapM_
            ( \s ->
                execute
                    conn
                    "INSERT INTO release_group_step \
                    \(run_id, stage_idx, step_idx, stage_name, stage_mode, app_group, service, release_id) \
                    \VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
                    (rid, s.stageIdx, s.stepIdx, s.stageName, stageModeText s.stageMode, s.appGroup, s.service, s.releaseId)
            )
            newSteps

type RunRow = (Text, Text, Text, Text, Text, Text, Text, Text, Maybe Text, UTCTime, UTCTime)

runCols :: Query
runCols = "id, bundle_id, bundle_name, env, description, state, halt_reason, created_by, approved_by, created_at, updated_at"

loadSteps :: Connection -> Text -> IO [RunStep]
loadSteps conn rid = do
    rows <-
        query
            conn
            "SELECT stage_idx, stage_mode, stage_name, app_group, service, release_id, state, step_idx \
            \FROM release_group_step WHERE run_id = ? ORDER BY stage_idx, step_idx"
            (Only rid) ::
            IO [(Int, Text, Text, Text, Text, Text, Text, Int)]
    pure
        [ RunStep si pi' sn (fromMaybe Sequential (parseStageMode m)) ag sv rel (fromMaybe Waiting (parseStepState st)) Nothing Nothing
        | (si, m, sn, ag, sv, rel, st, pi') <- rows
        ]

toRun :: RunRow -> [RunStep] -> Maybe GroupRun
toRun (i, bi, bn, e, d, st, hr, by, ap, c, u) stps = do
    s <- parseRunState st
    pure (GroupRun i bi bn e d s hr by ap c u stps)

getRun :: (MonadFlow m) => Text -> m (Maybe GroupRun)
getRun rid = withDb $ \db -> withConn db $ \conn -> do
    rows <- query conn ("SELECT " <> runCols <> " FROM release_group_run WHERE id = ?") (Only rid)
    case rows of
        (r : _) -> toRun r <$> loadSteps conn rid
        [] -> pure Nothing

-- | Newest first.
listRuns :: (MonadFlow m) => Int -> m [GroupRun]
listRuns lim = withDb $ \db -> withConn db $ \conn -> do
    rows <- query conn ("SELECT " <> runCols <> " FROM release_group_run ORDER BY created_at DESC LIMIT ?") (Only lim)
    fmap (mapMaybe id) $ forM rows $ \r@(i, _, _, _, _, _, _, _, _, _, _) -> toRun r <$> loadSteps conn i

-- | Runs the coordinator has to look at.
activeRuns :: (MonadFlow m) => m [GroupRun]
activeRuns = withDb $ \db -> withConn db $ \conn -> do
    rows <- query conn ("SELECT " <> runCols <> " FROM release_group_run WHERE state = 'RUNNING'") ()
    fmap (mapMaybe id) $ forM rows $ \r@(i, _, _, _, _, _, _, _, _, _, _) -> toRun r <$> loadSteps conn i

-- | (run id, run state) of the group a tracker belongs to, if any.
runForRelease :: (MonadFlow m) => Text -> m (Maybe (Text, RunState))
runForRelease rel = withDb $ \db -> withConn db $ \conn -> do
    rows <-
        query
            conn
            "SELECT r.id, r.state FROM release_group_step s JOIN release_group_run r ON r.id = s.run_id \
            \WHERE s.release_id = ? LIMIT 1"
            (Only rel) ::
            IO [(Text, Text)]
    pure $ case rows of
        ((i, st) : _) -> (,) i <$> parseRunState st
        [] -> Nothing

-- | CAS: only moves the run if it is currently in one of @from@.
transitionRun :: (MonadFlow m) => Text -> [RunState] -> RunState -> Text -> m Bool
transitionRun rid from to reason = withDb $ \db -> withConn db $ \conn ->
    (> 0)
        <$> execute
            conn
            "UPDATE release_group_run SET state = ?, halt_reason = ?, updated_at = now() WHERE id = ? AND state IN ?"
            (runStateText to, reason, rid, In (map runStateText from))

setRunApprover :: (MonadFlow m) => Text -> Text -> m ()
setRunApprover rid who = withDb $ \db -> withConn db $ \conn ->
    void $ execute conn "UPDATE release_group_run SET approved_by = ?, updated_at = now() WHERE id = ?" (who, rid)

setStepState :: (MonadFlow m) => Text -> Int -> Int -> StepState -> m ()
setStepState rid si pi' st = withDb $ \db -> withConn db $ \conn ->
    void $
        execute
            conn
            "UPDATE release_group_step SET state = ? WHERE run_id = ? AND stage_idx = ? AND step_idx = ?"
            (stepStateText st, rid, si, pi')

-- | CAS WAITING -> STARTED so two coordinators never start the same step.
claimStep :: (MonadFlow m) => Text -> Int -> Int -> m Bool
claimStep rid si pi' = withDb $ \db -> withConn db $ \conn ->
    (> 0)
        <$> execute
            conn
            "UPDATE release_group_step SET state = 'STARTED' \
            \WHERE run_id = ? AND stage_idx = ? AND step_idx = ? AND state = 'WAITING'"
            (rid, si, pi')

-- | Mark the given started steps skipped (operator chose to move past them).
skipStarted :: (MonadFlow m) => Text -> [(Int, Int)] -> m ()
skipStarted rid = mapM_ (\(si, pi') -> setStepState rid si pi' Skipped)
