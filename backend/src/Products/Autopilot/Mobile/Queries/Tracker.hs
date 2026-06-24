{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Cross-cutting helpers used by the mobile workflow stages and the
-- mobile create endpoint. Concerns split out of the workflow modules so
-- T12-T14 (workflow stages) and T17 (create endpoint) can share a single
-- source of truth for the dispatch-group + AppCatalog joins, the
-- ResolveRunId attempt counter, and tracker INSERTs.
--
-- Note: 'loadGhCreds' lives in @Products.Autopilot.Mobile.Github.Auth@ and
-- 'loadPlayCreds' lives in @Products.Autopilot.Mobile.Versioning@; this
-- module deliberately does not redefine them.
module Products.Autopilot.Mobile.Queries.Tracker
  ( findSiblingsByDispatchId,
    setExternalRunIdForDispatch,
    setReviewDecided,
    setReviewSubmitted,
    setMobileWfStatus,
    setRolloutState,
    clearRolloutColumns,
    setAscIds,
    markReleaseInProgress,
    updateStoreSyncBuildCode,
    setStoreSyncMetadata,
    setProductionRolloutReflection,
    findExternalReviewRow,
    findMobileVersionRow,
    listIncomingMobileVersions,
    sccActiveReleaseExistsForVersion,
    setExternalReviewState,
    completeExternalReviewRow,
    findActiveRolloutReleases,
    findMobileAwaitingRollout,
    incrementResolveAttempts,
    appCatalogForRow,
    appCatalogForRowRaw,
    appCatalogByKey,
    logEvent,
    gitOwner,
    gitRepo,
    insertMobileTracker,
    mkMobileTrackerRow,
    -- Revert helpers
    fetchRevertCandidates,
    findMobileReleaseById,
    parseMobileTargetState,
    insertMobileRevertTracker,
    markReleaseRevertedBy,
    isReverted,
    ReleaseTrackerRow,
  )
where

import Control.Monad (forM_, when)
import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.List (find)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime)
import Data.Int (Int32)
import Database.Beam
import Products.Autopilot.Mobile.RevertResolver (RevertCand (..))
import Products.Autopilot.Mobile.Types
  ( MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    claimsStoreIdentity,
    isDebugBuildType,
  )
import Products.Autopilot.Mobile.Types.Storage
  ( AppCatalog,
    AppCatalogT (..),
  )
import Products.Autopilot.Queries.ReleaseTracker
  ( encodeJsonText,
    insertReleaseEvent,
    insertReleaseTrackerRow,
    parseJsonTextMaybe,
    parseMode,
    parseReleaseCategory,
    parseReleaseStatus,
    parseReleaseWFStatus,
  )
import Products.Autopilot.Types.Release
  ( Mode,
    ReleaseStatus,
    ReleaseTracker (..),
  )
import Products.Autopilot.Types.Storage.Schema
  ( AutopilotDb (..),
    ReleaseTrackerT (..),
    autopilotDb,
  )
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Types.Workflow (ReleaseCategory, ReleaseWFStatus)

-- | All tracker rows in the same dispatch group, paired with their
-- @AppCatalog@ row. The join key is @(app_group, surface, platform)@,
-- which uniquely identifies a catalog entry (DB unique constraint).
--
-- Rows whose catalog entry has been deleted are silently dropped (INNER
-- JOIN); the mobile workflow never expects this to happen, but it's
-- safer than crashing the worker tick.
findSiblingsByDispatchId ::
  (MonadFlow m) =>
  Text ->
  m [(ReleaseTracker, AppCatalog)]
findSiblingsByDispatchId dispatchId = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          orderBy_ (\(rt, _) -> asc_ (rtId rt)) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            ac <- all_ (appCatalogs autopilotDb)
            guard_ (rtDispatchId rt ==. val_ (Just dispatchId))
            guard_ (acName ac ==. rtAppGroup rt)
            guard_ (acSurface ac ==. rtService rt)
            guard_ (acPlatform ac ==. rtEnv rt)
            pure (rt, ac)
  pure (map (\(rt, ac) -> (rowToDomain rt, ac)) rows)

-- | Set @external_run_id@ and @commit_sha@ on every tracker row in the
-- dispatch group. A single SQL UPDATE so siblings can never disagree on
-- which GHA run they're tied to or which commit they built from.
--
-- @commit_sha@ is the @head_sha@ returned by the GH run API — i.e. the
-- SHA of HEAD at dispatch time on whichever ref the dispatch carried
-- (branch or tag). All siblings in the dispatch group share the same
-- ref, so they all carry the same SHA.
setExternalRunIdForDispatch ::
  (MonadFlow m) =>
  Text ->
  Text ->
  Text ->
  m ()
setExternalRunIdForDispatch dispatchId runId headSha = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat
              [ rtExternalRunId rt <-. val_ (Just runId),
                rtCommitSha rt <-. val_ (Just headSha)
              ]
        )
        (\rt -> rtDispatchId rt ==. val_ (Just dispatchId))

-- | Persist the review outcome to the @0027@ columns (called by the review-poll
-- stage on approve/reject, and by the operator mark-* endpoints in Phase 6).
setReviewDecided ::
  (MonadFlow m) =>
  Text ->
  Text ->
  UTCTime ->
  Maybe Text ->
  m ()
setReviewDecided releaseId_ reviewStatus decidedAt mReason = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat
              [ rtReviewStatus rt <-. val_ (Just reviewStatus),
                rtReviewDecidedAt rt <-. val_ (Just decidedAt),
                rtReviewRejectReason rt <-. val_ mReason
              ]
        )
        (\rt -> rtId rt ==. val_ releaseId_)

-- | Promote → review: set @mb_wf_status = MBInReview@ + @mbReviewSubmittedAt@ in
-- the target-state JSON, plus the @review_status@ / @review_submitted_at@ columns.
-- Called by @POST /promote@ after a successful store submission.
setReviewSubmitted :: (MonadFlow m) => Text -> Text -> UTCTime -> m ()
setReviewSubmitted releaseId_ reviewStatus now = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId_)
          pure rt
  case mRow of
    Nothing -> throwM $ DBError "setReviewSubmitted" ("release not found: " <> releaseId_)
    Just row -> case parseMobileTargetState (rtTargetState row) of
      Nothing -> throwM $ DBError "setReviewSubmitted" ("not a mobile release: " <> releaseId_)
      Just s -> do
        let encoded = encodeJsonText (MobileBuildState s {mbWfStatus = MBInReview, mbReviewSubmittedAt = Just now})
        runDB db $
          runUpdate $
            update
              (releaseTrackers autopilotDb)
              ( \rt ->
                  mconcat
                    [ rtTargetState rt <-. val_ (Just encoded),
                      rtReviewStatus rt <-. val_ (Just reviewStatus),
                      rtReviewSubmittedAt rt <-. val_ (Just now)
                    ]
              )
              (\rt -> rtId rt ==. val_ releaseId_)

