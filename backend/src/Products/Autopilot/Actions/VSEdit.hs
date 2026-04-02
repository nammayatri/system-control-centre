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

import Control.Applicative ((<|>))
import Control.Monad.IO.Class (liftIO)
import Data.List (find)
import Core.Config (Config (..))
import Core.Utils.FlowMonad (Flow, getConfig, getDBEnv)
import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Yaml as Yaml
import Data.Text.Encoding (decodeUtf8)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Products.Autopilot.K8s.Execute (K8sError (..), runCmd, shellQuote)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ProductService
import Products.Autopilot.Queries.ReleaseTracker (insertReleaseTrackerRow, insertReleaseEvent, listReleaseEvents)
import Products.Autopilot.Workflow.Helpers (stripK8sNoiseValue)
import Products.Autopilot.Queries.VsEditTracker
import Products.Autopilot.Types.API
import qualified Shared.Types.Storage.Schema as S

-- ============================================================================
-- VS Edit Tracker CRUD (using release_tracker with category=VSEdit)
-- ============================================================================

-- | Convert a release_tracker row (category=VSEdit) to VsEditTrackerResponse
-- VS-specific data: old_vs_data and new_vs_data are now stored as SNAPSHOT events.
-- Lock info is in deployment_config.vs_locked_by.
-- For backward compat, also check udf2/udf3 for old data that hasn't been migrated.
releaseRowToVsResponse :: S.ReleaseTrackerRow -> VsEditTrackerResponse
releaseRowToVsResponse t =
    let vsName' = fromMaybe "" (S.rtMetadata t)  -- vs_name stored in metadata
    in VsEditTrackerResponse
        { vetRespId = S.rtId t
        , vetRespAppGroup = S.rtAppGroup t
        , vetRespService = S.rtService t
        , vetRespEnv = S.rtEnv t
        , vetRespVsName = vsName'
        , vetRespOldVsData = S.rtUdf2 t           -- backward compat: old data still in udf2
        , vetRespNewVsData = S.rtUdf3 t            -- backward compat: old data still in udf3
        , vetRespStatus = S.rtStatus t
        , vetRespCreatedBy = S.rtCreatedBy t
        , vetRespApprovedBy = S.rtApprovedBy t
        , vetRespIsLocked = Just (S.rtStatus t == "LOCKED")
        , vetRespLockedBy = Nothing                -- lock info from deployment_config only
        , vetRespLockedAt = S.rtStartTime t
        , vetRespLockExpiry = S.rtEndTime t
        , vetRespMonitoringEndTime = S.rtScheduleTime t
        , vetRespInfo = S.rtInfo t
        , vetRespCreatedAt = S.rtCreatedAt t
        , vetRespUpdatedAt = S.rtUpdatedAt t
        }

-- | Enriched version that reads VS data from SNAPSHOT events
releaseRowToVsResponseWithEvents :: S.ReleaseTrackerRow -> [S.ReleaseEvent] -> VsEditTrackerResponse
releaseRowToVsResponseWithEvents t events =
    let base = releaseRowToVsResponse t
        snaps = filter (\e -> S.reCategory e == "SNAPSHOT") events
        findSnap label = find (\e -> S.reLabel e == label) snaps
        payloadText (String s) = Just s
        payloadText _ = Nothing
        oldFromEvent = findSnap "VS_OLD" >>= payloadText . S.rePayload
        newFromEvent = findSnap "VS_NEW" >>= payloadText . S.rePayload
    in base
        { vetRespOldVsData = oldFromEvent <|> vetRespOldVsData base
        , vetRespNewVsData = newFromEvent <|> vetRespNewVsData base
        }

-- | Build a release_tracker row for a VS edit
-- VS data (old/new) is now stored as SNAPSHOT events, not in udf fields.
-- Lock info is in deployment_config.vs_locked_by only.
mkVsEditRow :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> Maybe Text -> Text -> UTCTime -> S.ReleaseTrackerRow
mkVsEditRow tid product' service' env' vsName' _oldVsData' createdBy' status' now =
    S.ReleaseTrackerT
        { rtId = tid
        , rtOldVersion = ""
        , rtNewVersion = ""
        , rtAppGroup = product'
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
        , rtUdf1 = Nothing                -- no longer used for locked_by
        , rtUdf2 = Nothing                -- no longer used for old_vs_data
        , rtUdf3 = Nothing                -- no longer used for new_vs_data
        , rtCreatedAt = now
        , rtUpdatedAt = now
        }

