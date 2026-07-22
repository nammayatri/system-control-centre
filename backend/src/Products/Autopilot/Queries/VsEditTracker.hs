{-# LANGUAGE OverloadedStrings #-}

{- | VS edit operations live on release_tracker (category='VSEdit') +
deployment_config (for VS lock state).
-}
module Products.Autopilot.Queries.VsEditTracker where

import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import Database.PostgreSQL.Simple (execute)
import Products.Autopilot.Queries.ReleaseTracker (visibleToCloud, withCloudDb)
import Products.Autopilot.Types.Storage.Schema

findActiveLockFromConfig :: (MonadFlow m) => Text -> m (Maybe DeploymentConfig)
findActiveLockFromConfig product' = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig autopilotDb)
                    guard_ (dcCloudType p ==. val_ cloud)
                    guard_ (dcAppGroup p ==. val_ product')
                    guard_ (isNothing_ (dcService p))
                    guard_ (isNothing_ (dcVsLockedBy p) ==. val_ False)
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

listVsEditTrackerRows :: (MonadFlow m) => Maybe UTCTime -> Maybe UTCTime -> m [ReleaseTrackerRow]
listVsEditTrackerRows mFrom mTo = withCloudDb $ \cloud db ->
    runDB db $
        runSelectReturningList $
            select $
                orderBy_ (desc_ . rtCreatedAt) $ do
                    t <- all_ (releaseTrackers autopilotDb)
                    guard_ (visibleToCloud cloud t)
                    guard_ (rtCategory t ==. val_ "VSEdit")
                    case mFrom of
                        Just from -> guard_ (rtCreatedAt t >=. val_ from)
                        Nothing -> pure ()
                    case mTo of
                        Just to -> guard_ (rtCreatedAt t <=. val_ to)
                        Nothing -> pure ()
                    pure t

findVsEditTrackerRowById :: (MonadFlow m) => Text -> m (Maybe ReleaseTrackerRow)
findVsEditTrackerRowById tid = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    t <- all_ (releaseTrackers autopilotDb)
                    guard_ (visibleToCloud cloud t)
                    guard_ (rtId t ==. val_ tid)
                    guard_ (rtCategory t ==. val_ "VSEdit")
                    pure t
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

{- | Mark as DISCARDED any CREATED VSEdit tracker for @appGroup'@ whose id
is not @keepTrackerId@. Closes a TOCTOU window between two concurrent
create calls that both acquire the VS lock. Returns count discarded.
-}
discardDuplicateCreatedVsTrackers :: (MonadFlow m) => Text -> Text -> m Int
discardDuplicateCreatedVsTrackers appGroup' keepTrackerId = withCloudDb $ \cloud db ->
    withConn db $ \conn -> do
        n <-
            execute
                conn
                "UPDATE release_tracker \
                \SET status = 'DISCARDED', last_updated = NOW() \
                \WHERE category = 'VSEdit' \
                \  AND app_group = ? \
                \  AND status = 'CREATED' \
                \  AND id <> ? \
                \  AND (cloud_type = ? OR cloud_type IS NULL)"
                (appGroup', keepTrackerId, cloud)
        pure (fromIntegral n)
