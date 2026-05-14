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
(T17) sets up for sibling rows (same dispatch group). Stage 2 grabs a
Postgres advisory lock keyed on that id so only one worker dispatches
the underlying GHA workflow even if multiple tick at once.

Two known limitations are documented inline:

* Stage 4 cannot match a freshly-dispatched GH run by nonce because
  GitHub omits @inputs@ from the @\/runs@ list response. We use the
  @created_at@ window heuristic instead.
* @persistReleaseState@ reuses the K8s/Config persist helper, which
  serializes @MobileBuildState@ via the shared 'TargetState' JSON
  encoding (already wired up in T8/T15).
-}
module Products.Autopilot.Mobile.Workflow (
    mobileBuildSpec,
) where

import Control.Exception (Exception, SomeException, fromException, throwIO, try)
import qualified Control.Monad.Catch as MC
import Control.Monad (when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import Control.Monad.State.Strict (gets, modify)
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
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as LBS
import Data.Char (isAlphaNum)
import Data.List (sortOn)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (addUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Database.PostgreSQL.Simple (Only (..), query)
import Products.Autopilot.Mobile.Github (
    Job (..),
    WorkflowDispatchReq (..),
    WorkflowRun (..),
    dispatchWorkflow,
    listJobs,
    listTags,
    listWorkflowRuns,
 )
import Products.Autopilot.Mobile.Github.Auth (loadGhCreds)
import Products.Autopilot.Mobile.Queries.Tracker (
    appCatalogForRow,
    findSiblingsByDispatchId,
    gitOwner,
    gitRepo,
    incrementResolveAttempts,
    logEvent,
    setExternalRunIdForDispatch,
 )
import Products.Autopilot.Mobile.Types (
    MobileBuildContext (..),
    MobileBuildTargetState (..),
    MobileBuildWFStatus (..),
    MobileDestination (..),
    isMBTerminal,
 )
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning (
    VersionResolution (..),
    resolveNextVersion,
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
    , stageFinalize ::
        Stage ReleaseState

-- | Stage 1 — Play Console lookup → next version_name + version_code.
stageResolveVersion =
    (mkStage "ResolveVersion" execResolveVersion)
        { stageGuard = mbStatusReached MBVersionResolved
        }

-- | Stage 2 — acquire the advisory lock keyed on @dispatch_id@.
stageGroupForDispatch =
    (mkStage "GroupForDispatch" execGroupForDispatch)
        { stageGuard = hasExternalRunId
        }

-- | Stage 3 — POST @workflow_dispatch@ with selected_apps + version + payload.
stageDispatchWorkflow =
    (mkStage "DispatchWorkflow" execDispatchWorkflow)
        { stageGuard = mbStatusReached MBDispatched
        }

{- | Stage 4 — poll @\/runs@ until we can match a freshly-created run by
the actor + created_at heuristic, then write @external_run_id@ on every
sibling in the dispatch group.
-}
stageResolveRunId =
    (mkStage "ResolveRunId" execResolveRunId)
        { stageGuard = hasExternalRunId
        }

-- | Stage 5 — poll @\/runs/:id\/jobs@; track this row's matrix job.
stagePollMatrixJobs =
    (mkStage "PollMatrixJobs" execPollMatrixJobs)
        { stageGuard = mbStatusTerminal
        }

-- | Stage 6 — list refs/tags matching the per-app prefix; backfill context.
stageConfirmTag =
    (mkStage "ConfirmTag" execConfirmTag)
        { stageGuard = hasTagPushed
        }

-- | Stage 7 — map fine-grained @MobileBuildWFStatus@ to user-facing 'ReleaseStatus'.
stageFinalize =
    (mkStage "Finalize" execFinalize)
        { stageGuard = trackerStatusTerminal
        }

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
    MBCompleted -> 7
    MBAborting -> 8
    MBAborted -> 9
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
    ac <- appCatalogForRow rt
    pkgName <- case acPackageName ac of
        Just p | not (T.null p) -> pure p
        _ ->
            abort $
                "AppCatalog row for "
                    <> appGroup rt
                    <> " has no package_name; cannot resolve next version"
    res <- resolveNextVersion (acPlatform ac) pkgName
    case res of
        Left err
            -- Configuration errors are NOT retriable — the runner would
            -- loop forever waiting for the operator to update server_config
            -- without ever surfacing the problem on the release row.
            -- Abort with the stable error tag so the row transitions to
            -- MBFailed and the UI shows it as ABORTED with a clear cause.
            -- Patterns matched here cover both Play and Apple variants:
            --   - "<*>_not_configured", "<*>_creds_missing"
            --   - "asc_app_not_found:..." / "play_package_not_found:..."
            --   - "unsupported platform: ..."
            -- API hiccups (asc_http_error, play_unauthorized, etc.) still
            -- flow through retry so transient outages recover on their own.
            | isConfigError err -> abort err
            | otherwise -> retry err
        Right (AndroidVersion nextName nextCode) -> do
            logInfoIO $
                "[ResolveVersion] "
                    <> releaseId rt
                    <> " resolved Android version "
                    <> nextName
                    <> " (code "
                    <> T.pack (show nextCode)
                    <> ")"
            -- Both updates are idempotent: writing the same values again is a no-op.
            modify $ \s ->
                let rt' = (releaseTracker s){newVersion = nextName}
                    ts' =
                        applyMobileTarget s $ \mt ->
                            mt
                                { mbContext = (mbContext mt){mbcVersionCode = Just nextCode}
                                , mbWfStatus = bumpStatus (mbWfStatus mt) MBVersionResolved
                                }
                 in s{releaseTracker = rt', targetState = Just (MobileBuildState ts')}
            logEvent (releaseId rt) "VERSION_RESOLVED" $
                object
                    [ "version_name" .= nextName
                    , "version_code" .= nextCode
                    , "source" .= ("play_console" :: T.Text)
                    ]
            pure StageSuccess
        Right (IosVersion nextNumber) -> do
            logInfoIO $
                "[ResolveVersion] "
                    <> releaseId rt
                    <> " resolved iOS version_number "
                    <> nextNumber
                    <> " (build number computed by workflow)"
            -- iOS rows: only newVersion is written. mbcVersionCode stays
            -- Nothing — the workflow computes it via fastlane and we read
            -- it later from the pushed tag in ConfirmTag.
            modify $ \s ->
                let rt' = (releaseTracker s){newVersion = nextNumber}
                    ts' =
                        applyMobileTarget s $ \mt ->
                            mt
                                { mbWfStatus = bumpStatus (mbWfStatus mt) MBVersionResolved
                                }
                 in s{releaseTracker = rt', targetState = Just (MobileBuildState ts')}
            logEvent (releaseId rt) "VERSION_RESOLVED" $
                object
                    [ "version_number" .= nextNumber
                    , "source" .= ("app_store_connect" :: T.Text)
                    ]
            pure StageSuccess

{- | Stage 2: Acquire the dispatch-group advisory lock.

* Looks up the row's @dispatch_id@. If NULL, abort: the create endpoint
  should always populate it before the workflow starts.
* @pg_try_advisory_lock(hashtext(dispatch_id))@; if another worker
  holds it, return Waiting so the engine retries on the next tick.
* The lock auto-releases when the pooled connection returns to the
  pool. We deliberately do NOT pin it across stages — re-acquiring per
  tick is the right contention pattern for a sibling-dispatch group.
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
            dispatchId <- case mDid of
                Just d | not (T.null d) -> pure d
                _ ->
                    abort $
                        "release "
                            <> releaseId rt
                            <> " has no dispatch_id; mobile create endpoint must set it"
            ok <- tryAdvisoryLockShared dispatchId
            if ok
                then do
                    logInfoIO $
                        "[GroupForDispatch] "
                            <> releaseId rt
                            <> " acquired advisory lock for dispatch_id="
                            <> dispatchId
                    pure StageSuccess
                else do
                    logInfoIO $
                        "[GroupForDispatch] "
                            <> releaseId rt
                            <> " advisory lock busy; waiting"
                    pure StageWaiting

{- | Stage 3: POST @workflow_dispatch@ with the assembled inputs.

Inputs are built from siblings (sorted by service for stability) joined
to the AppCatalog so the GHA workflow knows which apps to build:

* @selected_apps@ — comma-separated CSV of @AppCatalog.surface@ values
  for every sibling in the dispatch group.
* @version_name@ — the resolved name from stage 1.
* @version_code@ — the resolved code from stage 1.
* @change_log@   — from @mbContext.changeLog@.
* @payload@      — JSON envelope with a fresh nonce so we can (in
  principle) match a run later. Note: GitHub's @\/runs@ endpoint does
  NOT echo @inputs@ back, so the nonce is best-effort observability
  only — see stage 4 for the actual matching strategy.

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
    let -- selected_apps is the comma-separated list of catalyst app NAMES
        -- (e.g. "NammaYatri,KeralaSavaari"), not surfaces. The workflow
        -- passes this to `catalyst -extract <platform>_prod --apps` which
        -- matches on the top-level keys of catalyst.yaml. Same shape on
        -- Android and iOS workflows.
        selectedApps =
            T.intercalate "," $
                map (acName . snd) (sortOn (acName . snd) siblings)
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
    -- selected_apps + catalyst path. SCC matches runs by actor + created_at
    -- window in ResolveRunId, not by an in-payload nonce.
    dispatchedAt <- liftIO getCurrentTime
    -- Build the workflow_dispatch inputs map. Two different shapes — the
    -- Android workflow declares `version_name` + `version_code` (two fields),
    -- the iOS workflow declares `version_number` (one field, semver string;
    -- the workflow computes the build number itself). Inputs not declared
    -- by a workflow are silently ignored by GitHub, but we keep the maps
    -- tight so the dispatch payload is honest about what each platform
    -- actually consumes.
    let inputs =
            case acPlatform ac of
                "ios" ->
                    KM.fromList
                        [ ("selected_apps", Aeson.String selectedApps)
                        , ("version_number", Aeson.String versionName)
                        , ("change_log", Aeson.String (mbcChangeLog (mbContext target)))
                        ]
                _ ->
                    -- Android (default; "android" or anything legacy).
                    KM.fromList
                        [ ("selected_apps", Aeson.String selectedApps)
                        , ("version_name", Aeson.String versionName)
                        , ("version_code", Aeson.String (T.pack (show versionCode)))
                        , ("change_log", Aeson.String (mbcChangeLog (mbContext target)))
                        ]
        body =
            WorkflowDispatchReq
                { wdrRef = "main"
                , wdrInputs = inputs
                }
    res <-
        dispatchWorkflow
            creds
            (gitOwner ac)
            (gitRepo ac)
            (acWorkflowPath ac)
            body
    case res of
        Right () -> do
            logInfoIO $
                "[DispatchWorkflow] "
                    <> releaseId rt
                    <> " dispatched workflow="
                    <> acWorkflowPath ac
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
                                        }
                                )
                    }
            logEvent (releaseId rt) "GH_DISPATCHED" $
                object
                    [ "workflow_path" .= acWorkflowPath ac
                    , "selected_apps" .= selectedApps
                    , "version_name" .= versionName
                    , "version_code" .= versionCode
                    ]
            pure StageSuccess
        Left e -> retry ("dispatchWorkflow failed: " <> e)

