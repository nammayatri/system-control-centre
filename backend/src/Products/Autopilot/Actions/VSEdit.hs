{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Products.Autopilot.Actions.VSEdit
  ( -- * VS Edit Tracker Handlers
    createVsEditTrackerH,
    listVsEditTrackersH,
    getVsEditTrackerH,
    updateVsEditTrackerH,
    lockVsEditTrackerH,
    unlockVsEditTrackerH,
    forceUnlockVsEditTrackerH,
    revertVsEditTrackerH,
    fetchCurrentVsH,
  )
where

import Control.Applicative ((<|>))
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson, requireDeploymentPermission)
import Core.Config (Config (..))
import Core.DB.Connection (withConn)
import Core.Environment (Flow, getConfig, getDBEnv)
import Core.Logging (logInfoG)
import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Data.Yaml qualified as Yaml
import Database.PostgreSQL.Simple qualified as PG
import Products.Autopilot.K8s.Execute (K8sError (..), runCmd, shellQuote)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import Products.Autopilot.Notifications
import Products.Autopilot.Queries.ProductService (findProductByNameAndCluster, getProductNamespace, getProductVsName, releaseVsLockIfOwner, tryAcquireVsLock, updateVsLockedBy)
import Products.Autopilot.Queries.ReleaseTracker (conditionalUpdateTrackerRow, insertReleaseEvent, insertReleaseTrackerRow, listReleaseEvents)
import Products.Autopilot.Queries.VsEditTracker
import Products.Autopilot.Types.API
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.Storage.Schema qualified as S
import Products.Autopilot.Workflow.Helpers (stripK8sNoiseValue)
import Shared.API.Response (APIResponse (..))

-- VS Edit Tracker CRUD (category=VSEdit rows in release_tracker)

vsStatusCreated, vsStatusApplied, vsStatusDiscarded :: Text
vsStatusCreated = "CREATED"
vsStatusApplied = "APPLIED"
vsStatusDiscarded = "DISCARDED"

-- | Atomically clear the deployment_config VS lock AND flip every LOCKED
-- VS-edit tracker row to UNLOCKED for the given app_group, in a single
-- transaction — splitting these risks half-state if the process dies between.
--
-- Returns the id of the most recently LOCKED tracker that was just freed (or
-- empty) so the caller can thread the unlock Slack notification under the
-- original lock message instead of posting a new top-level thread.
forceUnlockAppGroupTransactional :: Text -> Flow Text
forceUnlockAppGroupTransactional ag = do
  db <- getDBEnv
  liftIO $ withConn db $ \conn -> PG.withTransaction conn $ do
    -- Snapshot most-recent LOCKED tracker before flipping it (for thread_ts).
    rows <-
      PG.query
        conn
        "SELECT id FROM release_tracker \
        \WHERE category = 'VSEdit' AND status = 'LOCKED' AND app_group = ? \
        \ORDER BY date_created DESC LIMIT 1"
        (PG.Only ag) ::
        IO [PG.Only Text]
    let tid = case rows of
          (PG.Only t : _) -> t
          _ -> ""
    _ <-
      PG.execute
        conn
        "UPDATE deployment_config \
        \SET vs_locked_by = NULL, vs_lock_timestamp = NULL \
        \WHERE app_group = ? AND service IS NULL"
        (PG.Only ag)
    _ <-
      PG.execute
        conn
        "UPDATE release_tracker \
        \SET status = 'UNLOCKED', last_updated = NOW(), end_time = NOW() \
        \WHERE category = 'VSEdit' AND status = 'LOCKED' AND app_group = ?"
        (PG.Only ag)
    pure tid