-- | Read-modify-write the target-state JSON to set @mb_wf_status@ (used by the
-- rollout / mark-* transitions: MBReviewApproved, MBReviewRejected, MBRollingOut, MBCompleted).
setMobileWfStatus :: (MonadFlow m) => Text -> MobileBuildWFStatus -> m ()
setMobileWfStatus releaseId_ st = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId_)
          pure rt
  case mRow of
    Nothing -> throwM $ DBError "setMobileWfStatus" ("release not found: " <> releaseId_)
    Just row -> case parseMobileTargetState (rtTargetState row) of
      Nothing -> throwM $ DBError "setMobileWfStatus" ("not a mobile release: " <> releaseId_)
      Just s ->
        runDB db $
          runUpdate $
            update
              (releaseTrackers autopilotDb)
              (\rt -> rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s {mbWfStatus = st}))))
              (\rt -> rtId rt ==. val_ releaseId_)

-- | Set the @rollout_status@ / @rollout_percent@ columns.
setRolloutState :: (MonadFlow m) => Text -> Text -> Maybe Double -> m ()
setRolloutState releaseId_ rolloutStatus mPercent = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat
              [ rtRolloutStatus rt <-. val_ (Just rolloutStatus),
                rtRolloutPercent rt <-. val_ mPercent
              ]
        )
        (\rt -> rtId rt ==. val_ releaseId_)

-- | Clear the rollout columns (rollout_status / rollout_percent → NULL). Used when
-- retiring a superseded rollout row so it no longer reads as rolling out / halted.
clearRolloutColumns :: (MonadFlow m) => Text -> m ()
clearRolloutColumns releaseId_ = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat
              [ rtRolloutStatus rt <-. val_ Nothing,
                rtRolloutPercent rt <-. val_ Nothing
              ]
        )
        (\rt -> rtId rt ==. val_ releaseId_)

-- | Cache the iOS App Store version id and/or phased-release id returned by the
-- store calls (@enablePhasedRelease@ → @asc_phased_id@), so later pause / resume /
-- release-all can act on the phased id directly without re-resolving it. A no-op
-- when both are 'Nothing' (avoids emitting a SET-less UPDATE).
setAscIds :: (MonadFlow m) => Text -> Maybe Text -> Maybe Text -> m ()
setAscIds _ Nothing Nothing = pure ()
setAscIds releaseId_ mVersionId mPhasedId = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat $
              [rtAscVersionId rt <-. val_ mVersionId | Just _ <- [mVersionId]]
                <> [rtAscPhasedId rt <-. val_ mPhasedId | Just _ <- [mPhasedId]]
        )
        (\rt -> rtId rt ==. val_ releaseId_)

-- | Flip a release to INPROGRESS. Used when promoting a store-sync internal /
-- TestFlight snapshot (a COMPLETED row): going INPROGRESS lets the runner + the
-- reconciler adopt it into the review/rollout lifecycle (poll, finalize).
markReleaseInProgress :: (MonadFlow m) => Text -> m ()
markReleaseInProgress releaseId_ = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        -- Promote = the version leaves the internal slot for the production review.
        -- Advance the monotonic track so it shows in PROD-INCOMING, not INTERNAL.
        ( \rt ->
            mconcat
              [ rtStatus rt <-. val_ "INPROGRESS"
              , rtStoreTrack rt <-. val_ (Just "production")
              ]
        )
        (\rt -> rtId rt ==. val_ releaseId_)

-- | Update a PRISTINE store-sync snapshot's build code + derived tag in place,
-- for when a new build of the SAME version appears on the store (e.g. iOS
-- 3.3.73(1) → (2)). The version-keyed store-sync dedup index blocks a re-insert,
-- so the build number/tag would otherwise stay frozen. Only touches COMPLETED
-- store-sync rows that were never promoted (review_status IS NULL) — never a
-- promoted/active row.
updateStoreSyncBuildCode :: (MonadFlow m) => AppCatalog -> Text -> Maybe Int32 -> Maybe Text -> m ()
updateStoreSyncBuildCode ac version newCode newTag = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtAppGroup rt ==. val_ (acName ac))
          guard_ (rtService rt ==. val_ (acSurface ac))
          guard_ (rtEnv rt ==. val_ (acPlatform ac))
          guard_ (rtNewVersion rt ==. val_ version)
          guard_ (rtMode rt ==. val_ (Just "STORE_SYNC"))
          guard_ (rtStatus rt ==. val_ "COMPLETED")
          guard_ (isNothing_ (rtReviewStatus rt))
          pure rt
  case mRow >>= \row -> (,) row <$> parseMobileTargetState (rtTargetState row) of
    Nothing -> pure ()
    Just (row, s) ->
      let s' = s {mbContext = (mbContext s){mbcVersionCode = newCode, mbcTagPushed = newTag}}
       in runDB db $
            runUpdate $
              update
                (releaseTrackers autopilotDb)
                ( \rt ->
                    mconcat
                      [ rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s')))
                      , -- keep the build-identity column in sync with the bumped code
                        rtVersionCode rt <-. val_ newCode
                      ]
                )
                (\rt -> rtId rt ==. val_ (rtId row))

-- | Overwrite the @metadata@ JSON of the leading store-sync row for an app
-- (identified by version). Store-sync calls this each pass to keep the per-track
-- snapshots (@metadata.tracks@) fresh — so e.g. the production version doesn't
-- lag while the (leading) internal version stays put. Only touches COMPLETED,
-- never-promoted store-sync rows; a no-op if no such row exists yet.
setStoreSyncMetadata :: (MonadFlow m) => AppCatalog -> Text -> Text -> m ()
setStoreSyncMetadata ac version metaJson = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        (\rt -> rtMetadata rt <-. val_ (Just metaJson))
        ( \rt ->
            rtAppGroup rt ==. val_ (acName ac)
              &&. rtService rt ==. val_ (acSurface ac)
              &&. rtEnv rt ==. val_ (acPlatform ac)
              &&. rtNewVersion rt ==. val_ version
              &&. rtMode rt ==. val_ (Just "STORE_SYNC")
              &&. rtStatus rt ==. val_ "COMPLETED"
              &&. isNothing_ (rtReviewStatus rt)
        )

