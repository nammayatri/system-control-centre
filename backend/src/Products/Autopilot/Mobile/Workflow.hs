{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Mobile (React Native) build workflow spec.

Seven checkpoint-and-resume stages drive a single mobile release through
Play Console version resolution, GitHub Actions @workflow_dispatch@,
matrix-job polling, tag observation, and final status mapping.

Each stage:

* Skips itself via 'stageGuard' if the persisted @mbWfStatus@ already
  shows the work is done — so the worker re-tick safely resumes.
* Returns 'StageWaiting' for poll-style stages (run lookup, job status,
  tag confirmation) so the engine retries on the next tick at the same
  stage instead of marking the workflow failed.
* Returns 'StageAbort' (via @throwError DomainError@) only on terminal
  conditions (max attempts exceeded, missing config).

Postgres-side: stages 2-4 share a @dispatch_id@ that the create endpoint
(T17) sets up for sibling rows (same dispatch group). Exactly one GH run
per group is enforced by the leader gate (stage 3) plus the durable
dispatch receipt: the leader persists @mbBuildStartedAt@ + the run-id
watermark BEFORE the POST, so any retry path first looks for (and adopts)
the run that receipt points at instead of dispatching a second one.

Two known limitations are documented inline:

* GitHub's dispatch POST returns 204 with no run id, and omits @inputs@
  from the @\/runs@ list response — so stage 4 identifies our run by
  actor (the App's bot account) + the pre-dispatch run-id watermark
  (+ matrix-job verification when several candidates remain).
* @persistReleaseState@ reuses the K8s/Config persist helper, which
  serializes @MobileBuildState@ via the shared 'TargetState' JSON
  encoding (already wired up in T8/T15).
-}
module Products.Autopilot.Mobile.Workflow (
    mobileBuildSpec,
    tagConfirmTimedOut,
    reviewPollTimedOut,
    reviewPollDue,
    selectBuildTag,
    selectProviderBuildTag,
    codeFromTag,
    tagPushedFromLog,
    droppableUnexpectedInputs,
    electDispatchLeader,
    dispatchGroupJobNames,
    findDispatchIdForRelease,
    findDispatchGroupContexts,
    externalRunIdForRelease,
    FirebaseReleaseInfo (..),
    parseFirebaseRelease,
) where

import Control.Exception (Exception, SomeException, fromException, throwIO, try)
import Control.Applicative ((<|>))
import Control.Monad (forM_, guard, when)
import qualified Control.Monad.Catch as MC
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Control.Monad.State.Strict (gets, modify)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Reader (runReaderT)
import Control.Monad.Trans.State.Strict (runStateT)
import Core.DB.Connection (withConn)
import Core.Environment (MonadFlow, withDb)
import Core.Logging (logInfoG, logWarningG)
import Core.Workflow.Spec (WorkflowSpec (..))
import Core.Workflow.Stage (Stage (..), StageM, StageOutcome (..), mkStage)
import Core.Workflow.Types (WorkFlowError (..))
import Data.Aeson (object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as AK
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Char (digitToInt, isAlphaNum, isDigit)
import Data.Int (Int32)
import Data.List (nub, sortOn)
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Text.Read (readMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Products.Autopilot.Mobile.Github (
    DispatchRunDetails (..),
    cancelRun,
    Job (..),
    WorkflowDispatchReq (..),
    WorkflowRun (..),
    dispatchWorkflow,
    findRunWithJob,
    fetchJobLog,
    listJobs,
    listTags,
    listTagsWithShas,
    getWorkflowRun,
    listWorkflowRuns,
    ownDispatchCandidates,
 )
import Products.Autopilot.Mobile.Github.Auth (BotIdentity (..), GhAppCreds (..), getBotIdentity, getInstallationToken, loadGhCreds)
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRow,
    markTagLogScanned,
    dispatchCeilingFor,
    externalRunIdsClaimedElsewhere,
    findSiblingsByDispatchId,
    gitOwner,
    gitRepo,
    incrementResolveAttempts,
    logEvent,
    markReleaseRevertedBy,
    parseMobileTargetState,
    retireOlderHeldInternal,
    setExternalRunIdForDispatch,
    setPhase,
    setReleaseVersionCode,
 )
import Products.Autopilot.Queries.ReleaseTracker (claimDispatchReceipt)
import Products.Autopilot.Mobile.Heal (
    JobFailureShape (..),
    RunIdentity (..),
    StoreVerifyResult (..),
    classifyFailedJob,
    extractFailureExcerpt,
    failedStepOf,
    fetchRunIdentity,
    verifyStoreArtifact,
 )
import Products.Autopilot.Mobile.StoreSync (releaseOrderBehind)
import Products.Autopilot.Mobile.Lifecycle.BuildKind (claimsStoreIdentity)
import Products.Autopilot.Mobile.Lifecycle.Phase (ReleasePhase (..))
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    isDebugBuildType,
    isMBTerminal,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning (
    VersionResolution (..),
    resolveNextVersion,
 )
import Products.Autopilot.Mobile.Versioning.Apple (
    AscReviewState (..),
    getAscReviewState,
    loadAscCredsFor,
    renderAscErr,
 )
import Products.Autopilot.Notifications (sendGroupChangelogSlackIfSettled)
import Products.Autopilot.RuntimeConfig (
    getMobileTagConfirmTimeoutMinutes,
    getReviewPollIntervalSeconds,
    getReviewPollTimeoutDays,
    isStagedRolloutEnabled,
 )
import Products.Autopilot.Types.Release (
    ReleaseStatus (..),
    ReleaseTracker (..),
    isTerminalStatus,
 )
import Products.Autopilot.Types.Target (TargetState (..))
import Products.Autopilot.Workflow.Helpers (persistWorkflowState)
import Products.Autopilot.Workflow.Types (ReleaseState (..), StateFlow)

-- ─── Spec ──────────────────────────────────────────────────────────

{- | The seven-stage mobile build workflow.

Stages execute in order; the engine handles per-stage skip-guard, lock
bracket, and persist on success.

@wsRollback@ intentionally does no work: there's nothing to revert on
the Play Store side once a build has been submitted, and unfinished
GHA runs the runner cancels separately on user-abort.
-}
mobileBuildSpec :: WorkflowSpec ReleaseState
mobileBuildSpec =
    WorkflowSpec
        { wsName = "MobileBuild"
        , wsStages =
            [ stageResolveVersion
            , stageGroupForDispatch
            , stageDispatchWorkflow
            , stageResolveRunId
            , stagePollMatrixJobs
            , stageConfirmTag
            , stagePollReview
            , stageFinalize
            ]
        , wsRollback = \_err -> pure ()
        , wsPersist = persistWorkflowState
        }

-- ─── Stage definitions ─────────────────────────────────────────────

stageResolveVersion
    , stageGroupForDispatch
    , stageDispatchWorkflow
    , stageResolveRunId
    , stagePollMatrixJobs
    , stageConfirmTag
    , stagePollReview
    , stageFinalize ::
        Stage ReleaseState

-- | Stage 1 — store lookup → version floor. An operator-typed version at or
-- above the floor is KEPT (source "operator"); below it, the resolved value
-- wins and the bump is audited (source "store_floor_bump").
stageResolveVersion =
    (mkStage "ResolveVersion" execResolveVersion)
        { stageGuard = mbStatusReached MBVersionResolved
        }

-- | Stage 2 — validate the dispatch group (dispatch_id present). Skipped once
-- the run id is known OR this row already dispatched (re-tick while stage 4
-- polls).
stageGroupForDispatch =
    (mkStage "GroupForDispatch" execGroupForDispatch)
        { stageGuard = \rs -> hasExternalRunId rs || mbStatusReached MBDispatched rs
        }

-- | Stage 3 — POST @workflow_dispatch@ (leader only), with a durable
-- pre-POST receipt so a lost outcome is adopted, never re-dispatched.
stageDispatchWorkflow =
    (mkStage "DispatchWorkflow" execDispatchWorkflow)
        { stageGuard = mbStatusReached MBDispatched
        }

{- | Stage 4 — poll @\/runs@ until we can match our freshly-created run
(bot actor + run-id watermark + unclaimed + matrix-job verification), then
write @external_run_id@ on every sibling in the dispatch group.
-}
stageResolveRunId =
    (mkStage "ResolveRunId" execResolveRunId)
        { stageGuard = hasExternalRunId
        }

{- | Stage 5 — poll @\/runs/:id\/jobs@; track this row's matrix job.
Skip once the build is submitted (MBSubmittedToStore) — its job is done by then.
Guarding on terminal alone would re-poll forever for a staged-rollout-held release
(parked non-terminal at MBTagPushed), spamming MATRIX_JOB_UPDATED + GitHub calls.
-}
stagePollMatrixJobs =
    (mkStage "PollMatrixJobs" execPollMatrixJobs)
        { stageGuard = mbStatusReached MBSubmittedToStore
        }

-- | Stage 6 — list refs/tags matching the per-app prefix; backfill context.
stageConfirmTag =
    (mkStage "ConfirmTag" execConfirmTag)
        { stageGuard = hasTagPushed
        }

-- | Stage 6.5 — bounded, throttled store-review poll (iOS; runs only at MBInReview).
stagePollReview =
    (mkStage "PollReview" execPollReview)
        { stageGuard = notInReview
        }

-- | Stage 7 — map fine-grained @MobileBuildWFStatus@ to user-facing 'ReleaseStatus'.
stageFinalize =
    (mkStage "Finalize" execFinalize)
        { stageGuard = trackerStatusTerminal
        }

-- | Skip the review-poll stage unless the release is exactly in review.
notInReview :: ReleaseState -> Bool
notInReview rs = case mobileTarget rs of
    Just s -> mbWfStatus s /= MBInReview
    Nothing -> True

-- ─── Skip predicates (pure on persisted state) ─────────────────────

-- | True if the persisted @mbWfStatus@ has reached or passed @target@.
mbStatusReached :: MobileBuildWFStatus -> ReleaseState -> Bool
mbStatusReached target rs = case mobileTarget rs of
    Just s -> mbStatusOrder (mbWfStatus s) >= mbStatusOrder target
    Nothing -> False

-- | True if @mbWfStatus@ is one of the terminal mobile build statuses.
mbStatusTerminal :: ReleaseState -> Bool
mbStatusTerminal rs = case mobileTarget rs of
    Just s -> isMBTerminal (mbWfStatus s)
    Nothing -> False

-- | True if @mbContext.tagPushed@ has a value.
hasTagPushed :: ReleaseState -> Bool
hasTagPushed rs = case mobileTarget rs of
    Just s -> case mbcTagPushed (mbContext s) of
        Just t -> not (T.null t)
        Nothing -> False
    Nothing -> False

-- | True if @release_tracker.status@ is one of the terminal lifecycle statuses.
trackerStatusTerminal :: ReleaseState -> Bool
trackerStatusTerminal rs = isTerminalStatus (status (releaseTracker rs))

{- | True if the targetState has @mbExternalRunId@ set. The
@release_tracker.external_run_id@ column is not in the domain
'ReleaseTracker' projection, so we stage it through the targetState
(kept in sync by 'execResolveRunId').
-}
hasExternalRunId :: ReleaseState -> Bool
hasExternalRunId rs = case mobileTarget rs of
    Just s -> case mbExternalRunId s of
        Just t -> not (T.null t)
        Nothing -> False
    Nothing -> False

{- | Classify an error tag produced by "Versioning.resolveNextVersion" (or
its sub-resolvers in @Versioning.Play@ / @Versioning.Apple@) as either a
configuration error (terminal — caller should @abort@) or a transient
runtime error (caller should @retry@).

Configuration errors mean the operator needs to do something out-of-band
(populate @server_config@, fix @app_catalog.package_name@, etc.). Looping
on @retry@ for these wastes runner ticks and hides the problem from the
release row's audit trail — by the time anyone notices, the row has
been "INPROGRESS" silently for hours.

Pattern-matched substrings cover both platforms:

* @"_not_configured"@ / @"creds_missing"@ — missing server_config rows.
* @"_app_not_found:"@ / @"_package_not_found:"@ — wrong / missing
  bundle id / package name in @app_catalog@.
* @"unsupported platform: "@ — unknown @platform@ column value.
* @"asc_app_id"@ / @"package_name"@ — earlier-stage guards that hit
  these specific tags also belong here.

Anything else (HTTP 5xx, 401 from transient creds rotation, etc.) is
treated as transient and retried.
-}
isConfigError :: T.Text -> Bool
isConfigError tag =
    any
        (`T.isInfixOf` tag)
        [ "_not_configured"
        , "creds_missing"
        , "_app_not_found"
        , "_package_not_found"
        , "unsupported platform"
        , "no package_name"
        , "asc_app_id"
        ]

{- | Total ordering on @MobileBuildWFStatus@ for skip-guard checks.

The constructors are not Ord-derivable because @MBFailed Text@ carries
a payload. We pin the chain index by hand and treat aborted/failed as
"past the end" (so any stage with a target before @MBCompleted@ skips
when the workflow has been failed terminally).
-}
mbStatusOrder :: MobileBuildWFStatus -> Int
mbStatusOrder = \case
    MBInit -> 0
    MBVersionResolved -> 1
    MBDispatched -> 2
    MBRunIdResolved -> 3
    MBBuilding -> 4
    MBSubmittedToStore -> 5
    MBTagPushed -> 6
    MBSubmittingForReview -> 7
    MBInReview -> 8
    MBReviewApproved -> 9
    MBRollingOut -> 10
    MBCompleted -> 11
    MBReviewRejected -> 12
    MBAborting -> 13
    MBAborted -> 14
    MBFailed _ -> 99

-- ─── Stage executors ───────────────────────────────────────────────

{- | Stage 1: Resolve next version via the platform-appropriate backend.

Delegates to "Mobile.Versioning"'s dispatcher (`resolveNextVersion`),
which picks Play Console for @platform="android"@ or App Store Connect
for @platform="ios"@. Returns a 'VersionResolution' sum:

* 'AndroidVersion' — carries both @vName@ and @vCode@; we write both
  to the tracker (existing behaviour).
* 'IosVersion' — carries only @vNumber@; @mbcVersionCode@ stays
  'Nothing'. The iOS workflow's @fastlane fetch_build_number@ computes
  the build number, and we recover it later from the pushed tag's
  @+NNN@ suffix in the @ConfirmTag@ stage.

Failure modes:

* Missing credentials or @package_name@ / bundle id — abort with a
  domain error (not retryable; user must fix server_config / app_catalog).
* Backend API hiccups — surface as retriable so the next tick retries.
-}
execResolveVersion :: forall m. (StageM ReleaseState m) => m StageOutcome
execResolveVersion = mobileStage "ResolveVersion" $ do
    rs <- gets id
    let rt = releaseTracker rs
        isDebug = case mobileTarget rs of
            Just target -> isDebugBuildType (mbcBuildType (mbContext target))
            Nothing -> False
        isFirebase = case mobileTarget rs of
            Just target -> mbcDestination (mbContext target) == Just "Firebase"
            Nothing -> False
    if isDebug
        then do
            logInfoIO $
                "[ResolveVersion] "
                    <> releaseId rt
                    <> " debug destination, skipping store version resolution"
            modify $ \s ->
                let ts' =
                        applyMobileTarget s $ \mt ->
                            mt{mbWfStatus = bumpStatus (mbWfStatus mt) MBVersionResolved}
                 in s{targetState = Just (MobileBuildState ts')}
            logEvent (releaseId rt) "VERSION_RESOLVED" $
                object ["source" .= ("debug_skip" :: T.Text)]
            pure StageSuccess
        else if isFirebase
        then do
            -- Firebase App Distribution builds never publish to Play, so a Play-resolved
            -- version just REPEATS (Firebase doesn't advance Play's code). The unique
            -- timestamp version (year.MMDD.HHMM) is stamped at CREATE (buildRow) so it's
            -- visible immediately; here we KEEP that value (don't regenerate, so the row's
            -- version never shifts under the operator) and only synthesize one as a
            -- fallback for older rows created before create-time stamping. version_code
            -- stays Nothing — the provider workflow computes its own.
            now <- liftIO getCurrentTime
            let existing = newVersion rt
                ver =
                    if T.null existing
                        then T.pack (formatTime defaultTimeLocale "%Y.%-m%d.%H%M" now)
                        else existing
            logInfoIO $
                "[ResolveVersion] " <> releaseId rt <> " Firebase build, version " <> ver
            modify $ \s ->
                let rt' = (releaseTracker s){newVersion = ver}
                    ts' =
                        applyMobileTarget s $ \mt ->
                            mt
                                { mbContext = (mbContext mt){mbcVersionCode = Nothing}
                                , mbWfStatus = bumpStatus (mbWfStatus mt) MBVersionResolved
                                }
                 in s{releaseTracker = rt', targetState = Just (MobileBuildState ts')}
            logEvent (releaseId rt) "VERSION_RESOLVED" $
                object ["version_name" .= ver, "source" .= ("firebase_auto" :: T.Text)]
            pure StageSuccess
        else do
            ac <- appCatalogForRow rt
            pkgName <- case acPackageName ac of
                Just p | not (T.null p) -> pure p
                _ ->
                    abort $
                        "AppCatalog row for "
                            <> appGroup rt
                            <> " has no package_name; cannot resolve next version"
            res <- resolveNextVersion (acStoreAccount ac) (acPlatform ac) pkgName
            case res of
                Left err
                    | isConfigError err -> abort err
                    | otherwise -> retry err
                Right (AndroidVersion nextName nextCode) -> do
                    -- The store result is a FLOOR, not a replacement. Play enforces
                    -- only CODE monotonicity, so a typed version NAME is always kept;
                    -- a typed code at/above the floor is kept, below it we bump.
                    let typedName = T.strip (newVersion rt)
                        typedCode = mobileTarget rs >>= mbcVersionCode . mbContext
                        finalName = if T.null typedName then nextName else typedName
                        (finalCode, source) = case typedCode of
                            Just c
                                | c > nextCode -> (c, "operator" :: T.Text)
                                | c == nextCode -> (c, "play_console")
                                | otherwise -> (nextCode, "store_floor_bump")
                            Nothing -> (nextCode, "play_console")
                    logInfoIO $
                        "[ResolveVersion] "
                            <> releaseId rt
                            <> " Android version "
                            <> finalName
                            <> " (code "
                            <> T.pack (show finalCode)
                            <> ", source "
                            <> source
                            <> ")"
                    modify $ \s ->
                        let rt' = (releaseTracker s){newVersion = finalName}
                            ts' =
                                applyMobileTarget s $ \mt ->
                                    mt
                                        { mbContext = (mbContext mt){mbcVersionCode = Just finalCode}
                                        , mbWfStatus = bumpStatus (mbWfStatus mt) MBVersionResolved
                                        }
                         in s{releaseTracker = rt', targetState = Just (MobileBuildState ts')}
                    logEvent (releaseId rt) "VERSION_RESOLVED" $
                        object $
                            [ "version_name" .= finalName
                            , "version_code" .= finalCode
                            , "source" .= source
                            ]
                                <> ["typed_code" .= c | source == "store_floor_bump", Just c <- [typedCode]]
                                <> ["floor_code" .= nextCode | source /= "play_console"]
                    pure StageSuccess
                Right (IosVersion nextNumber) -> do
                    -- ASC enforces version_number > live, so the resolved value is
                    -- the floor: a typed number at/above it is kept, below it bumps.
                    let typed = T.strip (newVersion rt)
                        (finalVer, source)
                            | T.null typed = (nextNumber, "app_store_connect" :: T.Text)
                            | versionLt typed nextNumber = (nextNumber, "store_floor_bump")
                            | typed == nextNumber = (nextNumber, "app_store_connect")
                            | otherwise = (typed, "operator")
                    logInfoIO $
                        "[ResolveVersion] "
                            <> releaseId rt
                            <> " iOS version_number "
                            <> finalVer
                            <> " (source "
                            <> source
                            <> "; build number computed by workflow)"
                    modify $ \s ->
                        let rt' = (releaseTracker s){newVersion = finalVer}
                            ts' =
                                applyMobileTarget s $ \mt ->
                                    mt
                                        { mbWfStatus = bumpStatus (mbWfStatus mt) MBVersionResolved
                                        }
                         in s{releaseTracker = rt', targetState = Just (MobileBuildState ts')}
                    logEvent (releaseId rt) "VERSION_RESOLVED" $
                        object $
                            [ "version_number" .= finalVer
                            , "source" .= source
                            ]
                                <> ["typed_version" .= typed | source == "store_floor_bump"]
                                <> ["floor_version" .= nextNumber | source /= "app_store_connect"]
                    pure StageSuccess

-- | Dotted numeric version ordering ("3.3.107" < "3.3.108"); non-numeric parts
-- compare as 0. Local mirror of StoreSync.versionOlderThan (same duplication
-- idiom as Play/Apple bumpPatch).
versionLt :: T.Text -> T.Text -> Bool
versionLt a b = comps a < comps b
  where
    comps = map (\p -> fromMaybe 0 (readMaybe (T.unpack p)) :: Int) . T.splitOn "."

{- | Stage 2: Validate the dispatch group.

* Looks up the row's @dispatch_id@. If NULL, abort: the create endpoint
  should always populate it before the workflow starts.

This stage used to take a Postgres SESSION advisory lock keyed on the
dispatch id. That lock was removed: session locks are NOT released when a
pooled connection is returned to the pool, so the "mutex" lingered on an
idle connection and stalled retries for minutes (until the pool happened to
hand the same connection back), while the actual POST ran on a different
connection anyway. Dispatch uniqueness is owned by the leader gate in
stage 3 plus the atomic pre-POST receipt claim ('claimDispatchReceipt' — a
TRANSACTION-scoped advisory lock that cannot leak into the pool) and
adopt-before-dispatch recovery.
-}
execGroupForDispatch :: forall m. (StageM ReleaseState m) => m StageOutcome
execGroupForDispatch = do
    -- Skip if external_run_id is already set (resume after a crash mid-dispatch).
    rs <- gets id
    if hasExternalRunId rs
        then pure StageSuccess
        else mobileStage "GroupForDispatch" $ do
            let rt = releaseTracker rs
            mDid <- findDispatchIdForRelease (releaseId rt)
            case mDid of
                Just d | not (T.null d) -> pure StageSuccess
                _ ->
                    abort $
                        "release "
                            <> releaseId rt
                            <> " has no dispatch_id; mobile create endpoint must set it"

{- | Stage 3: POST @workflow_dispatch@ — exactly ONE GitHub run per dispatch
group, via the leader gate ('electDispatchLeader'): the first non-terminal
sibling dispatches, everyone else waits and then adopts the leader's run id
('adoptGroupRun').

Inputs are built from the LIVING (non-terminal) siblings joined to the
AppCatalog so the GHA workflow knows which apps to build:

* @selected_apps@ — comma-separated CSV of @AppCatalog.name@ values; the
  workflow expands it into one matrix job per app.
* version\/changelog inputs vary by surface\/platform (see
  'dispatchFreshRun'); a batched consumer run sends NO version inputs —
  each matrix job auto-versions and ConfirmTag adopts the code from the
  pushed tag ('mbBatchDispatch').
* We deliberately do NOT send the workflow's @payload@ input — a non-empty
  payload makes its Set-Matrix step bypass @selected_apps@. GitHub's
  @\/runs@ endpoint doesn't echo inputs anyway, so stage 4 matches the run
  by actor + created-at window (+ job-name verification when ambiguous).

Failure modes:

* Missing GH credentials → abort.
* Sibling list empty → abort (worker bug — at least the row itself
  should be in its own dispatch group).
* HTTP error → retriable.
-}
execDispatchWorkflow :: forall m. (StageM ReleaseState m) => m StageOutcome
execDispatchWorkflow = mobileStage "DispatchWorkflow" $ do
    rs <- gets id
    let rt = releaseTracker rs
    ac <- appCatalogForRow rt
    -- 'loadGhCreds' throws 'InternalError' when any of the three
    -- @github_app_*@ rows are blank (see Mobile/Github/Auth.hs:147-149).
    -- That exception would otherwise bubble up to forkFlow's safety net
    -- and get silently logged — leaving the row stuck at @MBVersionResolved@
    -- forever. Catch it here and abort with a stable error tag so the row
    -- transitions to MBFailed and the UI surfaces the cause clearly.
    eCreds <- MC.try @_ @SomeException loadGhCreds
    creds <- case eCreds of
        Right c -> pure c
        Left _ -> abort "github_app_credentials_not_configured"
    mDid <- findDispatchIdForRelease (releaseId rt)
    dispatchId <- case mDid of
        Just d | not (T.null d) -> pure d
        _ -> abort "dispatch_id missing at DispatchWorkflow stage"
    siblings <- findSiblingsByDispatchId dispatchId
    when (null siblings) $
        abort $
            "no sibling rows for dispatch_id=" <> dispatchId
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at DispatchWorkflow stage"
    -- ── Leader gate: ONE GH run per dispatch group ──
    -- The first living sibling by id is the leader — the only row that
    -- dispatches. Followers adopt the run id the leader's ResolveRunId stamps
    -- on every sibling ROW (a column read; their own state predates the stamp).
    let living = [p | p@(r, _) <- siblings, not (isTerminalStatus (status r))]
        leaderId = electDispatchLeader (releaseId rt) [(releaseId r, isTerminalStatus (status r)) | (r, _) <- siblings]
    mStamp <- externalRunIdForRelease (releaseId rt)
    -- Sibling contexts serve two reads: the dispatcher's persisted
    -- mbBatchDispatch (adopters inherit it so ConfirmTag knows whether version
    -- inputs were sent) and the prior-dispatch anchor for the orphan-adopt path.
    contexts <- findDispatchGroupContexts dispatchId
    let siblingStates = [st | (_, mCtx) <- contexts, Just st <- [parseMobileTargetState mCtx]]
        inheritedBatch = listToMaybe [b | st <- siblingStates, Just b <- [mbBatchDispatch st]]
        inheritedVersions = listToMaybe [v | st <- siblingStates, Just v <- [mbVersionsPassed st]]
    -- Abort-propagation gate: while a sibling is ABORTING **and the group has a
    -- run in flight** (a bound run id, or a receipt proving a POST was made),
    -- the group is being torn down — a not-yet-flipped row must neither adopt
    -- nor dispatch. That teardown window is where a dead group hijacked a
    -- same-app successor's run (19 Aug); 'claimDispatchReceipt' re-checks
    -- ABORTING in-lock, this parks before the GitHub calls.
    --
    -- The in-flight condition matters: an ABORTING row that never dispatched
    -- has no cancel target, so 'resolveForCancel' returns Nothing on every
    -- sweep and it only settles at the 30-min deadline. Parking on that would
    -- freeze the group's healthy siblings for half an hour over a row that
    -- provably never built anything. Settled aborts never park either —
    -- partial aborts leave the living siblings to continue.
    let groupAborting = any (\(r, _) -> status r == ABORTING) siblings
        groupHasRunInFlight =
            maybe False (not . T.null) mStamp
                || any (isJust . mbBuildStartedAt) siblingStates
    when (groupAborting && groupHasRunInFlight) $
        retry "dispatch group abort in progress (run teardown) — parking (no adopt, no dispatch)"
    case mStamp of
        Just runId
            | not (T.null runId) ->
                -- The group's run already exists — adopt, never dispatch a second.
                adoptGroupRun rt leaderId runId inheritedBatch inheritedVersions
        _
            | releaseId rt /= leaderId -> do
                logInfoIO $
                    "[DispatchWorkflow] "
                        <> releaseId rt
                        <> " follower; waiting for leader "
                        <> leaderId
                        <> " to dispatch (dispatch_id="
                        <> dispatchId
                        <> ")"
                pure StageWaiting
            | otherwise -> do
                -- Leader. A dispatch receipt (mbBuildStartedAt + run-id watermark,
                -- persisted BEFORE the POST) on any sibling context proves a dispatch
                -- was ATTEMPTED — by a dead ex-leader, or by ourselves on a tick whose
                -- POST outcome was lost (timeout / crash / restart). Adopt the run that
                -- receipt points at; dispatch fresh only when the receipt is old enough
                -- that a created run would provably be visible by now. This read is a
                -- RACY first look (two replicas can both see the same picture within
                -- the same tick) — the authoritative re-check happens inside
                -- 'claimDispatchReceipt', which re-reads the group's receipts under a
                -- pg advisory xact lock before any POST is allowed.
                --
                -- Receipts are picked as a PAIR (anchor + its own watermark) from the
                -- LATEST attempt: after leader succession a dead ex-leader's stale
                -- receipt also sits in the group, and clocking the grace from it (or
                -- mixing its anchor with another row's watermark) would expire the
                -- grace instantly and re-dispatch during ordinary GH list lag.
                let receipts =
                        [ (t, mbDispatchWatermark st)
                        | st <- siblingStates
                        , Just t <- [mbBuildStartedAt st]
                        ]
                case listToMaybe (sortOn (Down . fst) receipts) of
                    Nothing -> dispatchFreshRun rt ac creds target living dispatchId Nothing
                    Just (anchor, mWatermark) -> do
                        res <- listWorkflowRuns creds (gitOwner ac) (gitRepo ac) (acWorkflowPath ac)
                        runs <- case res of
                            Right xs -> pure xs
                            Left e -> retry ("listWorkflowRuns failed while checking for an orphaned dispatch: " <> e)
                        mBot <- getBotIdentity creds
                        mCeiling <- dispatchCeilingFor ac anchor
                        cands <-
                            unclaimedCandidates
                                dispatchId
                                (ownDispatchCandidates (biUserId <$> mBot) mWatermark anchor mCeiling runs)
                        let stampAndAdopt r = do
                                let runIdT = T.pack (show (wrId r))
                                -- First-writer-wins bind: another pod may have
                                -- bound a different run while we verified this
                                -- one. Adopt whatever the group ended up on —
                                -- never fight over the binding.
                                boundId <- setExternalRunIdForDispatch dispatchId runIdT (wrHeadSha r)
                                if boundId /= runIdT
                                    then do
                                        logInfoIO $
                                            "[DispatchWorkflow] "
                                                <> releaseId rt
                                                <> " orphan-adopt lost the bind to run "
                                                <> boundId
                                                <> " — adopting it instead of "
                                                <> runIdT
                                        adoptGroupRun rt leaderId boundId inheritedBatch inheritedVersions
                                    else do
                                        logEvent (releaseId rt) "GH_RUN_RESOLVED" $
                                            object
                                                [ "run_id" .= runIdT
                                                , "head_sha" .= wrHeadSha r
                                                , "html_url" .= wrHtmlUrl r
                                                , "source" .= ("orphan_adopt" :: Text)
                                                ]
                                        adoptGroupRun rt leaderId runIdT inheritedBatch inheritedVersions
                        case cands of
                            [] -> do
                                now <- liftIO getCurrentTime
                                if diffUTCTime now anchor < dispatchAdoptGrace
                                    then do
                                        logInfoIO $
                                            "[DispatchWorkflow] "
                                                <> releaseId rt
                                                <> " dispatch receipt but no adoptable run yet — waiting out the grace period (GH list lag)"
                                        pure StageWaiting
                                    else do
                                        logInfoIO $
                                            "[DispatchWorkflow] "
                                                <> releaseId rt
                                                <> " dispatch receipt but no run appeared within grace — dispatching fresh"
                                        dispatchFreshRun rt ac creds target living dispatchId (Just anchor)
                            candRuns -> do
                                -- Adopt ONLY a run proven to contain one of the GROUP's
                                -- matrix jobs (oldest first — the run created right after
                                -- our receipt is ours). Even a SINGLE candidate needs
                                -- proof: our POST may never have created anything, and the
                                -- one run above the watermark can be another group's
                                -- not-yet-stamped dispatch. Matrix jobs only list once the
                                -- run's setup job expands them (minutes), so Nothing = not
                                -- verifiable YET → wait; never dispatch fresh while
                                -- unclaimed candidates exist (a foreign one gets claimed by
                                -- its owner soon and drops out).
                                let groupJobs = nub (mbcMatrixJobName (mbContext target) : [mbcMatrixJobName (mbContext st) | st <- siblingStates])
                                mV <- findRunWithJob creds (gitOwner ac) (gitRepo ac) groupJobs candRuns
                                now <- liftIO getCurrentTime
                                let anyCandidateLive = any (\r -> wrStatus r /= "completed") candRuns
                                case mV of
                                    Just r -> stampAndAdopt r
                                    -- A LONE settled dead-conclusion candidate is OUR run,
                                    -- killed before its matrix expanded (manual cancel on
                                    -- GitHub, setup failure): a jobless dead run can never
                                    -- verify, and under the receipt + watermark + created-at
                                    -- + unclaimed filters nothing else lands alone in that
                                    -- window. Fail honestly — NEVER quietly dispatch a
                                    -- replacement the operator didn't ask for.
                                    Nothing
                                        | [r] <- candRuns
                                        , wrStatus r == "completed"
                                        , Just concl <- wrConclusion r
                                        , concl `elem` ["cancelled", "failure", "startup_failure", "timed_out"] -> do
                                            logEvent (releaseId rt) "STATUS_UPDATED" $
                                                object
                                                    [ "run_id" .= T.pack (show (wrId r))
                                                    , "html_url" .= wrHtmlUrl r
                                                    , "reason" .= ("the GitHub run ended '" <> concl <> "' before its matrix expanded — nothing to bind or build" :: Text)
                                                    ]
                                            abort ("GitHub run ended '" <> concl <> "' before the matrix expanded")
                                    -- Every candidate is COMPLETED and none carries a group
                                    -- job — a settled run's job list is final, so these are
                                    -- provably not ours (an abandoned foreign dispatch that
                                    -- was never claimed). Nothing to adopt: fall back to the
                                    -- grace-gated fresh dispatch instead of parking forever.
                                    Nothing
                                        | not anyCandidateLive && diffUTCTime now anchor >= dispatchAdoptGrace -> do
                                            logInfoIO $
                                                "[DispatchWorkflow] "
                                                    <> releaseId rt
                                                    <> " candidates all settled without a group job (foreign) — dispatching fresh"
                                            dispatchFreshRun rt ac creds target living dispatchId (Just anchor)
                                    Nothing -> do
                                        forM_ (listToMaybe candRuns) (noteCandidateRun dispatchId target)
                                        logInfoIO $
                                            "[DispatchWorkflow] "
                                                <> releaseId rt
                                                <> " orphan-adopt: "
                                                <> T.pack (show (length candRuns))
                                                <> " candidate run(s), none verified yet — waiting"
                                        pure StageWaiting

{- | The dispatch-group leader: the first NON-TERMINAL sibling by release id
(siblings arrive id-ascending from 'findSiblingsByDispatchId', so leadership
slides to the next living row when the current leader aborts/fails). Falls
back to @self@ when every sibling reads terminal — the executing row is itself
a sibling, so that only happens on a mid-tick external flip.
-}
electDispatchLeader :: Text -> [(Text, Bool)] -> Text
electDispatchLeader self sibs =
    fromMaybe self (listToMaybe [i | (i, isTerm) <- sibs, not isTerm])

{- | How long after a dispatch receipt we keep looking for the run before
concluding the POST never reached GitHub and dispatching fresh. GitHub
creates the run synchronously on accept; only its LIST endpoint lags, and
that lag is seconds — two minutes is far beyond it, while the cost of
waiting is trivial next to a duplicate run (tag collision, zombie build).
-}
dispatchAdoptGrace :: NominalDiffTime
dispatchAdoptGrace = 120

-- | Drop candidates whose run id is already claimed (@external_run_id@) by a
-- row OUTSIDE this dispatch group — one group must never bind another
-- group's run.
unclaimedCandidates :: Text -> [WorkflowRun] -> StateFlow [WorkflowRun]
unclaimedCandidates dispatchId cands = do
    claimed <- externalRunIdsClaimedElsewhere dispatchId (map (T.pack . show . wrId) cands)
    pure [r | r <- cands, T.pack (show (wrId r)) `notElem` claimed]

{- | Matrix job names of every row in this release's dispatch group (terminal
rows included — a run dispatched before a sibling died still carries its job).
Run verification matches on ANY of these: one hit proves the run belongs to
the group, while the executing row's own job alone is NOT reliable evidence —
CI's matrix step silently drops apps missing from the repo's config, so the
leader's own job may never exist in a perfectly good group run. Always
contains at least the row's own job name.
-}
dispatchGroupJobNames :: (MonadFlow m) => Text -> MobileBuildTargetState -> m [Text]
dispatchGroupJobNames rid target = do
    mDid <- findDispatchIdForRelease rid
    names <- case mDid of
        Just did | not (T.null did) -> do
            contexts <- findDispatchGroupContexts did
            pure
                [ mbcMatrixJobName (mbContext st)
                | (_, mCtx) <- contexts
                , Just st <- [parseMobileTargetState mCtx]
                ]
        _ -> pure []
    pure (nub (mbcMatrixJobName (mbContext target) : names))

{- | Adopt the group's already-dispatched GH run on THIS row: record the run id
and dispatch progress without touching GitHub. Backfills @mbBuildStartedAt@
(the ConfirmTag wall-clock anchor) for adopters that never dispatched, and
inherits the dispatcher's batch flag so ConfirmTag matches the tag the same way.
-}
adoptGroupRun :: ReleaseTracker -> Text -> Text -> Maybe Bool -> Maybe Bool -> StateFlow StageOutcome
adoptGroupRun rt leaderId runId mBatch mVersions = do
    now <- liftIO getCurrentTime
    modify $ \s ->
        s
            { targetState =
                Just $
                    MobileBuildState
                        ( applyMobileTarget s $ \mt ->
                            mt
                                { mbExternalRunId = Just runId
                                , mbWfStatus = bumpStatus (mbWfStatus mt) MBDispatched
                                , mbBuildStartedAt = Just (fromMaybe now (mbBuildStartedAt mt))
                                , mbBatchDispatch = case mBatch of
                                    Just b -> Just b
                                    Nothing -> mbBatchDispatch mt
                                , mbVersionsPassed = case mVersions of
                                    Just v -> Just v
                                    Nothing -> mbVersionsPassed mt
                                }
                        )
            }
    logEvent (releaseId rt) "GH_RUN_ADOPTED" $
        object ["run_id" .= runId, "leader" .= leaderId]
    logInfoIO $
        "[DispatchWorkflow] " <> releaseId rt <> " adopted group run_id=" <> runId
    pure StageSuccess

{- | The actual @workflow_dispatch@ POST — reached only through the leader gate
in 'execDispatchWorkflow'. @living@ is the group's non-terminal siblings:
selected_apps is built from them, so a leader takeover never rebuilds an app
whose row was already aborted.
-}
dispatchFreshRun ::
    ReleaseTracker ->
    AppCatalog ->
    GhAppCreds ->
    MobileBuildTargetState ->
    [(ReleaseTracker, AppCatalog)] ->
    -- | dispatch_id — key of the cross-replica receipt claim
    Text ->
    -- | latest sibling receipt the caller's decision was based on
    -- (Nothing = decided off "no receipt at all")
    Maybe UTCTime ->
    StateFlow StageOutcome
dispatchFreshRun rt ac creds target living dispatchId mObservedAnchor = do
    let
        -- selected_apps is the comma-separated list of catalyst app NAMES
        -- (e.g. "NammaYatri,KeralaSavaari"), not surfaces. The workflow
        -- passes this to `catalyst -extract <platform>_prod --apps` which
        -- matches on the top-level keys of catalyst.yaml. Same shape on
        -- Android and iOS workflows.
        selectedApps =
            T.intercalate "," $
                map (acName . snd) (sortOn (acName . snd) living)
        versionName = newVersion rt
        -- Only meaningful for Android rows. iOS rows have versionCode = 0
        -- here because the iOS workflow's `fastlane fetch_build_number`
        -- computes the build number internally; we never send it.
        versionCode = case mbcVersionCode (mbContext target) of
            Just c -> c
            Nothing -> 0
    -- NOTE: We deliberately do NOT pass the workflow's `payload` input. The
    -- workflow's Set-Matrix step treats any non-empty payload as a full matrix
    -- envelope (`echo "$PAYLOAD" | jq -c '.matrices'`) and bypasses the
    -- selected_apps + catalyst path. SCC matches runs by actor + run-id
    -- watermark in ResolveRunId, not by an in-payload nonce.
    --
    -- Pre-dispatch watermark: the highest run id that already exists for this
    -- workflow file. Our run will be the first bot-authored run ABOVE it.
    -- A failed listing degrades to Nothing (created-at window fallback) —
    -- never blocks the dispatch.
    wmRes <- listWorkflowRuns creds (gitOwner ac) (gitRepo ac) (acWorkflowPath ac)
    mWatermark <- case wmRes of
        Right runs -> pure (Just (maximum (0 : map wrId runs)))
        Left e -> do
            logInfoIO $
                "[DispatchWorkflow] "
                    <> releaseId rt
                    <> " watermark listing failed (window fallback will apply): "
                    <> e
            pure Nothing
    dispatchedAt <- liftIO getCurrentTime
    -- ── Per-app `versions` input (consumer prod only) ───────────────
    -- {appName: {version_name, version_code}} ({version_number} on iOS); the
    -- workflow's Set-Matrix merges it into each app's matrix entry, so every
    -- app in a batched run builds ITS OWN resolved identity instead of
    -- auto-detecting from the store. Names from each sibling's tracker row,
    -- codes from its persisted build context. Provider/debug workflows don't
    -- declare the input, and GitHub 422s a POST carrying an undeclared input
    -- (validated against the workflow AT THE DISPATCHED REF — a branch cut
    -- before the input existed fails dispatch until rebased).
    versionsMap <-
        if acSurface ac == "driver" || isDebugBuildType (mbcBuildType (mbContext target))
            then pure KM.empty
            else do
                ctxs <- findDispatchGroupContexts dispatchId
                let codePairs =
                        [ (cid, mbcVersionCode (mbContext st))
                        | (cid, mCtx) <- ctxs
                        , Just st <- [parseMobileTargetState mCtx]
                        ]
                    entry :: (ReleaseTracker, AppCatalog) -> Maybe (KM.Key, Aeson.Value)
                    entry (r, a)
                        | T.null (newVersion r) = Nothing -- unresolved (API edge): auto-detect
                        | acPlatform a == "ios" =
                            Just (AK.fromText (acName a), object ["version_number" .= newVersion r])
                        | otherwise =
                            let codeField =
                                    [ "version_code" .= T.pack (show c)
                                    | Just (Just c) <- [lookup (releaseId r) codePairs]
                                    ]
                             in Just (AK.fromText (acName a), object (("version_name" .= newVersion r) : codeField))
                pure (KM.fromList (mapMaybe entry living))
    -- Build the workflow_dispatch inputs map. Two different shapes — the
    -- Android workflow declares `version_name` + `version_code` (two fields),
    -- the iOS workflow declares `version_number` (one field, semver string;
    -- the workflow computes the build number itself). Inputs not declared
    -- by a workflow are silently ignored by GitHub, but we keep the maps
    -- tight so the dispatch payload is honest about what each platform
    -- actually consumes.
    let isDebug = isDebugBuildType (mbcBuildType (mbContext target))
        changeLogVal = mbcChangeLog (mbContext target)
        isProvider = acSurface ac == "driver"
        versionsSent = not (KM.null versionsMap)
        versionsInput =
            [ ("versions", Aeson.String (TE.decodeUtf8 (LBS.toStrict (Aeson.encode (Aeson.Object versionsMap)))))
            | versionsSent
            ]
        -- Batched (multi-app) consumer run: a run-level version input would
        -- force the LEADER's version onto every app, so send NONE at run level
        -- — each app's identity travels in the `versions` map instead (its
        -- matrix entry wins over run-level inputs in the workflow). Provider
        -- cohorts batch only when versions agree (grouped at dispatch), so the
        -- provider branch below still sends the cohort's shared version_name;
        -- for them isBatch only switches ConfirmTag to tag-truth code adoption.
        isBatch = length living > 1
        -- Debug builds skip store version resolution, so newVersion is blank — but
        -- the provider workflow REQUIRES a non-empty version_name. Use a date-based
        -- (CalVer) version, e.g. "2026.6.8", for provider DEBUG builds; provider
        -- prod uses the resolved version.
        providerVersionName =
            if isDebug
                then T.pack (formatTime defaultTimeLocale "%Y.%-m.%-d" dispatchedAt)
                else versionName
        inputs
            -- Provider (driver) workflows — debug AND prod, Android AND iOS — all
            -- declare the SAME base required inputs: selected_apps, version_name,
            -- release_notes. This is a different schema from the customer
            -- workflows (which use change_log / version_code), so a customer-shaped
            -- payload omits the provider's required `version_name` → GitHub 422
            -- and the release sticks at DISPATCH_REQUESTED. Branch on surface first.
            --
            -- provider-prod-apk-gen.yaml additionally declares a required
            -- `destination` (choice GooglePlay|Firebase). Its implicit default is
            -- Firebase App Distribution — NOT a store release — so we send
            -- destination=GooglePlay explicitly for provider PROD Android to publish
            -- to the Play Store. Debug builds and the iOS prod workflow don't
            -- declare this input.
            | isProvider =
                let providerBase =
                        [ ("selected_apps", Aeson.String selectedApps)
                        , ("version_name", Aeson.String providerVersionName)
                        , ("release_notes", Aeson.String changeLogVal)
                        ]
                    providerProdAndroid = not isDebug && acPlatform ac == "android"
                    -- Operator's choice from the create form; falls back to
                    -- GooglePlay when unset (older rows / API callers).
                    destinationVal = fromMaybe "GooglePlay" (mbcDestination (mbContext target))
                 in KM.fromList $
                        if providerProdAndroid
                            then providerBase <> [("destination", Aeson.String destinationVal)]
                            else providerBase
            | isDebug =
                KM.fromList
                    [ ("selected_apps", Aeson.String selectedApps)
                    , ("change_log", Aeson.String changeLogVal)
                    ]
            | otherwise = case acPlatform ac of
                "ios" ->
                    KM.fromList $
                        [ ("selected_apps", Aeson.String selectedApps)
                        , ("change_log", Aeson.String changeLogVal)
                        ]
                            <> [("version_number", Aeson.String versionName) | not isBatch]
                            <> versionsInput
                _ ->
                    KM.fromList $
                        [ ("selected_apps", Aeson.String selectedApps)
                        , ("change_log", Aeson.String changeLogVal)
                        ]
                            <> ( if isBatch
                                    then []
                                    else
                                        [ ("version_name", Aeson.String versionName)
                                        , ("version_code", Aeson.String (T.pack (show versionCode)))
                                        ]
                               )
                            <> versionsInput
        ref = fromMaybe "main" (sourceRef rt)
        body =
            WorkflowDispatchReq
                { wdrRef = ref
                , wdrInputs = inputs
                }
        wfPath = acWorkflowPath ac
    -- ── Durable receipt BEFORE the POST ─────────────────────────────
    -- The POST's outcome can be lost (timeout after GitHub accepted, 5xx
    -- after processing, crash/restart mid-call). Write the attempt down
    -- first: any later tick — this row's or a successor leader's — goes
    -- adopt-first off this receipt instead of blindly dispatching again.
    -- Written straight to the DB (not just tick state) because the engine
    -- only persists on StageSuccess — exactly what a lost tick never reaches.
    modify $ \s ->
        s
            { targetState =
                Just $
                    MobileBuildState
                        ( applyMobileTarget s $ \mt ->
                            mt
                                { mbBuildStartedAt = Just dispatchedAt
                                , mbDispatchWatermark = mWatermark
                                , -- Part of the receipt: decided pre-POST, and the
                                  -- adopt path inherits it from sibling contexts —
                                  -- ConfirmTag needs it even when the POST outcome
                                  -- was lost and the run was adopted later.
                                  mbBatchDispatch = Just isBatch
                                , mbVersionsPassed = Just versionsSent
                                }
                        )
            }
    sReceipt <- gets id
    receiptLanded <- claimDispatchReceipt dispatchId mObservedAnchor (releaseTracker sReceipt) (targetState sReceipt)
    -- The claim is atomic across replicas (advisory-locked receipt CAS): it
    -- fails when a concurrent dispatcher on another pod just wrote a fresher
    -- receipt, when the group was already bound to a run (external_run_id),
    -- when ANY sibling is ABORTING (re-checked in-lock — the stage-entry gate
    -- is stale by several GitHub calls at this point), or when this row
    -- flipped to ABORTING/PAUSED mid-tick. Either way: no claim ⇒ no POST —
    -- otherwise a second GH run would exist with no record anywhere. The
    -- retry's next tick sees the winner's receipt / bound run and adopts it
    -- (or the abort/un-pause flow takes over).
    when (not receiptLanded) $
        retry "dispatch receipt claim lost (concurrent dispatcher, run already bound, or group aborting) — skipping the POST"
    logEvent (releaseId rt) "GH_DISPATCH_ATTEMPTED" $
        object
            [ "workflow_path" .= wfPath
            , "ref" .= ref
            , "watermark" .= mWatermark
            , "dispatched_at" .= dispatchedAt
            ]
    res0 <-
        dispatchWorkflow
            creds
            (gitOwner ac)
            (gitRepo ac)
            wfPath
            body
    -- Optional-input fallback. The workflow file AT THE DISPATCHED REF owns the
    -- input schema, so a ref cut before `versions` existed 422s the whole POST
    -- ("Unexpected inputs provided"). GitHub rejects the REQUEST — no run is
    -- created — so we can safely drop the optional keys and retry once: the
    -- build runs with the workflow's own auto-detect instead of failing the
    -- release. Only inputs whose absence changes nothing else are droppable;
    -- any other unexpected input still aborts (a real schema mismatch).
    (res, versionsLanded) <- case res0 of
        Left e
            | Just dropped <- droppableUnexpectedInputs e -> do
                logEvent (releaseId rt) "DISPATCH_INPUT_FALLBACK" $
                    object
                        [ "dropped" .= dropped
                        , "workflow_path" .= wfPath
                        , "ref" .= ref
                        , "detail" .= ("workflow at this ref predates the input — retried without it" :: Text)
                        ]
                logInfoIO $
                    "[DispatchWorkflow] "
                        <> releaseId rt
                        <> " ref "
                        <> ref
                        <> " does not declare ["
                        <> T.intercalate ", " dropped
                        <> "] — retrying without it (apps auto-detect their versions)"
                r <-
                    dispatchWorkflow
                        creds
                        (gitOwner ac)
                        (gitRepo ac)
                        wfPath
                        body{wdrInputs = foldr (KM.delete . AK.fromText) inputs dropped}
                pure (r, False)
        _ -> pure (res0, versionsSent)
    case res of
        Right mDetails -> do
            logInfoIO $
                "[DispatchWorkflow] "
                    <> releaseId rt
                    <> " dispatched workflow="
                    <> wfPath
                    <> " ref="
                    <> ref
                    <> " selected_apps=["
                    <> selectedApps
                    <> "]"
            modify $ \s ->
                s
                    { targetState =
                        Just $
                            MobileBuildState
                                ( applyMobileTarget s $ \mt ->
                                    mt
                                        { mbWfStatus = bumpStatus (mbWfStatus mt) MBDispatched
                                        , mbBuildStartedAt = Just dispatchedAt
                                        , mbBatchDispatch = Just isBatch
                                        , mbVersionsPassed = Just versionsLanded
                                        }
                                )
                    }
            logEvent (releaseId rt) "GH_DISPATCHED" $
                object
                    [ "workflow_path" .= wfPath
                    , "ref" .= ref
                    , "selected_apps" .= selectedApps
                    , "version_name" .= versionName
                    , "version_code" .= versionCode
                    , "batch" .= isBatch
                    , "versions_passed" .= versionsLanded
                    ]
            -- ── Inline bind (return_run_details) ────────────────────────
            -- GitHub told us OUR run's id in the dispatch response — bind it
            -- now: no listing, no candidate matching, nothing to mis-adopt.
            -- head_sha isn't in the response, so one exact GET-by-id fetches
            -- it; if that GET fails (or the 204 legacy path returned no
            -- details) we bind nothing and ResolveRunId hunts as before —
            -- one binding path for the column + sha, never a partial stamp.
            forM_ mDetails $ \d -> do
                let runIdT = T.pack (show (drdRunId d))
                eRun <- getWorkflowRun creds (gitOwner ac) (gitRepo ac) runIdT
                case eRun of
                    Right run -> do
                        boundId <- setExternalRunIdForDispatch dispatchId runIdT (wrHeadSha run)
                        modify $ \s ->
                            s
                                { targetState =
                                    Just $
                                        MobileBuildState
                                            (applyMobileTarget s $ \mt -> mt{mbExternalRunId = Just boundId})
                                }
                        -- Losing the bind means a peer bound a different run
                        -- between our claim and this stamp, so the run we just
                        -- POSTed is a duplicate the group will never reference:
                        -- no cancel tier could ever find it, and left alone it
                        -- builds for hours, pushes our tag and uploads a second
                        -- artifact of the same identity. CANCEL it — ownership
                        -- is not inferred here, GitHub named this run id in our
                        -- own dispatch response. A failed cancel still leaves
                        -- the group on ONE binding; the event carries the run
                        -- so an operator can finish the job by hand.
                        if boundId /= runIdT
                            then do
                                eCancel <- cancelRun creds (gitOwner ac) (gitRepo ac) runIdT
                                logEvent (releaseId rt) "STATUS_UPDATED" $
                                    object
                                        [ "reason" .= ("dispatched run is a duplicate — the group was bound to another run first" :: Text)
                                        , "orphan_run_id" .= runIdT
                                        , "orphan_html_url" .= fromMaybe (wrHtmlUrl run) (drdHtmlUrl d)
                                        , "bound_run_id" .= boundId
                                        , "orphan_cancelled" .= either (const False) (const True) eCancel
                                        , "cancel_error" .= either Just (const Nothing) eCancel
                                        ]
                            else logEvent (releaseId rt) "GH_RUN_RESOLVED" $
                                object
                                    [ "run_id" .= runIdT
                                    , "head_sha" .= wrHeadSha run
                                    , "html_url" .= fromMaybe (wrHtmlUrl run) (drdHtmlUrl d)
                                    , "source" .= ("dispatch_response" :: Text)
                                    ]
                    Left e ->
                        logInfoIO $
                            "[DispatchWorkflow] "
                                <> releaseId rt
                                <> " run-by-id fetch failed after dispatch (ResolveRunId will bind run "
                                <> runIdT
                                <> "): "
                                <> e
            pure StageSuccess
        -- A 4xx from GitHub means the request itself is rejected — unknown/extra
        -- inputs (422, e.g. the dispatched ref's workflow declares a different input
        -- schema), workflow or ref not found (404), malformed body (400). These NEVER
        -- succeed on retry, so retrying just hangs the build at MBVersionResolved
        -- forever (the symptom that motivated this branch). Abort to MBFailed with
        -- GitHub's message surfaced so the operator sees the real cause immediately;
        -- only genuinely transient failures (5xx / network) keep retrying.
        Left e
            | isPermanentDispatchError e -> abort ("workflow_dispatch rejected by GitHub (check the workflow inputs / source ref): " <> e)
            -- Ambiguous outcome (timeout / 5xx / network): GitHub may or may
            -- not have created a run. The receipt persisted above makes the
            -- next tick go ADOPT-FIRST — it only re-dispatches if no run
            -- appears within 'dispatchAdoptGrace'.
            | otherwise -> retry ("dispatchWorkflow failed (adopt-first on next tick): " <> e)