-- | Convert a VSEdit release_tracker row to response. old/new VS data live in
-- SNAPSHOT events; envOverrideData/slackThreadTs are checked as legacy fallback
-- for unmigrated rows.
releaseRowToVsResponse :: S.ReleaseTrackerRow -> VsEditTrackerResponse
releaseRowToVsResponse t =
  let vsName' = fromMaybe "" (S.rtMetadata t)
   in VsEditTrackerResponse
        { vetRespId = S.rtId t,
          vetRespAppGroup = S.rtAppGroup t,
          vetRespService = S.rtService t,
          vetRespEnv = S.rtEnv t,
          vetRespVsName = vsName',
          vetRespOldVsData = S.rtEnvOverrideData t,
          vetRespNewVsData = S.rtSlackThreadTs t,
          vetRespStatus = S.rtStatus t,
          vetRespCreatedBy = S.rtCreatedBy t,
          vetRespApprovedBy = S.rtApprovedBy t,
          vetRespIsLocked = Just (S.rtStatus t == "LOCKED"),
          vetRespLockedBy = Nothing,
          vetRespLockedAt = S.rtStartTime t,
          vetRespLockExpiry = S.rtEndTime t,
          vetRespMonitoringEndTime = S.rtScheduleTime t,
          vetRespInfo = S.rtInfo t,
          vetRespCreatedAt = S.rtCreatedAt t,
          vetRespUpdatedAt = S.rtUpdatedAt t
        }

-- | Variant that overlays VS data from SNAPSHOT events onto the base response.
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
        { vetRespOldVsData = oldFromEvent <|> vetRespOldVsData base,
          vetRespNewVsData = newFromEvent <|> vetRespNewVsData base
        }

mkVsEditRow :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> Text -> UTCTime -> S.ReleaseTrackerRow
mkVsEditRow tid product' service' env' vsName' createdBy' status' now =
  S.ReleaseTrackerT
    { rtId = tid,
      rtOldVersion = "",
      rtNewVersion = "",
      rtAppGroup = product',
      rtService = service',
      rtPriority = 0,
      rtEnv = env',
      rtCategory = "VSEdit",
      rtStatus = status',
      rtReleaseWFStatus = "INIT",
      rtMode = Nothing,
      rtCreatedBy = fromMaybe "admin" createdBy',
      rtApprovedBy = Nothing,
      rtIsApproved = Nothing,
      rtIsInfraApproved = Nothing,
      rtReleaseTag = Just ("VSEDIT_" <> product' <> "_" <> T.pack (show now)),
      rtScheduleTime = Nothing,
      rtStartTime = Just now,
      rtEndTime = Nothing,
      rtRolloutStrategy = Nothing,
      rtRolloutHistory = Nothing,
      rtTargetState = Nothing,
      rtInfo = Nothing,
      rtDescription = Nothing,
      rtChangeLog = Nothing,
      rtMetadata = Just vsName',
      rtGlobalId = Nothing,
      rtSyncEnabled = Nothing,
      rtEnvOverrideData = Nothing,
      rtSlackThreadTs = Nothing,
      rtDispatchId = Nothing,
      rtExternalRunId = Nothing,
      -- Mobile/revert-only columns — not applicable to a VS edit. Must be
      -- set or the Beam row is partial and crashes on INSERT (-Wmissing-fields).
      rtSourceRef = Nothing,
      rtCommitSha = Nothing,
      rtRevertsReleaseId = Nothing,
      rtAbValidation = Nothing,
      rtAbValidationStatus = Nothing,
      rtReviewStatus = Nothing,
      rtReviewSubmittedAt = Nothing,
      rtReviewDecidedAt = Nothing,
      rtReviewRejectReason = Nothing,
      rtRolloutStatus = Nothing,
      rtRolloutPercent = Nothing,
      rtStoreRolloutHistory = Nothing,
      rtAscVersionId = Nothing,
      rtAscPhasedId = Nothing,
      rtStoreTrack = Nothing,
      rtVersionCode = Nothing,
      rtTerminalStatus = Nothing,
      rtCreatedAt = now,
      rtUpdatedAt = now
    }

createVsEditTrackerH :: AuthedPerson -> CreateVsEditTrackerReq -> Flow Value
createVsEditTrackerH ap CreateVsEditTrackerReq {..} = do
  requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_CREATE) ap appGroup
  now <- liftIO getCurrentTime
  tid <- liftIO (UUID.toText <$> UUID.nextRandom)
  -- Atomic acquire; tryAcquireVsLock treats a stale lock
  -- (> lock_expiry_delay_minutes) as released so crash-mid-edit doesn't wedge.
  acquired <- tryAcquireVsLock appGroup createdBy
  if not acquired
    then throwM (Conflict ("VS is already locked for app group " <> appGroup))
    else do
      let row = mkVsEditRow tid appGroup service env vsName (Just createdBy) vsStatusCreated now
      -- Race: insertReleaseTrackerRow and the duplicate sweep below run
      -- in separate DB connections, not one transaction. Mitigated by
      -- tryAcquireVsLock holding the VS lock across the whole handler,
      -- so a racing duplicate requires the same owner double-clicking.
      insertReleaseTrackerRow row
      -- VS_OLD snapshot is mandatory at lock time so revert can restore
      -- the original. If caller didn't supply it, fetch live VS now.
      cfg <- getConfig
      mProdCfg <- findProductByNameAndCluster appGroup ""
      let mNs = getProductNamespace <$> mProdCfg
          vsToFetch = vsName
      capturedOld <- case oldVsData of
        Just d -> pure (Just d)
        Nothing -> case mNs of
          Just ns | not (T.null vsToFetch) -> do
            result <- liftIO $ getVirtualServiceJson cfg ns vsToFetch
            case result of
              Right vsText -> pure (Just vsText)
              Left _ -> pure Nothing
          _ -> pure Nothing
      case capturedOld of
        Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_OLD" (String d)
        Nothing -> pure ()
      -- TOCTOU close: mark any earlier CREATED trackers for this VS
      -- DISCARDED so only the latest one survives.
      discardedCount <- discardDuplicateCreatedVsTrackers appGroup tid
      if discardedCount > 0
        then do
          liftIO $
            logInfoG $
              "[VS-EDIT] DISCARDED "
                <> T.pack (show discardedCount)
                <> " duplicate CREATED tracker(s) for app_group="
                <> appGroup
                <> " (kept: "
                <> tid
                <> ")"
          insertReleaseEvent
            tid
            "BUSINESS"
            "DUPLICATE_DISCARDED"
            (toJSON (object ["discardedCount" .= discardedCount, "appGroup" .= appGroup]))
        else pure ()
      notifyVsEditCreated tid appGroup service (Just createdBy)
      pure $ toJSON $ releaseRowToVsResponse row

