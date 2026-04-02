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
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseTrackerRow, encodeJsonText)
import Products.Autopilot.Queries.VsEditTracker
import Products.Autopilot.Types.API
import qualified Shared.Types.Storage.Schema as S

-- ============================================================================
-- VS Edit Tracker CRUD (using release_tracker with category=VSEdit)
-- ============================================================================

-- | Convert a release_tracker row (category=VSEdit) to VsEditTrackerResponse
-- VS-specific data is stored in: udf1=old_vs_data, udf2=new_vs_data, metadata=vs_name
-- Lock info is in deployment_config.vs_locked_by
releaseRowToVsResponse :: S.ReleaseTrackerRow -> VsEditTrackerResponse
releaseRowToVsResponse t =
    let vsName' = fromMaybe "" (S.rtMetadata t)  -- vs_name stored in metadata
        lockedBy = S.rtUdf1 t                     -- locked_by in udf1 (reused)
        lockExpiry = Nothing                       -- no longer tracked per-row
    in VsEditTrackerResponse
        { vetRespId = S.rtId t
        , vetRespProduct = S.rtProduct t
        , vetRespService = S.rtService t
        , vetRespEnv = S.rtEnv t
        , vetRespVsName = vsName'
        , vetRespOldVsData = S.rtUdf2 t           -- old_vs_data in udf2
        , vetRespNewVsData = S.rtUdf3 t            -- new_vs_data in udf3
        , vetRespStatus = S.rtStatus t
        , vetRespCreatedBy = S.rtCreatedBy t
        , vetRespApprovedBy = S.rtApprovedBy t
        , vetRespIsLocked = Just (S.rtStatus t == "LOCKED")
        , vetRespLockedBy = lockedBy
        , vetRespLockedAt = S.rtStartTime t
        , vetRespLockExpiry = S.rtEndTime t
        , vetRespMonitoringEndTime = S.rtScheduleTime t
        , vetRespInfo = S.rtInfo t
        , vetRespCreatedAt = S.rtCreatedAt t
        , vetRespUpdatedAt = S.rtUpdatedAt t
        }