-- | Reconcile the production-rollout REFLECTION across an app's android store-sync
-- snapshot rows in one pass, so the release list matches the App Monitor. The
-- leading-track logic ('setStoreSyncMetadata') only refreshes the NEWEST build's
-- row; when an OLDER version is mid-rollout on production (a newer build sits on
-- internal), that version's row would otherwise never show the ramp.
--
-- @mActive@ is @Just (version, rollout_status, percent)@ for the version actively
-- ramping on production below 100%, else @Nothing@. This stamps
-- @rollout_status@ + @rollout_percent@ onto that version's row (bumping
-- @date_updated@ so it floats to the top of the list) and CLEARS those keys from
-- every other store-sync row — so a version SUPERSEDED by a later 100% promote
-- stops showing "rolling out" and reverts to its natural track badge.
--
-- It deliberately does NOT touch @store_track@ or @status@: the row stays a
-- COMPLETED snapshot outside the rollout reconciler ('findActiveRolloutReleases' is
-- INPROGRESS-gated — Apple / the operator owns the ramp), and the rollout-aware
-- track badge shows "Rolling out X%" without implying the version is fully live.
-- 100% is intentionally excluded by the caller: a completed rollout IS the live
-- production version, badged "Production" via 'setStoreSyncMetadata' as usual.
setProductionRolloutReflection :: (MonadFlow m) => AppCatalog -> Maybe (Text, Text, Double) -> UTCTime -> m ()
setProductionRolloutReflection ac mActive now = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtAppGroup rt ==. val_ (acName ac))
          guard_ (rtService rt ==. val_ (acSurface ac))
          guard_ (rtEnv rt ==. val_ (acPlatform ac))
          -- Both STORE_SYNC and EXTERNAL_REVIEW are store-sync-managed synthetic rows.
          -- A build that went through external review keeps its production-rollout
          -- reflection (it flips to EXTERNAL_REVIEW once a review is detected, but its
          -- later staged rollout must still surface as "Rolling out X%" not "Completed").
          guard_
            ( rtMode rt ==. val_ (Just "STORE_SYNC")
                ||. rtMode rt ==. val_ (Just "EXTERNAL_REVIEW")
            )
          guard_ (rtStatus rt ==. val_ "COMPLETED")
          guard_ (isNothing_ (rtReviewStatus rt))
          pure rt
  forM_ rows $ \row -> do
    -- The list reads the reflection from @metadata@ (the rollout columns aren't in
    -- its response); the detail page (GET /rollout) reads the @rollout_status@ /
    -- @rollout_percent@ COLUMNS. Write both so every surface agrees. The row stays
    -- COMPLETED, so the INPROGRESS-gated reconciler still never touches it.
    let (newMeta, newStatus, newPct, bump) = case mActive of
          Just (v, st, pct)
            | rtNewVersion row == v -> (setRolloutMeta (rtMetadata row) st pct, Just st, Just pct, True)
          _ -> (clearRolloutMeta (rtMetadata row), Nothing, Nothing, False)
        changed =
          Just newMeta /= rtMetadata row
            || newStatus /= rtRolloutStatus row
            || newPct /= rtRolloutPercent row
    when changed $
      runDB db $
        runUpdate $
          update
            (releaseTrackers autopilotDb)
            ( \rt ->
                mconcat $
                  [ rtMetadata rt <-. val_ (Just newMeta),
                    rtRolloutStatus rt <-. val_ newStatus,
                    rtRolloutPercent rt <-. val_ newPct
                  ]
                    <> [rtUpdatedAt rt <-. val_ now | bump]
            )
            (\rt -> rtId rt ==. val_ (rtId row))

-- | The store-sync @metadata@ object (or empty), shared by the rollout-reflection
-- set/clear helpers. Preserves every existing key (notably @store_track@ and the
-- per-track @tracks@ snapshots).
storeMetaObject :: Maybe Text -> KM.KeyMap Value
storeMetaObject mCur = case mCur >>= (Aeson.decodeStrict . TE.encodeUtf8) of
  Just (Aeson.Object o) -> o
  _ -> KM.empty

-- | Add @rollout_status@ + @rollout_percent@ to a store-sync metadata blob.
setRolloutMeta :: Maybe Text -> Text -> Double -> Text
setRolloutMeta mCur rolloutStatus pct =
  encodeJsonText . Aeson.Object $
    KM.insert "rollout_status" (Aeson.String rolloutStatus) $
      KM.insert "rollout_percent" (Aeson.Number (realToFrac pct)) $
        storeMetaObject mCur

-- | Strip the @rollout_status@ / @rollout_percent@ reflection back out (a version
-- no longer actively rolling out on production — finished or superseded).
clearRolloutMeta :: Maybe Text -> Text
clearRolloutMeta mCur =
  encodeJsonText . Aeson.Object . KM.delete "rollout_status" . KM.delete "rollout_percent" $
    storeMetaObject mCur

-- | Strip the external-review markers (@external@ / @review_inferred@) from a metadata
-- blob, preserving everything else (e.g. a rollout reflection's rollout_status/percent).
-- Once a build leaves review (rolling out / live) it is no longer an out-of-band store
-- submission, so it should drop the EXTERNAL chip and read as a normal store row.
-- 'Nothing' when nothing else remains, so the row carries no stale metadata.
clearExternalMeta :: Maybe Text -> Maybe Text
clearExternalMeta mCur =
  let o = KM.delete "external" (KM.delete "review_inferred" (storeMetaObject mCur))
   in if KM.null o then Nothing else Just (encodeJsonText (Aeson.Object o))

-- ─── Out-of-band (external) review snapshots ───────────────────────
--
-- When an App Store version is in review but was NOT submitted from SCC, store
-- sync surfaces it as a synthetic INPROGRESS row tagged @mode = 'EXTERNAL_REVIEW'@
-- (so it's outside the store-sync version dedup index, and — having no
-- @dispatch_id@ / @rollout_status@ — invisible to the build runner and the
-- rollout reconciler). store sync owns its whole lifecycle.

-- | The current external-review row for an app that store sync still owns — i.e.
-- still in the review phase. Once an operator releases it (rollout_status set),
-- store sync hands off: the release/rollout handlers + the rollout reconciler
-- drive it exactly like a normal SCC build, and store sync must NOT keep
-- reconciling it (else it would complete the rollout the moment the version goes
-- live). So this excludes rows that have entered rollout.
findExternalReviewRow :: (MonadFlow m) => Text -> Text -> Text -> m (Maybe ReleaseTrackerRow)
findExternalReviewRow appGroup surface platform = withDb $ \db ->
  runDB db $
    runSelectReturningOne $
      select $
        limit_ 1 $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtAppGroup rt ==. val_ appGroup)
          guard_ (rtService rt ==. val_ surface)
          guard_ (rtEnv rt ==. val_ platform)
          guard_ (rtMode rt ==. val_ (Just "EXTERNAL_REVIEW"))
          guard_ (rtStatus rt ==. val_ "INPROGRESS")
          guard_ (isNothing_ (rtRolloutStatus rt))
          pure rt

