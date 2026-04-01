{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Products.Autopilot.Actions.VSEdit
    ( -- * VS Edit Tracker Handlers
      createVsEditTrackerH
    , listVsEditTrackersH
    , getVsEditTrackerH
    , updateVsEditTrackerH
    , lockVsEditTrackerH
    , unlockVsEditTrackerH
    , revertVsEditTrackerH
    , fetchCurrentVsH
    ) where

import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.VsEditTracker
import Products.Autopilot.Types.API
import qualified Shared.Types.Storage.Schema as S

-- ============================================================================
-- VS Edit Tracker CRUD
-- ============================================================================

vsEditTrackerToResponse :: S.VsEditTracker -> VsEditTrackerResponse
vsEditTrackerToResponse t =
    VsEditTrackerResponse
        { vetRespId = S.vetId t
        , vetRespProduct = S.vetProduct t
        , vetRespService = S.vetService t
        , vetRespEnv = S.vetEnv t
        , vetRespVsName = S.vetVsName t
        , vetRespOldVsData = S.vetOldVsData t
        , vetRespNewVsData = S.vetNewVsData t
        , vetRespStatus = S.vetStatus t
        , vetRespCreatedBy = S.vetCreatedBy t
        , vetRespApprovedBy = S.vetApprovedBy t
        , vetRespIsLocked = S.vetIsLocked t
        , vetRespLockedBy = S.vetLockedBy t
        , vetRespLockedAt = S.vetLockedAt t
        , vetRespLockExpiry = S.vetLockExpiry t
        , vetRespMonitoringEndTime = S.vetMonitoringEndTime t
        , vetRespInfo = S.vetInfo t
        , vetRespCreatedAt = S.vetCreatedAt t
        , vetRespUpdatedAt = S.vetUpdatedAt t
        }

createVsEditTrackerH :: CreateVsEditTrackerReq -> Flow Value
createVsEditTrackerH CreateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    tid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- Check for existing active lock
    mLock <- liftIO $ findActiveLock db product vsName env now
    case mLock of
        Just existing ->
            pure $ toJSON $ VsLockErrorResponse
                { vleError = "VS is already locked by " <> fromMaybe "unknown" (S.vetLockedBy existing)
                , vleLockedBy = S.vetLockedBy existing
                , vleLockExpiry = S.vetLockExpiry existing
                }
        Nothing -> do
            let lockExpiry = addUTCTime (15 * 60) now -- 15 min default
                row = S.VsEditTrackerT
                    { vetId = tid
                    , vetProduct = product
                    , vetService = service
                    , vetEnv = env
                    , vetVsName = vsName
                    , vetOldVsData = oldVsData
                    , vetNewVsData = Nothing
                    , vetStatus = "CREATED"
                    , vetCreatedBy = createdBy
                    , vetApprovedBy = Nothing
                    , vetIsLocked = Just True
                    , vetLockedBy = Just createdBy
                    , vetLockedAt = Just now
                    , vetLockExpiry = Just lockExpiry
                    , vetMonitoringEndTime = Nothing
                    , vetInfo = info
                    , vetCreatedAt = now
                    , vetUpdatedAt = now
                    }
            liftIO $ insertVsEditTracker db row
            pure $ toJSON $ vsEditTrackerToResponse row

listVsEditTrackersH :: Maybe Text -> Maybe Text -> Flow [VsEditTrackerResponse]
listVsEditTrackersH mFrom mTo = do
    db <- getDBEnv
    let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
            Just v -> Just v
            Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
        from = mFrom >>= tryParse
        to = mTo >>= tryParse
    rows <- liftIO $ listVsEditTrackers db from to
    pure $ map vsEditTrackerToResponse rows

getVsEditTrackerH :: Text -> Flow Value
getVsEditTrackerH tid = do
    db <- getDBEnv
    m <- liftIO $ findVsEditTrackerById db tid
    case m of
        Nothing -> pure $ toJSON $ ErrorResponse "VS edit tracker not found" Nothing
        Just t -> pure $ toJSON $ vsEditTrackerToResponse t

updateVsEditTrackerH :: Text -> UpdateVsEditTrackerReq -> Flow APIResponse
updateVsEditTrackerH tid UpdateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            let updated = existing
                    { S.vetNewVsData = case newVsData of
                        Just d -> Just d
                        Nothing -> S.vetNewVsData existing
                    , S.vetStatus = fromMaybe (S.vetStatus existing) status
                    , S.vetApprovedBy = case approvedBy of
                        Just a -> Just a
                        Nothing -> S.vetApprovedBy existing
                    , S.vetInfo = case info of
                        Just i -> Just i
                        Nothing -> S.vetInfo existing
                    , S.vetUpdatedAt = now
                    }
            liftIO $ updateVsEditTracker db updated
            case status of
                Just "APPLIED" -> liftIO $ notifyVsEditApplied db (S.vetProduct existing) (S.vetService existing) (fromMaybe "admin" approvedBy)
                _ -> pure ()
            pure $ APIResponse "SUCCESS" "VS edit tracker updated"

lockVsEditTrackerH :: VsLockReq -> Flow APIResponse
lockVsEditTrackerH VsLockReq{..} = do
    db <- getDBEnv
    cfg <- getConfig
    now <- liftIO getCurrentTime
    -- Resolve vsName from product_config if not provided
    mProdCfg <- liftIO $ findProductByNameAndCluster db product ""
    let resolvedVsName = fromMaybe (maybe "" getProductVsName mProdCfg) vsName
        resolvedEnv = fromMaybe (envName cfg) env
        resolvedService = fromMaybe "" service
        resolvedLockedBy = fromMaybe "admin" lockedBy
    -- Check for existing active lock
    mLock <- liftIO $ findActiveLock db product resolvedVsName resolvedEnv now
    case mLock of
        Just existing ->
            pure $ APIResponse "ERROR" ("VS already locked by " <> fromMaybe "unknown" (S.vetLockedBy existing))
        Nothing -> do
            tid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let durationSecs = fromIntegral (fromMaybe 15 lockDurationMinutes) * 60
                lockExpiry = addUTCTime durationSecs now
                row = S.VsEditTrackerT
                    { vetId = tid
                    , vetProduct = product
                    , vetService = resolvedService
                    , vetEnv = resolvedEnv
                    , vetVsName = resolvedVsName
                    , vetOldVsData = oldVsData
                    , vetNewVsData = Nothing
                    , vetStatus = "LOCKED"
                    , vetCreatedBy = resolvedLockedBy
                    , vetApprovedBy = Nothing
                    , vetIsLocked = Just True
                    , vetLockedBy = Just resolvedLockedBy
                    , vetLockedAt = Just now
                    , vetLockExpiry = Just lockExpiry
                    , vetMonitoringEndTime = Nothing
                    , vetInfo = Nothing
                    , vetCreatedAt = now
                    , vetUpdatedAt = now
                    }
            liftIO $ insertVsEditTracker db row
            liftIO $ notifyVsEditLocked db product (fromMaybe "" service) (fromMaybe "admin" lockedBy)
            pure $ APIResponse "SUCCESS" ("VS locked. Tracker ID: " <> tid)

unlockVsEditTrackerH :: VsUnlockReq -> Flow APIResponse
unlockVsEditTrackerH VsUnlockReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    -- Can unlock by trackerId OR by product+vsName+env
    case trackerId of
        Just tid -> do
            m <- liftIO $ findVsEditTrackerById db tid
            case m of
                Nothing -> pure $ APIResponse "ERROR" "Tracker not found"
                Just existing -> do
                    let updated = existing { S.vetIsLocked = Just False, S.vetLockExpiry = Just now, S.vetUpdatedAt = now, S.vetStatus = "UNLOCKED" }
                    liftIO $ updateVsEditTracker db updated
                    liftIO $ notifyVsEditUnlocked db (S.vetProduct existing) (S.vetService existing)
                    pure $ APIResponse "SUCCESS" "VS unlocked"
        Nothing -> do
            let p = fromMaybe "" product
                v = fromMaybe "" vsName
                e = fromMaybe "" env
            mLock <- liftIO $ findActiveLock db p v e now
            case mLock of
                Nothing -> pure $ APIResponse "ERROR" "No active lock found"
                Just existing -> do
                    let updated = existing { S.vetIsLocked = Just False, S.vetLockExpiry = Just now, S.vetUpdatedAt = now, S.vetStatus = "UNLOCKED" }
                    liftIO $ updateVsEditTracker db updated
                    liftIO $ notifyVsEditUnlocked db (S.vetProduct existing) (S.vetService existing)
                    pure $ APIResponse "SUCCESS" "VS unlocked"

revertVsEditTrackerH :: Text -> Flow APIResponse
revertVsEditTrackerH tid = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            case S.vetOldVsData existing of
                Nothing -> pure $ APIResponse "ERROR" "No old VS data to revert to"
                Just _oldData -> do
                    let updated = existing
                            { S.vetStatus = "REVERTED"
                            , S.vetUpdatedAt = now
                            }
                    liftIO $ updateVsEditTracker db updated
                    liftIO $ notifyVsEditReverted db (S.vetProduct existing) (S.vetService existing)
                    pure $ APIResponse "SUCCESS" "VS edit tracker marked as REVERTED"

-- | Fetch the current live VirtualService JSON from K8s
-- Uses the product_config's vsName (e.g. "atlas-vs"), NOT the service name
fetchCurrentVsH :: Maybe Text -> Maybe Text -> Flow Value
fetchCurrentVsH mProduct _mService = do
    cfg <- getConfig
    db <- getDBEnv
    case mProduct of
        Just prod -> do
            mProdCfg <- liftIO $ findProductByNameAndCluster db prod ""
            case mProdCfg of
                Nothing -> pure $ toJSON $ ErrorResponse ("No product_config found for " <> prod) (Just "Configure product first")
                Just pCfg -> do
                    let ns = getProductNamespace pCfg
                        vsN = getProductVsName pCfg
                    if T.null vsN
                        then pure $ toJSON $ ErrorResponse ("No vsName configured for product " <> prod) (Just "Set vsName in product config")
                        else do
                            result <- liftIO $ getVirtualServiceJson cfg ns vsN
                            case result of
                                Left err -> pure $ toJSON $ ErrorResponse (T.pack (show err)) (Just "Failed to fetch VirtualService")
                                Right vsText -> case eitherDecode (LBS.pack (T.unpack vsText)) of
                                    Right vsJson -> pure vsJson
                                    Left _ -> pure $ object ["data" .= vsText]
        _ -> pure $ toJSON $ ErrorResponse "product query param required" Nothing