listVsEditTrackersH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow [VsEditTrackerResponse]
listVsEditTrackersH _ap mFrom mTo = do
  let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
        Just v -> Just v
        Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
      from = mFrom >>= tryParse
      to = mTo >>= tryParse
  rows <- listVsEditTrackerRows from to
  pure $ map releaseRowToVsResponse rows

getVsEditTrackerH :: AuthedPerson -> Text -> Flow Value
getVsEditTrackerH _ap tid = do
  m <- findVsEditTrackerRowById tid
  case m of
    Nothing -> pure $ toJSON $ ErrorResponse "VS edit tracker not found" Nothing
    Just t -> do
      events <- listReleaseEvents tid
      pure $ toJSON $ releaseRowToVsResponseWithEvents t events

updateVsEditTrackerH :: AuthedPerson -> Text -> UpdateVsEditTrackerReq -> Flow APIResponse
updateVsEditTrackerH ap tid UpdateVsEditTrackerReq {..} = do
  cfg <- getConfig
  now <- liftIO getCurrentTime
  m <- findVsEditTrackerRowById tid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
    Just existing -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_UPDATE) ap (S.rtAppGroup existing)
      let oldStatusText = S.rtStatus existing
          updated =
            existing
              { S.rtStatus = fromMaybe oldStatusText status,
                S.rtApprovedBy = case approvedBy of
                  Just a -> Just a
                  Nothing -> S.rtApprovedBy existing,
                S.rtInfo = case info of
                  Just i -> Just i
                  Nothing -> S.rtInfo existing,
                S.rtUpdatedAt = now
              }
      case status of
        Just s | s == vsStatusCreated -> do
          -- Save-changes path: capture VS_NEW, VS stays locked until apply/discard.
          case newVsData of
            Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_NEW" (String d)
            Nothing -> pure ()
          ok <- conditionalUpdateTrackerRow updated oldStatusText
          if ok
            then pure $ APIResponse "SUCCESS" "VS edit saved"
            else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."
        Just s | s == vsStatusApplied -> do
          events <- listReleaseEvents tid
          let mNewVs = find (\e -> S.reCategory e == "SNAPSHOT" && S.reLabel e == "VS_NEW") events
          case mNewVs of
            Nothing -> pure $ APIResponse "ERROR" "No new VS data found"
            Just newVsEvt -> do
              mProdCfg <- findProductByNameAndCluster (S.rtAppGroup existing) ""
              case mProdCfg of
                Nothing -> pure $ APIResponse "ERROR" "No product config found"
                Just pCfg -> do
                  let ns = getProductNamespace pCfg
                      vsContent = case S.rePayload newVsEvt of
                        String s' -> s'
                        _ -> ""
                  if T.null vsContent
                    then pure $ APIResponse "ERROR" "Empty VS data"
                    else do
                      -- Known drift: kubectl replace runs BEFORE CAS-updating
                      -- the tracker row; on CAS loss the VS is patched but DB
                      -- still says CREATED. Rare + recoverable by retry;
                      -- proper fix needs K8s-side idempotency.
                      result <- liftIO $ applyVsToK8s cfg (T.unpack ns) vsContent
                      case result of
                        Left err -> pure $ APIResponse "ERROR" ("K8s apply failed: " <> err)
                        Right () -> do
                          ok <- conditionalUpdateTrackerRow updated oldStatusText
                          if ok
                            then do
                              -- Ownership-checked unlock: if expiry sweep reassigned
                              -- the lock mid-apply, don't clobber.
                              _ <- releaseVsLockIfOwner (S.rtAppGroup existing) (S.rtCreatedBy existing)
                              notifyVsEditApplied tid (S.rtAppGroup existing) (S.rtService existing) (fromMaybe "admin" approvedBy)
                              pure $ APIResponse "SUCCESS" "VS edit applied to K8s"
                            else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."
        Just s | s == vsStatusDiscarded -> do
          ok <- conditionalUpdateTrackerRow updated oldStatusText
          if ok
            then do
              -- Ownership-checked: only clear if we still hold the lock.
              _ <- releaseVsLockIfOwner (S.rtAppGroup existing) (S.rtCreatedBy existing)
              notifyVsEditDiscarded tid (S.rtAppGroup existing) (S.rtService existing)
              pure $ APIResponse "SUCCESS" "VS edit discarded"
            else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."
        _ -> do
          -- Generic update (approval, info change, etc.)
          ok <- conditionalUpdateTrackerRow updated oldStatusText
          if ok
            then do
              case newVsData of
                Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_NEW" (String d)
                Nothing -> pure ()
              case approvedBy of
                Just ab -> notifyVsEditApproved tid (S.rtAppGroup existing) (S.rtService existing) ab
                Nothing -> pure ()
              pure $ APIResponse "SUCCESS" "VS edit tracker updated"
            else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."