-- | The SINGLE mobile-build row for a version. With the version-keyed identity
-- (migration 0034: one row per (app_group, service, env, new_version)) this is
-- unique regardless of mode/origin — the convergence point every reconcile/merge
-- writes through, so a store-sync snapshot, an external-review detection, and a
-- rollout all land on the same row instead of forking.
findMobileVersionRow :: (MonadFlow m) => Text -> Text -> Text -> Text -> Maybe Int32 -> m (Maybe ReleaseTrackerRow)
findMobileVersionRow appGroup surface platform version mCode = do
  rows <- withDb $ \db ->
    runDB db $
      runSelectReturningList $
        select $
          -- Build identity is (name, code) (migration 0035), so when the caller knows
          -- the build number, match it exactly. Without it (iOS authoritative review),
          -- fall back to name and take the highest code (latest build) deterministically.
          orderBy_ (\rt -> desc_ (rtVersionCode rt)) $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtAppGroup rt ==. val_ appGroup)
            guard_ (rtService rt ==. val_ surface)
            guard_ (rtEnv rt ==. val_ platform)
            guard_ (rtNewVersion rt ==. val_ version)
            guard_ (rtCategory rt ==. val_ "MobileBuild")
            maybe (pure ()) (\c -> guard_ (rtVersionCode rt ==. val_ (Just c))) mCode
            pure rt
  -- Resolve only to a STORE-IDENTITY row (mirrors the uq_release_tracker_mobile_build
  -- predicate): skip debug + Firebase-distribution builds, which inherit a repeating
  -- Play-derived (name, code) and so must never be the convergence target for a real
  -- store release's review / rollout / supersession. Rows stay ordered by desc code, so
  -- 'find' still yields the highest-code store build for the iOS (no-code) fallback.
  pure (find isStoreIdentityRow rows)

-- | A row that actually claims a store identity: published to Play / App Store under its
-- version_code — i.e. NOT a debug build and NOT routed to Firebase App Distribution
-- (those reuse a Play-derived code that repeats, so they own no unique identity). A row
-- whose target state can't be parsed defaults to True (conservative — preserves the prior
-- "any matching row" behaviour for non-mobile-shaped rows).
isStoreIdentityRow :: ReleaseTrackerRow -> Bool
isStoreIdentityRow row = case parseMobileTargetState (rtTargetState row) of
  Just st -> claimsStoreIdentity (mbContext st)
  Nothing -> True

-- | The PROD-INCOMING rows across all apps (version-keyed model): a version on the
-- production track that's in review / approved-held / rejected but NOT yet rolling
-- out — i.e. the "next" version, distinct from the live serving one. The App Monitor
-- surfaces these as its Incoming cell, so an in-review build shows even after it has
-- left the internal track. At most one per (app_group, service, env) by the slot model.
listIncomingMobileVersions :: (MonadFlow m) => m [ReleaseTrackerRow]
listIncomingMobileVersions = withDb $ \db ->
  runDB db $
    runSelectReturningList $
      select $ do
        rt <- all_ (releaseTrackers autopilotDb)
        guard_ (rtCategory rt ==. val_ "MobileBuild")
        guard_ (rtStatus rt ==. val_ "INPROGRESS")
        guard_ (rtStoreTrack rt ==. val_ (Just "production"))
        guard_ (not_ (isNothing_ (rtReviewStatus rt))) -- in review / approved / rejected
        guard_ (isNothing_ (rtRolloutStatus rt)) -- not yet rolling out (that's PROD-LIVE)
        pure rt

-- | Has this version GRADUATED PAST review — i.e. does its row carry a
-- @rollout_status@ (rolling out / halted / superseded / live mirror, at any
-- status)? That's the single signal the external reconcile uses to STOP surfacing
-- "in review" and retire it: once a version is rolling out it's past review.
--
-- In the version-keyed model (migration 0034) the review state lives ON the one
-- version row, so a plain INPROGRESS in-review row is NOT "owned by a separate SCC
-- release" — it IS the review. Counting INPROGRESS here (as an earlier version did)
-- made the convergence retire its OWN review on the next sync (the in-review →
-- COMPLETED flip-flop with a stale @production@ track). So only rollout_status counts.
sccActiveReleaseExistsForVersion :: (MonadFlow m) => Text -> Text -> Text -> Text -> m Bool
sccActiveReleaseExistsForVersion appGroup surface platform version = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $
          limit_ 1 $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtAppGroup rt ==. val_ appGroup)
            guard_ (rtService rt ==. val_ surface)
            guard_ (rtEnv rt ==. val_ platform)
            guard_ (rtNewVersion rt ==. val_ version)
            guard_ (rtCategory rt ==. val_ "MobileBuild")
            -- Owned = the version has GRADUATED PAST review, i.e. carries a
            -- rollout_status (rolling out / halted / superseded / live mirror),
            -- regardless of INPROGRESS/COMPLETED. That's the only signal that means
            -- "stop surfacing in-review" — when it's true the external reconcile
            -- retires the review. We must NOT count a plain INPROGRESS in-review row
            -- here: with the version-keyed model (migration 0034) the review state
            -- lives ON the single version row, so an INPROGRESS in-review row IS the
            -- review — counting it as "owned" made the convergence retire its own
            -- review on the next pass (the in-review → COMPLETED flip-flop).
            guard_ (not_ (isNothing_ (rtRolloutStatus rt)))
            pure (rtId rt)
  pure (isJust mRow)