{- | Stage 4: Resolve @external_run_id@ by polling GH for a recently-
created @workflow_dispatch@ run.

GitHub's @\/actions\/workflows\/{file}\/runs@ list response does NOT
include @inputs@ in each row, so we cannot match by nonce. Instead:

1. Fetch the @\/runs@ list (event=workflow_dispatch).
2. Filter to rows created within @[dispatchedAt - 30s, dispatchedAt + 5min]@.
3. Sort by @created_at DESC@; pick the first match.
4. Persist @external_run_id@ to all sibling rows in a single SQL UPDATE.

This is a heuristic, not a guarantee. A concurrent dispatch from
another operator on the same workflow file with overlapping timing
could be mis-attributed; the operator can recover by aborting +
recreating.

Bounded retry: after 10 ticks (~5 min at 30s intervals) we abort with
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
            creds <- loadGhCreds
            mDid <- findDispatchIdForRelease (releaseId rt)
            dispatchId <- case mDid of
                Just d -> pure d
                Nothing -> abort "dispatch_id missing at ResolveRunId"
            attempts <- incrementResolveAttempts (releaseId rt)
            when (attempts > 10) $ do
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
                        , "reason" .= ("ResolveRunId exceeded 10 attempts" :: Text)
                        ]
                abort "ResolveRunId: max attempts exceeded"
            res <-
                listWorkflowRuns
                    creds
                    (gitOwner ac)
                    (gitRepo ac)
                    (acWorkflowPath ac)
            allRuns <- case res of
                Right xs -> pure xs
                Left e -> retry ("listWorkflowRuns failed: " <> e)
            now <- liftIO getCurrentTime
            let dispatchedAt = fromMaybe now (mbBuildStartedAt target)
                lo = addUTCTime (-30) dispatchedAt
                hi = addUTCTime 300 dispatchedAt
                inWindow r =
                    wrEvent r == "workflow_dispatch"
                        && wrCreatedAt r >= lo
                        && wrCreatedAt r <= hi
                candidates = sortOn (Down . wrCreatedAt) (filter inWindow allRuns)
            case candidates of
                (r : _) -> do
                    let runIdT = T.pack (show (wrId r))
                    setExternalRunIdForDispatch dispatchId runIdT
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
                            , "html_url" .= wrHtmlUrl r
                            , "created_at" .= wrCreatedAt r
                            , "candidates" .= length candidates
                            ]
                    logInfoIO $
                        "[ResolveRunId] "
                            <> releaseId rt
                            <> " bound to run_id="
                            <> runIdT
                    pure StageSuccess
                [] -> do
                    logInfoIO $
                        "[ResolveRunId] "
                            <> releaseId rt
                            <> " no candidate run yet (attempt "
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
    creds <- loadGhCreds
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
                    ("completed", Just other) ->
                        MBFailed ("matrix_job_" <> other)
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
                ("completed", Just "success") -> pure StageSuccess
                ("completed", Just other) ->
                    abort $ "matrix job ended with conclusion=" <> other
                ("completed", Nothing) ->
                    -- Spec violation from GH: completed without a conclusion.
                    -- Treat as transient; tick again.
                    pure StageWaiting
                _ -> pure StageWaiting