createVsEditTrackerH :: CreateVsEditTrackerReq -> Flow Value
createVsEditTrackerH CreateVsEditTrackerReq{..} = do
    db <- getDBEnv
    now <- liftIO getCurrentTime
    tid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- Check for existing active lock via deployment_config
    mLock <- liftIO $ findActiveLockFromConfig db appGroup
    case mLock of
        Just existing ->
            pure $ toJSON $ VsLockErrorResponse
                { vleError = "VS is already locked by " <> fromMaybe "unknown" (S.dcVsLockedBy existing)
                , vleLockedBy = S.dcVsLockedBy existing
                , vleLockExpiry = Nothing
                }
        Nothing -> do
            let row = mkVsEditRow tid appGroup service env vsName oldVsData (Just createdBy) "CREATED" now
            liftIO $ insertReleaseTrackerRow db row
            -- Capture old VS data as SNAPSHOT event
            case oldVsData of
                Just d -> liftIO $ insertReleaseEvent db tid "SNAPSHOT" "VS_OLD" (String d)
                Nothing -> pure ()
            -- Set vs_locked_by in deployment_config
            liftIO $ updateVsLockedBy db appGroup (Just createdBy)
            liftIO $ notifyVsEditCreated db tid appGroup service (Just createdBy)
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
        Just t -> do
            events <- liftIO $ listReleaseEvents db tid
            pure $ toJSON $ releaseRowToVsResponseWithEvents t events

updateVsEditTrackerH :: Text -> UpdateVsEditTrackerReq -> Flow APIResponse
updateVsEditTrackerH tid UpdateVsEditTrackerReq{..} = do
    db <- getDBEnv
    cfg <- getConfig
    now <- liftIO getCurrentTime
    m <- liftIO $ findVsEditTrackerRowById db tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            let updated = existing
                    { S.rtStatus = fromMaybe (S.rtStatus existing) status
                    , S.rtApprovedBy = case approvedBy of
                        Just a -> Just a
                        Nothing -> S.rtApprovedBy existing
                    , S.rtInfo = case info of
                        Just i -> Just i
                        Nothing -> S.rtInfo existing
                    , S.rtUpdatedAt = now
                    }
            -- Handle status-specific logic
            case status of
                Just "CREATED" -> do
                    -- Saving changes: capture VS_NEW snapshot, VS stays locked until apply/discard
                    case newVsData of
                        Just d -> liftIO $ insertReleaseEvent db tid "SNAPSHOT" "VS_NEW" (String d)
                        Nothing -> pure ()
                    liftIO $ insertReleaseTrackerRow db updated
                    pure $ APIResponse "SUCCESS" "VS edit saved"

                Just "APPLIED" -> do
                    -- Get the new VS data from SNAPSHOT events
                    events <- liftIO $ listReleaseEvents db tid
                    let mNewVs = find (\e -> S.reCategory e == "SNAPSHOT" && S.reLabel e == "VS_NEW") events
                    case mNewVs of
                        Nothing -> pure $ APIResponse "ERROR" "No new VS data found"
                        Just newVsEvt -> do
                            -- Get product config for namespace
                            mProdCfg <- liftIO $ findProductByNameAndCluster db (S.rtAppGroup existing) ""
                            case mProdCfg of
                                Nothing -> pure $ APIResponse "ERROR" "No product config found"
                                Just pCfg -> do
                                    let ns = getProductNamespace pCfg
                                        vsContent = case S.rePayload newVsEvt of
                                            String s -> s
                                            _ -> ""
                                    if T.null vsContent
                                        then pure $ APIResponse "ERROR" "Empty VS data"
                                        else do
                                            -- Apply to K8s via kubectl replace
                                            result <- liftIO $ applyVsToK8s cfg (T.unpack ns) vsContent
                                            case result of
                                                Left err -> pure $ APIResponse "ERROR" ("K8s apply failed: " <> err)
                                                Right () -> do
                                                    liftIO $ insertReleaseTrackerRow db updated
                                                    -- Unlock VS after successful apply
                                                    liftIO $ updateVsLockedBy db (S.rtAppGroup existing) Nothing
                                                    liftIO $ notifyVsEditApplied db tid (S.rtAppGroup existing) (S.rtService existing) (fromMaybe "admin" approvedBy)
                                                    pure $ APIResponse "SUCCESS" "VS edit applied to K8s"

                Just "DISCARDED" -> do
                    liftIO $ insertReleaseTrackerRow db updated
                    -- Clear lock if present
                    liftIO $ updateVsLockedBy db (S.rtAppGroup existing) Nothing
                    liftIO $ notifyVsEditDiscarded db tid (S.rtAppGroup existing) (S.rtService existing)
                    pure $ APIResponse "SUCCESS" "VS edit discarded"

                _ -> do
                    -- Generic update (approval, info change, etc.)
                    liftIO $ insertReleaseTrackerRow db updated
                    case newVsData of
                        Just d -> liftIO $ insertReleaseEvent db tid "SNAPSHOT" "VS_NEW" (String d)
                        Nothing -> pure ()
                    -- Notification for approval
                    case approvedBy of
                        Just ab -> liftIO $ notifyVsEditApproved db tid (S.rtAppGroup existing) (S.rtService existing) ab
                        Nothing -> pure ()
                    pure $ APIResponse "SUCCESS" "VS edit tracker updated"