-- | Apply a review state onto the version's row in place. Used both to update an
-- existing EXTERNAL_REVIEW row AND to CONVERGE a store-sync snapshot of the same
-- version onto the review state (version-keyed identity) instead of forking a
-- second row. Review is a production-track, in-progress lifecycle state, so this
-- also advances @store_track@ -> production and @status@ -> INPROGRESS (both no-ops
-- for an existing external row, correct for a converged snapshot).
setExternalReviewState :: (MonadFlow m) => Text -> Text -> MobileBuildWFStatus -> m ()
setExternalReviewState releaseId_ reviewStatus mbStatus = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId_)
          pure rt
  case mRow >>= \row -> (,) row <$> parseMobileTargetState (rtTargetState row) of
    Nothing -> pure ()
    Just (row, s) ->
      let s' = s {mbWfStatus = mbStatus}
       in runDB db $
            runUpdate $
              update
                (releaseTrackers autopilotDb)
                ( \rt ->
                    mconcat
                      [ rtReviewStatus rt <-. val_ (Just reviewStatus)
                      , rtStatus rt <-. val_ "INPROGRESS"
                      , rtStoreTrack rt <-. val_ (Just "production")
                      , rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s')))
                      ]
                )
                (\rt -> rtId rt ==. val_ (rtId row))

-- | Mark an external-review row done (its version went live / left review).
completeExternalReviewRow :: (MonadFlow m) => Text -> m ()
completeExternalReviewRow releaseId_ = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId_)
          pure rt
  case mRow >>= \row -> (,) row <$> parseMobileTargetState (rtTargetState row) of
    Nothing -> pure ()
    Just (row, s) ->
      let s' = s {mbWfStatus = MBCompleted}
       in runDB db $
            runUpdate $
              update
                (releaseTrackers autopilotDb)
                ( \rt ->
                    mconcat
                      [ rtStatus rt <-. val_ "COMPLETED"
                      , -- Clear the now-stale review_status so a retired external row can
                        -- never resurface as "in_review" (e.g. a path reading the column).
                        rtReviewStatus rt <-. val_ Nothing
                      , -- It has left review (rolling out / live) → drop the EXTERNAL chip
                        -- so it reads as a normal store row (rolling out X%, then Production).
                        rtMetadata rt <-. val_ (clearExternalMeta (rtMetadata row))
                      , rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s')))
                      ]
                )
                (\rt -> rtId rt ==. val_ (rtId row))

-- | Mobile releases in an active staged rollout (@rollout_status@ 'rolling_out'
-- or 'halted') that are still INPROGRESS — the rows the Phase-7 reconciler keeps
-- in sync with the live store state. Reviews are deliberately excluded: iOS
-- review advances via the Phase-5 poll stage and Android review is operator-
-- marked, so neither needs store reconciliation here.
findActiveRolloutReleases :: (MonadFlow m) => m [ReleaseTrackerRow]
findActiveRolloutReleases = withDb $ \db ->
  runDB db $
    runSelectReturningList $
      select $ do
        rt <- all_ (releaseTrackers autopilotDb)
        guard_ (rtCategory rt ==. val_ "MobileBuild")
        guard_ (rtStatus rt ==. val_ "INPROGRESS")
        guard_
          ( rtRolloutStatus rt ==. val_ (Just "rolling_out")
              ||. rtRolloutStatus rt ==. val_ (Just "halted")
          )
        pure rt

-- | Mobile releases SCC has promoted (review submitted) but hasn't started rolling
-- out itself — for the given platform: INPROGRESS, no @rollout_status@ yet, and
-- past promote (@review_status@ set). The candidates for detecting a release /
-- rollout started OUTSIDE SCC — Android via a Play Console rollout-% bump
-- (@StoreSync.detectConsoleRollout@), iOS via an App Store Connect "Release"
-- (@StoreSync.detectIosRelease@).
findMobileAwaitingRollout :: (MonadFlow m) => Text -> m [ReleaseTrackerRow]
findMobileAwaitingRollout platform = withDb $ \db ->
  runDB db $
    runSelectReturningList $
      select $ do
        rt <- all_ (releaseTrackers autopilotDb)
        guard_ (rtCategory rt ==. val_ "MobileBuild")
        guard_ (rtEnv rt ==. val_ platform)
        guard_ (rtStatus rt ==. val_ "INPROGRESS")
        guard_ (isNothing_ (rtRolloutStatus rt))
        guard_
          ( rtReviewStatus rt ==. val_ (Just "approved")
              ||. rtReviewStatus rt ==. val_ (Just "submitted")
              ||. rtReviewStatus rt ==. val_ (Just "in_review")
          )
        pure rt

-- | Bump the ResolveRunId attempt counter stored in the tracker's
-- @release_context@ JSON (a @MobileBuildTargetState@ wrapped in
-- @TargetState.MobileBuildState@). Returns the post-increment value so
-- the caller can decide whether to give up.
--
-- Concurrency: this is a read-modify-write loop, not a SQL-side
-- increment. The mobile worker drives ResolveRunId from a single tick
-- loop, so concurrent bumps on the same row don't happen in practice.
incrementResolveAttempts ::
  (MonadFlow m) =>
  Text ->
  m Int
incrementResolveAttempts releaseId' = withDb $ \db -> do
  mRow <-
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId')
          pure rt
  case mRow of
    Nothing ->
      throwM $
        DBError "incrementResolveAttempts" $
          "release_tracker not found for id=" <> releaseId'
    Just row -> do
      let prev = rtTargetState row >>= decodeMobile
          next = case prev of
            Just s ->
              let n = fromMaybe 0 (mbResolveAttempts s) + 1
               in s {mbResolveAttempts = Just n}
            Nothing ->
              throwImpureBecauseRowIsNotMobile releaseId'
          newCount = fromMaybe 0 (mbResolveAttempts next)
          encoded = encodeJsonText (MobileBuildState next)
      runDB db $
        runUpdate $
          update
            (releaseTrackers autopilotDb)
            (\rt -> rtTargetState rt <-. val_ (Just encoded))
            (\rt -> rtId rt ==. val_ releaseId')
      pure newCount
  where
    decodeMobile :: Text -> Maybe MobileBuildTargetState
    decodeMobile t = case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
      Right (MobileBuildState s) -> Just s
      _ -> Nothing

    -- Helper to keep the case branch readable. If the row is not a
    -- MobileBuild tracker (or has lost its context), the caller is
    -- buggy: incrementResolveAttempts is only valid for mobile rows.
    throwImpureBecauseRowIsNotMobile :: Text -> a
    throwImpureBecauseRowIsNotMobile rid =
      error $
        "incrementResolveAttempts: tracker "
          <> T.unpack rid
          <> " has no MobileBuildState release_context"

-- | Look up the AppCatalog row for a tracker. Throws 'DBError' on miss
-- because a well-formed mobile tracker row always has a matching catalog
-- entry (enforced at create time).
appCatalogForRow ::
  (MonadFlow m) =>
  ReleaseTracker ->
  m AppCatalog
appCatalogForRow rt = appCatalogByKey (appGroup rt) (service rt) (env rt)

-- | Row-variant of 'appCatalogForRow'. Same lookup, but takes the raw
-- Beam row so callers that haven't projected to the domain type (e.g.
-- the revert handler) don't need to construct a stub 'ReleaseTracker'.
appCatalogForRowRaw ::
  (MonadFlow m) =>
  ReleaseTrackerRow ->
  m AppCatalog
