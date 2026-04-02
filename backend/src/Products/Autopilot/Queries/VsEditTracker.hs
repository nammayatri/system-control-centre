{-# LANGUAGE OverloadedStrings #-}

-- | VS Edit operations now use release_tracker with category='VSEdit'
-- and deployment_config for VS lock state.
-- This module provides thin wrappers for backward compatibility.
module Products.Autopilot.Queries.VsEditTracker where

import Core.DB.Connection (runDB)
import Core.Environment (DBEnv)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import Shared.Types.Storage.Schema

-- | Find active VS lock by checking deployment_config.vs_locked_by IS NOT NULL
findActiveLockFromConfig :: DBEnv -> Text -> IO (Maybe DeploymentConfig)
findActiveLockFromConfig db product' = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (deploymentConfig nammaAPDb)
                    guard_ (dcAppGroup p ==. val_ product')
                    guard_ (isNothing_ (dcService p))
                    guard_ (isNothing_ (dcVsLockedBy p) ==. val_ False)
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

-- | List VS edit trackers = release_tracker WHERE category='VSEdit'
listVsEditTrackerRows :: DBEnv -> Maybe UTCTime -> Maybe UTCTime -> IO [ReleaseTrackerRow]
listVsEditTrackerRows db mFrom mTo =
    runDB db $
        runSelectReturningList $
            select $
                orderBy_ (desc_ . rtCreatedAt) $ do
                    t <- all_ (releaseTrackers nammaAPDb)
                    guard_ (rtCategory t ==. val_ "VSEdit")
                    case mFrom of
                        Just from -> guard_ (rtCreatedAt t >=. val_ from)
                        Nothing -> pure ()
                    case mTo of
                        Just to -> guard_ (rtCreatedAt t <=. val_ to)
                        Nothing -> pure ()
                    pure t

-- | Find VS edit tracker by ID = release_tracker WHERE id=? AND category='VSEdit'
findVsEditTrackerRowById :: DBEnv -> Text -> IO (Maybe ReleaseTrackerRow)
findVsEditTrackerRowById db tid = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    t <- all_ (releaseTrackers nammaAPDb)
                    guard_ (rtId t ==. val_ tid)
                    guard_ (rtCategory t ==. val_ "VSEdit")
                    pure t
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x
