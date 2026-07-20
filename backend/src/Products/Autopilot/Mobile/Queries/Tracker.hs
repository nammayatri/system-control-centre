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
    findRunSiblingsStillBuilding,
    setExternalRunIdForDispatch,
    setPhase,
    setAscIds,
    markReleaseInProgress,
    updateStoreSyncBuildCode,
    setReleaseVersionCode,
    findExternalReviewRow,
    findExternalReviewRowForVersion,
    storeSyncRowExistsForVersion,
    convergeStoreSyncRow,
    findAdoptableDraft,
    adoptDraftAsStoreBuild,
    findMobileVersionRow,
    retireOlderHeldInternal,
    listIncomingMobileVersions,
    sccActiveReleaseExistsForVersion,
    applyExternalReviewPhase,
    closeExternalReviewRow,
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

import Control.Monad (forM_, unless, when)
import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow, logWarning, withDb)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int32)
import Data.List (find)
import Data.Maybe (fromMaybe, isJust, isNothing, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, getCurrentTime)
import Database.Beam
import Products.Autopilot.Mobile.Lifecycle.BuildKind (buildKind, claimsStoreIdentity)
import Products.Autopilot.Mobile.Lifecycle.Phase
  ( Projection (..),
    ReleasePhase (..),
    canTransition,
    phaseFromFields,
    pEngineStatus,
    phaseToWfStatus,
    project,
  )
import Products.Autopilot.Mobile.RevertResolver (RevertCand (..))
import Products.Autopilot.Mobile.Types
  ( MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
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
    releaseStatusToText,
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

-- | App names of OTHER rows in a dispatch group whose build is still running
-- (non-terminal status, wf before MBSubmittedToStore — nothing uploaded yet).
-- Aborting any row cancels the group's shared GH run, so these builds die
-- with it; the FE lists them in the abort confirm. Already-uploaded siblings
-- (MBSubmittedToStore+) are safe from a run-cancel and excluded.
findRunSiblingsStillBuilding :: (MonadFlow m) => Text -> Text -> m [Text]
findRunSiblingsStillBuilding dispatchId excludeRid = do
  rows <- withDb $ \db ->
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtDispatchId rt ==. val_ (Just dispatchId))
          guard_ (rtId rt /=. val_ excludeRid)
          guard_ (rtStatus rt `in_` [val_ "CREATED", val_ "INPROGRESS"])
          pure (rtAppGroup rt, rtTargetState rt)
  pure
    [ ag
    | (ag, mCtx) <- rows
    , Just st <- [parseMobileTargetState mCtx]
    , stillBuilding (mbWfStatus st)
    ]
  where
    stillBuilding wf =
      wf `elem` [MBInit, MBVersionResolved, MBDispatched, MBRunIdResolved, MBBuilding]

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

