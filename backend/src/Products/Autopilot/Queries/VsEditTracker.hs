{-# LANGUAGE OverloadedStrings #-}

{- | VS Edit operations now use release_tracker with category='VSEdit'
and deployment_config for VS lock state.

Migrated to the 'MonadFlow' constraint pattern: callers no longer need to
pass 'DBEnv' or wrap calls in 'liftIO'. Just call the query directly from
any 'MonadFlow' computation.
-}
module Products.Autopilot.Queries.VsEditTracker where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import Database.PostgreSQL.Simple (execute)
import Products.Autopilot.Types.Storage.Schema

-- | Find active VS lock by checking deployment_config.vs_locked_by IS NOT NULL
findActiveLockFromConfig :: (MonadFlow m) => Text -> m (Maybe DeploymentConfig)
findActiveLockFromConfig product' = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcAppGroup p ==. val_ product')
                    guard_ (isNothing_ (dcService p))
                    guard_ (isNothing_ (dcVsLockedBy p) ==. val_ False)
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

-- | List VS edit trackers = release_tracker WHERE category='VSEdit'
listVsEditTrackerRows :: (MonadFlow m) => Maybe UTCTime -> Maybe UTCTime -> m [ReleaseTrackerRow]
listVsEditTrackerRows mFrom mTo = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $
                orderBy_ (desc_ . rtCreatedAt) $ do
                    t <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtCategory t ==. val_ "VSEdit")
                    case mFrom of
                        Just from -> guard_ (rtCreatedAt t >=. val_ from)
                        Nothing -> pure ()
                    case mTo of
                        Just to -> guard_ (rtCreatedAt t <=. val_ to)
                        Nothing -> pure ()
                    pure t

-- | Find VS edit tracker by ID = release_tracker WHERE id=? AND category='VSEdit'
findVsEditTrackerRowById :: (MonadFlow m) => Text -> m (Maybe ReleaseTrackerRow)
findVsEditTrackerRowById tid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    t <- all_ (releaseTrackers autopilotDb)
                    guard_ (rtId t ==. val_ tid)
                    guard_ (rtCategory t ==. val_ "VSEdit")
                    pure t
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

{- | Mark as DISCARDED any CREATED VSEdit tracker for the given app_group
whose id is NOT the one just created. Mirrors Julia's
'validateExistingVSTrackers' + 'discardIfDuplicate' post-insert cleanup
(api/vsedit/create.jl:46-62). This closes the TOCTOU window between two
concurrent createVsEditTrackerH calls that both manage to acquire the VS
lock (e.g. if one caller observes a stale lock and installs a new one
just as another call succeeds with the same owner).

Returns the number of trackers discarded.
-}
discardDuplicateCreatedVsTrackers :: (MonadFlow m) => Text -> Text -> m Int
discardDuplicateCreatedVsTrackers appGroup' keepTrackerId = withDb $ \db ->
    withConn db $ \conn -> do
        n <-
            execute
                conn
                "UPDATE release_tracker \
                \SET status = 'DISCARDED', last_updated = NOW() \
                \WHERE category = 'VSEdit' \
                \  AND app_group = ? \
                \  AND status = 'CREATED' \
                \  AND id <> ?"
                (appGroup', keepTrackerId)
        pure (fromIntegral n)