-- | Build a release_tracker row for a VS edit
mkVsEditRow :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> Maybe Text -> Text -> UTCTime -> S.ReleaseTrackerRow
mkVsEditRow tid product' service' env' vsName' oldVsData' createdBy' status' now =
    S.ReleaseTrackerT
        { rtId = tid
        , rtOldVersion = ""
        , rtNewVersion = ""
        , rtProduct = product'
        , rtService = service'
        , rtPriority = 0
        , rtEnv = env'
        , rtCategory = "VSEdit"
        , rtStatus = status'
        , rtReleaseWFStatus = "Init"
        , rtMode = Nothing
        , rtCreatedBy = fromMaybe "admin" createdBy'
        , rtApprovedBy = Nothing
        , rtIsApproved = Nothing
        , rtIsInfraApproved = Nothing
        , rtReleaseTag = Just ("VSEDIT_" <> product' <> "_" <> T.pack (show now))
        , rtScheduleTime = Nothing
        , rtStartTime = Just now
        , rtEndTime = Nothing
        , rtRolloutStrategy = Nothing
        , rtRolloutHistory = Nothing
        , rtTargetState = Nothing
        , rtInfo = Nothing
        , rtDescription = Nothing
        , rtChangeLog = Nothing
        , rtMetadata = Just vsName'       -- vs_name in metadata
        , rtGlobalId = Nothing
        , rtUdf1 = createdBy'             -- locked_by in udf1
        , rtUdf2 = oldVsData'             -- old_vs_data in udf2
        , rtUdf3 = Nothing                -- new_vs_data in udf3 (initially empty)
        , rtCreatedAt = now
        , rtUpdatedAt = now
        }

createVsEditTrackerH :: CreateVsEditTrackerReq -> Flow Value
createVsEditTrackerH CreateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    tid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- Check for existing active lock via deployment_config
    mLock <- liftIO $ findActiveLockFromConfig db product
    case mLock of
        Just existing ->
            pure $ toJSON $ VsLockErrorResponse
                { vleError = "VS is already locked by " <> fromMaybe "unknown" (S.dcVsLockedBy existing)
                , vleLockedBy = S.dcVsLockedBy existing
                , vleLockExpiry = Nothing
                }
        Nothing -> do
            let row = mkVsEditRow tid product service env vsName oldVsData (Just createdBy) "CREATED" now
            liftIO $ insertReleaseTrackerRow db row
            -- Set vs_locked_by in deployment_config
            liftIO $ updateVsLockedBy db product (Just createdBy)
            pure $ toJSON $ releaseRowToVsResponse row

listVsEditTrackersH :: Maybe Text -> Maybe Text -> Flow [VsEditTrackerResponse]
listVsEditTrackersH mFrom mTo = do
    db <- getDBEnv
    let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
            Just v -> Just v
            Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
        from = mFrom >>= tryParse
        to = mTo >>= tryParse
    rows <- liftIO $ listVsEditTrackerRows db from to
    pure $ map releaseRowToVsResponse rows

getVsEditTrackerH :: Text -> Flow Value
getVsEditTrackerH tid = do
    db <- getDBEnv
    m <- liftIO $ findVsEditTrackerRowById db tid
    case m of
        Nothing -> pure $ toJSON $ ErrorResponse "VS edit tracker not found" Nothing
        Just t -> pure $ toJSON $ releaseRowToVsResponse t

updateVsEditTrackerH :: Text -> UpdateVsEditTrackerReq -> Flow APIResponse
updateVsEditTrackerH tid UpdateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerRowById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            let updated = existing
                    { S.rtUdf3 = case newVsData of
                        Just d -> Just d
                        Nothing -> S.rtUdf3 existing
                    , S.rtStatus = fromMaybe (S.rtStatus existing) status
                    , S.rtApprovedBy = case approvedBy of
                        Just a -> Just a
                        Nothing -> S.rtApprovedBy existing
                    , S.rtInfo = case info of
                        Just i -> Just i
                        Nothing -> S.rtInfo existing
                    , S.rtUpdatedAt = now
                    }
            liftIO $ insertReleaseTrackerRow db updated
            case status of
                Just "APPLIED" -> liftIO $ notifyVsEditApplied db (S.rtProduct existing) (S.rtService existing) (fromMaybe "admin" approvedBy)
                _ -> pure ()
            pure $ APIResponse "SUCCESS" "VS edit tracker updated"

lockVsEditTrackerH :: VsLockReq -> Flow APIResponse
lockVsEditTrackerH VsLockReq{..} = do
    db <- getDBEnv
    cfg <- getConfig
    now <- liftIO getCurrentTime
    -- Resolve vsName from deployment_config if not provided
    mProdCfg <- liftIO $ findProductByNameAndCluster db product ""
    let resolvedVsName = fromMaybe (maybe "" getProductVsName mProdCfg) vsName
        resolvedEnv = fromMaybe (envName cfg) env
        resolvedService = fromMaybe "" service
        resolvedLockedBy = fromMaybe "admin" lockedBy
    -- Check for existing active lock via deployment_config
    mLock <- liftIO $ findActiveLockFromConfig db product
    case mLock of
        Just existing ->
            pure $ APIResponse "ERROR" ("VS already locked by " <> fromMaybe "unknown" (S.dcVsLockedBy existing))
        Nothing -> do
            tid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let durationSecs = fromIntegral (fromMaybe 15 lockDurationMinutes) * 60
                lockExpiry = addUTCTime durationSecs now
                row = mkVsEditRow tid product resolvedService resolvedEnv resolvedVsName oldVsData (Just resolvedLockedBy) "LOCKED" now
                rowWithExpiry = row { S.rtEndTime = Just lockExpiry }
            liftIO $ insertReleaseTrackerRow db rowWithExpiry
            -- Set vs_locked_by in deployment_config
            liftIO $ updateVsLockedBy db product (Just resolvedLockedBy)
            liftIO $ notifyVsEditLocked db product (fromMaybe "" service) (fromMaybe "admin" lockedBy)
            pure $ APIResponse "SUCCESS" ("VS locked. Tracker ID: " <> tid)

unlockVsEditTrackerH :: VsUnlockReq -> Flow APIResponse
unlockVsEditTrackerH VsUnlockReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    case trackerId of
        Just tid -> do
            m <- liftIO $ findVsEditTrackerRowById db tid
            case m of
                Nothing -> pure $ APIResponse "ERROR" "Tracker not found"
                Just existing -> do
                    let updated = existing { S.rtStatus = "UNLOCKED", S.rtUpdatedAt = now, S.rtEndTime = Just now }
                    liftIO $ insertReleaseTrackerRow db updated
                    -- Clear vs_locked_by in deployment_config
                    liftIO $ updateVsLockedBy db (S.rtProduct existing) Nothing
                    liftIO $ notifyVsEditUnlocked db (S.rtProduct existing) (S.rtService existing)
                    pure $ APIResponse "SUCCESS" "VS unlocked"
        Nothing -> do
            let p = fromMaybe "" product
            mLock <- liftIO $ findActiveLockFromConfig db p
            case mLock of
                Nothing -> pure $ APIResponse "ERROR" "No active lock found"
                Just _existing -> do
                    -- Clear vs_locked_by in deployment_config
                    liftIO $ updateVsLockedBy db p Nothing
                    liftIO $ notifyVsEditUnlocked db p ""
                    pure $ APIResponse "SUCCESS" "VS unlocked"

revertVsEditTrackerH :: Text -> Flow APIResponse
revertVsEditTrackerH tid = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerRowById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            case S.rtUdf2 existing of  -- old_vs_data in udf2
                Nothing -> pure $ APIResponse "ERROR" "No old VS data to revert to"
                Just _oldData -> do
                    let updated = existing
                            { S.rtStatus = "REVERTED"
                            , S.rtUpdatedAt = now
                            }
                    liftIO $ insertReleaseTrackerRow db updated
                    -- Clear vs lock
                    liftIO $ updateVsLockedBy db (S.rtProduct existing) Nothing
                    liftIO $ notifyVsEditReverted db (S.rtProduct existing) (S.rtService existing)
                    pure $ APIResponse "SUCCESS" "VS edit tracker marked as REVERTED"

-- | Fetch the current live VirtualService JSON from K8s
-- Uses the deployment_config's vs_name (e.g. "atlas-vs"), NOT the service name
fetchCurrentVsH :: Maybe Text -> Maybe Text -> Flow Value
fetchCurrentVsH mProduct _mService = do
    cfg <- getConfig
    db <- getDBEnv
    case mProduct of
        Just prod -> do
            mProdCfg <- liftIO $ findProductByNameAndCluster db prod ""
            case mProdCfg of
                Nothing -> pure $ toJSON $ ErrorResponse ("No deployment_config found for " <> prod) (Just "Configure product first")
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