-- | The single writer: one ReleasePhase projects the whole status tuple
-- (review/rollout/percent/track/reason + mb_wf_status + review *_at) in one UPDATE.
-- Logged-not-blocked guard; rt_status stays Finalize-owned till step 5.
setPhase :: (MonadFlow m) => UTCTime -> Text -> ReleasePhase -> m ()
setPhase now releaseId_ next = do
  mWarn <- withDb $ \db -> do
    mRow <-
      runDB db $
        runSelectReturningOne $
          select $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtId rt ==. val_ releaseId_)
            pure rt
    case mRow of
      Nothing -> throwM $ DBError "setPhase" ("release not found: " <> releaseId_)
      Just row -> case parseMobileTargetState (rtTargetState row) of
        Nothing -> throwM $ DBError "setPhase" ("not a mobile release: " <> releaseId_)
        Just s -> do
          let cur =
                phaseFromFields
                  (buildKind (mbContext s))
                  (mbWfStatus s)
                  (rtReviewStatus row)
                  (rtRolloutStatus row)
                  (rtRolloutPercent row)
                  (rtStoreTrack row)
              Projection rv ro pct trk = project next
              -- JSON side-effect: stamp review-submitted-at on entry to review
              -- (anchors the 7-day review timeout, read from the target-state).
              s' = case next of
                InReview -> s{mbWfStatus = MBInReview, mbReviewSubmittedAt = Just now}
                _ -> maybe s (\w -> s{mbWfStatus = w}) (phaseToWfStatus next)
              reason = case next of Rejected r | not (T.null r) -> Just r; _ -> Nothing
              decided = case next of Approved -> True; Rejected _ -> True; _ -> False
              -- Write-once terminal outcome. Stamped the first time a build hits a
              -- terminal phase; the read-time fallback uses it once the build is on
              -- no live store_status cell. Never overwritten (a build past 100% can't
              -- become superseded), so it can't drift.
              mTerminal = case next of
                Live -> Just "RELEASED"
                Superseded -> Just "SUPERSEDED"
                Aborted -> Just "ABORTED"
                _ -> Nothing
              setTerminal = isJust mTerminal && isNothing (rtTerminalStatus row)
          runDB db $
            runUpdate $
              update
                (releaseTrackers autopilotDb)
                ( \rt ->
                    mconcat $
                      [ rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s'))),
                        rtReviewStatus rt <-. val_ rv,
                        rtRolloutStatus rt <-. val_ ro,
                        rtRolloutPercent rt <-. val_ pct,
                        rtStoreTrack rt <-. val_ trk,
                        rtReviewRejectReason rt <-. val_ reason
                      ]
                        <> [rtReviewSubmittedAt rt <-. val_ (Just now) | InReview <- [next]]
                        <> [rtReviewDecidedAt rt <-. val_ (Just now) | decided]
                        <> [rtTerminalStatus rt <-. val_ mTerminal | setTerminal]
                )
                (\rt -> rtId rt ==. val_ releaseId_)
          -- Shadow guard: report (don't block) an out-of-order transition.
          pure (if canTransition cur next then Nothing else Just (T.pack (show cur) <> " -> " <> T.pack (show next)))
  forM_ mWarn $ \t -> logWarning ("setPhase " <> releaseId_ <> ": unexpected transition " <> t)

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
              [ rtStatus rt <-. val_ "INPROGRESS",
                rtStoreTrack rt <-. val_ (Just "production")
              ]
        )
        (\rt -> rtId rt ==. val_ releaseId_)

-- | Bump a PRISTINE store-sync snapshot's build code + tag in place when a newer build
-- of the SAME version appears (e.g. iOS 3.3.73(1) → (2)); the dedup index blocks a
-- re-insert. Only COMPLETED store-sync rows with no review (never a promoted/MANUAL row).
-- Returns True if it bumped one; False (no snapshot to bump — a MANUAL build owns the
-- version) tells the caller the observed build is out-of-band and needs its own row.
updateStoreSyncBuildCode :: (MonadFlow m) => AppCatalog -> Text -> Maybe Int32 -> Maybe Text -> m Bool
updateStoreSyncBuildCode ac version newCode newTag = do
  mRow <- withDb $ \db ->
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
    Nothing -> pure False
    Just (row, s) -> do
      -- Guarded bump: moving the snapshot to (version, newCode) must not
      -- collide with a row that already OWNS that identity (e.g. the MANUAL row of a
      -- resubmitted build) — the cross-mode unique index would abort the sync pass.
      -- If owned, report False; the caller's insert-if-absent dedupes to a no-op.
      taken <- case newCode of
        Nothing -> pure False
        Just c -> do
          mOwner <- findMobileVersionRow (acName ac) (acSurface ac) (acPlatform ac) version (Just c)
          pure (maybe False ((/= rtId row) . rtId) mOwner)
      if taken
        then pure False
        else do
          let s' = s{mbContext = (mbContext s){mbcVersionCode = newCode, mbcTagPushed = newTag}}
          withDb $ \db ->
            runDB db $
              runUpdate $
                update
                  (releaseTrackers autopilotDb)
                  ( \rt ->
                      mconcat
                        [ rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s'))),
                          rtVersionCode rt <-. val_ newCode
                        ]
                  )
                  (\rt -> rtId rt ==. val_ (rtId row))
          pure True

