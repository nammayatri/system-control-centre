{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Products.Autopilot.Actions.VSEdit (
    -- * VS Edit Tracker Handlers
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
import Core.Auth.Protected (AuthedPerson)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig)
import Core.Logging (logInfoG)
import Data.Aeson (Value (..), eitherDecode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import qualified Data.Yaml as Yaml
import Products.Autopilot.K8s.Execute (K8sError (..), runCmd, shellQuote)
import Products.Autopilot.K8s.VirtualService (getVirtualServiceJson)
import Products.Autopilot.Notifications
import Core.DB.Connection (withConn)
import Core.Environment (getDBEnv)
import qualified Database.PostgreSQL.Simple as PG
import Products.Autopilot.Queries.ProductService (findProductByNameAndCluster, getProductNamespace, getProductVsName, releaseVsLockIfOwner, tryAcquireVsLock, updateVsLockedBy)
import Products.Autopilot.Queries.ReleaseTracker (conditionalUpdateTrackerRow, insertReleaseEvent, insertReleaseTrackerRow, listReleaseEvents)
import Products.Autopilot.Queries.VsEditTracker
import Products.Autopilot.Types.API
import qualified Products.Autopilot.Types.Storage.Schema as S
import Products.Autopilot.Workflow.Helpers (stripK8sNoiseValue)
import Shared.API.Response (APIResponse (..))

-- ============================================================================
-- VS Edit Tracker CRUD (using release_tracker with category=VSEdit)
-- ============================================================================

{- | String constants for rtStatus values used by VS edit trackers.
Centralised so the case branches in updateVsEditTrackerH stop drifting.
-}
vsStatusCreated, vsStatusApplied, vsStatusDiscarded :: Text
vsStatusCreated = "CREATED"
vsStatusApplied = "APPLIED"
vsStatusDiscarded = "DISCARDED"

{- | Atomically clear the deployment_config VS lock AND flip every LOCKED
VS-edit tracker row to UNLOCKED for the given app_group, in a single
transaction. Round 7 audit B3: doing the two updates in separate
transactions risks half-state if the process dies between them
(deployment_config.vs_locked_by=NULL while tracker rows still LOCKED).
The single txn guarantees both succeed or neither does.

Returns the id of the most recently LOCKED tracker that was just freed
(or empty), so the caller can pass it to notifyVsEditUnlocked for proper
Slack thread continuity. Without this, the unlock notification posts as
a brand-new top-level Slack message instead of replying under the lock.
-}
forceUnlockAppGroupTransactional :: Text -> Flow Text
forceUnlockAppGroupTransactional ag = do
    db <- getDBEnv
    liftIO $ withConn db $ \conn -> PG.withTransaction conn $ do
        -- Snapshot the most-recent LOCKED tracker BEFORE flipping it,
        -- so the caller can use its id for thread_ts lookup.
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

{- | Legacy single-table helper kept for the periodic expired-lock sweep
which already updates deployment_config separately in its own txn.
-}
unlockOrphanLockedTrackersForAppGroup :: Text -> Flow ()
unlockOrphanLockedTrackersForAppGroup ag = do
    db <- getDBEnv
    liftIO $ withConn db $ \conn -> do
        _ <-
            PG.execute
                conn
                "UPDATE release_tracker \
                \SET status = 'UNLOCKED', last_updated = NOW(), end_time = NOW() \
                \WHERE category = 'VSEdit' AND status = 'LOCKED' AND app_group = ?"
                (PG.Only ag)
        pure ()

{- | Convert a release_tracker row (category=VSEdit) to VsEditTrackerResponse
VS-specific data: old_vs_data and new_vs_data are now stored as SNAPSHOT events.
Lock info is in deployment_config.vs_locked_by.
For backward compat, also check envOverrideData/slackThreadTs for old data that hasn't been migrated.
-}
releaseRowToVsResponse :: S.ReleaseTrackerRow -> VsEditTrackerResponse
releaseRowToVsResponse t =
    let vsName' = fromMaybe "" (S.rtMetadata t) -- vs_name stored in metadata
     in VsEditTrackerResponse
            { vetRespId = S.rtId t
            , vetRespAppGroup = S.rtAppGroup t
            , vetRespService = S.rtService t
            , vetRespEnv = S.rtEnv t
            , vetRespVsName = vsName'
            , vetRespOldVsData = S.rtEnvOverrideData t -- backward compat: old data still in env_override_data
            , vetRespNewVsData = S.rtSlackThreadTs t -- backward compat: old data still in slack_thread_ts
            , vetRespStatus = S.rtStatus t
            , vetRespCreatedBy = S.rtCreatedBy t
            , vetRespApprovedBy = S.rtApprovedBy t
            , vetRespIsLocked = Just (S.rtStatus t == "LOCKED")
            , vetRespLockedBy = Nothing -- lock info from deployment_config only
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

{- | Build a release_tracker row for a VS edit
VS data (old/new) is now stored as SNAPSHOT events, not in udf fields.
Lock info is in deployment_config.vs_locked_by only.
-}
mkVsEditRow :: Text -> Text -> Text -> Text -> Text -> Maybe Text -> Text -> UTCTime -> S.ReleaseTrackerRow
mkVsEditRow tid product' service' env' vsName' createdBy' status' now =
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
        , rtReleaseWFStatus = "INIT"
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
        , rtMetadata = Just vsName' -- vs_name in metadata
        , rtGlobalId = Nothing
        , rtSyncEnabled = Nothing -- no longer used for locked_by
        , rtEnvOverrideData = Nothing -- no longer used for old_vs_data
        , rtSlackThreadTs = Nothing -- no longer used for new_vs_data
        , rtCreatedAt = now
        , rtUpdatedAt = now
        }

createVsEditTrackerH :: AuthedPerson -> CreateVsEditTrackerReq -> Flow Value
createVsEditTrackerH _ap CreateVsEditTrackerReq{..} = do
    now <- liftIO getCurrentTime
    tid <- liftIO (UUID.toText <$> UUID.nextRandom)
    -- Atomically acquire VS lock. The UPDATE inside tryAcquireVsLock treats a
    -- lock whose vs_lock_timestamp is stale (> lock_expiry_delay_minutes old)
    -- as released, so a crashed-mid-edit lock no longer blocks all new edits.
    -- Conflict throws HTTP 409 (was previously HTTP 200 with body-level error).
    acquired <- tryAcquireVsLock appGroup createdBy
    if not acquired
        then throwM (Conflict ("VS is already locked for app group " <> appGroup))
        else do
            let row = mkVsEditRow tid appGroup service env vsName (Just createdBy) vsStatusCreated now
            -- RACE WINDOW (task #34, M3): insertReleaseTrackerRow and the
            -- discardDuplicateCreatedVsTrackers sweep below run in two separate
            -- DB connections, NOT a single transaction. Between them, another
            -- caller can insert its own CREATED tracker that this sweep will
            -- not see (and that sweep will not see ours either if it runs
            -- first). Wrapping both in one withTransaction would require
            -- pushing both queries through a shared `Connection`, which the
            -- current Queries layer (Flow + per-call withDb) does not expose.
            -- Mitigated in practice by tryAcquireVsLock holding the VS lock
            -- across this whole handler — only the lock-owner reaches this
            -- code path, so a true racing duplicate requires the same owner
            -- double-clicking. Revisit when the query layer grows a
            -- transaction-scoped variant.
            insertReleaseTrackerRow row
            -- Capture old VS data as SNAPSHOT event
            case oldVsData of
                Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_OLD" (String d)
                Nothing -> pure ()
            -- Close the TOCTOU window: if another caller raced us (same owner,
            -- stale-lock expiry race, retry after transient error) and also
            -- created a CREATED tracker for this VS, mark those earlier trackers
            -- DISCARDED so only the latest one survives. Mirrors Julia's
            -- validateExistingVSTrackers + discardIfDuplicate (create.jl:46-62).
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
updateVsEditTrackerH _ap tid UpdateVsEditTrackerReq{..} = do
    cfg <- getConfig
    now <- liftIO getCurrentTime
    m <- findVsEditTrackerRowById tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" "VS edit tracker not found"
        Just existing -> do
            let oldStatusText = S.rtStatus existing
                updated =
                    existing
                        { S.rtStatus = fromMaybe oldStatusText status
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
                Just s | s == vsStatusCreated -> do
                    -- Saving changes: capture VS_NEW snapshot, VS stays locked until apply/discard
                    case newVsData of
                        Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_NEW" (String d)
                        Nothing -> pure ()
                    ok <- conditionalUpdateTrackerRow updated oldStatusText
                    if ok
                        then pure $ APIResponse "SUCCESS" "VS edit saved"
                        else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."
                Just s | s == vsStatusApplied -> do
                    -- Get the new VS data from SNAPSHOT events
                    events <- listReleaseEvents tid
                    let mNewVs = find (\e -> S.reCategory e == "SNAPSHOT" && S.reLabel e == "VS_NEW") events
                    case mNewVs of
                        Nothing -> pure $ APIResponse "ERROR" "No new VS data found"
                        Just newVsEvt -> do
                            -- Get product config for namespace
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
                                            -- NOTE (M7 — deferred, task #10 audit):
                                            -- kubectl replace runs BEFORE the DB tracker row flips
                                            -- to APPLIED. If kubectl succeeds but the subsequent
                                            -- conditionalUpdateTrackerRow loses a CAS race (another
                                            -- request already mutated the tracker row), K8s has
                                            -- already been patched while the DB still says CREATED
                                            -- — a drift between reality and our record. Julia has
                                            -- the same ordering (api/vsedit/apply.jl). Team-lead's
                                            -- call (see race-hunter task #10 report): do NOT fix
                                            -- now — the CAS loser branch is rare, recoverable
                                            -- (retry the update with the new baseline), and fixing
                                            -- it properly needs an idempotency token on the K8s
                                            -- side we don't have yet. Revisit alongside the planned
                                            -- APPLIED-event-sourced rollback scheme.
                                            result <- liftIO $ applyVsToK8s cfg (T.unpack ns) vsContent
                                            case result of
                                                Left err -> pure $ APIResponse "ERROR" ("K8s apply failed: " <> err)
                                                Right () -> do
                                                    ok <- conditionalUpdateTrackerRow updated oldStatusText
                                                    if ok
                                                        then do
                                                            -- Ownership-checked unlock: if the lock-expiry sweep
                                                            -- reassigned the lock to a new owner mid-apply, do NOT
                                                            -- clobber it. (task #34: avoid blind release.)
                                                            _ <- releaseVsLockIfOwner (S.rtAppGroup existing) (S.rtCreatedBy existing)
                                                            notifyVsEditApplied tid (S.rtAppGroup existing) (S.rtService existing) (fromMaybe "admin" approvedBy)
                                                            pure $ APIResponse "SUCCESS" "VS edit applied to K8s"
                                                        else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."
                Just s | s == vsStatusDiscarded -> do
                    ok <- conditionalUpdateTrackerRow updated oldStatusText
                    if ok
                        then do
                            -- Ownership-checked release (task #34): expiry sweep may
                            -- have reassigned the lock; only clear if we still hold it.
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
                            -- Notification for approval
                            case approvedBy of
                                Just ab -> notifyVsEditApproved tid (S.rtAppGroup existing) (S.rtService existing) ab
                                Nothing -> pure ()
                            pure $ APIResponse "SUCCESS" "VS edit tracker updated"
                        else pure $ APIResponse "ERROR" "VS edit was modified by another request. Please refresh and try again."

lockVsEditTrackerH :: AuthedPerson -> VsLockReq -> Flow APIResponse
lockVsEditTrackerH _ap VsLockReq{..} = do
    cfg <- getConfig
    now <- liftIO getCurrentTime
    -- Resolve vsName from deployment_config if not provided
    mProdCfg <- findProductByNameAndCluster appGroup ""
    let resolvedVsName = case vsName of
            Just v | not (T.null v) -> v
            _ -> maybe "" getProductVsName mProdCfg
        resolvedEnv = fromMaybe (envName cfg) env
        resolvedService = fromMaybe "" service
        resolvedLockedBy = fromMaybe "admin" lockedBy
    -- Atomically acquire VS lock (single UPDATE WHERE vs_locked_by IS NULL)
    acquired <- tryAcquireVsLock appGroup resolvedLockedBy
    if not acquired
        then throwM (Conflict ("VS is already locked for app group " <> appGroup))
        else do
            tid <- liftIO (UUID.toText <$> UUID.nextRandom)
            let durationSecs = fromIntegral (fromMaybe 15 lockDurationMinutes) * 60
                lockExpiry = addUTCTime durationSecs now
                row = mkVsEditRow tid appGroup resolvedService resolvedEnv resolvedVsName (Just resolvedLockedBy) "LOCKED" now
                rowWithExpiry = row{S.rtEndTime = Just lockExpiry}
            insertReleaseTrackerRow rowWithExpiry
            -- Capture old VS data as SNAPSHOT event
            case oldVsData of
                Just d -> insertReleaseEvent tid "SNAPSHOT" "VS_OLD" (String d)
                Nothing -> pure ()
            notifyVsEditLocked tid appGroup (fromMaybe "" service) (fromMaybe "admin" lockedBy)
            pure $ APIResponse "SUCCESS" ("VS locked. Tracker ID: " <> tid)

{- | Ownership-checked unlock (task #10 audit, M6). Anyone holding the
tracker ID used to be able to clear the lock unconditionally, even if the
lock was held by someone else — a soft auth hole. The check is now:

  1. Look up the tracker row. Its 'rtCreatedBy' is the owner-of-record
     (set at lock time to whatever identity lockVsEditTrackerH was called
     with).
  2. Ask the DB to release the lock ONLY IF deployment_config.vs_locked_by
     matches that owner ('releaseVsLockIfOwner'). The guard is in a single
     UPDATE, so there is no TOCTOU between check and release.
  3. If the guard fails — because some other identity acquired the lock
     after this tracker was created (e.g. after the prior lock was
     expired+swept by 'tryAcquireVsLock') — return an error pointing the
     caller at the force-unlock endpoint.

The tracker row is still flipped to UNLOCKED and an event is emitted, but
only after the DB lock release succeeds, so we never record an "unlocked"
state that doesn't reflect reality.

The no-tracker-id branch (legacy "just unlock whatever's held for this
app_group") is intentionally refused: without a tracker row we have no
record of who the expected owner is, so we cannot safely do an ownership
check. Callers in that situation must use the superadmin force-unlock.
-}
unlockVsEditTrackerH :: AuthedPerson -> VsUnlockReq -> Flow APIResponse
unlockVsEditTrackerH _ap VsUnlockReq{..} = do
    now <- liftIO getCurrentTime
    case trackerId of
        Just tid -> do
            m <- findVsEditTrackerRowById tid
            case m of
                Nothing -> pure $ APIResponse "ERROR" "Tracker not found"
                Just existing -> do
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
                            -- CAS (task #34 M6): blind insert overwrote concurrent writers
                            -- (e.g. an updateVsEditTrackerH running in parallel). Expected
                            -- status is whatever the tracker was when we read it above.
                            -- Lock is already cleared, so on CAS failure we still return
                            -- the lock-release outcome but flag the tracker as stale so
                            -- the UI refreshes rather than showing this handler's snapshot.
                            let updated = existing{S.rtStatus = "UNLOCKED", S.rtUpdatedAt = now, S.rtEndTime = Just now}
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

{- | Superadmin-only force unlock (task #10 audit, M6). Bypasses the
ownership check in 'unlockVsEditTrackerH' and unconditionally clears the
VS lock for a given app_group. Intended for operator recovery when a
tracker row is missing, the owner identity is unknown, or the lock is
stuck for some other reason outside the normal expiry sweep.

Gating: the route is wired to the 'AP_CONFIG_FORCE_UNLOCK' permission,
which by convention is granted only to superadmin. The middleware's
superadmin bypass ('Core.Auth.Middleware.handleAuth') ensures that
permission-checked routes go through the superadmin-only path; a
non-superadmin with no matching role will get a 403.
-}
forceUnlockVsEditTrackerH :: AuthedPerson -> VsUnlockReq -> Flow APIResponse
forceUnlockVsEditTrackerH _ap VsUnlockReq{..} = do
    now <- liftIO getCurrentTime
    case trackerId of
        Just tid -> do
            m <- findVsEditTrackerRowById tid
            case m of
                Nothing -> do
                    -- Allow force-unlock by app_group even if tracker lookup fails,
                    -- as long as the body also passed appGroup.
                    case appGroup of
                        Just p | not (T.null p) -> do
                            -- Use the same atomic helper so the freed-tracker id
                            -- is available for thread continuity.
                            freedTid <- forceUnlockAppGroupTransactional p
                            notifyVsEditUnlocked freedTid p ""
                            pure $ APIResponse "SUCCESS" ("VS force-unlocked for app_group=" <> p <> " (tracker missing)")
                        _ -> pure $ APIResponse "ERROR" "Tracker not found and no appGroup provided"
                Just existing -> do
                    updateVsLockedBy (S.rtAppGroup existing) Nothing
                    -- CAS (task #34 M7): same fix as M6. Force-unlock is an operator
                    -- recovery path, so the tracker row MAY have been edited by an
                    -- unrelated writer in parallel; blind insert would silently
                    -- overwrite that. Lock has already been force-cleared, which is
                    -- the authoritative side effect; the tracker update is housekeeping.
                    let updated = existing{S.rtStatus = "UNLOCKED", S.rtUpdatedAt = now, S.rtEndTime = Just now}
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
                    mLock <- findActiveLockFromConfig p
                    case mLock of
                        Nothing -> pure $ APIResponse "ERROR" ("No active lock found for app_group=" <> p)
                        Just _existing -> do
                            -- Round 7 audit B3: single-transaction force-unlock
                            -- (deployment_config + tracker rows in one txn).
                            -- Returns the just-freed LOCKED tracker id so the
                            -- unlock Slack notification threads under the
                            -- original lock message instead of posting a new
                            -- top-level thread.
                            freedTid <- forceUnlockAppGroupTransactional p
                            notifyVsEditUnlocked freedTid p ""
                            pure $ APIResponse "SUCCESS" ("VS force-unlocked for app_group=" <> p)

{- | Revert a previously-applied VS edit by re-applying the VS_OLD snapshot
captured at lock time. Only meaningful for trackers that reached the
APPLIED state — anything earlier has nothing to undo.

Symmetric to ConfigMap revert: creates a new tracker pointing at the original,
captures CURRENT VS as the new tracker's VS_OLD, then re-applies the original's
VS_OLD payload to k8s. Original tracker is left in COMPLETED — only the new
tracker carries the revert audit trail.
-}
revertVsEditTrackerH :: AuthedPerson -> Text -> Flow APIResponse
revertVsEditTrackerH _ap tid = do
    cfg <- getConfig
    m <- findVsEditTrackerRowById tid
    case m of
        Nothing -> pure $ APIResponse "ERROR" ("VS edit tracker not found: " <> tid)
        Just orig -> do
            -- Only allow revert of APPLIED trackers (others have no kubectl-side effect)
            if S.rtStatus orig /= "APPLIED"
                then pure $ APIResponse "ERROR" ("Cannot revert VS edit in status " <> S.rtStatus orig <> ". Only APPLIED edits can be reverted.")
                else do
                    -- Find the VS_OLD snapshot captured when the original was locked
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
                                        oldVsContent = case S.rePayload oldVsEvt of
                                            String s' -> s'
                                            _ -> ""
                                    if T.null oldVsContent
                                        then pure $ APIResponse "ERROR" "Empty VS_OLD snapshot"
                                        else do
                                            -- Acquire VS lock for the revert
                                            acquired <- tryAcquireVsLock (S.rtAppGroup orig) (S.rtCreatedBy orig <> "-revert")
                                            if not acquired
                                                then throwM (Conflict ("VS is already locked for app group " <> S.rtAppGroup orig))
                                                else do
                                                    now <- liftIO getCurrentTime
                                                    newTid <- liftIO (UUID.toText <$> UUID.nextRandom)
                                                    let revertRow =
                                                            (mkVsEditRow newTid (S.rtAppGroup orig) (S.rtService orig) (S.rtEnv orig) (fromMaybe "" (S.rtMetadata orig)) (Just (S.rtCreatedBy orig <> "-revert")) "CREATED" now)
                                                                { S.rtInfo = Just ("Revert of " <> tid)
                                                                , S.rtDescription = Just ("Revert of " <> tid)
                                                                }
                                                    insertReleaseTrackerRow revertRow
                                                    insertReleaseEvent newTid "BUSINESS" "REVERT_TRACKER_CREATED" (String ("Revert of " <> tid))
                                                    -- Apply the original VS_OLD payload
                                                    insertReleaseEvent newTid "SNAPSHOT" "VS_NEW" (String oldVsContent)
                                                    applyResult <- liftIO $ applyVsToK8s cfg (T.unpack ns) oldVsContent
                                                    case applyResult of
                                                        Left err -> do
                                                            _ <- releaseVsLockIfOwner (S.rtAppGroup orig) (S.rtCreatedBy orig <> "-revert")
                                                            pure $ APIResponse "ERROR" ("K8s apply failed during revert: " <> err)
                                                        Right () -> do
                                                            -- Mark revert tracker APPLIED + release lock.
                                                            -- Round 7 audit B8: surface a CAS miss instead of swallowing it
                                                            -- silently. The VS itself has already been kubectl-applied so
                                                            -- the side effect is real either way; the API response should
                                                            -- tell the operator if the audit row drifted.
                                                            let appliedRow = revertRow{S.rtStatus = "APPLIED", S.rtUpdatedAt = now}
                                                            casOk <- conditionalUpdateTrackerRow appliedRow "CREATED"
                                                            _ <- releaseVsLockIfOwner (S.rtAppGroup orig) (S.rtCreatedBy orig <> "-revert")
                                                            notifyVsEditApplied newTid (S.rtAppGroup orig) (S.rtService orig) (S.rtCreatedBy orig <> "-revert")
                                                            if casOk
                                                                then pure $ APIResponse "SUCCESS" ("VS edit reverted. New tracker: " <> newTid)
                                                                else pure $ APIResponse "WARNING" ("VS edit applied to K8s but tracker row was modified concurrently. New tracker: " <> newTid)

{- | Fetch the current live VirtualService JSON from K8s
Uses the deployment_config's vs_name (e.g. "atlas-vs"), NOT the service name
-}
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

-- ============================================================================
-- K8s helpers
-- ============================================================================

{- | Apply VS data to K8s via kubectl replace (same pattern as replaceFromStdin
in BackendConfigWorkflow)
-}
applyVsToK8s :: Config -> String -> Text -> IO (Either Text ())
applyVsToK8s cfg ns content = do
    let cmd = unwords ["echo", shellQuote content, "|", kubectlBin cfg, "-n", ns, "replace -f -"]
    logInfoG $ "[VS-APPLY] Running: kubectl -n " <> T.pack ns <> " replace -f -"
    result <- runCmd cmd
    case result of
        Right _ -> pure (Right ())
        Left (K8sError err) -> pure (Left ("kubectl replace failed: " <> err))