lockVsEditTrackerH :: AuthedPerson -> VsLockReq -> Flow APIResponse
lockVsEditTrackerH ap VsLockReq {..} = do
  requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_CREATE) ap appGroup
  cfg <- getConfig
  now <- liftIO getCurrentTime
  mProdCfg <- findProductByNameAndCluster appGroup ""
  let resolvedVsName = case vsName of
        Just v | not (T.null v) -> v
        _ -> maybe "" getProductVsName mProdCfg
      resolvedEnv = fromMaybe (envName cfg) env
      resolvedService = fromMaybe "" service
      resolvedLockedBy = fromMaybe "admin" lockedBy
  acquired <- tryAcquireVsLock appGroup resolvedLockedBy
  if not acquired
    then throwM (Conflict ("VS is already locked for app group " <> appGroup))
    else do
      tid <- liftIO (UUID.toText <$> UUID.nextRandom)
      let durationSecs = fromIntegral (fromMaybe 15 lockDurationMinutes) * 60
          lockExpiry = addUTCTime durationSecs now
          row = mkVsEditRow tid appGroup resolvedService resolvedEnv resolvedVsName (Just resolvedLockedBy) "LOCKED" now
          rowWithExpiry = row {S.rtEndTime = Just lockExpiry}
      insertReleaseTrackerRow rowWithExpiry
      capturedOld <- case oldVsData of
        Just d -> pure (Just d)
        Nothing -> case mProdCfg of
          Just pCfg | not (T.null resolvedVsName) -> do
            let ns = getProductNamespace pCfg
            result <- liftIO $ getVirtualServiceJson cfg ns resolvedVsName
            case result of
              Right vsText -> pure (Just vsText)
              Left _ -> pure Nothing
          _ -> pure Nothing
      case capturedOld of
        Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_OLD" (String d)
        Nothing -> pure ()
      notifyVsEditLocked tid appGroup (fromMaybe "" service) (fromMaybe "admin" lockedBy)
      pure $ APIResponse "SUCCESS" ("VS locked. Tracker ID: " <> tid)