-- | Stamp the resolved build code onto a release row's @version_code@ column by id.
-- The workflow persist (@insertReleaseTracker@) omits @version_code@, so ConfirmTag
-- calls this once the tag is observed — giving iOS/provider builds (code assigned by
-- the build, read back from the tag) the identity code Android consumer builds get on
-- dispatch. Keyed off by the (version, code) store_status join.
setReleaseVersionCode :: (MonadFlow m) => Text -> Int32 -> m ()
setReleaseVersionCode rid code = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        (\rt -> rtVersionCode rt <-. val_ (Just code))
        (\rt -> rtId rt ==. val_ rid)

-- | The store-sync @metadata@ object (or empty). Preserves every existing key
-- (notably @store_track@ and the per-track @tracks@ snapshots).
storeMetaObject :: Maybe Text -> KM.KeyMap Value
storeMetaObject mCur = case mCur >>= (Aeson.decodeStrict . TE.encodeUtf8) of
  Just (Aeson.Object o) -> o
  _ -> KM.empty

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

-- | The EXTERNAL_REVIEW row for an EXACT build (version + code). The convergence
-- target when a reviewed build goes live, so store-sync transitions it in place
-- instead of minting a duplicate. Code is matched COALESCE(-1) like the identity
-- index, so a resubmit with a bumped code targets its own row, not a sibling.
findExternalReviewRowForVersion :: (MonadFlow m) => Text -> Text -> Text -> Text -> Maybe Int32 -> m (Maybe ReleaseTrackerRow)
findExternalReviewRowForVersion appGroup surface platform version mCode = withDb $ \db ->
  runDB db $
    runSelectReturningOne $
      select $
        limit_ 1 $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtAppGroup rt ==. val_ appGroup)
          guard_ (rtService rt ==. val_ surface)
          guard_ (rtEnv rt ==. val_ platform)
          guard_ (rtNewVersion rt ==. val_ version)
          guard_ (coalesce_ [rtVersionCode rt] (val_ (-1)) ==. val_ (fromMaybe (-1) mCode))
          guard_ (rtMode rt ==. val_ (Just "EXTERNAL_REVIEW"))
          pure rt

-- | Whether a STORE_SYNC row already exists for this exact build (version + code).
-- Guards the in-place external-review transition so flipping a row to STORE_SYNC
-- can't create a second one and violate the identity index.
storeSyncRowExistsForVersion :: (MonadFlow m) => Text -> Text -> Text -> Text -> Maybe Int32 -> m Bool
storeSyncRowExistsForVersion appGroup surface platform version mCode = withDb $ \db -> do
  rows <-
    runDB db $
      runSelectReturningList $
        select $
          limit_ 1 $ do
            rt <- all_ (releaseTrackers autopilotDb)
            guard_ (rtAppGroup rt ==. val_ appGroup)
            guard_ (rtService rt ==. val_ surface)
            guard_ (rtEnv rt ==. val_ platform)
            guard_ (rtNewVersion rt ==. val_ version)
            guard_ (coalesce_ [rtVersionCode rt] (val_ (-1)) ==. val_ (fromMaybe (-1) mCode))
            guard_ (rtMode rt ==. val_ (Just "STORE_SYNC"))
            pure (rtId rt)
  pure (not (null rows))

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
          -- Build identity is (name, code), so when the caller knows the build
          -- number, match it exactly. Without it, fall back to name and take the
          -- highest code (latest build). COALESCE(-1) orders code-less legacy rows
          -- LAST — plain DESC is NULLS FIRST in Postgres, which made a NULL-code
          -- phantom row win over the real coded build.
          orderBy_ (\rt -> desc_ (coalesce_ [rtVersionCode rt] (val_ (-1)))) $ do
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