-- | A 'dispatchWorkflow' error that will never succeed on retry — GitHub rejected
-- the request, not a transient hiccup. Matched on the rendered HTTP error string.
isPermanentDispatchError :: Text -> Bool
isPermanentDispatchError e =
    any
        (`T.isInfixOf` e)
        [ "HTTP 422"
        , "HTTP 404"
        , "HTTP 400"
        , "Unexpected inputs"
        ]

{- | Inputs named by GitHub's @Unexpected inputs provided: [...]@ 422, when EVERY
name it listed is optional enrichment we can drop and retry without. 'Nothing'
otherwise — including when it names an input the build's behaviour depends on,
which is a genuine schema mismatch and must stay a hard failure.

@versions@ is droppable by construction: absent, each matrix job auto-detects
its own version exactly as it did before the input existed.
-}
droppableUnexpectedInputs :: Text -> Maybe [Text]
droppableUnexpectedInputs e
    | T.null rest = Nothing
    | null names = Nothing
    | all (`elem` droppable) names = Just names
    | otherwise = Nothing
  where
    droppable = ["versions"] :: [Text]
    (_, rest) = T.breakOn "Unexpected inputs provided" e
    -- The names sit in a bracketed list whose quotes arrive JSON-escaped
    -- (\"versions\"); keep only identifier characters per element.
    inside = T.takeWhile (/= ']') (T.drop 1 (T.dropWhile (/= '[') rest))
    names =
        filter (not . T.null) $
            map (T.filter (\c -> isAlphaNum c || c == '_' || c == '-')) (T.splitOn "," inside)

{- | Stage 4: Resolve @external_run_id@ by polling GH for the run our
dispatch created.

FALLBACK path: since @return_run_details@ (GitHub changelog 2026-02-19)
the dispatch response carries our run id and 'dispatchFreshRun' binds it
inline — this stage then skips on its @hasExternalRunId@ guard. It still
runs when the dispatch response was lost (timeout\/crash), parsed as a
legacy 204, or the post-dispatch GET-by-id failed. In those cases the
@\/runs@ list omits @inputs@, so the run is identified by evidence:

1. Fetch the @\/runs@ list (event=workflow_dispatch).
2. Keep runs authored by OUR App's bot account ('BotIdentity') whose id is
   strictly above the pre-dispatch watermark from the receipt (created-at
   window fallback for pre-watermark rows) — 'ownDispatchCandidates'.
3. Drop runs already claimed by another dispatch group
   ('externalRunIdsClaimedElsewhere').
4. Oldest first: one candidate binds directly; several bind only via
   matrix-job verification ('findRunWithJob').
5. Persist @external_run_id@ to all sibling rows in a single SQL UPDATE.

Bounded retry: after 10 ticks with no candidate we abort with
@MBFailed "run_lookup_timeout"@ so the row doesn't poll forever.
-}
execResolveRunId :: forall m. (StageM ReleaseState m) => m StageOutcome
execResolveRunId = do
    rs <- gets id
    if hasExternalRunId rs
        then pure StageSuccess
        else mobileStage "ResolveRunId" $ do
            let rt = releaseTracker rs
            target <- case mobileTarget rs of
                Just t -> pure t
                Nothing -> abort "MobileBuildState missing at ResolveRunId"
            ac <- appCatalogForRow rt
            creds <- loadGhCredsSafe
            mDid <- findDispatchIdForRelease (releaseId rt)
            dispatchId <- case mDid of
                Just d -> pure d
                Nothing -> abort "dispatch_id missing at ResolveRunId"
            -- Same abort-propagation gate as DispatchWorkflow: never bind a run
            -- while the group's run is being torn down (that teardown window is
            -- where a dying row adopted a successor's run). Reaching this stage
            -- means a POST was made, so the in-flight test is the row's own
            -- receipt — no extra query. Parked before incrementResolveAttempts
            -- so a park never burns the bounded retry budget.
            siblingsNow <- findSiblingsByDispatchId dispatchId
            when (any (\(r, _) -> status r == ABORTING) siblingsNow && isJust (mbBuildStartedAt target)) $
                retry "dispatch group abort in progress (run teardown) — parking (no bind)"
            attempts <- incrementResolveAttempts (releaseId rt)
            let wfPath = acWorkflowPath ac
            res <-
                listWorkflowRuns
                    creds
                    (gitOwner ac)
                    (gitRepo ac)
                    wfPath
            allRuns <- case res of
                Right xs -> pure xs
                Left e -> retry ("listWorkflowRuns failed: " <> e)
            mBot <- getBotIdentity creds
            now <- liftIO getCurrentTime
            let dispatchedAt = fromMaybe now (mbBuildStartedAt target)
                mWatermark = mbDispatchWatermark target
            mCeiling <- dispatchCeilingFor ac dispatchedAt
            candidates <-
                unclaimedCandidates dispatchId $
                    ownDispatchCandidates (biUserId <$> mBot) mWatermark dispatchedAt mCeiling allRuns
            -- Bounded retry, two tiers. No candidate at all after ~10 ticks =
            -- the dispatch never materialised (today's rule). Candidates present
            -- but not yet verified NEVER time out while any of them is still
            -- running: matrix jobs only list once the run's setup phase
            -- finishes, and that phase is minutes on Android but 10-20+ min on
            -- the iOS workflows (a long setup-environment job precedes the
            -- matrix) — a wall-clock cap here failed real in-progress builds.
            -- Once every candidate has COMPLETED and still none carries a
            -- group job, no amount of waiting will produce one — time out
            -- then. A foreign live run can't park us forever: its owner
            -- stamps it, claimed-exclusion drops it, and the null-candidates
            -- tier fires on the next tick.
            let anyCandidateLive = any (\r -> wrStatus r /= "completed") candidates
            when ((attempts > 10 && null candidates) || (attempts > 40 && not anyCandidateLive)) $ do
                modify $ \s ->
                    s
                        { targetState =
                            Just $
                                MobileBuildState
                                    ( applyMobileTarget s $ \mt ->
                                        mt{mbWfStatus = MBFailed "run_lookup_timeout"}
                                    )
                        }
                logEvent (releaseId rt) "STATUS_UPDATED" $
                    object
                        [ "mb_wf_status" .= ("MBFailed: run_lookup_timeout" :: Text)
                        , "reason" .= ("ResolveRunId exceeded attempts (candidates=" <> T.pack (show (length candidates)) <> ")" :: Text)
                        ]
                abort "ResolveRunId: max attempts exceeded"
            -- Bind ONLY to a run proven to contain one of the GROUP's matrix
            -- jobs — even a single candidate can be another group's run (same
            -- workflow file, provider version cohorts / concurrent operators)
            -- created inside our window before its owner stamped it. Group
            -- names, not just this row's: CI silently drops apps missing from
            -- the repo's matrix config, so the executing row's own job may
            -- never exist in the group's perfectly good run. Matrix jobs list
            -- once the setup job expands them (~a minute), so a pending
            -- verification just waits a few ticks; the attempts>40 tier
            -- bounds it.
            -- A LONE settled candidate with a dead conclusion is OUR run,
            -- killed before its matrix expanded (manual cancel on GitHub,
            -- setup failure): under the receipt + watermark + created-at +
            -- unclaimed filters nothing else lands alone in that window, and
            -- a settled jobless run can never verify. Waiting would mislabel
            -- this as run_lookup_timeout ~13 min later — fail with the truth.
            case candidates of
                [r]
                    | wrStatus r == "completed"
                    , Just concl <- wrConclusion r
                    , concl `elem` ["cancelled", "failure", "startup_failure", "timed_out"] -> do
                        modify $ \s ->
                            s
                                { targetState =
                                    Just $
                                        MobileBuildState
                                            ( applyMobileTarget s $ \mt ->
                                                mt{mbWfStatus = MBFailed ("run_" <> concl <> "_before_verification")}
                                            )
                                }
                        logEvent (releaseId rt) "STATUS_UPDATED" $
                            object
                                [ "mb_wf_status" .= ("MBFailed: run_" <> concl <> "_before_verification" :: Text)
                                , "run_id" .= T.pack (show (wrId r))
                                , "html_url" .= wrHtmlUrl r
                                , "reason" .= ("the GitHub run ended '" <> concl <> "' before its matrix expanded — nothing to bind or build" :: Text)
                                ]
                        abort ("GitHub run ended '" <> concl <> "' before the matrix expanded")
                _ -> pure ()
            groupJobs <- dispatchGroupJobNames (releaseId rt) target
            mBound <- case candidates of
                [] -> pure Nothing
                _ ->
                    findRunWithJob
                        creds
                        (gitOwner ac)
                        (gitRepo ac)
                        groupJobs
                        candidates
            case mBound of
                Just r -> do
                    let verifiedId = T.pack (show (wrId r))
                        headSha = wrHeadSha r
                    -- First-writer-wins bind: a peer pod (inline bind or its own
                    -- resolve) may have bound a different run while we verified
                    -- this one. Take the group's binding, never overwrite it.
                    runIdT <- setExternalRunIdForDispatch dispatchId verifiedId headSha
                    modify $ \s ->
                        s
                            { targetState =
                                Just $
                                    MobileBuildState
                                        ( applyMobileTarget s $ \mt ->
                                            mt
                                                { mbExternalRunId = Just runIdT
                                                , mbWfStatus = bumpStatus (mbWfStatus mt) MBRunIdResolved
                                                }
                                        )
                            }
                    logEvent (releaseId rt) "GH_RUN_RESOLVED" $
                        object
                            [ "run_id" .= runIdT
                            , "head_sha" .= headSha
                            , "html_url" .= wrHtmlUrl r
                            , "created_at" .= wrCreatedAt r
                            , "candidates" .= length candidates
                            , "verified_run_id" .= verifiedId
                            ]
                    logInfoIO $
                        "[ResolveRunId] "
                            <> releaseId rt
                            <> " bound to run_id="
                            <> runIdT
                            <> " head_sha="
                            <> headSha
                    pure StageSuccess
                Nothing -> do
                    -- Show the (almost certainly ours) oldest candidate in the
                    -- UI while verification pends — display-only stamp + event.
                    forM_ (listToMaybe candidates) (noteCandidateRun dispatchId target)
                    logInfoIO $
                        "[ResolveRunId] "
                            <> releaseId rt
                            <> " no verified candidate run yet ("
                            <> T.pack (show (length candidates))
                            <> " in window, attempt "
                            <> T.pack (show attempts)
                            <> ")"
                    pure StageWaiting

{- | Stage 5: Poll @\/runs/:id\/jobs@ and update @mbMatrixJobStatus@.

The GHA workflow runs each app on a matrix axis, with a deterministic
@job.name@ per axis (recorded in @mbContext.matrixJobName@ at create
time). We find that job, persist its status to @targetState@, and emit
a release event so the UI can show progress.

* @completed/success@ → SubmittedToStore (next stage handles tag).
* @completed/failure|cancelled|timed_out@ → MBFailed and abort.
* anything else (queued/in_progress/etc.) → Waiting; tick again.
* job missing entirely → Waiting (matrix may not have spawned yet).
-}
execPollMatrixJobs :: forall m. (StageM ReleaseState m) => m StageOutcome
execPollMatrixJobs = mobileStage "PollMatrixJobs" $ do
    rs <- gets id
    let rt = releaseTracker rs
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at PollMatrixJobs"
    runId <- case mbExternalRunId target of
        Just r | not (T.null r) -> pure r
        _ -> abort "external_run_id missing at PollMatrixJobs"
    ac <- appCatalogForRow rt
    creds <- loadGhCredsSafe
    res <- listJobs creds (gitOwner ac) (gitRepo ac) runId
    jobs <- case res of
        Right xs -> pure xs
        Left e -> retry ("listJobs failed: " <> e)
    let jobName = mbcMatrixJobName (mbContext target)
        matching = filter (\j -> jName j == jobName) jobs
        anyInFlight = any (\j -> jStatus j /= "completed") jobs
        anyFailed =
            any
                ( \j ->
                    jStatus j == "completed"
                        && jConclusion j `elem` map Just ["failure", "cancelled", "timed_out", "startup_failure"]
                )
                jobs
    case matching of
        []
            -- Our matrix job never appeared. If at least one job has run AND none
            -- are still in flight AND any of them ended in a failure-like state,
            -- the run failed before matrix expansion (e.g., a bad `strategy:` expression).
            -- Don't wait forever — record and abort.
            | not (null jobs) && not anyInFlight && anyFailed -> do
                logInfoIO $
                    "[PollMatrixJobs] "
                        <> releaseId rt
                        <> " matrix job "
                        <> jobName
                        <> " never appeared and run has failing terminal jobs; aborting"
                logEvent (releaseId rt) "MATRIX_JOB_UPDATED" $
                    object
                        [ "job_name" .= jobName
                        , "status" .= ("missing" :: Text)
                        , "conclusion" .= ("workflow_failure" :: Text)
                        , "detail" .= ("matrix expansion failed before our job started" :: Text)
                        ]
                abort "matrix job never appeared; workflow run failed before matrix expansion"
            -- Our job is absent and nothing is in flight. Job-absence is only
            -- trustworthy when the RUN itself is settled on attempt 1: the jobs
            -- listing shows only the LATEST attempt (a "re-run failed jobs"
            -- hides our attempt-1 green job), and a partial mid-run listing
            -- (setup job done, matrix not yet listed) must keep waiting — so
            -- confirm against the run record, never from the job list alone.
            --
            -- Three settled shapes end here, and the run's own conclusion tells
            -- them apart:
            --   * run GREEN without our job — selected_apps is only a request;
            --     the matrix step silently drops apps it doesn't know for this
            --     flavor. Fail with the real cause.
            --   * run DEAD with zero jobs (startup_failure / cancelled while
            --     queued) or with only its setup job — nothing ever built.
            -- The dead shapes reach this stage ONLY since the dispatch-response
            -- inline bind: it skips ResolveRunId, whose lone-dead-candidate rule
            -- used to catch them. Without this branch such a row polls forever.
            | not anyInFlight && not anyFailed -> do
                runE <- getWorkflowRun creds (gitOwner ac) (gitRepo ac) runId
                let mRun = either (const Nothing) Just runE
                    settledAttempt1 = case mRun of
                        Just r -> wrStatus r == "completed" && maybe True (<= 1) (wrRunAttempt r)
                        Nothing -> False
                    mConcl = mRun >>= wrConclusion
                    deadConcl = case mConcl of
                        Just c | c `elem` ["cancelled", "failure", "startup_failure", "timed_out"] -> Just c
                        _ -> Nothing
                case (settledAttempt1, deadConcl) of
                    (False, _) -> do
                        logInfoIO $
                            "[PollMatrixJobs] "
                                <> releaseId rt
                                <> " job "
                                <> jobName
                                <> " missing but run not settled on attempt 1 — waiting"
                        pure StageWaiting
                    (True, Just concl) -> do
                        logInfoIO $
                            "[PollMatrixJobs] "
                                <> releaseId rt
                                <> " run ended '"
                                <> concl
                                <> "' before job "
                                <> jobName
                                <> " started; aborting"
                        logEvent (releaseId rt) "MATRIX_JOB_UPDATED" $
                            object
                                [ "job_name" .= jobName
                                , "status" .= ("missing" :: Text)
                                , "conclusion" .= ("run_" <> concl :: Text)
                                , "html_url" .= (wrHtmlUrl <$> mRun)
                                , "detail" .= ("the GitHub run ended '" <> concl <> "' before this app's job started — nothing was built" :: Text)
                                ]
                        abort ("GitHub run ended '" <> concl <> "' before matrix job " <> jobName <> " started")
                    (True, Nothing) -> do
                        logInfoIO $
                            "[PollMatrixJobs] "
                                <> releaseId rt
                                <> " run completed without matrix job "
                                <> jobName
                                <> " — app not in the repo's matrix config; aborting"
                        logEvent (releaseId rt) "MATRIX_JOB_UPDATED" $
                            object
                                [ "job_name" .= jobName
                                , "status" .= ("missing" :: Text)
                                , "conclusion" .= ("not_in_matrix" :: Text)
                                , "detail" .= ("run completed without this app's job — add the app to the repo's matrix config for this build flavor" :: Text)
                                ]
                        abort ("matrix job " <> jobName <> " never appeared — app is not in the repo's matrix config for this build flavor")
            | otherwise -> do
                logInfoIO $
                    "[PollMatrixJobs] "
                        <> releaseId rt
                        <> " job "
                        <> jobName
                        <> " not yet present (waiting)"
                pure StageWaiting
        (j : _) -> do
            let status' = jStatus j
                conclusion = jConclusion j
                bumped = case (status', conclusion) of
                    ("completed", Just "success") ->
                        bumpStatus (mbWfStatus target) MBSubmittedToStore
                    ("completed", Just "cancelled") ->
                        MBFailed "matrix_job_cancelled"
                    ("completed", Just _) ->
                        -- Failure-like conclusion: HOLD the current status — the
                        -- auto-heal gate below decides (heal / wait / fail).
                        -- Writing MBFailed here would satisfy this stage's
                        -- skip-guard and strand the verification loop.
                        mbWfStatus target
                    _ ->
                        if mbWfStatus target == MBDispatched || mbWfStatus target == MBRunIdResolved
                            then MBBuilding
                            else mbWfStatus target
            -- Persist the latest status snapshot regardless of outcome — UI
            -- consumers want the live label even mid-build.
            modify $ \s ->
                s
                    { targetState =
                        Just $
                            MobileBuildState
                                ( applyMobileTarget s $ \mt ->
                                    mt
                                        { mbMatrixJobStatus = Just status'
                                        , mbBuildCompletedAt = case (status', conclusion) of
                                            ("completed", _) -> jCompletedAt j
                                            _ -> mbBuildCompletedAt mt
                                        , mbWfStatus = bumped
                                        }
                                )
                    }
            logEvent (releaseId rt) "MATRIX_JOB_UPDATED" $
                object
                    [ "job_name" .= jobName
                    , "job_id" .= jId j
                    , "status" .= status'
                    , "conclusion" .= conclusion
                    , "html_url" .= jHtmlUrl j
                    ]
            case (status', conclusion) of
                ("completed", Just "success") -> do
                    -- Firebase-distributed builds: the real identity (version
                    -- code + console/tester links) exists ONLY in the fastlane
                    -- job log — no tag, no store artifact. That covers debug
                    -- AND provider prod dispatched with destination=Firebase,
                    -- whose log carries the same "and created release" line.
                    -- Read it once, fail soft.
                    when
                        ( isDebugBuildType (mbcBuildType (mbContext target))
                            || mbcDestination (mbContext target) == Just "Firebase"
                        )
                        $ observeFirebaseRelease rt creds ac j
                    pure StageSuccess
                ("completed", Just "cancelled") ->
                    -- The shared GH run was cancelled (a sibling's abort or a manual
                    -- cancel on GitHub) — this build died with it, it didn't fail.
                    abort "build cancelled — the GH run was cancelled (sibling abort or manual cancel)"
                ("completed", Just other) -> do
                    -- CI claims failure, but a post-upload step death (tag push,
                    -- notify) leaves a live store artifact behind a failed job.
                    -- Store truth decides — never mark a shipped build failed.
                    outcome <- attemptAutoHeal rt target j
                    case outcome of
                        AutoHealed mObs -> do
                            modify $ \s ->
                                s
                                    { targetState =
                                        Just $
                                            MobileBuildState
                                                ( applyMobileTarget s $ \mt ->
                                                    mt
                                                        { mbWfStatus = bumpStatus (mbWfStatus mt) MBSubmittedToStore
                                                        , mbContext = (mbContext mt){mbcVersionCode = mbcVersionCode (mbContext mt) <|> mObs}
                                                        }
                                                )
                                    }
                            logEvent (releaseId rt) "BUILD_HEALED_FROM_STORE" $
                                object
                                    [ "trigger" .= ("auto" :: Text)
                                    , "job_conclusion" .= other
                                    , "observed_code" .= mObs
                                    ]
                            pure StageSuccess
                        AutoHealWaiting n mErr -> do
                            modify $ \s ->
                                s
                                    { targetState =
                                        Just $
                                            MobileBuildState
                                                (applyMobileTarget s $ \mt -> mt{mbVerifyAttempts = Just n})
                                    }
                            logEvent (releaseId rt) "BUILD_HEAL_CHECK" $
                                object ["attempt" .= n, "job_conclusion" .= other, "error" .= mErr]
                            pure StageWaiting
                        AutoHealNo detail -> do
                            captureFailureDetail rt j
                            modify $ \s ->
                                s
                                    { targetState =
                                        Just $
                                            MobileBuildState
                                                ( applyMobileTarget s $ \mt ->
                                                    mt{mbWfStatus = MBFailed ("matrix_job_" <> other)}
                                                )
                                    }
                            abort $ "matrix job ended with conclusion=" <> other <> detail
                ("completed", Nothing) ->
                    -- Spec violation from GH: completed without a conclusion.
                    -- Treat as transient; tick again.
                    pure StageWaiting
                _ -> pure StageWaiting

-- ─── Auto-heal gate (store truth vs a failed matrix job) ───────────

data AutoHealOutcome
    = AutoHealed (Maybe Int32)
    -- ^ Store has the artifact (observed code when reported) — resume the lifecycle.
    | AutoHealWaiting Int (Maybe Text)
    -- ^ Not confirmed yet (attempt count, transient error) — tick again.
    | AutoHealNo Text
    -- ^ Genuine failure; the detail suffix explains why healing was ruled out.

-- | Bounded verification budget (scheduler ticks). Store APIs list a build
-- from upload time — not processing-complete — so a short window suffices.
maxAutoHealAttempts :: Int
maxAutoHealAttempts = 4

{- | Best-effort: record the GH-side failure cause — the failed step name plus
the @##[error]@ excerpt from the job log — as a BUILD_FAILURE_DETAIL event;
the failed card renders it. Wrapped so a log-fetch hiccup can never block or
retry the failure path itself (worst case the event carries the step only).
-}
captureFailureDetail :: ReleaseTracker -> Job -> StateFlow ()
captureFailureDetail rt j = do
    eExcerpt <- MC.try @_ @SomeException $ do
        ac <- appCatalogForRow rt
        creds <- loadGhCredsSafe
        eLog <- fetchJobLog creds (gitOwner ac) (gitRepo ac) (jId j)
        pure (either (const Nothing) extractFailureExcerpt eLog)
    logEvent (releaseId rt) "BUILD_FAILURE_DETAIL" $
        object
            [ "failed_step" .= failedStepOf j
            , "excerpt" .= either (const Nothing) id eExcerpt
            , "html_url" .= jHtmlUrl j
            ]

{- | Decide whether a failed matrix job actually shipped its artifact.

Debug/Firebase rows have no store: never healable. An upload step that
failed or never ran is a genuine build failure — ruled out with zero store
calls. Otherwise verify the exact artifact against store truth
("Products.Autopilot.Mobile.Heal"), sharpened by the build code parsed from
the job log (accepted only when the log's version matches this row).
-}
attemptAutoHeal :: ReleaseTracker -> MobileBuildTargetState -> Job -> StateFlow AutoHealOutcome
attemptAutoHeal rt target j = do
    let ctx = mbContext target
        attempts = fromMaybe 0 (mbVerifyAttempts target)
    if isDebugBuildType (mbcBuildType ctx) || mbcDestination ctx == Just "Firebase"
        then pure (AutoHealNo "")
        else case classifyFailedJob j of
            UploadFailed -> pure (AutoHealNo " (upload step failed — no store artifact)")
            UploadNotReached -> pure (AutoHealNo " (died before the upload step — no store artifact)")
            _ -> do
                ac <- appCatalogForRow rt
                creds <- loadGhCredsSafe
                eIdent <- fetchRunIdentity creds (gitOwner ac) (gitRepo ac) (jId j)
                let mLogCode = case eIdent of
                        Right ident | riVersionName ident == newVersion rt -> riVersionCode ident
                        _ -> Nothing
                    mCode = mbcVersionCode ctx <|> mLogCode
                res <- lift (verifyStoreArtifact ac (newVersion rt) mCode (mbBuildStartedAt target))
                pure $ case res of
                    ArtifactFound mObs -> AutoHealed mObs
                    _
                        | attempts + 1 >= maxAutoHealAttempts ->
                            AutoHealNo
                                ( " (store verified: no artifact after "
                                    <> T.pack (show (attempts + 1))
                                    <> " checks)"
                                )
                    ArtifactMissing -> AutoHealWaiting (attempts + 1) Nothing
                    VerifyErrored e -> AutoHealWaiting (attempts + 1) (Just e)

{- | Stage 6: confirm the annotated tag THIS build pushed.

The @ny-react-native@ fastlane workflows tag deterministically (see
@fastlane-android.yaml@ / @fastlane.yaml@ "Create and push annotated release
tag"):

> TAG = {normalize(app)}/prod/{platform}/v{version_name}+{version_code}

For a SINGLE-app dispatch SCC passes @version_name@ + @version_code@ as inputs,
so the workflow's auto-detect is skipped and it tags with /exactly/ the version
SCC resolved — the tag is fully reconstructible from the release row. A BATCHED
dispatch sends no version inputs (each matrix job auto-versions), so the code is
workflow-assigned and matched like iOS: any @+\<digits\>@ tag of this version,
then read the real code back off the tag (@mbBatchDispatch@ / @effCode@).

We must select that exact tag — NOT "the first ref under a broad prefix". GitHub's
@matching-refs@ API returns refs in ascending lexicographic order, so the first
is the /oldest/ version (e.g. @v3.3.15+421@ when this build pushed @v3.3.17+460@).
Once a repo has more than one version under the prefix, "first" is wrong. See
'selectBuildTag'.
-}

{- | Select the tag this build pushed from the refs returned by @listTags@.

Matches the build's resolved identity exactly:
@{prefix}{version_name}+{version_code}@ (the @+{code}@ is omitted only when the
release has no version code). Returns 'Nothing' when that exact tag isn't present
yet, so the caller falls through to the wall-clock wait/timeout — i.e. "the build
hasn't pushed it yet", never "use some other tag".

@prefix@ already ends in @.../v@ (built in 'execConfirmTag'); @refs@ are full
@refs\/tags\/...@ strings.
-}
selectBuildTag :: Text -> Text -> Maybe Int32 -> [Text] -> Maybe Text
selectBuildTag prefix version mCode refs =
    let names = map stripRefsTags refs
        bare = prefix <> version -- "{prefix}{version}" (no +code)
        plusPrefix = bare <> "+" -- "{prefix}{version}+"
        suffixOf n = T.drop (T.length plusPrefix) n
        isCoded n = plusPrefix `T.isPrefixOf` n && not (T.null (suffixOf n)) && T.all isDigit (suffixOf n)
        coded = filter isCoded names
        codeOf n = T.foldl' (\acc c -> acc * 10 + digitToInt c) (0 :: Int) (suffixOf n)
     in case mCode of
            -- Known code (Android consumer — SCC sends version_code on dispatch): exact match.
            Just c ->
                let t = plusPrefix <> T.pack (show c)
                 in if t `elem` names then Just t else Nothing
            -- Unknown code (iOS — the workflow assigns the build number): match the
            -- {prefix}{version}+<digits> the build actually pushed (highest code wins),
            -- falling back to a bare {prefix}{version} tag if that's the scheme.
            Nothing -> case sortOn (Down . codeOf) coded of
                (t : _) -> Just t
                [] -> if bare `elem` names then Just bare else Nothing

{- | Select the tag a PROVIDER prod build pushed. Provider workflows tag as
@{acName}-v{version}-{code}@. We match the @{acName}-v{version}-@ prefix (numeric
suffix) and prefer the exact @{code}@ SCC resolved at create time — version_name
AND version_code are fetched from the store, the same values the consumer path
matches on. The provider workflow assigns the code itself (SCC never sends
@version_code@ to it), so on the off chance its code diverges from ours we fall
back to the highest code for this version rather than time out. @verPrefix@ already
ends in the trailing @-@. Returns 'Nothing' when no such tag is present yet, so the
caller keeps polling — never "use some other tag".
-}
selectProviderBuildTag :: Text -> Maybe Int32 -> [Text] -> Maybe Text
selectProviderBuildTag verPrefix mCode refs =
    let names = map stripRefsTags refs
        suffixOf n = T.drop (T.length verPrefix) n
        isMatch n =
            verPrefix `T.isPrefixOf` n
                && not (T.null (suffixOf n))
                && T.all isDigit (suffixOf n)
        matches = filter isMatch names
        codeOf n = T.foldl' (\acc c -> acc * 10 + digitToInt c) (0 :: Int) (suffixOf n)
        exact = do
            c <- mCode
            let t = verPrefix <> T.pack (show c)
            if t `elem` matches then Just t else Nothing
     in case exact of
            Just t -> Just t
            Nothing -> case sortOn (Down . codeOf) matches of
                (t : _) -> Just t
                [] -> Nothing

{- | The build code embedded in the observed tag — the number the build itself
assigned. Consumer tags end in @+{code}@; provider tags in the @{code}@ after
@verPrefix@. 'Nothing' for a bare (codeless) tag. Lets ConfirmTag stamp version_code
for iOS/provider builds, whose code SCC doesn't know until the tag lands.
-}
codeFromTag :: Bool -> Text -> Text -> Text -> Text -> Maybe Int32
codeFromTag isProvider verPrefix prefix version tag =
    let mDigits
            | isProvider = T.stripPrefix verPrefix tag
            | otherwise = T.stripPrefix (prefix <> version <> "+") tag
     in mDigits >>= \d ->
            if not (T.null d) && T.all isDigit d
                then Just (T.foldl' (\acc c -> acc * 10 + fromIntegral (digitToInt c)) (0 :: Int32) d)
                else Nothing

{- | Pure: the tag a build's job log says it pushed. Recognises the tag
steps' EXISTING confirmation lines — no workflow changes needed:

* @Annotated tag pushed: \<tag\>@ — consumer workflows, post-push.
* @Successfully created and pushed tag: \<tag\>@ — provider workflows, post-push.
* @Tag \<tag\> already exists, skipping@ — provider same-identity rebuild:
  the push is skipped but the tag is still this build's identity (the
  provenance gate judges whether its commit is right).

Job logs also contain the script SOURCE dump, where these lines carry the
un-expanded @$TAG_NAME@ — candidates are restricted to a plausible tag
charset and must contain a scheme separator (@/@ or @-v@), which rejects
those artifacts. The LAST candidate wins (execution output follows the dump).
-}
tagPushedFromLog :: Text -> Maybe Text
tagPushedFromLog logTxt =
    listToMaybe (reverse (concatMap candidates (T.lines logTxt)))
  where
    prefixMarkers = ["Annotated tag pushed: ", "Successfully created and pushed tag: "]
    existsMarker = " already exists, skipping"
    candidates ln =
        [ tag
        | m <- prefixMarkers
        , let (_, rest) = T.breakOn m ln
        , m `T.isPrefixOf` rest
        , let tag = T.takeWhile plausibleTagChar (T.stripStart (T.drop (T.length m) rest))
        , plausibleTag tag
        ]
            <> [ tag
               | existsMarker `T.isInfixOf` ln
               , let (pre, _) = T.breakOn existsMarker ln
               , let tag = T.takeWhileEnd plausibleTagChar pre
               , plausibleTag tag
               ]
    plausibleTagChar c = isAlphaNum c || c `elem` ("./+-_" :: String)
    -- Both tag schemes carry a separator ('/' consumer, "-v" provider);
    -- bare variable names from the script dump (e.g. "TAG_NAME") have neither.
    plausibleTag t = not (T.null t) && ("/" `T.isInfixOf` t || "-v" `T.isInfixOf` t)

{- | Outcome of reading the build's own matrix-job log for the tag it pushed.
'LogTagAbsent' is a SETTLED answer — ConfirmTag only runs once the job has
completed, so its log is final and re-reading it can never yield a tag —
while 'LogUnavailable' is a transient miss worth retrying next tick.
-}
data JobLogTag
    = LogTagFound Text
    | LogTagAbsent
    | LogUnavailable

{- | Best-effort: the tag THIS build pushed, read from its own matrix job's
log. Strongest attribution available — bound run id → own matrix job → its
log — so two same-app runs pushing same-version tags can never cross-adopt.
A run unbound, job absent, or fetch/parse failure yields 'LogUnavailable' and
the caller falls back to the repo-tags listing for this tick. The caller
validates any returned tag against the row's pinned identity — the log line is
a pointer, never a trust root.
-}
tagFromJobLog :: (MonadFlow m) => GhAppCreds -> AppCatalog -> MobileBuildTargetState -> m JobLogTag
tagFromJobLog creds ac target =
    fmap (either (const LogUnavailable) id) . MC.try @_ @SomeException $
        case mbExternalRunId target of
            Nothing -> pure LogUnavailable
            Just runId -> do
                eJobs <- listJobs creds (gitOwner ac) (gitRepo ac) runId
                case eJobs of
                    Left _ -> pure LogUnavailable
                    Right jobs ->
                        case filter (\j -> jName j == mbcMatrixJobName (mbContext target)) jobs of
                            (j : _) -> do
                                eLog <- fetchJobLog creds (gitOwner ac) (gitRepo ac) (jId j)
                                pure $ case eLog of
                                    Left _ -> LogUnavailable
                                    Right body -> maybe LogTagAbsent LogTagFound (tagPushedFromLog body)
                            [] -> pure LogUnavailable

{- | Pure predicate for the ConfirmTag wall-clock guard. Has the stage waited
past @timeoutMin@ for the build's tag? Anchors on build-completion, falling back
to build-start. If neither timestamp is set we can't measure elapsed time, so we
report 'False' (keep polling) rather than fail spuriously.
-}
tagConfirmTimedOut :: UTCTime -> Maybe UTCTime -> Maybe UTCTime -> Int -> Bool
tagConfirmTimedOut now mCompletedAt mStartedAt timeoutMin =
    case mCompletedAt of
        Just c -> overBudget c
        Nothing -> maybe False overBudget mStartedAt
  where
    overBudget anchor = diffUTCTime now anchor > fromIntegral (timeoutMin * 60)

{- | Pure SOFT-timeout predicate for the review poll: has review been pending past
@timeoutDays@ since it was submitted? Used only to surface "review taking long" —
a nudge, NOT a failure. 'Nothing' submitted-at ⇒ can't measure ⇒ 'False'.
-}
reviewPollTimedOut :: UTCTime -> Maybe UTCTime -> Int -> Bool
reviewPollTimedOut now mSubmittedAt timeoutDays =
    case mSubmittedAt of
        Just t -> diffUTCTime now t > fromIntegral (timeoutDays * 86400)
        Nothing -> False

{- | Pure throttle predicate: should the review-poll stage hit the store this tick?
'True' if at least @intervalSec@ has elapsed since the last poll (or it has never
polled). Keeps the ~20s runner tick from hammering the store APIs.
-}
reviewPollDue :: UTCTime -> Maybe UTCTime -> Int -> Bool
reviewPollDue now mLastPolled intervalSec =
    case mLastPolled of
        Nothing -> True
        Just t -> diffUTCTime now t >= fromIntegral intervalSec

{- | After a build is confirmed built+tagged (ConfirmTag → MBTagPushed), post the
release changelog to the mobile Slack channel — but ONLY for releases that opted
in at create time (the "Send changelog summary to Slack" tickbox).

The opt-in is @mbcChangelogSlackOptIn@ ('changelogSlackOptedIn' — legacy rows
fall back to the body's presence); the body is @mbcChangelogSummary@, always
stored now, with the typed changelog @mbcChangeLog@ as the send-time fallback.
Both live on the build context ('release_context'), read straight off
@target@. Storing them in @release_context@ — not the shared @metadata@
column — is what makes it reliable: store-sync / rollout passes overwrite
@metadata@ between create and ConfirmTag, but never touch @release_context@.

@mobile_slack_channel@ is the destination (not the gate). Exactly-once is
provided by the ConfirmTag stage guard (skipped once MBTagPushed is reached).
Best-effort: a Slack failure is logged, never aborts the stage.
-}
execConfirmTag :: forall m. (StageM ReleaseState m) => m StageOutcome
execConfirmTag = mobileStage "ConfirmTag" $ do
    rs <- gets id
    let rt = releaseTracker rs
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at ConfirmTag"
    let isDebug = isDebugBuildType (mbcBuildType (mbContext target))
        -- The provider prod workflow cuts a tag ONLY for the store destination:
        -- @Create Release Tag@ is gated on @destination == 'GooglePlay'@, and
        -- @Upload signed AAB artifact@ on @'DownloadAAB'@. Firebase and
        -- DownloadAAB therefore provably never produce one, and waiting for it
        -- parks the row at BUILDING until the tag timeout. mbcDestination is
        -- only ever set for provider prod (see 'buildRow'), so a set-but-not-
        -- GooglePlay value is exactly that case.
        mDest = mbcDestination (mbContext target)
        noTagDestination = maybe False (/= "GooglePlay") mDest
        skipTag = isDebug || noTagDestination
        skipMarker
            | isDebug = "debug-no-tag"
            | otherwise = T.toLower (fromMaybe "" mDest) <> "-no-tag"
        skipSource = if isDebug then "debug_skip" else "destination_skip" :: Text
    if skipTag
        then do
            logInfoIO $
                "[ConfirmTag] "
                    <> releaseId rt
                    <> (if isDebug then " debug destination" else " destination=" <> fromMaybe "" mDest <> " pushes no tag")
                    <> ", skipping tag confirmation"
            modify $ \s ->
                s
                    { targetState =
                        Just $
                            MobileBuildState
                                ( applyMobileTarget s $ \mt ->
                                    mt
                                        { mbContext = (mbContext target){mbcTagPushed = Just skipMarker}
                                        , mbWfStatus = bumpStatus (mbWfStatus mt) MBTagPushed
                                        }
                                )
                    }
            logEvent (releaseId rt) "TAG_OBSERVED" $
                object ["tag" .= skipMarker, "source" .= skipSource, "destination" .= mDest]
            -- This row just settled (debug tag). Re-check the group barrier: the
            -- changelog posts ONCE per group when every member has settled.
            lift (sendGroupChangelogSlackIfSettled (mbcReleaseGroupId (mbContext target)) (Just (releaseId rt)))
            pure StageSuccess
        else do
            ac <- appCatalogForRow rt
            creds <- loadGhCredsSafe
            -- Tag scheme differs by surface:
            --   consumer: {normalize(app)}/prod/{platform}/v{version}+{code} — exact match
            --             when SCC supplied version_code on dispatch; a batched dispatch
            --             sends no version inputs, so the code is workflow-assigned and
            --             matched like iOS (see isBatch/effCode below).
            --   provider: {acName}-v{version}-{code} — the provider workflow assigns the
            --             version code itself (SCC never sends version_code to it), so we
            --             match the {acName}-v{version}- prefix and read the code back.
            --             See selectProviderBuildTag.
            let isProvider = acSurface ac == "driver"
                platform = acPlatform ac
                version = newVersion rt
                mCode = mbcVersionCode (mbContext target)
                -- Batched dispatch withOUT the per-app `versions` input (older
                -- rows): the code SCC pre-resolved was never given to the
                -- workflow — match like iOS (any +<digits> tag of this version,
                -- highest wins) and read the real code back off the pushed tag.
                -- With mbVersionsPassed the workflow built exactly OUR identity,
                -- so exact-match even in a batch.
                autoVersioned =
                    mbBatchDispatch target == Just True
                        && mbVersionsPassed target /= Just True
                effCode = if autoVersioned then Nothing else mCode
                prefix
                    | isProvider = acName ac <> "-v"
                    | otherwise = normalizeAppSegment (acName ac) <> "/prod/" <> platform <> "/v"
                providerVerPrefix = acName ac <> "-v" <> version <> "-"
                expectedTag
                    | isProvider = providerVerPrefix <> maybe "<code>" (T.pack . show) effCode
                    | otherwise = prefix <> version <> maybe "" (\c -> "+" <> T.pack (show c)) effCode
            -- ── Log-first tag discovery ─────────────────────────────
            -- The build's own job log names the tag it pushed ("Annotated tag
            -- pushed: <tag>") and the run id is bound to THIS row, so the tag
            -- is attributed to this exact build — no cross-run inference (two
            -- same-app runs pushing same-version tags are indistinguishable
            -- in the repo listing). The log is a pointer, not a trust root:
            -- the tag must match the row's pinned identity below and still
            -- passes the provenance gate. Any miss falls back to the
            -- repo-tags listing.
            -- Read the log at most ONCE per row. ConfirmTag runs only after the
            -- matrix job completed, so its log is FINAL: whatever it names (or
            -- doesn't) can never change on a later read, while the stage
            -- re-enters every poll until the tag appears or the 180-minute
            -- timeout expires — each tick pulling tens of MB, on both pods.
            -- Only 'LogUnavailable' (run unbound / job missing / fetch or parse
            -- failure) is worth retrying; the caller marks every SETTLED
            -- outcome below, once it knows whether the tag was usable.
            alreadyScanned <- pure (mbTagLogScanned target == Just True)
            logOutcome <-
                if alreadyScanned
                    then pure LogUnavailable
                    else tagFromJobLog creds ac target
            let mLogTag = case logOutcome of
                    LogTagFound t -> Just t
                    _ -> Nothing
                -- Settled = the log was read in full. A tag that does not match
                -- this row is as final as no tag at all: the row's identity
                -- (prefix / version / effCode) is fixed, so it can never start
                -- matching. That is exactly the row headed for tag_timeout —
                -- the one that would otherwise re-download for three hours.
                logSettled = case logOutcome of
                    LogTagFound _ -> True
                    LogTagAbsent -> True
                    LogUnavailable -> False
            let base = prefix <> version
                -- selectBuildTag / selectProviderBuildTag's acceptance rule,
                -- applied to the log's tag. Provider accepts any code of this
                -- version: the workflow assigns the code itself, so the run's
                -- own log outranks the code SCC pre-resolved.
                logTagMatches t
                    | isProvider =
                        let sfx = T.drop (T.length providerVerPrefix) t
                         in providerVerPrefix `T.isPrefixOf` t && not (T.null sfx) && T.all isDigit sfx
                    | otherwise = case effCode of
                        Just c -> t == base <> "+" <> T.pack (show c)
                        Nothing ->
                            t == base
                                || ((base <> "+") `T.isPrefixOf` t && T.all isDigit (T.drop (T.length base + 1) t))
            mSelected <- case mLogTag of
                Just t
                    | logTagMatches t -> do
                        logInfoIO $
                            "[ConfirmTag] " <> releaseId rt <> " tag read from own job log: " <> t
                        pure (Just t)
                    -- This row PINNED its identity via the `versions` input, yet
                    -- the build's own log says it tagged something else — a real
                    -- conflict (CI ignored the pin / workflow drift). Fail with
                    -- the evidence instead of waiting out a tag_timeout.
                    | mbVersionsPassed target == Just True -> do
                        logEvent (releaseId rt) "TAG_CONFLICT" $
                            object
                                [ "log_tag" .= t
                                , "expected" .= expectedTag
                                , "source" .= ("job_log" :: Text)
                                ]
                        abort $
                            "build's job log says it pushed "
                                <> t
                                <> " but this row pinned "
                                <> expectedTag
                                <> " via the versions input — check the workflow's version handling"
                _ -> do
                    -- Legacy auto-versioned row whose log tag names a different
                    -- version: surface it — it explains the tag_timeout this row
                    -- is otherwise headed for.
                    forM_ mLogTag $ \t ->
                        logInfoIO $
                            "[ConfirmTag] "
                                <> releaseId rt
                                <> " job-log tag "
                                <> t
                                <> " does not match this row's identity ("
                                <> expectedTag
                                <> ") — falling back to repo tags"
                    -- Reaching the fallback with a SETTLED log means that log
                    -- holds nothing this row can ever use. Record it so the
                    -- remaining ticks of the tag window skip the fetch — this
                    -- branch, not the no-tag one, is where a row can idle for
                    -- the full 180 minutes.
                    when (logSettled && not alreadyScanned) $
                        markTagLogScanned (releaseId rt)
                    res <- listTags creds (gitOwner ac) (gitRepo ac) prefix
                    refs <- case res of
                        Right xs -> pure xs
                        Left e -> retry ("listTags failed: " <> e)
                    pure $
                        if isProvider
                            then selectProviderBuildTag providerVerPrefix effCode refs
                            else selectBuildTag prefix version effCode refs
            case mSelected of
                Nothing -> do
                    -- Tag not pushed yet. Wall-clock guard (mirrors
                    -- max_job_completion_hours for backend jobs): if the expected tag
                    -- hasn't appeared within the budget since the build completed, fail
                    -- rather than poll forever. Anchor on build-completed → build-started
                    -- → now (last ⇒ no anchor, so we don't time out this tick).
                    now <- liftIO getCurrentTime
                    timeoutMin <- getMobileTagConfirmTimeoutMinutes
                    if tagConfirmTimedOut now (mbBuildCompletedAt target) (mbBuildStartedAt target) timeoutMin
                        then do
                            modify $ \s ->
                                s
                                    { targetState =
                                        Just $
                                            MobileBuildState
                                                ( applyMobileTarget s $ \mt ->
                                                    mt{mbWfStatus = MBFailed "tag_timeout"}
                                                )
                                    }
                            logEvent (releaseId rt) "STATUS_UPDATED" $
                                object
                                    [ "mb_wf_status" .= ("MBFailed: tag_timeout" :: Text)
                                    , "reason"
                                        .= ( "ConfirmTag exceeded "
                                                <> T.pack (show timeoutMin)
                                                <> "m waiting for tag (expected="
                                                <> expectedTag
                                                <> ")"
                                           )
                                    ]
                            abort "ConfirmTag: tag confirmation timed out"
                        else do
                            logInfoIO $
                                "[ConfirmTag] "
                                    <> releaseId rt
                                    <> " expected tag not present yet: "
                                    <> expectedTag
                            pure StageWaiting
                Just tagName -> do
                    -- Provenance gate: name-matching alone can adopt a STALE tag — a
                    -- non-store run (or manual push) that burned this name earlier
                    -- points at a commit this build never shipped. The tag must peel
                    -- to the commit THIS run built (release_tracker.commit_sha,
                    -- stamped at ResolveRunId). Legacy rows without a stored sha
                    -- adopt as before. Never force-move a published tag: mismatch
                    -- fails the row with the retag command; after the operator
                    -- retags, "Verify on store" resumes it through here again.
                    forM_ (commitSha rt) $ \expectSha -> do
                        eShas <- listTagsWithShas creds (gitOwner ac) (gitRepo ac) tagName
                        tagSha <- case eShas of
                            Left e -> retry ("tag provenance lookup failed: " <> e)
                            Right pairs -> case lookup tagName pairs of
                                Nothing -> retry ("tag provenance: could not resolve " <> tagName)
                                Just sha -> pure sha
                        when (T.toLower tagSha /= T.toLower expectSha) $ do
                            logEvent (releaseId rt) "TAG_CONFLICT" $
                                object
                                    [ "tag" .= tagName
                                    , "tag_commit" .= tagSha
                                    , "build_commit" .= expectSha
                                    , "remediation"
                                        .= ( "git push origin :refs/tags/"
                                                <> tagName
                                                <> " && git tag -a "
                                                <> tagName
                                                <> " "
                                                <> expectSha
                                                <> " -m 'Release "
                                                <> tagName
                                                <> "' && git push origin refs/tags/"
                                                <> tagName
                                           )
                                    ]
                            abort $
                                "tag "
                                    <> tagName
                                    <> " points at "
                                    <> T.take 9 tagSha
                                    <> " but this build is from "
                                    <> T.take 9 expectSha
                                    <> " — stale tag burned the name; retag it (see TAG_CONFLICT event), then press Verify on store"
                    -- The build assigns the build number (esp. iOS, where SCC has no code
                    -- at dispatch); it's embedded in the tag it pushed. Read it back so
                    -- every store-bound row carries its identity code — version+code is the
                    -- key the store_status join matches on.
                    -- effCode known → trust it (exact match found). Unknown (iOS /
                    -- batched) → the tag's embedded code is the truth; fall back to
                    -- the pre-resolved one only for a bare (codeless) tag.
                    let observedCode = case effCode of
                            Just c -> Just c
                            Nothing -> maybe mCode Just (codeFromTag isProvider providerVerPrefix prefix version tagName)
                    modify $ \s ->
                        s
                            { targetState =
                                Just $
                                    MobileBuildState
                                        ( applyMobileTarget s $ \mt ->
                                            mt
                                                { mbContext = (mbContext target){mbcTagPushed = Just tagName, mbcVersionCode = observedCode}
                                                , mbWfStatus = bumpStatus (mbWfStatus mt) MBTagPushed
                                                }
                                        )
                            }
                    -- persistWorkflowState (checkpointReleaseTracker) doesn't write the
                    -- version_code COLUMN, so stamp it explicitly for store-bound builds
                    -- (toRow's gate) — the JSON above alone wouldn't reach the column.
                    when (claimsStoreIdentity (mbContext target)) $ do
                        forM_ observedCode (setReleaseVersionCode (releaseId rt))
                        -- Land-time supersession: this build now owns the internal
                        -- track — retire held siblings behind it in release order NOW
                        -- (same SSOT predicate; sync convergence stays the heal).
                        retired <-
                            retireOlderHeldInternal (appGroup rt) (service rt) (env rt) (releaseId rt) $
                                \v c -> releaseOrderBehind v c version observedCode
                        forM_ retired $ \i ->
                            logEvent i "HELD_SUPERSEDED" $
                                object ["by_version" .= version, "by_code" .= observedCode, "source" .= ("build_landed" :: Text)]
                    logEvent (releaseId rt) "TAG_OBSERVED" $
                        object ["tag" .= tagName, "expected" .= expectedTag, "prefix" .= prefix, "version_code" .= observedCode]
                    logInfoIO $
                        "[ConfirmTag] "
                            <> releaseId rt
                            <> " bound to tag="
                            <> tagName
                    -- This row just settled (tag observed). Re-check the group
                    -- barrier: the changelog posts ONCE per group, when every
                    -- member has settled (shipped or failed) and ≥1 shipped.
                    lift (sendGroupChangelogSlackIfSettled (mbcReleaseGroupId (mbContext target)) (Just (releaseId rt)))
                    pure StageSuccess

{- | Stage 7: Map fine-grained @MobileBuildWFStatus@ to the user-facing
'ReleaseStatus' that appears on the dashboard.

* @MBCompleted@ / @MBTagPushed@ → COMPLETED (TagPushed implies the
  build succeeded; the engine may finalize before stage 6 records the
  status bump if upstream stages already wrote MBTagPushed).
* @MBFailed _@                → ABORTED
* @MBAborted@                 → USER_ABORTED
* anything else               → no-op (engine should not have called
  Finalize before a terminal mb status; defensive).
-}

{- | Stage 6.5: bounded, throttled poll of the store review state. Runs only when
@mbWfStatus == MBInReview@. iOS advances to MBReviewApproved / MBReviewRejected via
'getAscReviewState'; Android review is opaque, so the stage waits for the operator's
mark-* endpoint. Throttled to @review_poll_interval_sec@ (default 20 min); soft-bounded
by @review_poll_timeout_days@ (a nudge, never a failure).
-}
execPollReview :: forall m. (StageM ReleaseState m) => m StageOutcome
execPollReview = mobileStage "PollReview" $ do
    rs <- gets id
    let rt = releaseTracker rs
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at PollReview"
    ac <- appCatalogForRow rt
    if acPlatform ac /= "ios"
        then do
            -- Android review is opaque (no API signal) — the operator records the
            -- outcome via the Phase-6 mark-* endpoint. Nothing to poll here.
            logInfoIO $ "[PollReview] " <> releaseId rt <> " android review is opaque; awaiting operator mark"
            pure StageWaiting
        else do
            now <- liftIO getCurrentTime
            intervalSec <- getReviewPollIntervalSeconds
            if not (reviewPollDue now (mbReviewLastPolledAt target) intervalSec)
                then pure StageWaiting -- throttled: not time to hit the store yet
                else do
                    timeoutDays <- getReviewPollTimeoutDays
                    when (reviewPollTimedOut now (mbReviewSubmittedAt target) timeoutDays) $
                        logEvent (releaseId rt) "REVIEW_SLOW" $
                            object
                                [ "message" .= ("App Store review pending beyond the soft timeout — check App Store Connect" :: Text)
                                , "timeout_days" .= timeoutDays
                                ]
                    mCreds <- loadAscCredsFor (acStoreAccount ac)
                    case mCreds of
                        Nothing -> do
                            logInfoIO $ "[PollReview] " <> releaseId rt <> " ASC creds missing; will retry"
                            stampPolled now
                            pure StageWaiting
                        Just creds -> do
                            res <- getAscReviewState creds (fromMaybe "" (acPackageName ac)) (newVersion rt)
                            stampPolled now
                            case res of
                                Left e -> do
                                    logInfoIO $ "[PollReview] " <> releaseId rt <> " poll error (retry): " <> renderAscErr e
                                    pure StageWaiting
                                Right AscApproved -> do
                                    setPhase now (releaseId rt) Approved
                                    advanceTo now MBReviewApproved
                                    logEvent (releaseId rt) "REVIEW_APPROVED" $ object ["store" .= ("asc" :: Text)]
                                    pure StageSuccess
                                Right AscLive -> do
                                    -- Already live in the App Store (released outside SCC during
                                    -- review). Record the approval + advance so the poll stops; the
                                    -- Phase-7 rollout reconciler then adopts the live state
                                    -- (rolling_out for a phased release, else completed).
                                    setPhase now (releaseId rt) Approved
                                    advanceTo now MBReviewApproved
                                    logEvent (releaseId rt) "REVIEW_APPROVED" $ object ["store" .= ("asc" :: Text), "already_live" .= True]
                                    pure StageSuccess
                                Right (AscRejected reason) -> do
                                    setPhase now (releaseId rt) (Rejected reason)
                                    advanceTo now MBReviewRejected
                                    logEvent (releaseId rt) "REVIEW_REJECTED" $ object ["reason" .= reason]
                                    pure StageSuccess
                                Right _ -> pure StageWaiting -- still in review (prepare / waiting / in-review / other)
  where
    stampPolled now =
        modify $ \s ->
            s{targetState = Just $ MobileBuildState (applyMobileTarget s (\mt -> mt{mbReviewLastPolledAt = Just now}))}
    advanceTo now st =
        modify $ \s ->
            s{targetState = Just $ MobileBuildState (applyMobileTarget s (\mt -> mt{mbWfStatus = bumpStatus (mbWfStatus mt) st, mbReviewLastPolledAt = Just now}))}

execFinalize :: forall m. (StageM ReleaseState m) => m StageOutcome
execFinalize = mobileStage "Finalize" $ do
    rs <- gets id
    let rt = releaseTracker rs
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at Finalize"
    staged <- isStagedRolloutEnabled
    let isDebug = isDebugBuildType (mbcBuildType (mbContext target))
        mb = mbWfStatus target
        mNew = case mb of
            MBCompleted -> Just COMPLETED
            -- Staged rollout: a RELEASE build HOLDS (stays INPROGRESS) at tag-push,
            -- awaiting the operator's "Promote to Review". Debug builds — and
            -- everything when the flag is off — complete at tag-push as before.
            MBTagPushed
                | staged && not isDebug -> Nothing
                | otherwise -> Just COMPLETED
            MBReviewRejected -> Just ABORTED
            MBFailed _ -> Just ABORTED
            MBAborted -> Just USER_ABORTED
            _ -> Nothing
    case mNew of
        Nothing -> do
            -- Defensive: shouldn't be reachable because the engine only enters
            -- this stage when no other stage has fired Waiting. But mobile is
            -- async-poll-heavy, so a partial state COULD reach here on resume.
            -- Stay where we are; the next tick will replay.
            logInfoIO $
                "[Finalize] "
                    <> releaseId rt
                    <> " mb_wf_status="
                    <> T.pack (show mb)
                    <> " not terminal yet; waiting"
            pure StageWaiting
        Just newStatus -> do
            -- Bump mb status to MBCompleted on the success path so a future
            -- resume short-circuits cleanly.
            let target' = case mb of
                    MBTagPushed -> target{mbWfStatus = MBCompleted}
                    _ -> target
            modify $ \s ->
                s
                    { releaseTracker = (releaseTracker s){status = newStatus}
                    , targetState = Just (MobileBuildState target')
                    }
            logEvent (releaseId rt) "STATUS_UPDATED" $
                object
                    [ "old_status" .= status rt
                    , "new_status" .= newStatus
                    , "mb_wf_status" .= T.pack (show mb)
                    ]
            case (newStatus, revertsReleaseId rt) of
                (COMPLETED, Just badId) ->
                    markReleaseRevertedBy badId (releaseId rt)
                _ -> pure ()
            logInfoIO $
                "[Finalize] "
                    <> releaseId rt
                    <> " status="
                    <> T.pack (show newStatus)
            pure StageSuccess

-- ─── Stage helpers (state, errors, locks) ──────────────────────────

{- | Wrap a 'StateFlow' body so it runs inside the engine's 'StageM'
monad and produces a 'StageOutcome'.

The stage-engine monad is a @ReaderT AppState@ stack that exposes
'MonadIO', 'MonadReader', 'MonadState', 'MonadCatch', 'MonadThrow', and
'MonadError WorkFlowError'. Mobile stage bodies use 'MonadFlow'
helpers (@withDb@, @logInfo@, @loadGhCreds@), which need 'MonadMask'
too — so we cannot run them directly inside 'StageM'.

The bridge: drop into a @StateT ReleaseState Flow@ action, returning
the desired @StageOutcome@. The inner action throws the typed
'MobileError' for fatal errors via 'abort' / 'retry'; we catch those
at the boundary and translate into 'WorkFlowError'.
-}
mobileStage ::
    forall m.
    (StageM ReleaseState m) =>
    Text ->
    StateFlow StageOutcome ->
    m StageOutcome
mobileStage tag action = do
    s0 <- gets id
    appSt <- ask
    eRes <- liftIO $ try @SomeException (runReaderT (runStateT action s0) appSt)
    case eRes of
        Right (outcome, s1) -> do
            modify (const s1)
            pure outcome
        Left ex ->
            case fromMobileException ex of
                Just (MobileAbort msg) -> do
                    liftIO (logWarningG ("[" <> tag <> "] abort: " <> msg))
                    throwError (DomainError (T.unpack msg))
                Just (MobileRetry msg) -> do
                    liftIO (logWarningG ("[" <> tag <> "] retry: " <> msg))
                    throwError (RetriableError (T.unpack msg))
                Nothing -> do
                    -- Re-raise any unexpected exception so the engine's
                    -- top-level catch records it as a domain failure.
                    liftIO (logWarningG ("[" <> tag <> "] uncaught: " <> T.pack (show ex)))
                    throwError (DomainError (T.unpack tag <> ": uncaught: " <> show ex))

{- | A typed exception thrown inside a 'StateFlow' body to stop a stage
early. 'mobileStage' catches and translates into 'WorkFlowError'.

We use a typed exception (rather than 'MonadError') because the inner
'StateFlow' / 'Flow' stack does not expose 'MonadError' on its own —
plumbing one through every helper would have meant a parallel monad
stack the same shape as the existing K8s workflows. Throwing in IO
keeps the call sites readable and the bridge boundary explicit.
-}
data MobileError
    = MobileAbort Text
    | MobileRetry Text
    deriving (Show)

instance Exception MobileError

-- | Recover a 'MobileError' from an opaque 'SomeException', if it is one.
fromMobileException :: SomeException -> Maybe MobileError
fromMobileException = fromException

-- | Inside a stage body: signal "this stage aborts; mark workflow failed."
abort :: Text -> StateFlow a
abort msg = liftIO (throwIO (MobileAbort msg))

-- | Inside a stage body: signal "this stage isn't done; tick me again."
retry :: Text -> StateFlow a
retry msg = liftIO (throwIO (MobileRetry msg))

-- | Lift @logInfoG@ inside a 'StateFlow' (which has 'MonadIO').
logInfoIO :: Text -> StateFlow ()
logInfoIO = liftIO . logInfoG

{- | 'loadGhCreds' variant for post-dispatch polling stages. Retries on the
next tick instead of killing the release when GitHub auth fails transiently
(clock drift, transient 401, GitHub 5xx, network blip) — the creds already
worked for dispatch, so the failure is transient.

Critically, this FORCES the installation-token exchange here, inside the try.
'loadGhCreds' only reads the env secrets; the token is minted lazily on the
first API call ('getInstallationToken' inside 'listJobs' etc.), whose 'throwM'
would otherwise escape that call's 'Left' handling and reach 'mobileStage' as
an UNCAUGHT exception — turning a transient blip into a fatal build abort even
while the GitHub job is building fine. Pre-warming the (cached) token here means
the later API calls reuse it and never do the exchange themselves.
-}
loadGhCredsSafe :: StateFlow GhAppCreds
loadGhCredsSafe = do
    eCreds <- MC.try @_ @SomeException $ do
        c <- loadGhCreds
        _ <- getInstallationToken c -- force + cache the token so poll calls can't throw
        pure c
    case eCreds of
        Right c -> pure c
        Left ex -> retry ("GH auth refresh failed (will retry): " <> T.pack (show ex))

-- ─── Helpers on ReleaseState / TargetState ─────────────────────────

-- | Project the 'MobileBuildTargetState' out of the wrapped 'TargetState'.
mobileTarget :: ReleaseState -> Maybe MobileBuildTargetState
mobileTarget rs = case targetState rs of
    Just (MobileBuildState t) -> Just t
    _ -> Nothing

{- | Apply @f@ to the 'MobileBuildTargetState' inside @ReleaseState@,
leaving everything else untouched. Returns a fresh
'MobileBuildTargetState' (the caller wraps it in 'MobileBuildState'
before assigning).

Used by the stage executors that need to mutate exactly one or two
fields of the inner target. If the targetState is missing entirely (no
'MobileBuildState' present), we fall back to a minimal placeholder so
the call doesn't crash — the relevant abort fires upstream.
-}
applyMobileTarget ::
    ReleaseState ->
    (MobileBuildTargetState -> MobileBuildTargetState) ->
    MobileBuildTargetState
applyMobileTarget rs f =
    case mobileTarget rs of
        Just t -> f t
        Nothing ->
            f
                MobileBuildTargetState
                    { mbWfStatus = MBInit
                    , mbContext =
                        MobileBuildContext
                            { mbcVersionCode = Nothing
                            , mbcChangeLog = ""
                            , -- Fallback when 'targetState' is missing entirely (no
                              -- MobileBuildState present). The relevant abort fires
                              -- upstream — but if we reach here, default to
                              -- "release" (the production build type per spec).
                              -- Originally this was 'error "..."' which would crash
                              -- the worker thread; defaulting to a safe value keeps
                              -- the placeholder usable while the real abort
                              -- propagates from the caller.
                              mbcBuildType = "release"
                            , mbcReleaseGroupId = ""
                            , mbcMatrixJobName = ""
                            , mbcOtaNamespace = Nothing
                            , mbcTagPushed = Nothing
                            , mbcDestination = Nothing
                            , mbcChangelogSummary = Nothing
                , mbcChangelogSummaryShort = Nothing
                , mbcChangelogSummaryModel = Nothing
                , mbcChangelogSlackOptIn = Nothing
                , mbcChangelogContentKey = Nothing
                , mbcStoreObserved = Nothing
                            }
                    , mbExternalRunId = Nothing
                    , mbMatrixJobStatus = Nothing
                    , mbBuildStartedAt = Nothing
                    , mbBuildCompletedAt = Nothing
                    , mbTagLogScanned = Nothing
                , mbResolveAttempts = Nothing
                    , mbReviewSubmittedAt = Nothing
                    , mbReviewLastPolledAt = Nothing
                    , mbBatchDispatch = Nothing
                    , mbVersionsPassed = Nothing
                    , mbVerifyAttempts = Nothing
                    , mbDispatchWatermark = Nothing
                    , mbCandidateRunId = Nothing
                    , mbFirebaseReleaseUrl = Nothing
                    , mbFirebaseTesterUrl = Nothing
                    }

{- | Status bump that respects ordering: never regresses to an earlier
state. If the target is "before" the current value (per
'mbStatusOrder'), keep the current. Used when a stage runs idempotently
and the persisted state is already past the local target.
-}
bumpStatus :: MobileBuildWFStatus -> MobileBuildWFStatus -> MobileBuildWFStatus
bumpStatus current target
    | mbStatusOrder target > mbStatusOrder current = target
    | otherwise = current

-- ─── Tag-prefix derivation ─────────────────────────────────────────

{- | Normalise an @AppCatalog.name@ to the @app-segment@ used in the
production tag prefix.

Rules (matching the @nammayatri/ny-react-native@ workflow):

* lowercase
* non-alphanumeric → @-@
* collapse runs of @-@ to a single @-@ (best-effort)

Example: @"NammaYatri"@ → @"nammayatri"@; @"Beckn Driver"@ →
@"beckn-driver"@.
-}

{- | Normalise an app name to its tag segment. Must match the shell
@normalize_segment@ in the fastlane workflows
(@sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'@): lowercase, keep
@a-z0-9._-@, replace any other run with a single @-@, trim leading\/trailing
@-@. Preserving @. _ -@ is what keeps SCC's expected tag equal to the tag the
build actually pushes for app names that contain those characters.
-}
normalizeAppSegment :: Text -> Text
normalizeAppSegment = collapseDashes . T.map step . T.toLower
  where
    step c
        | isAlphaNum c = c
        | c == '.' || c == '_' || c == '-' = c
        | otherwise = '-'
    collapseDashes :: Text -> Text
    collapseDashes t =
        T.dropWhile (== '-') $
            T.dropWhileEnd (== '-') $
                T.intercalate "-" $
                    filter (not . T.null) (T.splitOn "-" t)

-- | Strip the leading @refs/tags/@ from a Git ref, leaving the bare tag name.
stripRefsTags :: Text -> Text
stripRefsTags r = fromMaybe r (T.stripPrefix "refs/tags/" r)

-- ─── Postgres helpers (raw SQL) ────────────────────────────────────

{- | Look up @release_tracker.dispatch_id@ for a given release id.

Not exposed via the domain 'ReleaseTracker' record (which mirrors the
shape used by K8s workflows) — we drop into a raw @SELECT@ instead so
the mobile workflow doesn't need to wait on a domain refactor.

Returns @Nothing@ if the row is missing OR the column is NULL.
-}
findDispatchIdForRelease ::
    (MonadFlow m) =>
    Text ->
    m (Maybe Text)
findDispatchIdForRelease rid = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query
                conn
                "SELECT dispatch_id FROM release_tracker WHERE id = ? LIMIT 1"
                (Only rid)
        pure $ case rows of
            [Only mDid] -> mDid
            _ -> Nothing

{- | The @external_run_id@ COLUMN for a release row. Deliberately a column
read, not a target-state read: the leader's ResolveRunId stamps the column on
every sibling in one UPDATE, and a follower must see that stamp on its next
tick — its own persisted target state predates it.
-}
externalRunIdForRelease ::
    (MonadFlow m) =>
    Text ->
    m (Maybe Text)
externalRunIdForRelease rid = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query
                conn
                "SELECT external_run_id FROM release_tracker WHERE id = ? LIMIT 1"
                (Only rid)
        pure $ case rows of
            [Only mRunId] -> mRunId
            _ -> Nothing

{- | DISPLAY-ONLY: stamp the sighted candidate run id into every group row's
context so all siblings' summaries can link the run while matrix-job
verification is still pending (iOS: 10-20 min of setup before the matrix
expands). Never touches @external_run_id@ — binding stays verification-gated.
-}
setCandidateRunIdForDispatch :: (MonadFlow m) => Text -> Text -> m ()
setCandidateRunIdForDispatch did runId = withDb $ \db ->
    withConn db $ \conn -> do
        _ <-
            execute
                conn
                -- The shape guard (object-looking text only) keeps a corrupt
                -- sibling context from throwing on the ::jsonb cast and
                -- failing the whole group's tick over a display-only stamp.
                "UPDATE release_tracker \
                \SET release_context = jsonb_set(release_context::jsonb, '{contents,mbCandidateRunId}', to_jsonb(?::text))::text \
                \WHERE dispatch_id = ? AND release_context IS NOT NULL AND release_context ~ '^\\s*\\{'"
                (runId, did)
        pure ()

{- | Surface the oldest unclaimed candidate run to the whole dispatch group
the moment it is sighted — long before verification can bind it. Deduped
against the tick-start state so the stamp + events fire once per candidate.
-}
noteCandidateRun :: Text -> MobileBuildTargetState -> WorkflowRun -> StateFlow ()
noteCandidateRun did target r = do
    let runIdT = T.pack (show (wrId r))
    when (mbCandidateRunId target /= Just runIdT) $ do
        setCandidateRunIdForDispatch did runIdT
        siblings <- findSiblingsByDispatchId did
        forM_ siblings $ \(srt, _) ->
            logEvent (releaseId srt) "GH_RUN_CANDIDATE" $
                object
                    [ "run_id" .= runIdT
                    , "html_url" .= wrHtmlUrl r
                    , "note" .= ("run sighted — matrix-job verification pending" :: Text)
                    ]

-- ─── Debug-build Firebase release observation ──────────────────────

-- | What fastlane's @firebase_app_distribution@ printed for a debug build:
-- the only record of the build's identity (debug lanes push no tag and
-- upload no GH artifacts). The version NAME is a hardcoded placeholder
-- ("99.0.0") in the debug workflows; the CODE is real — assigned by
-- @increment_version_code@ against Firebase's latest release.
data FirebaseReleaseInfo = FirebaseReleaseInfo
    { friVersionName :: Text
    , friVersionCode :: Int32
    , friConsoleUrl :: Maybe Text
    , friTesterUrl :: Maybe Text
    }
    deriving (Eq, Show)

{- | Parse fastlane's @firebase_app_distribution@ output out of a job log:

>  ✅ Uploaded AAB successfully and created release 99.0.0 (392).
>  🔗 View this release in the Firebase console: https://console.firebase.google.com/…
>  🔗 Share this release with testers who have access: https://appdistribution.firebase.google.com/…

Log lines carry timestamps and ANSI colour codes, so match on substrings and
trim non-URL tails. 'Nothing' when no release line exists (not a Firebase
lane, or the plugin's wording changed) — callers fail SOFT: the version just
stays blank, exactly as before this parser existed.
-}
parseFirebaseRelease :: Text -> Maybe FirebaseReleaseInfo
parseFirebaseRelease logTxt = do
    relLine <- firstLineWith releaseMark
    let body = T.drop (T.length releaseMark) (snd (T.breakOn releaseMark relLine))
        (ver, afterVer) = T.breakOn " (" body
        codeTxt = T.takeWhile isDigit (T.drop 2 afterVer)
    code <- readMaybe (T.unpack codeTxt)
    guard (not (T.null (T.strip ver)))
    pure
        FirebaseReleaseInfo
            { friVersionName = T.strip ver
            , friVersionCode = code
            , friConsoleUrl = urlAfter "View this release in the Firebase console: "
            , friTesterUrl = urlAfter "Share this release with testers who have access: "
            }
  where
    releaseMark = "and created release "
    lns = T.lines logTxt
    firstLineWith needle = listToMaybe [l | l <- lns, needle `T.isInfixOf` l]
    urlAfter prefix = do
        l <- firstLineWith prefix
        let u = T.drop (T.length prefix) (snd (T.breakOn prefix l))
            cleaned = T.takeWhile (\c -> c /= '\ESC' && c /= ' ' && c /= '\r') u
        if "http" `T.isPrefixOf` cleaned then Just cleaned else Nothing

{- | Debug builds only: recover the build's Firebase identity from the
completed matrix job's log — version code onto the tracker column AND the
context mirror (the same field auto-heal stamps, which every version cell
reads), console/tester links into the target state for the summary page.
Best-effort in every direction: any failure logs and leaves the version
blank; it can never fail a build that just succeeded.
-}
observeFirebaseRelease :: ReleaseTracker -> GhAppCreds -> AppCatalog -> Job -> StateFlow ()
observeFirebaseRelease rt creds ac j = do
    eRes <- MC.try @_ @SomeException $ do
        eLog <- fetchJobLog creds (gitOwner ac) (gitRepo ac) (jId j)
        case eLog of
            Left e ->
                logInfoIO $ "[PollMatrixJobs] " <> releaseId rt <> " firebase-release log fetch failed (version stays blank): " <> e
            Right logTxt -> case parseFirebaseRelease logTxt of
                Nothing ->
                    logInfoIO $ "[PollMatrixJobs] " <> releaseId rt <> " no firebase release line in job log (version stays blank)"
                Just fri -> do
                    setReleaseVersionCode (releaseId rt) (friVersionCode fri)
                    modify $ \s ->
                        s
                            { targetState =
                                Just $
                                    MobileBuildState
                                        ( applyMobileTarget s $ \mt ->
                                            mt
                                                { mbContext = (mbContext mt){mbcVersionCode = mbcVersionCode (mbContext mt) <|> Just (friVersionCode fri)}
                                                , mbFirebaseReleaseUrl = friConsoleUrl fri
                                                , mbFirebaseTesterUrl = friTesterUrl fri
                                                }
                                        )
                            }
                    logEvent (releaseId rt) "FIREBASE_RELEASE_OBSERVED" $
                        object
                            [ "version_name" .= friVersionName fri
                            , "version_code" .= friVersionCode fri
                            , "html_url" .= friConsoleUrl fri
                            , "tester_url" .= friTesterUrl fri
                            ]
    case eRes of
        Left ex ->
            logInfoIO $ "[PollMatrixJobs] " <> releaseId rt <> " firebase-release observation threw (ignored): " <> T.pack (show ex)
        Right () -> pure ()

{- | (id, release_context) for every row in a dispatch group — terminal rows
included. The leader gate parses these to detect a dispatch by a dead
ex-leader (a context carrying @mbBuildStartedAt@) and adopt its run instead of
double-dispatching.
-}
findDispatchGroupContexts ::
    (MonadFlow m) =>
    Text ->
    m [(Text, Maybe Text)]
findDispatchGroupContexts did = withDb $ \db ->
    withConn db $ \conn ->
        query
            conn
            "SELECT id, release_context FROM release_tracker WHERE dispatch_id = ?"
            (Only did)