-- | Ownership-checked unlock. releaseVsLockIfOwner guards the clear in a
-- single UPDATE (no TOCTOU between check and release). If the current
-- lock-holder differs from the tracker's 'rtCreatedBy' (e.g. expiry sweep
-- reassigned), the call fails and we direct the caller at force-unlock. The
-- no-tracker-id path is refused because we have no owner to verify against.
unlockVsEditTrackerH :: AuthedPerson -> VsUnlockReq -> Flow APIResponse
unlockVsEditTrackerH ap VsUnlockReq {..} = do
  now <- liftIO getCurrentTime
  case trackerId of
    Just tid -> do
      m <- findVsEditTrackerRowById tid
      case m of
        Nothing -> pure $ APIResponse "ERROR" "Tracker not found"
        Just existing -> do
          requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_UPDATE) ap (S.rtAppGroup existing)
          let expectedOwner = S.rtCreatedBy existing
          released <- releaseVsLockIfOwner (S.rtAppGroup existing) expectedOwner
          if not released
            then
              pure $
                APIResponse
                  "ERROR"
                  ( "VS lock is not held by tracker owner ('"
                      <> expectedOwner
                      <> "'). Use /vs-edit-tracker/force-unlock (superadmin only) to override."
                  )
            else do
              -- CAS on tracker row: lock is already cleared, but avoid
              -- clobbering a concurrent update to the tracker itself.
              let updated = existing {S.rtStatus = "UNLOCKED", S.rtUpdatedAt = now, S.rtEndTime = Just now}
              ok <- conditionalUpdateTrackerRow updated (S.rtStatus existing)
              if ok
                then do
                  notifyVsEditUnlocked (S.rtId existing) (S.rtAppGroup existing) (S.rtService existing)
                  pure $ APIResponse "SUCCESS" "VS unlocked"
                else
                  pure $
                    APIResponse
                      "WARNING"
                      "VS lock was released, but the tracker row was modified by another request. Please refresh."
    Nothing ->
      pure $
        APIResponse
          "ERROR"
          ( "trackerId is required to verify ownership. "
              <> maybe "" (\p -> "(app_group=" <> p <> ") ") appGroup
              <> "Use /vs-edit-tracker/force-unlock (superadmin only) if no tracker is available."
          )