-- | Rule C: when a newer build is promoted, retire OLDER held-on-internal builds of the
-- app to history (COMPLETED, keeping version_code). A lower code can't reach production
-- once a higher one is in review. Only LANDED (MBTagPushed) builds, never mid-build.
retireOlderHeldInternal :: (MonadFlow m) => Text -> Text -> Text -> Text -> Maybe Int32 -> m [Text]
retireOlderHeldInternal _ _ _ _ Nothing = pure []
retireOlderHeldInternal appGroup surface platform excludeRid (Just promotedCode) = do
  rows <- withDb $ \db ->
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtAppGroup rt ==. val_ appGroup)
          guard_ (rtService rt ==. val_ surface)
          guard_ (rtEnv rt ==. val_ platform)
          guard_ (rtCategory rt ==. val_ "MobileBuild")
          guard_ (rtId rt /=. val_ excludeRid)
          guard_ (rtStatus rt ==. val_ "INPROGRESS")
          guard_ (isNothing_ (rtStoreTrack rt)) -- not promoted (no production track)
          guard_ (isNothing_ (rtReviewStatus rt)) -- not in review
          guard_ (isNothing_ (rtRolloutStatus rt)) -- not rolling out
          guard_ (rtVersionCode rt <. just_ (val_ promotedCode))
          pure rt
  -- Only retire builds that actually landed (held at MBTagPushed); never orphan a
  -- build still in flight.
  let landed :: ReleaseTrackerRow -> Bool
      landed r = (mbWfStatus <$> parseMobileTargetState (rtTargetState r)) == Just MBTagPushed
      ids = map rtId (filter landed rows)
  forM_ ids $ \i ->
    withDb $ \db ->
      runDB db $
        runUpdate $
          update
            (releaseTrackers autopilotDb)
            (\rt -> rtStatus rt <-. val_ "COMPLETED")
            (\rt -> rtId rt ==. val_ i)
  pure ids

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

{- | Apply an externally-observed review verdict onto the version's row THROUGH
the single writer (§16e-2): fill a missing build code, advance the engine status
(a converged store-sync snapshot re-enters the active lifecycle), then 'setPhase'
the verdict — which projects the consistent column set and mirrors the wf status.

Idempotent: re-observing the SAME verdict on a sync pass is a no-op (never
re-stamps @review_submitted_at@ / churns the row); the code-fill still runs so a
legacy code-less row heals even when its verdict is unchanged.
-}
applyExternalReviewPhase :: (MonadFlow m) => Text -> Text -> Maybe Int32 -> m ()
applyExternalReviewPhase releaseId_ reviewStatus mCode = do
  mRow <- withDb $ \db ->
    runDB db $
      runSelectReturningOne $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtId rt ==. val_ releaseId_)
          pure rt
  forM_ mRow $ \row -> do
    -- Fill a MISSING build code (identity completion for legacy code-less rows);
    -- never overwrite one, and never claim a (version, code) another row already
    -- owns (the cross-mode uq_release_tracker_mobile_build identity).
    fill <- case (rtVersionCode row, mCode) of
      (Nothing, Just c) -> do
        mOwner <- findMobileVersionRow (rtAppGroup row) (rtService row) (rtEnv row) (rtNewVersion row) (Just c)
        pure $ if maybe True ((== rtId row) . rtId) mOwner then Just c else Nothing
      _ -> pure Nothing
    forM_ fill (fillRowVersionCode row)
    unless (rtReviewStatus row == Just reviewStatus) $ do
      markReleaseInProgress releaseId_
      now <- liftIO getCurrentTime
      setPhase now releaseId_ $ case reviewStatus of
        "approved" -> Approved
        "rejected" -> Rejected ""
        _ -> InReview

