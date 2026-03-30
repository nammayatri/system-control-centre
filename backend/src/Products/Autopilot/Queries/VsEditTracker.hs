{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Queries.VsEditTracker where

import Core.DB.Connection (runDB)
import Core.Environment (DBEnv)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import GHC.Int (Int32)
import Shared.Types.Storage.Schema

insertVsEditTracker :: DBEnv -> VsEditTracker -> IO ()
insertVsEditTracker db row =
    runDB db $
        runInsert $
            insert (vsEditTrackers nammaAPDb) $
                insertValues [row]

findVsEditTrackerById :: DBEnv -> Text -> IO (Maybe VsEditTracker)
findVsEditTrackerById db tid = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    t <- all_ (vsEditTrackers nammaAPDb)
                    guard_ (vetId t ==. val_ tid)
                    pure t
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

listVsEditTrackers :: DBEnv -> Maybe UTCTime -> Maybe UTCTime -> IO [VsEditTracker]
listVsEditTrackers db mFrom mTo =
    runDB db $
        runSelectReturningList $
            select $
                orderBy_ (desc_ . vetCreatedAt) $ do
                    t <- all_ (vsEditTrackers nammaAPDb)
                    case mFrom of
                        Just from -> guard_ (vetCreatedAt t >=. val_ from)
                        Nothing -> pure ()
                    case mTo of
                        Just to -> guard_ (vetCreatedAt t <=. val_ to)
                        Nothing -> pure ()
                    pure t

updateVsEditTracker :: DBEnv -> VsEditTracker -> IO ()
updateVsEditTracker db row = do
    runDB db $ do
        runDelete $
            delete (vsEditTrackers nammaAPDb) (\t -> vetId t ==. val_ (vetId row))
        runInsert $
            insert (vsEditTrackers nammaAPDb) $
                insertValues [row]

deleteVsEditTracker :: DBEnv -> Text -> IO ()
deleteVsEditTracker db tid =
    runDB db $
        runDelete $
            delete (vsEditTrackers nammaAPDb) (\t -> vetId t ==. val_ tid)

-- | Find active lock on a VS (non-expired, is_locked = true)
findActiveLock :: DBEnv -> Text -> Text -> Text -> UTCTime -> IO (Maybe VsEditTracker)
findActiveLock db product' vsName' env' now = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    t <- all_ (vsEditTrackers nammaAPDb)
                    guard_ (vetProduct t ==. val_ product')
                    guard_ (vetVsName t ==. val_ vsName')
                    guard_ (vetEnv t ==. val_ env')
                    guard_ (vetIsLocked t ==. val_ (Just True))
                    guard_ (vetLockExpiry t >=. val_ (Just now))
                    pure t
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

-- | List all release configs (no filter)
listAllReleaseConfigs :: DBEnv -> IO [ReleaseConfig]
listAllReleaseConfigs db =
    runDB db $
        runSelectReturningList $
            select $
                all_ (releaseConfig nammaAPDb)

-- | Find product config by ID
findProductConfigById :: DBEnv -> Int32 -> IO (Maybe ProductConfig)
findProductConfigById db pid = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    p <- all_ (productConfig nammaAPDb)
                    guard_ (productConfigId p ==. val_ pid)
                    pure p
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

-- | Delete product config by ID
deleteProductConfig :: DBEnv -> Int32 -> IO ()
deleteProductConfig db pid =
    runDB db $
        runDelete $
            delete (productConfig nammaAPDb) (\p -> productConfigId p ==. val_ pid)

-- | Find release config by ID
findReleaseConfigById :: DBEnv -> Int32 -> IO (Maybe ReleaseConfig)
findReleaseConfigById db rid = do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    r <- all_ (releaseConfig nammaAPDb)
                    guard_ (releaseConfigId r ==. val_ rid)
                    pure r
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

-- | Delete release config by ID
deleteReleaseConfig :: DBEnv -> Int32 -> IO ()
deleteReleaseConfig db rid =
    runDB db $
        runDelete $
            delete (releaseConfig nammaAPDb) (\r -> releaseConfigId r ==. val_ rid)