-- | Superadmin-only force unlock. Bypasses the ownership check in
-- 'unlockVsEditTrackerH' for operator recovery (tracker missing, owner
-- unknown, stuck lock). Gated by 'AP_CONFIG_FORCE_UNLOCK'.
forceUnlockVsEditTrackerH :: AuthedPerson -> VsUnlockReq -> Flow APIResponse
forceUnlockVsEditTrackerH ap VsUnlockReq {..} = do
  now <- liftIO getCurrentTime
  case trackerId of
    Just tid -> do
      m <- findVsEditTrackerRowById tid
      case m of
        Nothing -> do
          -- Fall back to app_group force-unlock if tracker missing.
          case appGroup of
            Just p | not (T.null p) -> do
              requireDeploymentPermission (Proxy :: Proxy 'AP_FORCE_UNLOCK) ap p
              freedTid <- forceUnlockAppGroupTransactional p
              notifyVsEditUnlocked freedTid p ""
              pure $ APIResponse "SUCCESS" ("VS force-unlocked for app_group=" <> p <> " (tracker missing)")
            _ -> pure $ APIResponse "ERROR" "Tracker not found and no appGroup provided"
        Just existing -> do
          requireDeploymentPermission (Proxy :: Proxy 'AP_FORCE_UNLOCK) ap (S.rtAppGroup existing)
          updateVsLockedBy (S.rtAppGroup existing) Nothing
          -- Lock already force-cleared (authoritative). Tracker update
          -- is housekeeping; CAS to avoid clobbering parallel writers.
          let updated = existing {S.rtStatus = "UNLOCKED", S.rtUpdatedAt = now, S.rtEndTime = Just now}
          ok <- conditionalUpdateTrackerRow updated (S.rtStatus existing)
          if ok
            then do
              notifyVsEditUnlocked (S.rtId existing) (S.rtAppGroup existing) (S.rtService existing)
              pure $ APIResponse "SUCCESS" "VS force-unlocked"
            else
              pure $
                APIResponse
                  "WARNING"
                  "VS lock was force-cleared, but the tracker row was modified by another request. Please refresh."
    Nothing -> do
      let p = fromMaybe "" appGroup
      if T.null p
        then pure $ APIResponse "ERROR" "trackerId or appGroup required"
        else do
          requireDeploymentPermission (Proxy :: Proxy 'AP_FORCE_UNLOCK) ap p
          mLock <- findActiveLockFromConfig p
          case mLock of
            Nothing -> pure $ APIResponse "ERROR" ("No active lock found for app_group=" <> p)
            Just _existing -> do
              freedTid <- forceUnlockAppGroupTransactional p
              notifyVsEditUnlocked freedTid p ""
              pure $ APIResponse "SUCCESS" ("VS force-unlocked for app_group=" <> p)

-- | Revert an APPLIED VS edit by re-applying its VS_OLD snapshot. Creates a
-- new tracker for the revert audit trail; original is left in COMPLETED.
revertVsEditTrackerH :: AuthedPerson -> Text -> Flow APIResponse
revertVsEditTrackerH ap tid = do
  cfg <- getConfig
  m <- findVsEditTrackerRowById tid
  case m of
    Nothing -> pure $ APIResponse "ERROR" ("VS edit tracker not found: " <> tid)
    Just orig -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_RELEASE_REVERT) ap (S.rtAppGroup orig)
      if S.rtStatus orig /= "APPLIED"
        then pure $ APIResponse "ERROR" ("Cannot revert VS edit in status " <> S.rtStatus orig <> ". Only APPLIED edits can be reverted.")
        else do
          events <- listReleaseEvents tid
          let mOldVs = find (\e -> S.reCategory e == "SNAPSHOT" && S.reLabel e == "VS_OLD") events
          case mOldVs of
            Nothing -> pure $ APIResponse "ERROR" "No VS_OLD snapshot found — cannot revert."
            Just oldVsEvt -> do
              mProdCfg <- findProductByNameAndCluster (S.rtAppGroup orig) ""
              case mProdCfg of
                Nothing -> pure $ APIResponse "ERROR" "No product config found"
                Just pCfg -> do
                  let ns = getProductNamespace pCfg
                      vsN = getProductVsName pCfg
                      oldVsContent = case S.rePayload oldVsEvt of
                        String s' -> s'
                        _ -> ""
                  if T.null oldVsContent
                    then pure $ APIResponse "ERROR" "Empty VS_OLD snapshot"
                    else do
                      -- Safety check: compare VS_NEW snapshot with live VS.
                      -- If they differ, a release or another edit changed the
                      -- VS after this edit was applied — revert would clobber
                      -- those changes.
                      let mNewVs = find (\e -> S.reCategory e == "SNAPSHOT" && S.reLabel e == "VS_NEW") events
                          newVsContent = case mNewVs of
                            Just evt -> case S.rePayload evt of
                              String s' -> s'
                              _ -> ""
                            Nothing -> ""
                      liveVsResult <- liftIO $ getVirtualServiceJson cfg ns vsN
                      case liveVsResult of
                        Left _ -> pure $ APIResponse "ERROR" "Failed to fetch live VS from k8s — cannot verify safety of revert."
                        Right liveVsText -> do
                          let cleanSpec t = case eitherDecode (LBS.pack (T.unpack t)) of
                                Right v -> Just (stripK8sNoiseValue v)
                                Left _ -> Nothing
                              liveClean = cleanSpec liveVsText
                              snapshotClean = cleanSpec newVsContent
                              vsModified = case (liveClean, snapshotClean) of
                                (Just l, Just s) -> l /= s
                                _ -> not (T.null newVsContent)
                          if vsModified
                            then do
                              insertReleaseEvent
                                tid
                                "BUSINESS"
                                "REVERT_BLOCKED"
                                (object ["reason" .= ("VS has been modified since this edit was applied (by a release or another edit). Cannot safely revert." :: Text)])
                              pure $ APIResponse "ERROR" "VS has been modified since this edit was applied (by a release or another edit). Cannot safely revert — manual intervention required."
                            else do
                              acquired <- tryAcquireVsLock (S.rtAppGroup orig) (S.rtCreatedBy orig <> "-revert")
                              if not acquired
                                then throwM (Conflict ("VS is already locked for app group " <> S.rtAppGroup orig))
                                else do
                                  now <- liftIO getCurrentTime
                                  newTid <- liftIO (UUID.toText <$> UUID.nextRandom)
                                  let revertRow =
                                        (mkVsEditRow newTid (S.rtAppGroup orig) (S.rtService orig) (S.rtEnv orig) (fromMaybe "" (S.rtMetadata orig)) (Just (S.rtCreatedBy orig <> "-revert")) "CREATED" now)
                                          { S.rtInfo = Just ("Revert of " <> tid),
                                            S.rtDescription = Just ("Revert of " <> tid)
                                          }
                                  insertReleaseTrackerRow revertRow
                                  insertReleaseEvent newTid "BUSINESS" "REVERT_TRACKER_CREATED" (String ("Revert of " <> tid))
                                  insertReleaseEvent newTid "SNAPSHOT" "VS_NEW" (String oldVsContent)
                                  applyResult <- liftIO $ applyVsToK8s cfg (T.unpack ns) oldVsContent
                                  case applyResult of
                                    Left err -> do
                                      _ <- releaseVsLockIfOwner (S.rtAppGroup orig) (S.rtCreatedBy orig <> "-revert")
                                      pure $ APIResponse "ERROR" ("K8s apply failed during revert: " <> err)
                                    Right () -> do
                                      let appliedRow = revertRow {S.rtStatus = "APPLIED", S.rtUpdatedAt = now}
                                      casOk <- conditionalUpdateTrackerRow appliedRow "CREATED"
                                      _ <- releaseVsLockIfOwner (S.rtAppGroup orig) (S.rtCreatedBy orig <> "-revert")
                                      notifyVsEditApplied newTid (S.rtAppGroup orig) (S.rtService orig) (S.rtCreatedBy orig <> "-revert")
                                      if casOk
                                        then pure $ APIResponse "SUCCESS" ("VS edit reverted. New tracker: " <> newTid)
                                        else pure $ APIResponse "WARNING" ("VS edit applied to K8s but tracker row was modified concurrently. New tracker: " <> newTid)

-- | Fetch live VS JSON from K8s; uses deployment_config.vs_name, not service.
fetchCurrentVsH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow Value
fetchCurrentVsH _ap mProduct _mService = do
  cfg <- getConfig
  case mProduct of
    Just prod -> do
      mProdCfg <- findProductByNameAndCluster prod ""
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

-- | Apply VS data to K8s via kubectl replace.
applyVsToK8s :: Config -> String -> Text -> IO (Either Text ())
applyVsToK8s cfg ns content = do
  let cmd = unwords ["echo", shellQuote content, "|", kubectlBin cfg, "-n", ns, "replace -f -"]
  logInfoG $ "[VS-APPLY] Running: kubectl -n " <> T.pack ns <> " replace -f -"
  result <- runCmd cmd
  case result of
    Right _ -> pure (Right ())
    Left (K8sError err) -> pure (Left ("kubectl replace failed: " <> err))