{- | Stage 6: List refs/tags whose name begins with the per-app prefix
and pick the first match.

Tag prefix shape (matches the existing @nammayatri/ny-react-native@
workflows): @${app-segment}/prod/${platform}/v...@ where:

* @app-segment@ is @AppCatalog.name@ normalised (lowercase, non-alnum
  → @-@). Example: @NammaYatri@ → @nammayatri@.
* @platform@ is @AppCatalog.platform@ ("android" / "ios").

We list refs at @refs\/tags\/{prefix}@ and pick the first one — the GHA
workflow only pushes a single tag per build, so there's nothing to
disambiguate. If no tag yet, return Waiting.
-}
execConfirmTag :: forall m. (StageM ReleaseState m) => m StageOutcome
execConfirmTag = mobileStage "ConfirmTag" $ do
    rs <- gets id
    let rt = releaseTracker rs
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at ConfirmTag"
    ac <- appCatalogForRow rt
    creds <- loadGhCreds
    let segment = normalizeAppSegment (acName ac)
        platform = acPlatform ac
        prefix = segment <> "/prod/" <> platform <> "/v"
    res <- listTags creds (gitOwner ac) (gitRepo ac) prefix
    refs <- case res of
        Right xs -> pure xs
        Left e -> retry ("listTags failed: " <> e)
    case refs of
        [] -> do
            logInfoIO $
                "[ConfirmTag] "
                    <> releaseId rt
                    <> " no tags yet for prefix="
                    <> prefix
            pure StageWaiting
        (r : _) -> do
            let tagName = stripRefsTags r
            modify $ \s ->
                s
                    { targetState =
                        Just $
                            MobileBuildState
                                ( applyMobileTarget s $ \mt ->
                                    mt
                                        { mbContext = (mbContext target){mbcTagPushed = Just tagName}
                                        , mbWfStatus = bumpStatus (mbWfStatus mt) MBTagPushed
                                        }
                                )
                    }
            logEvent (releaseId rt) "TAG_OBSERVED" $
                object ["tag" .= tagName, "ref" .= r, "prefix" .= prefix]
            logInfoIO $
                "[ConfirmTag] "
                    <> releaseId rt
                    <> " bound to tag="
                    <> tagName
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
execFinalize :: forall m. (StageM ReleaseState m) => m StageOutcome
execFinalize = mobileStage "Finalize" $ do
    rs <- gets id
    let rt = releaseTracker rs
    target <- case mobileTarget rs of
        Just t -> pure t
        Nothing -> abort "MobileBuildState missing at Finalize"
    let mb = mbWfStatus target
        mNew = case mb of
            MBCompleted -> Just COMPLETED
            MBTagPushed -> Just COMPLETED
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
                              -- 'MBGooglePlay' (the production destination per
                              -- spec). Originally this was 'error "..."' which would
                              -- crash the worker thread; defaulting to a safe value
                              -- keeps the placeholder usable while the real abort
                              -- propagates from the caller.
                              mbcDestination = MBGooglePlay
                            , mbcReleaseGroupId = ""
                            , mbcMatrixJobName = ""
                            , mbcOtaNamespace = Nothing
                            , mbcTagPushed = Nothing
                            }
                    , mbExternalRunId = Nothing
                    , mbMatrixJobStatus = Nothing
                    , mbBuildStartedAt = Nothing
                    , mbBuildCompletedAt = Nothing
                    , mbResolveAttempts = Nothing
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
normalizeAppSegment :: Text -> Text
normalizeAppSegment = collapseDashes . T.map step . T.toLower
  where
    step c
        | isAlphaNum c = c
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

{- | @pg_try_advisory_lock(hashtext($1))@ — non-blocking advisory lock
keyed on the dispatch id. Returns True if acquired, False if held by
another connection.

The lock is connection-bound: when the pooled connection returns to
the pool (or closes), the lock auto-releases. We deliberately do NOT
keep the connection pinned beyond the call — re-acquiring per stage
tick is the desired semantics for sibling-dispatch grouping (only one
worker should ever progress past stage 2 at a time, and that's
guaranteed by re-trying the lock on every tick).
-}
tryAdvisoryLockShared ::
    (MonadFlow m) =>
    Text ->
    m Bool
tryAdvisoryLockShared key = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query
                conn
                "SELECT pg_try_advisory_lock(hashtext(?))"
                (Only key)
        pure $ case rows of
            [Only b] -> b
            _ -> False