appCatalogForRowRaw rt = appCatalogByKey (rtAppGroup rt) (rtService rt) (rtEnv rt)

appCatalogByKey ::
  (MonadFlow m) =>
  Text ->
  Text ->
  Text ->
  m AppCatalog
appCatalogByKey nameK surfaceK platformK = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          ac <- all_ (appCatalogs autopilotDb)
          guard_ (acName ac ==. val_ nameK)
          guard_ (acSurface ac ==. val_ surfaceK)
          guard_ (acPlatform ac ==. val_ platformK)
          pure ac
  case rows of
    (x : _) -> pure x
    [] ->
      throwM $
        DBError "appCatalogForRow" $
          "no app_catalog row for ("
            <> nameK
            <> ", "
            <> surfaceK
            <> ", "
            <> platformK
            <> ")"

-- | Generic BUSINESS-category event emitter. Wraps
-- @insertReleaseEvent@ from the autopilot query module so mobile callers
-- don't have to thread the category string through every site.
logEvent ::
  (MonadFlow m) =>
  Text ->
  Text ->
  Value ->
  m ()
logEvent rid label payload = insertReleaseEvent rid "BUSINESS" label payload

-- | Owner part of an @"owner/repo"@ slug from an AppCatalog row.
gitOwner :: AppCatalog -> Text
gitOwner ac = T.takeWhile (/= '/') (acGithubRepo ac)

-- | Repo part of an @"owner/repo"@ slug from an AppCatalog row.
gitRepo :: AppCatalog -> Text
gitRepo ac = T.drop 1 (T.dropWhile (/= '/') (acGithubRepo ac))

-- | Insert a fully-formed mobile tracker row. The release_context
-- column is populated with @MobileBuildState target@ encoded as JSON
-- text, so workflow stages can deserialize it via the standard
-- 'TargetState' parser. @dispatch_id@ and @external_run_id@ are left
-- NULL — the dispatch endpoint sets them later.
--
-- The underlying @insertReleaseTrackerRow@ does DELETE + INSERT in a
-- transaction, so a stale row with the same id is replaced. The mobile
-- create flow generates fresh UUIDs so this collision path should not
-- fire.
insertMobileTracker ::
  (MonadFlow m) =>
  Text ->
  AppCatalog ->
  MobileBuildTargetState ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  UTCTime ->
  m ()
insertMobileTracker rid ac targetState mVersionName mSourceRef createdBy_ createdAt =
  insertReleaseTrackerRow (mkMobileTrackerRow rid ac targetState mVersionName mSourceRef createdBy_ createdAt)

-- | Pure builder for a fresh MobileBuild @release_tracker@ row (status CREATED,
-- mode MANUAL, unapproved). Extracted from 'insertMobileTracker' so the create
-- handler can build N rows and insert them in one transaction via
-- 'insertReleaseTrackerRowsBatch'.
mkMobileTrackerRow ::
  Text ->
  AppCatalog ->
  MobileBuildTargetState ->
  Maybe Text ->
  Maybe Text ->
  Text ->
  UTCTime ->
  ReleaseTrackerRow
mkMobileTrackerRow rid ac targetState mVersionName mSourceRef createdBy_ createdAt = row
  where
    versionName = fromMaybe "" mVersionName
    encodedCtx = encodeJsonText (MobileBuildState targetState)
    row =
      ReleaseTrackerT
        { rtId = rid,
          rtOldVersion = "",
          rtNewVersion = versionName,
          rtAppGroup = acName ac,
          rtService = acSurface ac,
          rtPriority = 0,
          rtEnv = acPlatform ac,
          rtCategory = "MobileBuild",
          rtStatus = "CREATED",
          rtReleaseWFStatus = "INIT",
          rtMode = Just "MANUAL",
          rtCreatedBy = createdBy_,
          rtApprovedBy = Nothing,
          rtIsApproved = Just False,
          rtIsInfraApproved = Just False,
          -- release_tag is NOT NULL in the schema; default it to the
          -- release id so the row inserts cleanly. The dispatch flow
          -- can overwrite this later if it needs a human-readable tag.
          rtReleaseTag = Just rid,
          rtScheduleTime = Nothing,
          rtStartTime = Nothing,
          rtEndTime = Nothing,
          rtRolloutStrategy = Nothing,
          rtRolloutHistory = Nothing,
          rtTargetState = Just encodedCtx,
          rtInfo = Nothing,
          rtDescription = Nothing,
          rtChangeLog = Nothing,
          rtMetadata = Nothing,
          rtGlobalId = Nothing,
          rtSyncEnabled = Nothing,
          rtEnvOverrideData = Nothing,
          rtSlackThreadTs = Nothing,
          rtDispatchId = Nothing,
          rtExternalRunId = Nothing,
          rtCommitSha = Nothing,
          rtSourceRef = mSourceRef,
          rtRevertsReleaseId = Nothing,
          rtAbValidationStatus = Nothing,
          rtAbValidation = Nothing,
          rtReviewStatus = Nothing,
          rtReviewSubmittedAt = Nothing,
          rtReviewDecidedAt = Nothing,
          rtReviewRejectReason = Nothing,
          rtRolloutStatus = Nothing,
          rtRolloutPercent = Nothing,
          rtStoreRolloutHistory = Nothing,
          rtAscVersionId = Nothing,
          rtAscPhasedId = Nothing,
          -- track is unknown until the build lands on a store / is promoted;
          -- store-sync and promote set it (internal -> production).
          rtStoreTrack = Nothing,
          -- build number from the target context — part of the build identity
          -- (migration 0035) so two builds of the same version name don't collide.
          -- Gated on claimsStoreIdentity: only store-bound builds (not debug, not
          -- Firebase) stamp the COLUMN; internal builds keep the code in the JSON only.
          rtVersionCode =
            if claimsStoreIdentity (mbContext targetState)
              then mbcVersionCode (mbContext targetState)
              else Nothing,
          rtCreatedAt = createdAt,
          rtUpdatedAt = createdAt
        }