lockVsEditTrackerH :: VsLockReq -> Flow APIResponse
lockVsEditTrackerH VsLockReq{..} = do
    db <- getDBEnv
    cfg <- getConfig
    now <- liftIO getCurrentTime
    -- Resolve vsName from deployment_config if not provided
    mProdCfg <- liftIO $ findProductByNameAndCluster db appGroup ""
    let resolvedVsName = case vsName of
            Just v | not (T.null v) -> v
            _ -> maybe "" getProductVsName mProdCfg
        resolvedEnv = fromMaybe (envName cfg) env
        resolvedService = fromMaybe "" service
        resolvedLockedBy = fromMaybe "admin" lockedBy
    -- Check for existing active lock via deployment_config
    mLock <- liftIO $ findActiveLockFromConfig db appGroup
    case mLock of
        Just existing ->
            pure $ APIResponse "ERROR" ("VS already locked by " <> fromMaybe "unknown" (S.dcVsLockedBy existing))
        Nothing -> do
            tid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let durationSecs = fromIntegral (fromMaybe 15 lockDurationMinutes) * 60
                lockExpiry = addUTCTime durationSecs now
                row = mkVsEditRow tid appGroup resolvedService resolvedEnv resolvedVsName oldVsData (Just resolvedLockedBy) "LOCKED" now
                rowWithExpiry = row { S.rtEndTime = Just lockExpiry }
            liftIO $ insertReleaseTrackerRow db rowWithExpiry
            -- Capture old VS data as SNAPSHOT event
            case oldVsData of
                Just d -> liftIO $ insertReleaseEvent db tid "SNAPSHOT" "VS_OLD" (String d)
                Nothing -> pure ()
            -- Set vs_locked_by in deployment_config
            liftIO $ updateVsLockedBy db appGroup (Just resolvedLockedBy)
            liftIO $ notifyVsEditLocked db tid appGroup (fromMaybe "" service) (fromMaybe "admin" lockedBy)
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
                    liftIO $ updateVsLockedBy db (S.rtAppGroup existing) Nothing
                    liftIO $ notifyVsEditUnlocked db (S.rtId existing) (S.rtAppGroup existing) (S.rtService existing)
                    pure $ APIResponse "SUCCESS" "VS unlocked"
        Nothing -> do
            let p = fromMaybe "" appGroup
            mLock <- liftIO $ findActiveLockFromConfig db p
            case mLock of
                Nothing -> pure $ APIResponse "ERROR" "No active lock found"
                Just _existing -> do
                    -- Clear vs_locked_by in deployment_config
                    liftIO $ updateVsLockedBy db p Nothing
                    liftIO $ notifyVsEditUnlocked db "" p ""
                    pure $ APIResponse "SUCCESS" "VS unlocked"

revertVsEditTrackerH :: Text -> Flow APIResponse
revertVsEditTrackerH _tid =
    pure $ APIResponse "ERROR" "VS edit revert is not supported. Create a new VS edit instead."

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
                                    Right vsJson ->
                                        let cleaned = stripK8sNoiseValue vsJson
                                            yamlText = decodeUtf8 (Yaml.encode cleaned)
                                        in pure $ toJSON yamlText
                                    Left _ -> pure $ toJSON vsText
        _ -> pure $ toJSON $ ErrorResponse "product query param required" Nothing

-- ============================================================================
-- K8s helpers
-- ============================================================================

-- | Apply VS data to K8s via kubectl replace (same pattern as replaceFromStdin
-- in BackendConfigWorkflow)
applyVsToK8s :: Config -> String -> Text -> IO (Either Text ())
applyVsToK8s cfg ns content = do
    let cmd = unwords ["echo", shellQuote content, "|", kubectlBin cfg, "-n", ns, "replace -f -"]
    putStrLn $ "[VS-APPLY] Running: kubectl -n " <> ns <> " replace -f -"
    result <- runCmd cmd
    case result of
        Right _ -> pure (Right ())
        Left (K8sError err) -> pure (Left ("kubectl replace failed: " <> err))