-- | Write a filled build code to BOTH the column and the JSON context, so the
-- row's two code sources can't diverge. Caller guarantees the identity is free.
fillRowVersionCode :: (MonadFlow m) => ReleaseTrackerRow -> Int32 -> m ()
fillRowVersionCode row c = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat $
              [rtVersionCode rt <-. val_ (Just c)]
                <> [ rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s{mbContext = (mbContext s){mbcVersionCode = Just c}})))
                   | Just s <- [parseMobileTargetState (rtTargetState row)]
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
      let s' = s{mbWfStatus = MBCompleted}
       in runDB db $
            runUpdate $
              update
                (releaseTrackers autopilotDb)
                ( \rt ->
                    mconcat
                      [ rtStatus rt <-. val_ "COMPLETED",
                        -- Clear the now-stale review_status so a retired external row can
                        -- never resurface as "in_review" (e.g. a path reading the column).
                        rtReviewStatus rt <-. val_ Nothing,
                        -- It has left review (rolling out / live) → drop the EXTERNAL chip
                        -- so it reads as a normal store row (rolling out X%, then Production).
                        rtMetadata rt <-. val_ (clearExternalMeta (rtMetadata row)),
                        rtTargetState rt <-. val_ (Just (encodeJsonText (MobileBuildState s')))
                      ]
                )
                (\rt -> rtId rt ==. val_ (rtId row))

{- | Close a store-sync-owned row with a terminal verdict (§16h-1): 'setPhase' the
outcome, then flip the engine status from 'pEngineStatus' — these rows have no
runner Finalize to do it, and an INPROGRESS leftover would keep occupying the
partial unique index slot (mode EXTERNAL_REVIEW AND status INPROGRESS), blocking
re-detection of the version.
-}
closeExternalReviewRow :: (MonadFlow m) => Text -> ReleasePhase -> m ()
closeExternalReviewRow releaseId_ ph = do
  now <- liftIO getCurrentTime
  setPhase now releaseId_ ph
  withDb $ \db ->
    runDB db $
      runUpdate $
        update
          (releaseTrackers autopilotDb)
          (\rt -> rtStatus rt <-. val_ (releaseStatusToText (pEngineStatus ph)))
          (\rt -> rtId rt ==. val_ releaseId_)

-- | Transition an external-review row into a live store-sync row IN PLACE: flip
-- mode/status to a completed STORE_SYNC build, clear the review state, stamp the
-- store track/version/state. Preserves date_created (only last_updated moves).
{- | The SCC draft that already claimed an identity now seen on a store track:
MANUAL, still CREATED, and never dispatched — the row store-sync ADOPTS
('adoptDraftAsStoreBuild') instead of leaving a stale draft whose build stages
can never legitimately run (the artifact exists; rebuilding would collide on
the version code).
-}
findAdoptableDraft :: (MonadFlow m) => Text -> Text -> Text -> Text -> Int32 -> m (Maybe ReleaseTrackerRow)
findAdoptableDraft appGroup surface platform version code = do
  rows <- withDb $ \db ->
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (rtAppGroup rt ==. val_ appGroup)
          guard_ (rtService rt ==. val_ surface)
          guard_ (rtEnv rt ==. val_ platform)
          guard_ (rtNewVersion rt ==. val_ version)
          guard_ (rtVersionCode rt ==. val_ (Just code))
          guard_ (rtCategory rt ==. val_ "MobileBuild")
          guard_ (rtMode rt ==. val_ (Just "MANUAL"))
          guard_ (rtStatus rt ==. val_ "CREATED")
          guard_ (isNothing_ (rtDispatchId rt))
          pure rt
  pure (safeHeadT rows)
  where
    safeHeadT (x : _) = Just x
    safeHeadT [] = Nothing

{- | Flip an adoptable draft to build-complete: the out-of-band upload IS the
build, so the row skips straight to the held-at-@MBTagPushed@ state the normal
pipeline would reach — approve/dispatch become ineligible (no longer CREATED)
and promote becomes genuinely valid. CAS on CREATED + undispatched so a
concurrent operator dispatch wins over adoption.
-}
adoptDraftAsStoreBuild :: (MonadFlow m) => Text -> Text -> Text -> UTCTime -> UTCTime -> m Bool
adoptDraftAsStoreBuild rid track encodedState startTime now = withDb $ \db -> do
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat
              [ rtStatus rt <-. val_ "INPROGRESS",
                rtReleaseWFStatus rt <-. val_ "INPROGRESS",
                rtStoreTrack rt <-. val_ (Just track),
                rtTargetState rt <-. val_ (Just encodedState),
                rtStartTime rt <-. val_ (Just startTime),
                rtUpdatedAt rt <-. val_ now
              ]
        )
        (\rt -> rtId rt ==. val_ rid &&. rtStatus rt ==. val_ "CREATED" &&. isNothing_ (rtDispatchId rt))
  -- Beam's runUpdate has no row count: read back to learn whether WE flipped
  -- it (a concurrent dispatch keeps status CREATED and wins).
  rows <- runDB db $
    runSelectReturningList $
      select $ do
        rt <- all_ (releaseTrackers autopilotDb)
        guard_ (rtId rt ==. val_ rid)
        pure (rtStatus rt)
  pure (rows == ["INPROGRESS"])

convergeStoreSyncRow :: (MonadFlow m) => Text -> Text -> Maybe Int32 -> Text -> Text -> UTCTime -> m ()
convergeStoreSyncRow rid track mCode encodedState meta now = withDb $ \db ->
  runDB db $
    runUpdate $
      update
        (releaseTrackers autopilotDb)
        ( \rt ->
            mconcat
              [ rtMode rt <-. val_ (Just "STORE_SYNC"),
                rtStatus rt <-. val_ "COMPLETED",
                rtReleaseWFStatus rt <-. val_ "COMPLETED",
                rtReviewStatus rt <-. val_ Nothing,
                rtReviewSubmittedAt rt <-. val_ Nothing,
                rtReviewDecidedAt rt <-. val_ Nothing,
                rtReviewRejectReason rt <-. val_ Nothing,
                rtStoreTrack rt <-. val_ (Just track),
                rtVersionCode rt <-. val_ mCode,
                rtTargetState rt <-. val_ (Just encodedState),
                rtMetadata rt <-. val_ (Just meta),
                rtIsApproved rt <-. val_ (Just True),
                rtIsInfraApproved rt <-. val_ (Just True),
                rtEndTime rt <-. val_ (Just now),
                rtDescription rt <-. val_ (Just ("Imported from store (" <> track <> ")")),
                rtUpdatedAt rt <-. val_ now
              ]
        )
        (\rt -> rtId rt ==. val_ rid)

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
               in s{mbResolveAttempts = Just n}
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
          rtTerminalStatus = Nothing,
          -- Queryable copy of the context's group id (migration 0042); the
          -- guard drops the empty-string placeholder some persists carry.
          rtReleaseGroupId = groupIdColumn targetState,
          rtReleaseGroupLabel = Nothing,
          rtCloudType = Nothing,
          rtCreatedAt = createdAt,
          rtUpdatedAt = createdAt
        }

-- | The context's release_group_id as a column value — Nothing for the
-- empty-string placeholder so blank ids never form an accidental group.
groupIdColumn :: MobileBuildTargetState -> Maybe Text
groupIdColumn ts =
  let gid = mbcReleaseGroupId (mbContext ts)
   in if T.null (T.strip gid) then Nothing else Just gid

-- ─── Internal helpers ──────────────────────────────────────────────

-- | Project a raw 'ReleaseTrackerRow' to the domain 'ReleaseTracker'
-- needed by callers of 'findSiblingsByDispatchId'. Mirrors the shape of
-- 'fromRow' in @Products.Autopilot.Queries.ReleaseTracker@ but exposes a
-- narrower projection: mobile callers don't need the parsed
-- 'TargetState' here (they get it from their own scheduler tick), and we
-- deliberately skip the K8s-specific 'releaseContext' summary.
rowToDomain :: ReleaseTrackerT Identity -> ReleaseTracker
rowToDomain ReleaseTrackerT{..} =
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
      versionCode = rtVersionCode,
      reviewStatus = rtReviewStatus,
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
-- resolve with a single ordered @LIMIT 1@ (see post-MVP design).
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
          rtTerminalStatus = Nothing,
          -- Inherited from the bad release via the context (Revert handler),
          -- so the revert shows up beside its siblings on the group page.
          rtReleaseGroupId = groupIdColumn targetState,
          rtReleaseGroupLabel = Nothing,
          -- Not cluster-bound (migration 0045): a build's identity is global,
          -- so it stays visible to every instance rather than one cloud's.
          rtCloudType = Nothing,
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