-- ─── Internal helpers ──────────────────────────────────────────────

-- | Project a raw 'ReleaseTrackerRow' to the domain 'ReleaseTracker'
-- needed by callers of 'findSiblingsByDispatchId'. Mirrors the shape of
-- 'fromRow' in @Products.Autopilot.Queries.ReleaseTracker@ but exposes a
-- narrower projection: mobile callers don't need the parsed
-- 'TargetState' here (they get it from their own scheduler tick), and we
-- deliberately skip the K8s-specific 'releaseContext' summary.
rowToDomain :: ReleaseTrackerT Identity -> ReleaseTracker
rowToDomain ReleaseTrackerT {..} =
  ReleaseTracker
    { releaseId = rtId,
      appGroup = rtAppGroup,
      service = rtService,
      env = rtEnv,
      category = parseCategory rtCategory,
      status = parseStatus rtStatus,
      releaseWFStatus = parseWFStatus rtReleaseWFStatus,
      mode = parseModeT rtMode,
      createdBy = rtCreatedBy,
      approvedBy = rtApprovedBy,
      isApproved = fromMaybe False rtIsApproved,
      isInfraApproved = fromMaybe False rtIsInfraApproved,
      releaseTag = rtReleaseTag,
      dateCreated = Just rtCreatedAt,
      lastUpdated = Just rtUpdatedAt,
      scheduleTime = rtScheduleTime,
      startTime = rtStartTime,
      endTime = rtEndTime,
      rolloutStrategy = [],
      rolloutHistory = [],
      oldVersion = rtOldVersion,
      newVersion = rtNewVersion,
      info = rtInfo,
      description = rtDescription,
      changeLog = rtChangeLog,
      metadata = Nothing,
      priority = rtPriority,
      globalId = rtGlobalId,
      syncEnabled = rtSyncEnabled,
      envOverrideData = rtEnvOverrideData,
      slackThreadTs = rtSlackThreadTs,
      releaseContext = Nothing,
      sourceRef = rtSourceRef,
      commitSha = rtCommitSha,
      revertsReleaseId = rtRevertsReleaseId,
      abValidationStatus = rtAbValidationStatus,
      abValidation = parseJsonTextMaybe rtAbValidation
    }

parseCategory :: Text -> ReleaseCategory
parseCategory = parseReleaseCategory

parseStatus :: Text -> ReleaseStatus
parseStatus = parseReleaseStatus

parseWFStatus :: Text -> ReleaseWFStatus
parseWFStatus = parseReleaseWFStatus

parseModeT :: Maybe Text -> Mode
parseModeT = parseMode

-- ─── Revert helpers ────────────────────────────────────────────────

-- | Decode a @release_tracker.release_context@ string into a
-- 'MobileBuildTargetState'. Returns @Nothing@ for backend rows (whose
-- target state is K8s-shaped) and for rows whose JSON failed to parse.
--
-- The revert handler needs this to read @mbcTagPushed@ (the tag pushed
-- by the workflow at release time — used as the dispatch ref for
-- revert) and @mbcVersionCode@ (the version code that shipped, so we
-- can compute @bad + 1@ for the revert).
parseMobileTargetState :: Maybe Text -> Maybe MobileBuildTargetState
parseMobileTargetState Nothing = Nothing
parseMobileTargetState (Just t) =
  case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
    Right (MobileBuildState s) -> Just s
    _ -> Nothing

-- | Fetch a single mobile release tracker by ID, paired with its
-- parsed mobile target state. Returns @Nothing@ if the row is not found
-- or is not a mobile release.
findMobileReleaseById ::
  (MonadFlow m) =>
  Text ->
  m (Maybe (ReleaseTrackerRow, Maybe MobileBuildTargetState))
findMobileReleaseById releaseId' = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId')
          guard_ (rtCategory rt ==. val_ "MobileBuild")
          pure rt
  pure $ case rows of
    (row : _) -> Just (row, parseMobileTargetState (rtTargetState row))
    [] -> Nothing

-- | Fetch the window of rollback candidates for an app: COMPLETED,
-- non-debug, non-reverted mobile releases for the same
-- @(app_group, service, env)@, excluding the bad release itself. Store-sync
-- rows are __included__ — they record real versions users were on, so they
-- are valid rollback targets (the resolver handles the case where such a
-- target has no SCC build artifact).
--
-- The window is bounded (most recent 50 by @created_at@) purely to cap the
-- row set; the actual rollback target is then chosen by /version order/, not
-- creation time — see "Products.Autopilot.Mobile.RevertResolver". The B4
-- store-sync dedup index keeps this window from filling with duplicates. If
-- an app ever outgrows 50, promote @version_code@ to an indexed column and
-- resolve with a single ordered @LIMIT 1@ (see post-MVP design §15).
--
-- Filtering of debug / reverted rows happens in Haskell because that state
-- lives inside the @target_state@ / @metadata@ JSON columns.
fetchRevertCandidates ::
  (MonadFlow m) =>
  -- | app_group (app name, e.g. "NammaYatri")
  Text ->
  -- | service (surface, e.g. "customer")
  Text ->
  -- | env (platform, e.g. "android")
  Text ->
  -- | id of the bad release, excluded from the window
  Text ->
  m [RevertCand]
fetchRevertCandidates appGroup' service' env' excludeId = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          limit_ 50 $
            orderBy_ (desc_ . rtCreatedAt) $ do
              rt <- all_ (releaseTrackers autopilotDb)
              guard_ (rtCategory rt ==. val_ "MobileBuild")
              guard_ (rtAppGroup rt ==. val_ appGroup')
              guard_ (rtService rt ==. val_ service')
              guard_ (rtEnv rt ==. val_ env')
              guard_ (rtStatus rt ==. val_ "COMPLETED")
              guard_ (rtId rt /=. val_ excludeId)
              pure rt
  pure (mapMaybe toCand rows)
  where
    toCand row
      | isReverted row = Nothing
      | otherwise =
          let mState = parseMobileTargetState (rtTargetState row)
           in case mState of
                Just st | isDebugBuildType (mbcBuildType (mbContext st)) -> Nothing
                _ ->
                  Just
                    RevertCand
                      { rcId = rtId row,
                        rcVersionName = rtNewVersion row,
                        rcVersionCode = mState >>= mbcVersionCode . mbContext,
                        rcTag = mState >>= mbcTagPushed . mbContext,
                        rcCommitSha = rtCommitSha row,
                        rcCreatedAt = rtCreatedAt row
                      }

isReverted :: ReleaseTrackerRow -> Bool
isReverted row = case rtMetadata row of
  Nothing -> False
  Just t -> case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
    Right (Aeson.Object o) -> KM.member (AK.fromText "reverted_by") o
    _ -> False

-- Re-export to keep the import surface tight for callers that need
-- the Beam row type without pulling Schema in directly.
type ReleaseTrackerRow = ReleaseTrackerT Identity

-- | Insert a mobile revert tracker row. Differs from the normal
-- 'insertMobileTracker' in three places:
--
-- * @source_ref@ is set to @refs\/tags\/<previous-good-tag>@ so the
--  dispatched workflow checks out the previous good commit.
-- * @reverts_release_id@ links back to the release being reverted.
-- * @change_log@ is provided up-front (auto-generated from the Compare
--  API by the caller; operator may have edited it in the UI).
--
-- Other fields mirror 'insertMobileTracker': status = CREATED,
-- isApproved = False, dispatch_id = NULL (the operator hits the
-- existing dispatch endpoint once the revert is approved).
insertMobileRevertTracker ::
  (MonadFlow m) =>
  -- | new release id (UUID)
  Text ->
  -- | app catalog row matching the bad release
  AppCatalog ->
  -- | initial target state (mbContext.versionCode = bad+1, etc.)
  MobileBuildTargetState ->
  -- | new version name (e.g. "1.2.4")
  Text ->
  -- | change log (auto-generated; operator may have edited)
  Text ->
  -- | source_ref (e.g. "refs/tags/nammayatri/prod/android/v1.2.2+450")
  Text ->
  -- | reverts_release_id (the bad release's id)
  Text ->
  -- | created_by (operator email from AuthedPerson)
  Text ->
  UTCTime ->
  m ()
insertMobileRevertTracker rid ac targetState versionName changeLog_ sourceRef_ revertsId createdBy_ createdAt =
  insertReleaseTrackerRow row
  where
    encodedCtx = encodeJsonText (MobileBuildState targetState)
    row =
      ReleaseTrackerT
        { rtId = rid,
          rtOldVersion = "",
          rtNewVersion = versionName,
          rtAppGroup = acName ac,
          rtService = acSurface ac,
          rtPriority = 0,
          rtEnv = acPlatform ac,
          rtCategory = "MobileBuild",
          rtStatus = "CREATED",
          rtReleaseWFStatus = "INIT",
          rtMode = Just "MANUAL",
          rtCreatedBy = createdBy_,
          rtApprovedBy = Nothing,
          rtIsApproved = Just False,
          rtIsInfraApproved = Just False,
          rtReleaseTag = Just rid,
          rtScheduleTime = Nothing,
          rtStartTime = Nothing,
          rtEndTime = Nothing,
          rtRolloutStrategy = Nothing,
          rtRolloutHistory = Nothing,
          rtTargetState = Just encodedCtx,
          rtInfo = Nothing,
          rtDescription = Nothing,
          rtChangeLog = Just changeLog_,
          rtMetadata = Nothing,
          rtGlobalId = Nothing,
          rtSyncEnabled = Nothing,
          rtEnvOverrideData = Nothing,
          rtSlackThreadTs = Nothing,
          rtDispatchId = Nothing,
          rtExternalRunId = Nothing,
          rtCommitSha = Nothing,
          rtSourceRef = Just sourceRef_,
          rtRevertsReleaseId = Just revertsId,
          rtAbValidationStatus = Nothing,
          rtAbValidation = Nothing,
          rtReviewStatus = Nothing,
          rtReviewSubmittedAt = Nothing,
          rtReviewDecidedAt = Nothing,
          rtReviewRejectReason = Nothing,
          rtRolloutStatus = Nothing,
          rtRolloutPercent = Nothing,
          rtStoreRolloutHistory = Nothing,
          rtAscVersionId = Nothing,
          rtAscPhasedId = Nothing,
          -- track is unknown until the build lands on a store / is promoted;
          -- store-sync and promote set it (internal -> production).
          rtStoreTrack = Nothing,
          -- build number from the target context — part of the build identity
          -- (migration 0035) so two builds of the same version name don't collide.
          -- Gated on claimsStoreIdentity: only store-bound builds (not debug, not
          -- Firebase) stamp the COLUMN; internal builds keep the code in the JSON only.
          rtVersionCode =
            if claimsStoreIdentity (mbContext targetState)
              then mbcVersionCode (mbContext targetState)
              else Nothing,
          rtCreatedAt = createdAt,
          rtUpdatedAt = createdAt
        }

-- | Stamp @metadata.reverted_by = <revertId>@ on the bad release row.
-- Drives the "⤴ Reverted by X" banner on the bad release's detail page.
--
-- Implementation: read the existing @metadata@ JSON (or @{}@ if NULL),
-- set the @reverted_by@ key, write it back. Single UPDATE.
markReleaseRevertedBy ::
  (MonadFlow m) =>
  -- | bad release id
  Text ->
  -- | revert release id
  Text ->
  m ()
markReleaseRevertedBy badId revertId = withDb $ \db -> do
  -- Read existing metadata.
  rows <-
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ badId)
          pure (rtMetadata rt)
  -- Merge existing keys with the new "reverted_by" key. If the
  -- existing metadata is missing or not an object, start fresh.
  let existingMap :: KM.KeyMap Aeson.Value
      existingMap = case rows of
        (Just existing : _) ->
          case Aeson.eitherDecodeStrict (TE.encodeUtf8 existing) of
            Right (Aeson.Object o) -> o
            _ -> KM.empty
        _ -> KM.empty
      updated =
        Aeson.Object
          ( KM.insert "reverted_by" (Aeson.String revertId) existingMap
          )
      encoded = encodeJsonText updated
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        (\rt -> rtMetadata rt <-. val_ (Just encoded))
        (\rt -> rtId rt ==. val_ badId)
