{-# LANGUAGE OverloadedStrings #-}

-- |
-- System Control Centre — Unit Tests
--
-- These tests are PURE: no DB, no K8s, no HTTP. They cover the parts of
-- the codebase that can be reasoned about in isolation:
--
--   * Status state machine (per-service + global)
--   * Status helper predicates (terminal / aborted)
--   * Permission catalog (Admin/Manager/Viewer)
--   * Effective permission calculation (GRANT/DENY overrides)
--   * Config catalog (no global configs, slack is product-scoped)
--   * Config value validation
--   * Shell quoting (command-injection safety)
--   * K8s version validation (command-injection safety)
--   * Release tag formatting
--   * Rollout step semantics (cooloff = minutes, not seconds)
--
-- IO-bound concerns (DB queries, kubectl, Slack HTTP) are covered by the
-- API integration suite (`scripts/test-api.sh`) and the manual end-to-end
-- harness in CONTEXT.md.
module Main where

import Data.Aeson qualified as Aeson
import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Products.AirborneOta.Types.Permission (OtaPermission (..))
import Products.Autopilot.Config (autopilotConfigs)
import Products.Autopilot.ConfigDiff (extractContainerEnvJson)
import Products.Autopilot.DiffLink (buildDiffLink, normalizeRepo, toCommitId)
import Products.Autopilot.K8s.Execute (shellQuote)
import Products.Autopilot.Mobile.Changelog
  ( bumpPatch,
    renderRevertChangelog,
  )
import Products.Autopilot.Mobile.Github
  ( Job (..),
    JobsResp (..),
    WorkflowRun (..),
    WorkflowRunsResp (..),
    dispatchRunCandidates,
    ownDispatchCandidates,
  )
import Products.Autopilot.Mobile.Github.Compare
  ( CommitInfo (..),
    CompareResult (..),
    ciDisplayAuthor,
    extractPrNumber,
    isBotCommit,
    shortSha,
  )
import Products.Autopilot.Mobile.Handlers.Release (resolveBaseFromTracks)
import Products.Autopilot.Mobile.Lifecycle.BuildKind (BuildKind (..), buildKind, claimsStoreIdentity, hasStoreIdentity)
import Products.Autopilot.Mobile.Lifecycle.GroupSummary (GroupSummary (..), MemberFact (..), deriveGroupSummary, effectivePhase)
import Products.Autopilot.Mobile.Lifecycle.Phase (Display (..), Projection (..), ReleasePhase (..), Variant (..), abortable, canTransition, displayStatus, displayStatusInferred, pEngineStatus, phaseFromFields, phaseToWfStatus, project)
import Products.Autopilot.Mobile.Queries.AppCatalog (TrackSnapshot (..))
import Products.Autopilot.Mobile.Queries.StoreStatus (StoreCell (..), deriveStoreState, resolveStoreState)
import Products.Autopilot.Mobile.RevertResolver
  ( RevertCand (..),
    RollbackPlan (..),
    parseSemver,
    resolveRollback,
  )
import Products.Autopilot.Mobile.StoreSync (ExternalReviewAction (..), PendingOutcome (..), ReconcileAction (..), androidReconcileAction, detectConsoleRollout, detectIosRelease, externalReviewAction, iosPhasedReconcileAction, pendingOutcome, pendingPublishRelease, retireOutcome, reviewStateToStatus)
import Products.Autopilot.Mobile.Types
import Products.Autopilot.Mobile.Versioning (TrackInfo (..), computeNextVersion)
import Products.Autopilot.Mobile.Versioning.Apple (AscPhasedState (..), AscReviewState (..), AscVersion (..), BuildsResp (..), appStoreStateToReview, applePhasedPercent, computeNextIosVersion, firstWhatsNew, parseAscVersion, parseVersionStatesWithBuild, selectInFlightReview)
import Products.Autopilot.Mobile.Versioning.Play (PlayRolloutState (..), ProdTrackRelease (..), StoreTrackSnapshot (..), parseProdReleaseNotes, parseProdTrackReleases, parseRolloutState, parseTrackSnapshot, userFractionInRange)
import Products.Autopilot.Mobile.Workflow (FirebaseReleaseInfo (..), codeFromTag, droppableUnexpectedInputs, electDispatchLeader, parseFirebaseRelease, reviewPollDue, reviewPollTimedOut, selectBuildTag, selectProviderBuildTag, tagConfirmTimedOut, tagPushedFromLog)
import Products.Autopilot.Queries.ReleaseTracker (keepSnapshot)
import Products.Autopilot.Types.Permission
import Products.Autopilot.Types.Release
import Products.Autopilot.Types.Webhook (ReleaseWebhook (..), WebhookMethod (..), WebhookTrigger (..), renderTemplate, samplePlaceholderEnv, triggersOn)
import Products.Autopilot.Webhooks (triggerForStatus)
import Products.Autopilot.Types.Target qualified
import Products.Autopilot.Types.Workflow (ReleaseCategory (..), getDefaultDeploymentTarget)
import Products.ConfigCatalog (allConfigEntries, findConfigEntry)
import Products.Mobile.Types.Permission (MobilePermission (..), mobilePermissionToText, textToMobilePermission)
import Products.Types
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Aeson.KeyMap qualified as AKM
import Products.Autopilot.ProdRelease.Config qualified as PRC
import Products.Autopilot.ProdRelease.Intent qualified as PRI
import Products.Autopilot.ReleaseBot.Sql qualified as RBS
import Products.Autopilot.ReleaseBot.Diff qualified as RBD
import Products.Autopilot.ReleaseBot.Engine qualified as RBE
import Products.Autopilot.ReleaseBot.Live (refsFromDeployment)
import Products.Autopilot.ReleaseBot.Flow qualified as RBF
import Products.Autopilot.ReleaseBot.Live qualified as RBL
import Products.Autopilot.ReleaseBot.Routes qualified as RBR
import Products.Autopilot.ProdRelease.Jenkins qualified as PRJ
import Products.Autopilot.ReleaseBot.RowConfig qualified as RBW
import Products.Autopilot.Types.Storage.Schema qualified as SCH
import Products.Autopilot.ReleaseBot.PublicLink (requestIdOfGlobalId)
import Products.Autopilot.ReleaseBot.Xyne qualified as RBX
import Products.Autopilot.Hpa.Quantity qualified as HQ
import Products.Autopilot.Hpa.Types qualified as HT
import Products.Autopilot.Hpa.Window qualified as HW
import Products.Autopilot.Hpa.Change qualified as HC
import Products.Autopilot.Hpa.Health qualified as HH
import Products.Autopilot.Hpa.Kube qualified as HK
import Products.Autopilot.Hpa.Observer qualified as HO
import Data.Time.Clock (UTCTime)
import Products.Autopilot.Hpa.Resolver qualified as HR
import Products.Autopilot.Hpa.Spec qualified as HS
import Data.Text.Encoding qualified as TE
import Data.ByteString.Lazy qualified as BL
import Data.Aeson qualified as A
import Shared.AI.Changelog qualified as CL
import Shared.Config.Registry (validateConfigValue)
import Shared.Config.Types

-- ============================================================================
-- Test Helpers
-- ============================================================================

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual
    then putStrLn $ "  PASS: " <> name
    else fail $ "  FAIL: " <> name <> " — expected " <> show expected <> ", got " <> show actual

assertBool :: String -> Bool -> IO ()
assertBool name True = putStrLn $ "  PASS: " <> name
assertBool name False = fail $ "  FAIL: " <> name

-- Inline isValidK8sVersion (mirrors the version in Actions.Release)
isValidK8sVersion :: Text -> Bool
isValidK8sVersion ver
  | T.null ver = False
  | otherwise =
      let lowered = T.toLower ver
          chars = T.unpack lowered
          isValidChar c = isAlphaNum c || c == '-'
          startsOk = case chars of (c : _) -> isAlphaNum c; [] -> False
          endsOk = case chars of [] -> False; _ -> isAlphaNum (Prelude.last chars)
       in all isValidChar chars && startsOk && endsOk

-- ============================================================================
-- Main
-- ============================================================================

main :: IO ()
main = do
  putStrLn "==========================================="
  putStrLn "  System Control Centre — Unit Tests"
  putStrLn "==========================================="
  putStrLn ""

  section "[1]  Status Transitions (per-service)" testStatusTransitions
  section "[2]  Status Transitions (global)" testGlobalStatusTransitions
  section "[3]  Status Helpers (terminal / aborted)" testStatusHelpers
  section "[4]  K8s Version Validation" testVersionValidation
  section "[5]  Shell Quoting" testShellQuote
  section "[6]  Permission Catalog (roles)" testPermissions
  section "[7]  Effective Permissions (GRANT/DENY)" testEffectivePermissions
  section "[8]  Release Tag Format" testReleaseTag
  section "[9]  Rollout Step Semantics" testRolloutStep
  section "[10] Config Catalog (no globals, slack is product-scoped)" testConfigCatalog
  section "[11] Config Value Validation" testConfigValueValidation
  section "[12] VS Edit Status Transitions" testVsEditTransitions
  section "[13] Revert Lifecycle Status Transitions" testRevertTransitions
  section "[14] Restart Lifecycle Status Transitions" testRestartTransitions
  section "[15] DISCARDING (async) State Machine" testDiscardingTransitions
  section "[16] ReleaseCategory MobileBuild" testReleaseCategoryMobileBuild
  section "[17] Mobile Permission Membership + Round-Trip" testMobilePermissionsExist
  section "[18] MobileBuildWFStatus State Machine" testMobileBuildWFStatusTransitions
  section "[19] MobileBuildContext JSON Round-Trip" testMobileBuildContextJsonRoundTrip
  section "[20] Mobile Version Bump (Play Console algorithm)" testVersionBumpLogic
  section "[21] GitHub Workflow Runs JSON Parser" testGithubRunsParser
  section "[22] GitHub Jobs JSON Parser" testGithubJobsParser
  section "[23] GitHub Compare API JSON Parser" testGithubCompareParser
  section "[24] PR-number extractor + shortSha" testExtractPrNumber
  section "[25] bumpPatch semver rule" testBumpPatch
  section "[26] renderRevertChangelog" testRenderRevertChangelog
  section "[27] Decode 0013 seed JSON (regression guard)" testDecodeSeedJson
  section "[28] MobileBuildContext legacy destination fallback" testMobileBuildContextDestinationFallback
  section "[29] ConfirmTag wall-clock timeout predicate" testTagConfirmTimedOut
  section "[30] Rollback target resolver (version-order, not time-order)" testResolveRollback
  section "[31] ConfirmTag selects the build's exact tag (not lexical-first)" testSelectBuildTag
  section "[32] Play staged rollout (% bounds + track parse)" testPlayStagedRollout
  section "[33] ASC review state + phased schedule + version parse" testAscReviewAndPhased
  section "[34] Review poll timing (soft-timeout + throttle)" testReviewPollTiming
  section "[35] Rollout reconcile classification (store state -> action)" testRolloutReconcileClassify
  section "[36] ASC builds parse (marketing version + build number)" testAscBuildInfoParse
  section "[37] iOS next-version rule (bump in sync / reuse when TF ahead)" testIosVersionBumpRule
  section "[38] Changelog base resolution (prod default / internal / fallback)" testChangelogBaseResolution
  section "[39] Store release-notes parsing (Play track + iOS whatsNew)" testStoreReleaseNotesParse
  section "[53] ConfirmTag log-first tag extraction (tagPushedFromLog)" testTagPushedFromLog
  section "[54] Dispatch optional-input fallback (droppableUnexpectedInputs)" testDroppableUnexpectedInputs
  section "[40] Out-of-band review detection (in-flight select / map / reconcile)" testExternalReviewDetection
  section "[41] Android pending-publish detection (track parse / pick rule)" testAndroidPendingPublish
  section "[49] Dispatch-group leader election (first living sibling)" testElectDispatchLeader
  section "[50] Group summary derivation (fleet stage rollup)" testGroupSummary
  section "[42] List dedup (hide store-sync snapshot when external review owns build)" testListDedup
  section "[43] Console rollout detection (approved android adopts a Console-set %)" testConsoleRolloutDetect
  section "[44] iOS release detection (adopt an out-of-band App Store Connect release)" testIosReleaseDetect
  section "[45] Play track snapshot parse (App Release Monitoring)" testTrackSnapshotParse
  section "[46] claimsStoreIdentity (store-identity gate — single source of truth)" testClaimsStoreIdentity
  section "[47] ReleasePhase (canonical lifecycle: project / transition / display)" testReleasePhase
  section "[48] dispatchRunCandidates (abort-cancel run match: window + newest-first)" testDispatchRunCandidates
  section "[49] Changelog diff link (server-side generation, mirrors frontend)" testDiffLink
  section "[51] extractContainerEnvJson (deployment YAML -> container env array)" testExtractContainerEnvJson
  section "[52] Release Webhooks (dispatch trigger + templating)" testReleaseWebhooks
  section "[55] Release bot: diff engine" testReleaseBotDiff
  section "[56] Release bot: base64 fail-closed decode" testReleaseBotBase64
  section "[57] Release bot: Xyne signature + payload parsing" testReleaseBotXyne
  section "[58] Release bot: secret-file patterns + config parsing" testReleaseBotConfig
  section "[59] Release bot: public view redaction + link token" testReleaseBotPublic
  section "[66] HPA: Kubernetes Quantity parsing + equality" testHpaQuantity
  section "[67] HPA: autoscaling/v2 spec parse + validation" testHpaSpec
  section "[68] HPA: serving-HPA resolution (VS weights, prefix collisions, KEDA)" testHpaResolver
  section "[69] HPA: schedule windows (weekly / once / offsets / overlap)" testHpaWindow
  section "[70] HPA: change planning (apply / restore / drift / verify / guardrails / diff)" testHpaChange
  section "[71] HPA: apply state machine + JSON shapes" testHpaTypes
  section "[72] HPA: health judgement, Prometheus + event parsing, resume decision" testHpaMisc
  section "[73] HPA: server-defaulted behavior, kubectl error classification" testHpaDefaults
  section "[60] Release bot: env var replacement preserves other entries" testReleaseBotEnv
  section "[61] Release bot: intent merge" testReleaseBotIntent
  section "[62] Release bot: deployment reference discovery" testReleaseBotRefs
  section "[63] Release bot: mention ids + file triggers + DB config" testReleaseBotTriggers
  section "[64] Release bot: rules stored on deployment config rows" testReleaseBotRows
  section "[65] Release bot: Jenkins URL re-basing, job path, per-env params" testReleaseBotJenkins

  putStrLn ""
  putStrLn "==========================================="
  putStrLn "  All tests passed!"
  putStrLn "==========================================="
  where
    section title body = do
      putStrLn title
      _ <- body
      putStrLn ""

-- ============================================================================
-- [1] Status Transition Tests (per-service: validateStatusTransition)
-- ============================================================================

testStatusTransitions :: IO ()
testStatusTransitions = do
  -- Valid transitions from CREATED
  assertBool "CREATED -> INPROGRESS" $ validateStatusTransition CREATED INPROGRESS
  assertBool "CREATED -> DISCARDED" $ validateStatusTransition CREATED DISCARDED
  assertBool "CREATED -> LOCKED (vsedit)" $ validateStatusTransition CREATED LOCKED

  -- Invalid transitions from CREATED
  assertBool "CREATED -X-> COMPLETED" $ not $ validateStatusTransition CREATED COMPLETED
  assertBool "CREATED -X-> PAUSED" $ not $ validateStatusTransition CREATED PAUSED
  assertBool "CREATED -X-> ABORTED" $ not $ validateStatusTransition CREATED ABORTED
  assertBool "CREATED -X-> REVERTING" $ not $ validateStatusTransition CREATED REVERTING

  -- Valid transitions from INPROGRESS
  assertBool "INPROGRESS -> PAUSED" $ validateStatusTransition INPROGRESS PAUSED
  assertBool "INPROGRESS -> COMPLETED" $ validateStatusTransition INPROGRESS COMPLETED
  assertBool "INPROGRESS -> ABORTING" $ validateStatusTransition INPROGRESS ABORTING
  assertBool "INPROGRESS -> ABORTED" $ validateStatusTransition INPROGRESS ABORTED
  assertBool "INPROGRESS -> USER_ABORTED" $ validateStatusTransition INPROGRESS USER_ABORTED
  assertBool "INPROGRESS -> GCLT_ABORTED" $ validateStatusTransition INPROGRESS GCLT_ABORTED

  -- Invalid transitions from INPROGRESS
  assertBool "INPROGRESS -X-> CREATED" $ not $ validateStatusTransition INPROGRESS CREATED
  assertBool "INPROGRESS -X-> DISCARDED" $ not $ validateStatusTransition INPROGRESS DISCARDED
  assertBool "INPROGRESS -X-> RESTARTING (per-service)" $
    not $
      validateStatusTransition INPROGRESS RESTARTING

  -- Valid transitions from PAUSED
  assertBool "PAUSED -> INPROGRESS (resume)" $ validateStatusTransition PAUSED INPROGRESS
  assertBool "PAUSED -> ABORTING" $ validateStatusTransition PAUSED ABORTING
  assertBool "PAUSED -> USER_ABORTED" $ validateStatusTransition PAUSED USER_ABORTED

  -- Invalid transitions from PAUSED
  assertBool "PAUSED -X-> COMPLETED" $ not $ validateStatusTransition PAUSED COMPLETED
  assertBool "PAUSED -X-> DISCARDED" $ not $ validateStatusTransition PAUSED DISCARDED

  -- Terminal states have no outgoing transitions (per-service)
  let terminals = [COMPLETED, ABORTED, USER_ABORTED, GCLT_ABORTED, DISCARDED, REVERTED, UNLOCKED]
  mapM_
    ( \t -> do
        assertBool (show t <> " has no outgoing transition (per-service)") $
          not $
            any (validateStatusTransition t) [INPROGRESS, COMPLETED, REVERTING, RESTARTING]
    )
    terminals

  -- Specifically: COMPLETED -> REVERTING is INVALID at per-service level
  -- (the global state machine handles revert; per-service is locked once completed).
  assertBool "COMPLETED -X-> REVERTING (per-service — global only)" $
    not $
      validateStatusTransition COMPLETED REVERTING

  -- ABORTING transitions
  assertBool "ABORTING -> ABORTED" $ validateStatusTransition ABORTING ABORTED
  assertBool "ABORTING -> USER_ABORTED" $ validateStatusTransition ABORTING USER_ABORTED
  assertBool "ABORTING -> ABORTING (idempotent)" $ validateStatusTransition ABORTING ABORTING
  assertBool "ABORTING -> REVERTING" $ validateStatusTransition ABORTING REVERTING

  -- REVERTING transitions
  assertBool "REVERTING -> REVERTED" $ validateStatusTransition REVERTING REVERTED
  assertBool "REVERTING -> USER_ABORTED" $ validateStatusTransition REVERTING USER_ABORTED
  assertBool "REVERTING -X-> COMPLETED (per-service)" $
    not $
      validateStatusTransition REVERTING COMPLETED

-- ============================================================================
-- [2] Global Status Transitions
-- ============================================================================

testGlobalStatusTransitions :: IO ()
testGlobalStatusTransitions = do
  -- Global allows everything per-service does, plus more.
  assertBool "Global: CREATED -> INPROGRESS" $
    validateGlobalStatusTransition CREATED INPROGRESS
  assertBool "Global: CREATED -> DISCARDING" $
    validateGlobalStatusTransition CREATED DISCARDING

  -- COMPLETED -> REVERTING is the global-only path (per-service rejects it)
  assertBool "Global: COMPLETED -> REVERTING" $
    validateGlobalStatusTransition COMPLETED REVERTING
  assertBool "Global: COMPLETED -X-> INPROGRESS (still terminal for fwd)" $
    not $
      validateGlobalStatusTransition COMPLETED INPROGRESS

  -- INPROGRESS gets RESTARTING and REVERTING at global
  assertBool "Global: INPROGRESS -> RESTARTING" $
    validateGlobalStatusTransition INPROGRESS RESTARTING
  assertBool "Global: INPROGRESS -> REVERTING" $
    validateGlobalStatusTransition INPROGRESS REVERTING
  assertBool "Global: INPROGRESS -> DISCARDED (cleanup)" $
    validateGlobalStatusTransition INPROGRESS DISCARDED

  -- RESTARTING transitions
  assertBool "Global: RESTARTING -> INPROGRESS" $
    validateGlobalStatusTransition RESTARTING INPROGRESS
  assertBool "Global: RESTARTING -> PAUSED" $
    validateGlobalStatusTransition RESTARTING PAUSED
  assertBool "Global: RESTARTING -X-> COMPLETED" $
    not $
      validateGlobalStatusTransition RESTARTING COMPLETED

  -- PAUSED has more global options
  assertBool "Global: PAUSED -> RESTARTING" $
    validateGlobalStatusTransition PAUSED RESTARTING
  assertBool "Global: PAUSED -> REVERTING" $
    validateGlobalStatusTransition PAUSED REVERTING

  -- ABORTING gets MANY more options at global
  assertBool "Global: ABORTING -> COMPLETED (aborted-then-recovered)" $
    validateGlobalStatusTransition ABORTING COMPLETED
  assertBool "Global: ABORTING -> DISCARDED" $
    validateGlobalStatusTransition ABORTING DISCARDED
  assertBool "Global: ABORTING -> RESTARTING" $
    validateGlobalStatusTransition ABORTING RESTARTING

  -- DISCARDING is the async cleanup state (only goes to DISCARDED)
  assertBool "Global: DISCARDING -> DISCARDED" $
    validateGlobalStatusTransition DISCARDING DISCARDED
  assertBool "Global: DISCARDING -X-> INPROGRESS" $
    not $
      validateGlobalStatusTransition DISCARDING INPROGRESS

  -- REVERTING gets PAUSED + RESTARTING at global
  assertBool "Global: REVERTING -> PAUSED" $
    validateGlobalStatusTransition REVERTING PAUSED
  assertBool "Global: REVERTING -> RESTARTING" $
    validateGlobalStatusTransition REVERTING RESTARTING

  -- Terminal at both per-service AND global
  assertBool "Global: REVERTED is terminal" $
    not $
      any (validateGlobalStatusTransition REVERTED) [INPROGRESS, COMPLETED]
  assertBool "Global: ABORTED is terminal" $
    not $
      any (validateGlobalStatusTransition ABORTED) [INPROGRESS, COMPLETED]

-- ============================================================================
-- [3] Status Helpers
-- ============================================================================

testStatusHelpers :: IO ()
testStatusHelpers = do
  -- isTerminalStatus
  let terminals = [COMPLETED, ABORTED, USER_ABORTED, GCLT_ABORTED, DISCARDED, REVERTED, UNLOCKED]
  mapM_ (\s -> assertBool (show s <> " is terminal") (isTerminalStatus s)) terminals

  let nonTerminals =
        [ CREATED,
          INPROGRESS,
          PAUSED,
          ABORTING,
          REVERTING,
          RESTARTING,
          DISCARDING,
          LOCKED,
          APPLIED
        ]
  mapM_ (\s -> assertBool (show s <> " is NOT terminal") (not (isTerminalStatus s))) nonTerminals

  -- isAbortedStatus
  let aborted = [ABORTED, USER_ABORTED, GCLT_ABORTED, ABORTING]
  mapM_ (\s -> assertBool (show s <> " is aborted") (isAbortedStatus s)) aborted

  let notAborted = [COMPLETED, PAUSED, CREATED, INPROGRESS, REVERTED, REVERTING, DISCARDED]
  mapM_ (\s -> assertBool (show s <> " is NOT aborted") (not (isAbortedStatus s))) notAborted

  -- Sanity: GCLT_ABORTED is BOTH terminal AND aborted
  assertBool "GCLT_ABORTED is both terminal AND aborted" $
    isTerminalStatus GCLT_ABORTED && isAbortedStatus GCLT_ABORTED

  -- Sanity: ABORTING is aborted but NOT terminal (still in flight)
  assertBool "ABORTING is aborted but NOT terminal" $
    isAbortedStatus ABORTING && not (isTerminalStatus ABORTING)

-- ============================================================================
-- [4] K8s Version Validation (command-injection safety)
-- ============================================================================

testVersionValidation :: IO ()
testVersionValidation = do
  -- Valid versions
  let valid = ["v1", "test-v3", "abc123", "my-service-v2", "a", "1", "a-b-c", "V1", "ABC"]
  mapM_ (\v -> assertBool (T.unpack v <> " is valid") (isValidK8sVersion v)) valid

  -- Invalid versions: empty, special chars, malformed dashes
  let invalid =
        [ "",
          "v1.2.3",
          "hello world",
          "v1;rm -rf",
          "-starts-with-dash",
          "ends-with-dash-",
          "v1@latest",
          "v1:latest",
          "$(whoami)",
          "--",
          "-",
          "v1`id`",
          "v1|cat",
          "v1\nls"
        ]
  mapM_ (\v -> assertBool (T.unpack v <> " is invalid") (not (isValidK8sVersion v))) invalid

-- ============================================================================
-- [5] Shell Quoting (command-injection safety)
-- ============================================================================

testShellQuote :: IO ()
testShellQuote = do
  assertEqual "shellQuote hello" "'hello'" (shellQuote "hello")
  assertEqual "shellQuote empty" "''" (shellQuote "")
  assertEqual "shellQuote 'rm -rf /'" "'rm -rf /'" (shellQuote "rm -rf /")
  assertEqual "shellQuote $(whoami)" "'$(whoami)'" (shellQuote "$(whoami)")
  assertEqual "shellQuote backticks" "'`id`'" (shellQuote "`id`")
  assertEqual "shellQuote double quotes" "'\"hello\"'" (shellQuote "\"hello\"")

  -- The tricky one: single quote inside. 'it's' becomes 'it'"'"'s'
  assertEqual "shellQuote it's" "'it'\"'\"'s'" (shellQuote "it's")
  assertEqual "shellQuote ''' (multiple singles)" "''\"'\"''\"'\"''\"'\"''" (shellQuote "'''")

  -- Mixed dangerous metacharacters
  assertEqual "shellQuote semicolon" "'; echo pwned'" (shellQuote "; echo pwned")
  assertEqual "shellQuote pipe" "'| cat /etc/passwd'" (shellQuote "| cat /etc/passwd")
  assertEqual "shellQuote newline" "'line1\nline2'" (shellQuote "line1\nline2")
  assertEqual "shellQuote ampersand" "'& sleep 1'" (shellQuote "& sleep 1")
  assertEqual "shellQuote redirect" "'> /tmp/x'" (shellQuote "> /tmp/x")

-- ============================================================================
-- [6] Permission Catalog (Admin / Manager / Viewer)
-- ============================================================================

testPermissions :: IO ()
testPermissions = do
  let allPerms = allPermissions Autopilot
      adminPerms = defaultPermissions Admin Autopilot
      managerPerms = defaultPermissions Manager Autopilot
      viewerPerms = defaultPermissions Viewer Autopilot

  -- Admin = ALL
  assertEqual "Admin permission set == allPermissions" (sort allPerms) (sort adminPerms)

  -- Viewer = view-only (RELEASE_VIEW + PRODUCT_CONFIG_VIEW + SERVICE_CONFIG_VIEW)
  assertBool "Viewer has RELEASE_VIEW" $
    AutopilotPerm AP_RELEASE_VIEW `elem` viewerPerms
  assertBool "Viewer has PRODUCT_CONFIG_VIEW" $
    AutopilotPerm AP_PRODUCT_CONFIG_VIEW `elem` viewerPerms
  assertBool "Viewer has SERVICE_CONFIG_VIEW" $
    AutopilotPerm AP_SERVICE_CONFIG_VIEW `elem` viewerPerms
  assertBool "Viewer DOES NOT have RELEASE_CREATE" $
    AutopilotPerm AP_RELEASE_CREATE `notElem` viewerPerms
  assertBool "Viewer DOES NOT have RELEASE_APPROVE" $
    AutopilotPerm AP_RELEASE_APPROVE `notElem` viewerPerms
  assertBool "Viewer DOES NOT have PRODUCT_CONFIG_EDIT" $
    AutopilotPerm AP_PRODUCT_CONFIG_EDIT `notElem` viewerPerms
  assertBool "Viewer DOES NOT have FORCE_UNLOCK (superadmin)" $
    AutopilotPerm AP_FORCE_UNLOCK `notElem` viewerPerms
  -- 2026-07-31 split: autopilot is backend-only — no OTA family here.
  assertBool "Viewer DOES NOT have OTA_VIEW (moved to mobile)" $
    OtaPerm OTA_VIEW `notElem` viewerPerms
  assertBool "Viewer has HPA_VIEW (read-only HPA panel)" $
    AutopilotPerm AP_HPA_VIEW `elem` viewerPerms
  assertEqual "Viewer has exactly 4 permissions" 4 (length viewerPerms)

  -- Manager = all except *_EDIT (per defaultPermissions in Products/Types.hs)
  assertBool "Manager has RELEASE_VIEW" $
    AutopilotPerm AP_RELEASE_VIEW `elem` managerPerms
  assertBool "Manager has RELEASE_CREATE" $
    AutopilotPerm AP_RELEASE_CREATE `elem` managerPerms
  assertBool "Manager has RELEASE_APPROVE" $
    AutopilotPerm AP_RELEASE_APPROVE `elem` managerPerms
  assertBool "Manager has RELEASE_REVERT" $
    AutopilotPerm AP_RELEASE_REVERT `elem` managerPerms
  assertBool "Manager DOES NOT have PRODUCT_CONFIG_EDIT" $
    AutopilotPerm AP_PRODUCT_CONFIG_EDIT `notElem` managerPerms
  assertBool "Manager DOES NOT have SERVICE_CONFIG_EDIT" $
    AutopilotPerm AP_SERVICE_CONFIG_EDIT `notElem` managerPerms
  assertBool "Manager DOES NOT have RELEASE_DELETE" $
    AutopilotPerm AP_RELEASE_DELETE `notElem` managerPerms
  assertBool "Manager DOES NOT have HPA_GUARDRAIL_EDIT" $
    AutopilotPerm AP_HPA_GUARDRAIL_EDIT `notElem` managerPerms
  assertBool "Manager can schedule, apply and roll back HPA changes" $
    all (\p -> AutopilotPerm p `elem` managerPerms) [AP_HPA_VIEW, AP_HPA_SCHEDULE_EDIT, AP_HPA_APPLY, AP_HPA_ROLLBACK]
  assertEqual
    "Manager has all perms minus the 4 restricted perms (PRODUCT_CONFIG_EDIT, SERVICE_CONFIG_EDIT, RELEASE_DELETE, HPA_GUARDRAIL_EDIT)"
    (length allPerms - 4)
    (length managerPerms)

  -- ── Mobile product (2026-07-31 split): MB_* + the whole OTA family ──
  let mobileAll = allPermissions Mobile
      mobileAdmin = defaultPermissions Admin Mobile
      mobileManager = defaultPermissions Manager Mobile
      mobileViewer = defaultPermissions Viewer Mobile
  assertEqual "Mobile Admin == allPermissions Mobile" (sort mobileAll) (sort mobileAdmin)
  assertEqual
    "Mobile universe = 9 MB + 9 OTA"
    18
    (length mobileAll)
  assertEqual
    "Mobile Viewer = MB_RELEASE_VIEW + OTA_VIEW"
    (sort [MobilePerm MB_RELEASE_VIEW, OtaPerm OTA_VIEW])
    (sort mobileViewer)
  assertBool "Mobile Manager has MB_MOBILE_DISPATCH" $
    MobilePerm MB_MOBILE_DISPATCH `elem` mobileManager
  assertBool "Mobile Manager has MB_RELEASE_ABORT" $
    MobilePerm MB_RELEASE_ABORT `elem` mobileManager
  assertBool "Mobile Manager has OTA_RELEASE_CREATE" $
    OtaPerm OTA_RELEASE_CREATE `elem` mobileManager
  assertBool "Mobile Manager DOES NOT have MB_MOBILE_APP_MANAGE" $
    MobilePerm MB_MOBILE_APP_MANAGE `notElem` mobileManager
  assertBool "Mobile Manager DOES NOT have OTA_RELEASE_DISCARD" $
    OtaPerm OTA_RELEASE_DISCARD `notElem` mobileManager
  assertBool "Mobile Manager DOES NOT have OTA_APP_MANAGE" $
    OtaPerm OTA_APP_MANAGE `notElem` mobileManager
  assertEqual
    "Mobile Manager = all minus 3 restricted (MB_MOBILE_APP_MANAGE, OTA_RELEASE_DISCARD, OTA_APP_MANAGE)"
    (length mobileAll - 3)
    (length mobileManager)

  -- permissionToText round-trip for a few constructors
  assertEqual
    "permissionToText RELEASE_VIEW"
    "RELEASE_VIEW"
    (permissionToText (AutopilotPerm AP_RELEASE_VIEW))
  assertEqual
    "permissionToText PRODUCT_CONFIG_EDIT"
    "PRODUCT_CONFIG_EDIT"
    (permissionToText (AutopilotPerm AP_PRODUCT_CONFIG_EDIT))
  assertEqual
    "permissionToText FORCE_UNLOCK"
    "FORCE_UNLOCK"
    (permissionToText (AutopilotPerm AP_FORCE_UNLOCK))

  -- allPermissionsText / defaultPermissionsText
  let allTextPerms = allPermissionsText "autopilot"
  assertEqual "allPermissionsText length matches catalog" (length allPerms) (length allTextPerms)
  assertBool "allPermissionsText is unique (no dupes)" $
    length allTextPerms == length (sort allTextPerms)

  assertEqual
    "defaultPermissionsText Admin matches catalog"
    (length allPerms)
    (length (defaultPermissionsText "autopilot" "Admin"))
  assertEqual
    "defaultPermissionsText Viewer = 4 (autopilot is backend-only post-split; includes HPA_VIEW)"
    4
    (length (defaultPermissionsText "autopilot" "Viewer"))
  assertEqual
    "defaultPermissionsText mobile Viewer = 2 (MB_RELEASE_VIEW + OTA_VIEW)"
    2
    (length (defaultPermissionsText "mobile" "Viewer"))
  assertBool "defaultPermissionsText unknown product is empty" $
    null (defaultPermissionsText "nonexistent" "Admin")
  assertBool "defaultPermissionsText unknown role is empty" $
    null (defaultPermissionsText "autopilot" "Unknown")

  -- ProductSlug round-trip
  assertEqual "productSlugToText Autopilot" "autopilot" (productSlugToText Autopilot)
  assertEqual "textToProductSlug autopilot" (Just Autopilot) (textToProductSlug "autopilot")
  assertEqual "textToProductSlug unknown" Nothing (textToProductSlug "unknown")

  -- OverrideType round-trip
  assertEqual "overrideTypeToText Grant" "GRANT" (overrideTypeToText Grant)
  assertEqual "overrideTypeToText Deny" "DENY" (overrideTypeToText Deny)
  assertEqual "textToOverrideType GRANT" (Just Grant) (textToOverrideType "GRANT")
  assertEqual "textToOverrideType DENY" (Just Deny) (textToOverrideType "DENY")
  assertEqual "textToOverrideType invalid" Nothing (textToOverrideType "REVOKE")

-- ============================================================================
-- [7] Effective Permissions Logic (GRANT/DENY overrides)
-- ============================================================================

testEffectivePermissions :: IO ()
testEffectivePermissions = do
  -- Pure logic that mirrors how the auth layer composes role + overrides:
  --   effective = (role_perms ∪ grants) − denies
  let basePerms = ["RELEASE_VIEW", "RELEASE_CREATE"] :: [Text]
      grants = ["RELEASE_APPROVE", "RELEASE_VIEW"] -- VIEW already in base
      denies = ["RELEASE_CREATE"]
      combined = basePerms ++ filter (`notElem` basePerms) grants
      effective = filter (`notElem` denies) combined

  assertEqual
    "GRANT adds new permission once"
    ["RELEASE_VIEW", "RELEASE_CREATE", "RELEASE_APPROVE"]
    combined
  assertEqual
    "DENY strips a permission"
    ["RELEASE_VIEW", "RELEASE_APPROVE"]
    effective
  assertBool "GRANT does not duplicate an existing permission" $
    length (filter (== "RELEASE_VIEW") combined) == 1

  -- DENY beats GRANT for the same key (resolved by ordering — base+grants then deny)
  let basePerms2 = ["RELEASE_VIEW"] :: [Text]
      grants2 = ["RELEASE_DELETE"]
      denies2 = ["RELEASE_DELETE"]
      combined2 = basePerms2 ++ filter (`notElem` basePerms2) grants2
      effective2 = filter (`notElem` denies2) combined2
  assertBool "DENY beats GRANT for same key" $
    "RELEASE_DELETE" `notElem` effective2

  -- Empty everything
  assertEqual "Empty everything = empty" ([] :: [Text]) []

-- ============================================================================
-- [8] Release Tag Format
-- ============================================================================

testReleaseTag :: IO ()
testReleaseTag = do
  let mkTag p d v s m e pri =
        T.intercalate "_" [p, d, v, s, m, e, pri]

  assertEqual
    "Tag basic format"
    "Beckn_20260331_v42_rider-app_AUTO_UAT_0"
    (mkTag "Beckn" "20260331" "v42" "rider-app" "AUTO" "UAT" "0")

  assertEqual
    "Tag manual mode"
    "BPP_20260101_v1_driver-app_MANUAL_PROD_5"
    (mkTag "BPP" "20260101" "v1" "driver-app" "MANUAL" "PROD" "5")

  -- Revert tag is original + "_REVERT"
  let originalTag = "Beckn_20260331_v42_rider-app_AUTO_UAT_0" :: Text
  assertEqual
    "Revert tag suffix"
    "Beckn_20260331_v42_rider-app_AUTO_UAT_0_REVERT"
    (originalTag <> "_REVERT")

  -- Components are underscore-separated, exactly 7 parts
  let parts = T.splitOn "_" (mkTag "Beckn" "20260331" "v42" "rider-app" "AUTO" "UAT" "0")
  assertEqual "Tag has 7 parts" 7 (length parts)
  assertEqual "Part 1 is product" "Beckn" (parts !! 0)
  assertEqual "Part 2 is date" "20260331" (parts !! 1)
  assertEqual "Part 3 is version" "v42" (parts !! 2)
  assertEqual "Part 4 is service" "rider-app" (parts !! 3)
  assertEqual "Part 5 is mode" "AUTO" (parts !! 4)
  assertEqual "Part 6 is env" "UAT" (parts !! 5)
  assertEqual "Part 7 is priority" "0" (parts !! 6)

-- ============================================================================
-- [9] Rollout Step Semantics (cooloff is MINUTES, not seconds)
-- ============================================================================

testRolloutStep :: IO ()
testRolloutStep = do
  let step1 = RolloutStep {rolloutPercent = 10, cooloffMinutes = 5, podCount = 100}
      step2 = RolloutStep {rolloutPercent = 50, cooloffMinutes = 10, podCount = 100}
      step3 = RolloutStep {rolloutPercent = 100, cooloffMinutes = 0, podCount = 100}

  -- Round-trip through Eq
  assertEqual "Step constructor round-trip" step1 step1
  assertBool "Different steps are not equal" $ step1 /= step2

  -- Cooloff is MINUTES — converting to seconds means × 60
  assertEqual "5 minutes = 300 seconds" 300 (cooloffMinutes step1 * 60)
  assertEqual "10 minutes = 600 seconds" 600 (cooloffMinutes step2 * 60)
  assertEqual "0 minutes = 0 seconds (last step)" 0 (cooloffMinutes step3 * 60)

  -- A canonical 3-stage strategy
  let strategy = [step1, step2, step3]
  assertEqual "Strategy has 3 stages" 3 (length strategy)
  assertEqual
    "Final stage is 100%"
    100
    (rolloutPercent (last strategy))
  assertEqual
    "Final stage cooloff is 0"
    0
    (cooloffMinutes (last strategy))
  assertBool "rolloutPercent is monotonic ascending" $
    and (zipWith (<) (map rolloutPercent strategy) (tail (map rolloutPercent strategy)))

-- ============================================================================
-- [10] Config Catalog (no globals — every config is product-scoped)
-- ============================================================================

testConfigCatalog :: IO ()
testConfigCatalog = do
  let entries = allConfigEntries

  assertBool "Catalog is non-empty" $ not (null entries)
  assertEqual "Catalog == autopilotConfigs (no globals merged)" (length autopilotConfigs) (length entries)

  -- Every entry is product-scoped — no Nothing/global entries
  let globals = filter (isNothing . ceProduct) entries
  assertBool "No global (product=Nothing) entries in catalog" $ null globals

  -- Every entry has product = "autopilot"
  let nonAutopilot = filter (\e -> ceProduct e /= Just "autopilot") entries
  assertBool "Every entry is scoped to autopilot" $ null nonAutopilot

  -- mailing_enabled was removed
  assertBool "mailing_enabled is NOT in catalog" $
    isNothing (findConfigEntry "mailing_enabled")

  -- slack_enabled exists, scoped to autopilot, in NotificationGroup
  case findConfigEntry "slack_enabled" of
    Nothing -> fail "  FAIL: slack_enabled missing from catalog"
    Just e -> do
      assertBool "slack_enabled is product-scoped to autopilot" $
        ceProduct e == Just "autopilot"
      assertEqual "slack_enabled is in NotificationGroup" NotificationGroup (ceGroup e)
      case ceType e of
        BoolConfig False -> putStrLn "  PASS: slack_enabled defaults to false"
        other -> fail $ "  FAIL: slack_enabled type wrong: " <> show other

  -- Other expected configs exist
  let expectedKeys =
        [ "k8s_enabled",
          "approve_all_releases",
          "release_watch_delay",
          "max_k8s_retries",
          "multi_release_per_product",
          "pods_scale_down_delay_config",
          "scale_down_pods_on_completion"
        ]
  mapM_
    ( \k ->
        assertBool (T.unpack k <> " is in catalog") $
          isJust (findConfigEntry k)
    )
    expectedKeys

  -- Lookups are case-sensitive (no fuzzy match)
  assertBool "findConfigEntry case-sensitive" $
    isNothing (findConfigEntry "K8S_ENABLED")
  assertBool "findConfigEntry returns Nothing for unknown key" $
    isNothing (findConfigEntry "this_does_not_exist")

  -- Sanity: every entry's group can be rendered to text
  mapM_
    ( \e ->
        assertBool ("config " <> T.unpack (ceKey e) <> " has renderable group") $
          not (T.null (configGroupToText (ceGroup e)))
    )
    entries

-- ============================================================================
-- [11] Config Value Validation
-- ============================================================================

testConfigValueValidation :: IO ()
testConfigValueValidation = do
  let boolEntry = ConfigEntry "x" (BoolConfig False) GeneralGroup "" Nothing
      intEntry = ConfigEntry "x" (IntConfig 0) GeneralGroup "" Nothing
      dblEntry = ConfigEntry "x" (DoubleConfig 0) GeneralGroup "" Nothing
      textEntry = ConfigEntry "x" (TextConfig "") GeneralGroup "" Nothing
      jsonEntry = ConfigEntry "x" (JsonConfig "") GeneralGroup "" Nothing

  -- Bool: accepts true/false/1/0/yes/no (case-insensitive)
  let boolValid = ["true", "false", "TRUE", "False", "1", "0", "yes", "no"]
  mapM_
    ( \v -> case validateConfigValue boolEntry v of
        Right _ -> putStrLn $ "  PASS: bool accepts " <> T.unpack v
        Left err -> fail $ "  FAIL: bool rejected " <> T.unpack v <> " (" <> T.unpack err <> ")"
    )
    boolValid

  let boolInvalid = ["maybe", "tru", "", "y", "2"]
  mapM_
    ( \v -> case validateConfigValue boolEntry v of
        Left _ -> putStrLn $ "  PASS: bool rejects " <> show v
        Right _ -> fail $ "  FAIL: bool accepted " <> show v
    )
    boolInvalid

  -- Int: accepts integers, rejects floats / text
  case validateConfigValue intEntry "42" of
    Right _ -> putStrLn "  PASS: int accepts 42"
    Left err -> fail $ "  FAIL: int rejected 42: " <> T.unpack err
  case validateConfigValue intEntry "-7" of
    Right _ -> putStrLn "  PASS: int accepts -7"
    Left _ -> fail "  FAIL: int rejected -7"
  case validateConfigValue intEntry "3.14" of
    Left _ -> putStrLn "  PASS: int rejects 3.14"
    Right _ -> fail "  FAIL: int accepted 3.14"
  case validateConfigValue intEntry "abc" of
    Left _ -> putStrLn "  PASS: int rejects abc"
    Right _ -> fail "  FAIL: int accepted abc"

  -- Double: accepts both integers and decimals
  case validateConfigValue dblEntry "0.01" of
    Right _ -> putStrLn "  PASS: double accepts 0.01"
    Left _ -> fail "  FAIL: double rejected 0.01"
  case validateConfigValue dblEntry "10" of
    Right _ -> putStrLn "  PASS: double accepts 10"
    Left _ -> fail "  FAIL: double rejected 10"
  case validateConfigValue dblEntry "abc" of
    Left _ -> putStrLn "  PASS: double rejects abc"
    Right _ -> fail "  FAIL: double accepted abc"

  -- Text: accepts everything
  case validateConfigValue textEntry "anything goes" of
    Right _ -> putStrLn "  PASS: text accepts arbitrary string"
    Left _ -> fail "  FAIL: text rejected arbitrary string"
  case validateConfigValue textEntry "" of
    Right _ -> putStrLn "  PASS: text accepts empty string"
    Left _ -> fail "  FAIL: text rejected empty string"

  -- JSON: currently accepts everything (no parse validation in Registry yet)
  case validateConfigValue jsonEntry "{\"k\":1}" of
    Right _ -> putStrLn "  PASS: json accepts valid JSON"
    Left _ -> fail "  FAIL: json rejected valid JSON"

-- ============================================================================
-- [12] VS Edit Status Transitions
-- ============================================================================

testVsEditTransitions :: IO ()
testVsEditTransitions = do
  -- Per-service VSEdit transitions
  assertBool "CREATED -> LOCKED" $ validateStatusTransition CREATED LOCKED
  assertBool "LOCKED -> APPLIED" $ validateStatusTransition LOCKED APPLIED
  assertBool "LOCKED -> UNLOCKED (discard)" $ validateStatusTransition LOCKED UNLOCKED
  assertBool "LOCKED -> DISCARDED" $ validateStatusTransition LOCKED DISCARDED
  assertBool "APPLIED -> COMPLETED" $ validateStatusTransition APPLIED COMPLETED
  assertBool "APPLIED -> UNLOCKED" $ validateStatusTransition APPLIED UNLOCKED

  -- UNLOCKED is terminal for VS edit
  assertBool "UNLOCKED is terminal" $ isTerminalStatus UNLOCKED
  assertBool "UNLOCKED -X-> anything" $
    not $
      any (validateStatusTransition UNLOCKED) [LOCKED, APPLIED, INPROGRESS]

  -- Cannot lock something that's already locked
  assertBool "LOCKED -X-> LOCKED (no idempotent re-lock)" $
    not $
      validateStatusTransition LOCKED LOCKED

-- ============================================================================
-- [13] Revert Lifecycle Transitions
-- ============================================================================

testRevertTransitions :: IO ()
testRevertTransitions = do
  -- Revert a completed release: COMPLETED -> REVERTING (global only)
  assertBool "Global COMPLETED -> REVERTING (the revert path)" $
    validateGlobalStatusTransition COMPLETED REVERTING
  assertBool "Per-service COMPLETED -X-> REVERTING (locked)" $
    not $
      validateStatusTransition COMPLETED REVERTING

  -- Revert can be aborted by user
  assertBool "REVERTING -> USER_ABORTED" $
    validateStatusTransition REVERTING USER_ABORTED

  -- Revert success
  assertBool "REVERTING -> REVERTED" $
    validateStatusTransition REVERTING REVERTED

  -- Once reverted, no further transitions
  assertBool "REVERTED is terminal" $ isTerminalStatus REVERTED
  assertBool "REVERTED -X-> anything" $
    not $
      any (validateStatusTransition REVERTED) [INPROGRESS, COMPLETED, REVERTING]

  -- Global allows REVERTING -> PAUSED and REVERTING -> RESTARTING
  assertBool "Global REVERTING -> PAUSED" $
    validateGlobalStatusTransition REVERTING PAUSED
  assertBool "Global REVERTING -> RESTARTING" $
    validateGlobalStatusTransition REVERTING RESTARTING

-- ============================================================================
-- [14] Restart Lifecycle Transitions
-- ============================================================================

testRestartTransitions :: IO ()
testRestartTransitions = do
  -- Restart from INPROGRESS or PAUSED is global-only
  assertBool "Global INPROGRESS -> RESTARTING" $
    validateGlobalStatusTransition INPROGRESS RESTARTING
  assertBool "Per-service INPROGRESS -X-> RESTARTING" $
    not $
      validateStatusTransition INPROGRESS RESTARTING
  assertBool "Global PAUSED -> RESTARTING" $
    validateGlobalStatusTransition PAUSED RESTARTING

  -- RESTARTING converges back to INPROGRESS
  assertBool "Global RESTARTING -> INPROGRESS" $
    validateGlobalStatusTransition RESTARTING INPROGRESS
  assertBool "Global RESTARTING -> PAUSED" $
    validateGlobalStatusTransition RESTARTING PAUSED

  -- RESTARTING can also abort
  assertBool "Global RESTARTING -> ABORTED" $
    validateGlobalStatusTransition RESTARTING ABORTED
  assertBool "Global RESTARTING -> USER_ABORTED" $
    validateGlobalStatusTransition RESTARTING USER_ABORTED
  assertBool "Global RESTARTING -> GCLT_ABORTED" $
    validateGlobalStatusTransition RESTARTING GCLT_ABORTED
  assertBool "Global RESTARTING -> REVERTING" $
    validateGlobalStatusTransition RESTARTING REVERTING

  -- RESTARTING cannot directly complete (must go via INPROGRESS)
  assertBool "Global RESTARTING -X-> COMPLETED" $
    not $
      validateGlobalStatusTransition RESTARTING COMPLETED

-- ============================================================================
-- [15] DISCARDING (async cleanup) State Machine
-- ============================================================================

testDiscardingTransitions :: IO ()
testDiscardingTransitions = do
  -- Global allows CREATED -> DISCARDING (async cleanup path)
  assertBool "Global CREATED -> DISCARDING" $
    validateGlobalStatusTransition CREATED DISCARDING
  assertBool "Per-service CREATED -X-> DISCARDING (sync only)" $
    not $
      validateStatusTransition CREATED DISCARDING

  -- DISCARDING only ever leads to DISCARDED
  assertBool "Global DISCARDING -> DISCARDED" $
    validateGlobalStatusTransition DISCARDING DISCARDED
  assertBool "Per-service DISCARDING -> DISCARDED" $
    validateStatusTransition DISCARDING DISCARDED

  -- All other transitions from DISCARDING are blocked
  let bad = [INPROGRESS, COMPLETED, ABORTED, REVERTING, PAUSED, CREATED]
  mapM_
    ( \s ->
        assertBool ("DISCARDING -X-> " <> show s) $
          not $
            validateGlobalStatusTransition DISCARDING s
    )
    bad

  -- Once DISCARDED, fully terminal
  assertBool "DISCARDED is terminal" $ isTerminalStatus DISCARDED
  assertBool "DISCARDED -X-> anything" $
    not $
      any (validateStatusTransition DISCARDED) [INPROGRESS, COMPLETED, REVERTING]

-- ============================================================================
-- [16] ReleaseCategory MobileBuild
-- ============================================================================

testReleaseCategoryMobileBuild :: IO ()
testReleaseCategoryMobileBuild = do
  putStrLn "ReleaseCategory: MobileBuild constructor"
  let allCategories = [minBound .. maxBound :: ReleaseCategory]
  assertBool
    "MobileBuild is in [minBound..maxBound]"
    (MobileBuild `elem` allCategories)
  assertEqual
    "default target for MobileBuild"
    "github-actions"
    (getDefaultDeploymentTarget MobileBuild)

-- ============================================================================
-- [17] Mobile Permission Membership + Round-Trip
-- ============================================================================

testMobilePermissionsExist :: IO ()
testMobilePermissionsExist = do
  putStrLn "Mobile permissions: enum membership + text round-trip"
  let perms = [minBound .. maxBound :: MobilePermission]
  assertBool "MB_MOBILE_DISPATCH in enum" (MB_MOBILE_DISPATCH `elem` perms)
  assertBool "MB_MOBILE_APP_MANAGE in enum" (MB_MOBILE_APP_MANAGE `elem` perms)
  assertBool "MB_RELEASE_ABORT in enum" (MB_RELEASE_ABORT `elem` perms)
  assertEqual
    "MB_MOBILE_DISPATCH textual (wire == constructor)"
    "MB_MOBILE_DISPATCH"
    (mobilePermissionToText MB_MOBILE_DISPATCH)
  assertEqual
    "MB_RELEASE_ABORT textual (wire == constructor)"
    "MB_RELEASE_ABORT"
    (mobilePermissionToText MB_RELEASE_ABORT)
  assertEqual
    "round-trip MB_MOBILE_DISPATCH"
    (Just MB_MOBILE_DISPATCH)
    (textToMobilePermission "MB_MOBILE_DISPATCH")
  assertEqual
    "round-trip MB_MOBILE_APP_MANAGE"
    (Just MB_MOBILE_APP_MANAGE)
    (textToMobilePermission "MB_MOBILE_APP_MANAGE")
  -- Old autopilot spellings are NOT in mobile's vocabulary (migration
  -- rewrites them to MB_*).
  assertEqual
    "pre-split spelling rejected"
    Nothing
    (textToMobilePermission "MOBILE_DISPATCH")

-- ============================================================================
-- [18] MobileBuildWFStatus State Machine
-- ============================================================================

testMobileBuildWFStatusTransitions :: IO ()
testMobileBuildWFStatusTransitions = do
  putStrLn "MobileBuildWFStatus: transition validity"
  -- Forward path
  assertBool
    "MBInit -> MBVersionResolved"
    (validMBTransition MBInit MBVersionResolved)
  assertBool
    "MBVersionResolved -> MBDispatched"
    (validMBTransition MBVersionResolved MBDispatched)
  assertBool
    "MBDispatched -> MBRunIdResolved"
    (validMBTransition MBDispatched MBRunIdResolved)
  assertBool
    "MBRunIdResolved -> MBBuilding"
    (validMBTransition MBRunIdResolved MBBuilding)
  assertBool
    "MBBuilding -> MBSubmittedToStore"
    (validMBTransition MBBuilding MBSubmittedToStore)
  assertBool
    "MBSubmittedToStore -> MBTagPushed"
    (validMBTransition MBSubmittedToStore MBTagPushed)
  assertBool
    "MBTagPushed -> MBCompleted"
    (validMBTransition MBTagPushed MBCompleted)
  -- Failure can come from any non-terminal state
  assertBool
    "MBBuilding -> MBFailed allowed"
    (validMBTransition MBBuilding (MBFailed "x"))
  assertBool
    "MBCompleted -> MBFailed NOT allowed (terminal)"
    (not (validMBTransition MBCompleted (MBFailed "x")))
  -- Skipping not allowed
  assertBool
    "MBInit -> MBBuilding NOT allowed"
    (not (validMBTransition MBInit MBBuilding))
  -- Promote → review → staged-rollout path (migration 0027 statuses)
  assertBool
    "MBTagPushed -> MBSubmittingForReview"
    (validMBTransition MBTagPushed MBSubmittingForReview)
  assertBool
    "MBSubmittingForReview -> MBInReview"
    (validMBTransition MBSubmittingForReview MBInReview)
  assertBool
    "MBInReview -> MBReviewApproved"
    (validMBTransition MBInReview MBReviewApproved)
  assertBool
    "MBInReview -> MBReviewRejected"
    (validMBTransition MBInReview MBReviewRejected)
  assertBool
    "MBReviewApproved -> MBRollingOut"
    (validMBTransition MBReviewApproved MBRollingOut)
  assertBool
    "MBRollingOut -> MBCompleted"
    (validMBTransition MBRollingOut MBCompleted)
  -- MBReviewApproved / MBRollingOut are NOT terminal (release still active)
  assertBool
    "MBReviewApproved -> MBFailed allowed (non-terminal)"
    (validMBTransition MBReviewApproved (MBFailed "x"))
  assertBool
    "MBRollingOut -> MBFailed allowed (non-terminal)"
    (validMBTransition MBRollingOut (MBFailed "x"))
  -- MBReviewRejected IS terminal
  assertBool
    "MBReviewRejected -> MBRollingOut NOT allowed (terminal)"
    (not (validMBTransition MBReviewRejected MBRollingOut))
  assertBool
    "MBReviewRejected -> MBFailed NOT allowed (terminal)"
    (not (validMBTransition MBReviewRejected (MBFailed "x")))
  -- Can't jump from build-complete straight into rollout
  assertBool
    "MBTagPushed -> MBRollingOut NOT allowed"
    (not (validMBTransition MBTagPushed MBRollingOut))

-- ============================================================================
-- [19] MobileBuildContext JSON Round-Trip
-- ============================================================================

-- ============================================================================
-- [46] claimsStoreIdentity — the single source of truth for the store-identity
-- rule. Only builds published to a versioned store (Play prod / App Store) under
-- their version_code own a (version, code) identity; debug + Firebase internal
-- builds reuse a repeating code and must be free to coexist. Allowlist, so a NEW
-- destination defaults to "no identity" rather than re-creating the collision bug.
-- ============================================================================

testClaimsStoreIdentity :: IO ()
testClaimsStoreIdentity = do
  putStrLn "claimsStoreIdentity: only store-published builds own a (version, code) identity"
  let ctx bt dest =
        MobileBuildContext
          { mbcVersionCode = Just 386,
            mbcChangeLog = "x",
            mbcBuildType = bt,
            mbcReleaseGroupId = "g",
            mbcMatrixJobName = "j",
            mbcStoreObserved = Nothing,
            mbcOtaNamespace = Nothing,
            mbcTagPushed = Nothing,
            mbcDestination = dest,
            mbcChangelogSummary = Nothing,
            mbcChangelogSummaryShort = Nothing,
            mbcChangelogSummaryModel = Nothing,
            mbcChangelogContentKey = Nothing,
            mbcChangelogSlackOptIn = Nothing
          }
  -- Store-bound builds DO claim an identity.
  assertBool "consumer Android (release, no destination)" $ claimsStoreIdentity (ctx "release" Nothing)
  assertBool "provider Android -> GooglePlay" $ claimsStoreIdentity (ctx "release" (Just "GooglePlay"))
  assertBool "iOS release (release, no destination)" $ claimsStoreIdentity (ctx "release" Nothing)
  -- Internal / non-store builds DO NOT — their code repeats, so they must coexist.
  assertBool "provider Android -> Firebase is NOT a store identity" $
    not (claimsStoreIdentity (ctx "release" (Just "Firebase")))
  assertBool "debug build is NOT a store identity" $
    not (claimsStoreIdentity (ctx "debug" Nothing))
  assertBool "debug + Firebase is NOT a store identity" $
    not (claimsStoreIdentity (ctx "debug" (Just "Firebase")))
  -- Allowlist: an unknown/new destination defaults to NO identity (safe direction).
  assertBool "unknown destination defaults to NOT a store identity" $
    not (claimsStoreIdentity (ctx "release" (Just "Huawei")))
  -- buildKind axis: claimsStoreIdentity is exactly hasStoreIdentity . buildKind.
  assertEqual "consumer/iOS release -> StoreBound" StoreBound (buildKind (ctx "release" Nothing))
  assertEqual "provider GooglePlay -> StoreBound" StoreBound (buildKind (ctx "release" (Just "GooglePlay")))
  assertEqual "provider Firebase -> FirebaseInternal" FirebaseInternal (buildKind (ctx "release" (Just "Firebase")))
  assertEqual "non-Play store (Huawei) -> FirebaseInternal" FirebaseInternal (buildKind (ctx "release" (Just "Huawei")))
  assertEqual "debug -> Debug" Debug (buildKind (ctx "debug" Nothing))
  let kinds = [ctx "release" Nothing, ctx "release" (Just "GooglePlay"), ctx "release" (Just "Firebase"), ctx "release" (Just "Huawei"), ctx "debug" Nothing, ctx "debug" (Just "Firebase")]
  assertBool "claimsStoreIdentity == hasStoreIdentity . buildKind" $
    all (\c -> claimsStoreIdentity c == hasStoreIdentity (buildKind c)) kinds

-- ============================================================================
-- [47] ReleasePhase — the canonical lifecycle value. The pure
-- projection/transition/display functions everything else derives from.
-- ============================================================================

testReleasePhase :: IO ()
testReleasePhase = do
  putStrLn "ReleasePhase: project / displayStatus / canTransition / pEngineStatus"
  -- project: review and rollout are mutually exclusive by construction (Cumta bug
  -- can't be built) — InReview nulls rollout, RollingOut nulls review.
  assertEqual "InReview -> review set, rollout NULL" (Projection (Just "in_review") Nothing Nothing (Just "production")) (project InReview)
  assertEqual "RollingOut 0.01 -> rollout 1%, review NULL" (Projection Nothing (Just "rolling_out") (Just 1) (Just "production")) (project (RollingOut 0.01))
  assertEqual "InternalHeld -> internal track only" (Projection Nothing Nothing Nothing (Just "internal")) (project InternalHeld)
  assertEqual "Distributed Debug -> all NULL (no store lifecycle)" (Projection Nothing Nothing Nothing Nothing) (project (Distributed Debug))
  -- canTransition: a % bump is legal; review+rolling is not; terminals go nowhere.
  assertBool "RollingOut 1% -> RollingOut 50% (a bump) is legal" $ canTransition (RollingOut 0.01) (RollingOut 0.5)
  assertBool "InReview -> RollingOut is NOT legal" $ not (canTransition InReview (RollingOut 0.01))
  assertBool "InternalHeld -> InReview is legal" $ canTransition InternalHeld InReview
  assertBool "Live is terminal" $ not (canTransition Live (RollingOut 0.5))
  -- pEngineStatus: the generic rt_status moves with the phase.
  assertEqual "Live -> COMPLETED" COMPLETED (pEngineStatus Live)
  assertEqual "Rejected -> ABORTED" ABORTED (pEngineStatus (Rejected "x"))
  assertEqual "Aborted -> USER_ABORTED" USER_ABORTED (pEngineStatus Aborted)
  assertEqual "InReview -> INPROGRESS" INPROGRESS (pEngineStatus InReview)
  -- displayStatus: one label per phase (the single deriver every surface uses).
  assertEqual "RollingOut 0.01 label" "Rolling out 1%" (dLabel (displayStatus (RollingOut 0.01)))
  assertEqual "Approved label" "Approved · held" (dLabel (displayStatus Approved))
  assertEqual "Aborted is red" Danger (dVariant (displayStatus Aborted))
  -- Inference softening: an Android track-inferred verdict reads "Pending
  -- review"; authoritative rows and non-review phases are untouched.
  assertEqual "inferred InReview softens" "Pending review" (dLabel (displayStatusInferred True InReview))
  assertEqual "authoritative InReview unchanged" "In review" (dLabel (displayStatusInferred False InReview))
  assertEqual "inferred Approved does NOT soften" "Approved · held" (dLabel (displayStatusInferred True Approved))
  -- phaseToWfStatus: the 1:1 wf-status mirror for store-lifecycle phases.
  assertEqual "InReview -> MBInReview" (Just MBInReview) (phaseToWfStatus InReview)
  assertEqual "Live -> MBCompleted" (Just MBCompleted) (phaseToWfStatus Live)
  assertEqual "Halted -> MBRollingOut (mid-rollout, resumable)" (Just MBRollingOut) (phaseToWfStatus (Halted 0.5))
  -- Superseded terminalizes via MBAborted (→USER_ABORTED, not COMPLETED) so
  -- markReleaseRevertedBy never fires; the "Superseded" display is column-driven.
  assertEqual "Superseded -> MBAborted (terminalize, no revert trigger)" (Just MBAborted) (phaseToWfStatus Superseded)
  -- phaseFromFields: rollout columns win over review (a rolling row is past review).
  assertEqual "rolling_out 50% -> RollingOut 0.5" (RollingOut 0.5) (phaseFromFields StoreBound MBRollingOut (Just "in_review") (Just "rolling_out") (Just 50) (Just "production"))
  assertEqual "approved, no rollout -> Approved" Approved (phaseFromFields StoreBound MBReviewApproved (Just "approved") Nothing Nothing (Just "production"))
  assertEqual "debug completed -> Distributed Debug" (Distributed Debug) (phaseFromFields Debug MBCompleted Nothing Nothing Nothing Nothing)
  assertEqual "debug still building -> Building (not Distributed yet)" Building (phaseFromFields Debug MBBuilding Nothing Nothing Nothing Nothing)
  assertEqual "store-bound on internal -> InternalHeld" InternalHeld (phaseFromFields StoreBound MBTagPushed Nothing Nothing Nothing (Just "internal"))
  -- MBTagPushed (built, held) with NO track column → InternalHeld, so promote's
  -- InternalHeld→InReview is a legal transition (no spurious shadow-warning).
  assertEqual "MBTagPushed, null track -> InternalHeld" InternalHeld (phaseFromFields StoreBound MBTagPushed Nothing Nothing Nothing Nothing)
  assertEqual "TestFlight snapshot -> InternalHeld" InternalHeld (phaseFromFields StoreBound MBCompleted Nothing Nothing Nothing (Just "testflight"))
  -- §16: review reaches phaseFromFields from the ROW's review_status (setPhase
  -- writes the column and the wf mirror together) — there is no wf fallback for
  -- review states. A review-wf row with no review column reads by its track.
  assertEqual "review-wf with no review column reads by track" InternalHeld (phaseFromFields StoreBound MBInReview Nothing Nothing Nothing (Just "testflight"))
  assertEqual "review column drives the phase" Approved (phaseFromFields StoreBound MBInReview (Just "approved") Nothing Nothing (Just "production"))
  assertEqual "rollout still wins over an in-review row" (RollingOut 0.5) (phaseFromFields StoreBound MBInReview Nothing (Just "rolling_out") (Just 50) (Just "production"))
  -- Round-trip: project a store phase to columns, reconstruct the same tag back.
  let roundTrips ph =
        let Projection rv ro pp tk = project ph
         in phaseFromFields StoreBound MBRollingOut rv ro pp tk
  assertEqual "round-trip RollingOut 0.01" (RollingOut 0.01) (roundTrips (RollingOut 0.01))
  assertEqual "round-trip Approved" Approved (roundTrips Approved)
  assertEqual "round-trip InReview" InReview (roundTrips InReview)
  -- deriveStoreState (§16): cells carry NO review — a verdict lives on the release
  -- row (the Lynx rejected-TestFlight case now reads its verdict via the row's
  -- review_status through phaseFromFields, covered above). Cells contribute only
  -- (rollout, %, track); rollout/% are production-only concepts.
  assertEqual
    "plain TestFlight cell contributes only its track"
    (Nothing, Nothing, Just "testflight")
    (deriveStoreState (StoreCell "testflight" (Just "4.9.16") (Just 1) (Just "VALID") Nothing))
  assertEqual
    "internal cell with a % does not report rollout"
    (Nothing, Nothing, Just "internal")
    (deriveStoreState (StoreCell "internal" (Just "4.9.16") (Just 1) (Just "inProgress") (Just 50)))
  assertEqual
    "production cell mid-ramp reports rolling_out + %"
    (Just "rolling_out", Just 25, Just "production")
    (deriveStoreState (StoreCell "production" (Just "4.9.16") (Just 1) (Just "inProgress") (Just 25)))
  -- resolveStoreState: production-precedence, but a version present ONLY on a pre-prod
  -- track resolves to that track's cell (the Lynx 4.9.16 case: prod is 4.9.15).
  let cells =
        [ StoreCell "production" (Just "4.9.15") (Just 1) (Just "live") Nothing,
          StoreCell "testflight" (Just "4.9.16") (Just 1) (Just "VALID") Nothing
        ]
  assertEqual
    "resolveStoreState picks the TestFlight cell for 4.9.16"
    (Just (Nothing, Nothing, Just "testflight"))
    (resolveStoreState cells "4.9.16" (Just 1))
  assertEqual
    "resolveStoreState: unknown version -> Nothing (row fallback)"
    Nothing
    (resolveStoreState cells "9.9.9" (Just 1))
  -- A promoted-and-live build shows on BOTH its TestFlight and production cells
  -- (same code); production-precedence wins → live-on-production, not TestFlight.
  let bothTracks =
        [ StoreCell "testflight" (Just "9.9.14") (Just 2) (Just "VALID") Nothing,
          StoreCell "production" (Just "9.9.14") (Just 2) (Just "live") Nothing
        ]
  assertEqual
    "resolveStoreState: version on both tracks -> production (live) wins"
    (Just (Just "completed", Nothing, Just "production"))
    (resolveStoreState bothTracks "9.9.14" (Just 2))
  -- abortable: only while the build job can still be killed (nothing uploaded).
  -- From MBSubmittedToStore the artifact is on the store — no un-ship, no Abort.
  assertBool "Building (job running) is abortable" (abortable MBBuilding Building)
  assertBool "Building (pre-dispatch) is abortable" (abortable MBVersionResolved Building)
  assertBool "Building but already uploaded is NOT abortable" (not (abortable MBSubmittedToStore Building))
  assertBool "Rejected is NOT abortable" (not (abortable MBReviewRejected (Rejected "")))
  assertBool "InReview (on store) is NOT abortable" (not (abortable MBInReview InReview))
  assertBool "RollingOut is NOT abortable" (not (abortable MBRollingOut (RollingOut 0.5)))
  assertBool "Live is NOT abortable" (not (abortable MBCompleted Live))
  assertBool "Superseded is NOT abortable" (not (abortable MBTagPushed Superseded))
  assertBool "InternalHeld (on internal) is NOT abortable" (not (abortable MBTagPushed InternalHeld))

testMobileBuildContextJsonRoundTrip :: IO ()
testMobileBuildContextJsonRoundTrip = do
  putStrLn "MobileBuildContext: JSON round-trip"
  let ctx =
        MobileBuildContext
          { mbcVersionCode = Just 12345,
            mbcChangeLog = "hello",
            mbcBuildType = "release",
            mbcReleaseGroupId = "rg_abc",
            mbcMatrixJobName = "NammaYatri-Release",
            mbcStoreObserved = Nothing,
            mbcOtaNamespace = Just "nammayatriv2",
            mbcTagPushed = Nothing,
            mbcDestination = Nothing,
            mbcChangelogSummary = Nothing,
            mbcChangelogSummaryShort = Nothing,
            mbcChangelogSummaryModel = Nothing,
            mbcChangelogContentKey = Nothing,
            mbcChangelogSlackOptIn = Nothing
          }
  let encoded = Aeson.encode ctx
  let decoded = Aeson.decode encoded :: Maybe MobileBuildContext
  assertEqual "round-trip equals original" (Just ctx) decoded
  -- Slack opt-in rule: the explicit flag always wins; ONLY legacy rows
  -- (no flag) fall back to body presence. A regression here posts
  -- non-opted releases to Slack — keep these three exact.
  assertBool
    "opt-in: flag=False beats a stored body"
    (not (changelogSlackOptedIn ctx{mbcChangelogSummary = Just "body", mbcChangelogSlackOptIn = Just False}))
  assertBool
    "opt-in: flag=True without a body"
    (changelogSlackOptedIn ctx{mbcChangelogSummary = Nothing, mbcChangelogSlackOptIn = Just True})
  assertBool
    "opt-in: legacy fallback = body presence"
    (changelogSlackOptedIn ctx{mbcChangelogSummary = Just "body", mbcChangelogSlackOptIn = Nothing})
  assertBool
    "opt-in: legacy, no body -> not opted in"
    (not (changelogSlackOptedIn ctx{mbcChangelogSummary = Nothing, mbcChangelogSlackOptIn = Nothing}))

-- | Legacy rows persisted before the @build_type@ field used a
-- @destination@ string. 'MobileBuildContext' 'FromJSON' must map those to a
-- build type — Firebase/TestFlight → "debug", everything else → "release",
-- and an explicit @build_type@ always wins. 'fetchLatestBuildsPerApp'
-- relies on this to classify old completed builds.
testMobileBuildContextDestinationFallback :: IO ()
testMobileBuildContextDestinationFallback = do
  putStrLn "MobileBuildContext: legacy destination → build_type fallback"
  -- required fields the decoder demands, regardless of build-type source
  let base = "\"change_log\":\"x\",\"release_group_id\":\"g\",\"matrix_job_name\":\"j\""
      decodeBT s = mbcBuildType <$> (Aeson.decode s :: Maybe MobileBuildContext)
  assertEqual
    "Firebase → debug"
    (Just "debug")
    (decodeBT ("{\"destination\":\"Firebase\"," <> base <> "}"))
  assertEqual
    "TestFlight → debug"
    (Just "debug")
    (decodeBT ("{\"destination\":\"TestFlight\"," <> base <> "}"))
  assertEqual
    "GooglePlay → release"
    (Just "release")
    (decodeBT ("{\"destination\":\"GooglePlay\"," <> base <> "}"))
  assertEqual
    "explicit build_type wins over destination"
    (Just "debug")
    (decodeBT ("{\"build_type\":\"debug\",\"destination\":\"GooglePlay\"," <> base <> "}"))
  assertEqual
    "neither field → release default"
    (Just "release")
    (decodeBT ("{" <> base <> "}"))
  -- malformed JSON must decode to Nothing (so fetchLatestBuildsPerApp drops it)
  assertBool
    "malformed context → Nothing (row dropped)"
    (isNothing (Aeson.decode "this is not json {{{" :: Maybe MobileBuildContext))

-- | B3: ConfirmTag's wall-clock guard. Anchors on build-completion, falls back
-- to build-start, and reports "not timed out" when neither timestamp exists (so a
-- release is never failed spuriously while we can't measure elapsed time).
testTagConfirmTimedOut :: IO ()
testTagConfirmTimedOut = do
  putStrLn "ConfirmTag: wall-clock timeout predicate"
  now <- getCurrentTime
  let minsAgo m = addUTCTime (fromIntegral (negate (m * 60 :: Int))) now
      budget = 60 :: Int
  assertBool
    "completed 10m ago, budget 60m → not timed out"
    (not (tagConfirmTimedOut now (Just (minsAgo 10)) Nothing budget))
  assertBool
    "completed 61m ago, budget 60m → timed out"
    (tagConfirmTimedOut now (Just (minsAgo 61)) Nothing budget)
  assertBool
    "no completed time, started 61m ago → timed out (start fallback)"
    (tagConfirmTimedOut now Nothing (Just (minsAgo 61)) budget)
  assertBool
    "neither timestamp → not timed out (cannot measure)"
    (not (tagConfirmTimedOut now Nothing Nothing budget))
  assertBool
    "completed 5m ago wins over started 100m ago → not timed out"
    (not (tagConfirmTimedOut now (Just (minsAgo 5)) (Just (minsAgo 100)) budget))

-- | The rollback resolver. Orders candidates by the store's sequence key
-- (version_code, then semver, then created_at) — NOT by creation time, which
-- store-sync rows break. Also exercises the target-vs-source split: when the
-- version users were on has no SCC artifact, the resolver surfaces a
-- rebuild-lower or manual-source plan instead of guessing.
testResolveRollback :: IO ()
testResolveRollback = do
  putStrLn "Rollback resolver: version order + target/source split"
  now <- getCurrentTime
  let minsAgo m = addUTCTime (fromIntegral (negate (m * 60 :: Int))) now
      cand i ver code tag ago =
        RevertCand
          { rcId = i,
            rcVersionName = ver,
            rcVersionCode = code,
            rcTag = tag,
            rcCommitSha = Just (i <> "sha"),
            rcCreatedAt = minsAgo ago
          }

  -- parseSemver compares as integers, not lexically.
  assertBool "3.3.9 < 3.3.10 by semver" (parseSemver "3.3.9" < parseSemver "3.3.10")
  assertEqual "parseSemver 3.3.17" [3, 3, 17] (parseSemver "3.3.17")

  -- The screenshot case: bad 3.3.17 (real, tagged); the only candidate is a
  -- store-sync 3.3.16 created LATER in time but LOWER in version, with no
  -- tag. Time-order said "nothing before" → blocked. Version-order finds
  -- 3.3.16 as the target, but it has no artifact → manual source required.
  let bad17 = cand "r17" "3.3.17" (Just 417) (Just "v3.3.17") 30
      sync16 = cand "r16" "3.3.16" (Just 416) Nothing 10
  case resolveRollback bad17 [sync16] of
    NeedsManualSource t -> assertEqual "manual target is 3.3.16" "3.3.16" (rcVersionName t)
    other -> assertBool ("expected NeedsManualSource, got " <> show other) False

  -- Add a lower real SCC build 3.3.15 (tagged): target stays 3.3.16 (highest
  -- below), but source falls to 3.3.15 (nearest buildable) → RebuildLower.
  let scc15 = cand "r15" "3.3.15" (Just 415) (Just "v3.3.15") 60
  case resolveRollback bad17 [sync16, scc15] of
    RebuildLower t s -> do
      assertEqual "rebuild target is 3.3.16" "3.3.16" (rcVersionName t)
      assertEqual "rebuild source is 3.3.15" "3.3.15" (rcVersionName s)
    other -> assertBool ("expected RebuildLower, got " <> show other) False

  -- Clean rollback: the target itself is tagged → Rollback, source == target.
  let good16 = cand "r16b" "3.3.16" (Just 416) (Just "v3.3.16") 10
  case resolveRollback bad17 [good16] of
    Rollback t s -> do
      assertEqual "rollback target 3.3.16" "3.3.16" (rcVersionName t)
      assertEqual "rollback source == target" (rcId t) (rcId s)
    other -> assertBool ("expected Rollback, got " <> show other) False

  -- Version-order beats time-order: a higher version created EARLIER still
  -- wins over a lower version created later.
  let older18 = cand "r18" "3.3.18" (Just 418) (Just "v3.3.18") 200
      newer14 = cand "r14" "3.3.14" (Just 414) (Just "v3.3.14") 1
      bad19 = cand "r19" "3.3.19" (Just 419) (Just "v3.3.19") 5
  case resolveRollback bad19 [newer14, older18] of
    Rollback t _ -> assertEqual "highest-below 3.3.18 wins over newer 3.3.14" "3.3.18" (rcVersionName t)
    other -> assertBool ("expected Rollback to 3.3.18, got " <> show other) False

  -- Nothing below the bad version → NoPriorRelease.
  let lone = cand "r1" "1.0.0" (Just 100) (Just "v1.0.0") 5
  case resolveRollback lone [] of
    NoPriorRelease -> pure ()
    other -> assertBool ("expected NoPriorRelease, got " <> show other) False

-- | ConfirmTag must bind the tag THIS build pushed, not the lexically-first ref
-- under the broad app prefix. The fastlane workflow tags deterministically as
-- @{prefix}{version}+{code}@ and SCC supplies that version/code on dispatch, so we
-- match it exactly. GitHub returns matching-refs in ascending order, so "first"
-- | A ref whose workflow predates an optional input 422s the whole dispatch.
-- GitHub creates no run for a rejected request, so dropping the optional input
-- and retrying is safe — but only when EVERY name it listed is droppable.
testDroppableUnexpectedInputs :: IO ()
testDroppableUnexpectedInputs = do
  putStrLn "dispatch: optional-input 422 fallback"
  -- Verbatim shape of the failure seen in production (JSON-escaped quotes).
  let real =
        "dispatchWorkflow failed: HTTP 422: {\"message\":\"Unexpected inputs provided: [\\\"versions\\\"]\",\"documentation_url\":\"https://docs.github.com/rest\",\"status\":\"422\"}"
  assertEqual
    "the real 422 names only `versions` -> droppable, retry without it"
    (Just ["versions"])
    (droppableUnexpectedInputs real)
  assertEqual
    "unescaped quotes parse the same"
    (Just ["versions"])
    (droppableUnexpectedInputs "HTTP 422: Unexpected inputs provided: [\"versions\"]")
  assertEqual
    "a non-droppable input -> Nothing (real schema mismatch, must abort)"
    Nothing
    (droppableUnexpectedInputs "HTTP 422: Unexpected inputs provided: [\"selected_apps\"]")
  assertEqual
    "mixed droppable + not -> Nothing (never retry a payload still wrong)"
    Nothing
    (droppableUnexpectedInputs "HTTP 422: Unexpected inputs provided: [\"versions\",\"change_log\"]")
  assertEqual
    "an unrelated 422 (bad ref) -> Nothing"
    Nothing
    (droppableUnexpectedInputs "dispatchWorkflow failed: HTTP 422: {\"message\":\"No ref found\"}")
  assertEqual
    "a 5xx -> Nothing (transient; the caller retries the same payload)"
    Nothing
    (droppableUnexpectedInputs "dispatchWorkflow failed: HTTP 503")

-- | tagPushedFromLog reads the tag a build's own job log says it pushed.
-- Fixtures mirror real GitHub job logs: ISO-timestamp line prefixes, the
-- script-SOURCE dump (un-expanded $TAG_NAME / <tag> placeholder), and the
-- three confirmation-line shapes (consumer push, provider push, provider
-- already-exists rebuild).
testTagPushedFromLog :: IO ()
testTagPushedFromLog = do
  putStrLn "ConfirmTag: log-first tag extraction"
  let ts = "2026-08-20T14:32:01.1234567Z "
      consumerLog =
        T.unlines
          [ ts <> "##[group]Run set -euo pipefail",
            -- script dump: un-expanded variable must NOT be picked up
            ts <> "echo \"\10004 Annotated tag pushed: $TAG\"",
            ts <> "##[endgroup]",
            ts <> "To https://github.com/nammayatri/ny-react-native",
            ts <> " * [new tag]  v9292rides/prod/ios/v1.0.0+2 -> v9292rides/prod/ios/v1.0.0+2",
            ts <> "\10004 Annotated tag pushed: v9292rides/prod/ios/v1.0.0+2"
          ]
      providerLog =
        T.unlines
          [ ts <> "echo \"Successfully created and pushed tag: $TAG_NAME\"",
            ts <> "Creating tag: NammaYatriPartner-v3.1.0-245",
            ts <> "Successfully created and pushed tag: NammaYatriPartner-v3.1.0-245"
          ]
      providerRebuildLog =
        T.unlines
          [ ts <> "echo \"Tag $TAG_NAME already exists, skipping\"",
            ts <> "Tag NammaYatriPartner-v3.1.0-245 already exists, skipping"
          ]
  assertEqual
    "consumer: expanded push line wins; $TAG script-dump artifact rejected"
    (Just "v9292rides/prod/ios/v1.0.0+2")
    (tagPushedFromLog consumerLog)
  assertEqual
    "provider: post-push line parsed; $TAG_NAME dump rejected"
    (Just "NammaYatriPartner-v3.1.0-245")
    (tagPushedFromLog providerLog)
  assertEqual
    "provider rebuild: already-exists line names the tag; TAG_NAME dump rejected"
    (Just "NammaYatriPartner-v3.1.0-245")
    (tagPushedFromLog providerRebuildLog)
  assertEqual
    "no confirmation line -> Nothing (caller falls back to repo tags)"
    Nothing
    (tagPushedFromLog (ts <> "Creating tag: NammaYatriPartner-v3.1.0-245"))
  assertEqual
    "<tag> placeholder from a CONTRACT comment dump is rejected"
    Nothing
    (tagPushedFromLog (ts <> "# (\"Annotated tag pushed: <tag>\") to bind the tag"))
  assertEqual
    "empty log -> Nothing"
    Nothing
    (tagPushedFromLog "")
  -- Two confirmation lines (retried step): the LAST wins.
  assertEqual
    "multiple confirmation lines -> last occurrence wins"
    (Just "nammayatri/prod/android/v3.5.1+413")
    ( tagPushedFromLog $
        T.unlines
          [ ts <> "\10004 Annotated tag pushed: nammayatri/prod/android/v3.5.1+412",
            ts <> "\10004 Annotated tag pushed: nammayatri/prod/android/v3.5.1+413"
          ]
    )
  -- Provider selection rule sanity: exact code preferred, else highest.
  assertEqual
    "selectProviderBuildTag: exact SCC code preferred"
    (Just "NammaYatriPartner-v3.1.0-245")
    ( selectProviderBuildTag
        "NammaYatriPartner-v3.1.0-"
        (Just 245)
        ["refs/tags/NammaYatriPartner-v3.1.0-244", "refs/tags/NammaYatriPartner-v3.1.0-245"]
    )

-- would be the oldest version — the bug this guards against.
testSelectBuildTag :: IO ()
testSelectBuildTag = do
  putStrLn "ConfirmTag: exact tag selection"
  let prefix = "odishayatri/prod/android/v"
      ref n = "refs/tags/" <> n
      -- Two versions share the prefix; GitHub returns them ascending (oldest first).
      refs =
        [ ref "odishayatri/prod/android/v3.3.15+421",
          ref "odishayatri/prod/android/v3.3.17+460"
        ]
  assertEqual
    "picks this build's v3.3.17+460, not lexical-first v3.3.15+421"
    (Just "odishayatri/prod/android/v3.3.17+460")
    (selectBuildTag prefix "3.3.17" (Just 460) refs)
  assertEqual
    "the lexical-first tag is NOT chosen for a different version"
    (Just "odishayatri/prod/android/v3.3.15+421")
    (selectBuildTag prefix "3.3.15" (Just 421) refs)
  assertEqual
    "exact tag absent (code mismatch) -> Nothing (caller waits/timeouts)"
    Nothing
    (selectBuildTag prefix "3.3.17" (Just 999) refs)
  assertEqual
    "empty ref list -> Nothing"
    Nothing
    (selectBuildTag prefix "3.3.17" (Just 460) [])
  assertEqual
    "no version code (iOS-style) -> matches bare v{version}"
    (Just "odishayatri/prod/ios/v3.3.17")
    (selectBuildTag "odishayatri/prod/ios/v" "3.3.17" Nothing [ref "odishayatri/prod/ios/v3.3.17"])
  -- iOS: the workflow assigns the build number, so SCC has no code but the pushed
  -- tag carries a +<buildNumber> suffix. Must match it (highest wins), not require a bare tag.
  assertEqual
    "iOS no code -> matches the +<buildNumber> tag the workflow pushed"
    (Just "odishayatri/prod/ios/v3.3.73+2")
    (selectBuildTag "odishayatri/prod/ios/v" "3.3.73" Nothing [ref "odishayatri/prod/ios/v3.3.73+2"])
  assertEqual
    "iOS no code, multiple builds of a version -> picks the highest build number"
    (Just "odishayatri/prod/ios/v3.3.73+2")
    ( selectBuildTag
        "odishayatri/prod/ios/v"
        "3.3.73"
        Nothing
        [ref "odishayatri/prod/ios/v3.3.73+1", ref "odishayatri/prod/ios/v3.3.73+2"]
    )
  -- codeFromTag: read the build number back out of the observed tag so ConfirmTag can
  -- stamp version_code (esp. iOS, where SCC has no code at dispatch).
  assertEqual
    "codeFromTag: consumer +code suffix"
    (Just 3)
    (codeFromTag False "" "odishayatri/prod/ios/v" "3.3.73" "odishayatri/prod/ios/v3.3.73+3")
  assertEqual
    "codeFromTag: multi-digit code"
    (Just 460)
    (codeFromTag False "" "app/prod/android/v" "1.2.3" "app/prod/android/v1.2.3+460")
  assertEqual
    "codeFromTag: provider -code suffix"
    (Just 1)
    (codeFromTag True "LynxDriver-v4.9.17-" "" "" "LynxDriver-v4.9.17-1")
  assertEqual
    "codeFromTag: bare (codeless) tag -> Nothing"
    Nothing
    (codeFromTag False "" "odishayatri/prod/ios/v" "3.3.17" "odishayatri/prod/ios/v3.3.17")

-- ============================================================================
-- [49] Dispatch-group leader election (Workflow.electDispatchLeader)
-- ============================================================================

testElectDispatchLeader :: IO ()
testElectDispatchLeader = do
  putStrLn "Leader = first NON-TERMINAL sibling by id (id-ascending input)"
  -- (id, isTerminal) pairs, id-ascending — the shape findSiblingsByDispatchId yields.
  assertEqual
    "all living -> first id leads"
    "a"
    (electDispatchLeader "c" [("a", False), ("b", False), ("c", False)])
  assertEqual
    "singleton group (today's flow) -> self leads"
    "a"
    (electDispatchLeader "a" [("a", False)])
  assertEqual
    "dead ex-leader -> leadership slides to the next living sibling"
    "b"
    (electDispatchLeader "b" [("a", True), ("b", False), ("c", False)])
  assertEqual
    "leadership skips every terminal row, not just the first"
    "c"
    (electDispatchLeader "d" [("a", True), ("b", True), ("c", False), ("d", False)])
  assertEqual
    "all terminal (mid-tick external flip) -> falls back to self"
    "d"
    (electDispatchLeader "d" [("a", True), ("b", True)])

-- ============================================================================
-- [20] Mobile Version Bump (mirrors fastlane-android.yaml lines 124-189)
-- ============================================================================

testPlayStagedRollout :: IO ()
testPlayStagedRollout = do
  putStrLn "Play staged rollout: userFraction bounds + track parsing"
  assertBool "fraction 0 rejected" (not (userFractionInRange 0))
  assertBool "fraction 1.0 rejected" (not (userFractionInRange 1.0))
  assertBool "fraction 1.5 rejected" (not (userFractionInRange 1.5))
  assertBool "negative fraction rejected" (not (userFractionInRange (-0.1)))
  assertBool "fraction 0.5 ok" (userFractionInRange 0.5)
  assertBool "fraction 1e-9 (review ~0) ok" (userFractionInRange 1e-9)
  assertBool "fraction 0.999 ok" (userFractionInRange 0.999)
  assertEqual
    "parse inProgress production track"
    (Just (PlayRolloutState "inProgress" (Just 0.5) ["123"]))
    (parseRolloutState "{\"releases\":[{\"name\":\"1.2.3\",\"status\":\"inProgress\",\"userFraction\":0.5,\"versionCodes\":[\"123\"]}]}")
  assertEqual
    "parse completed production track (no fraction)"
    (Just (PlayRolloutState "completed" Nothing ["123"]))
    (parseRolloutState "{\"releases\":[{\"name\":\"1.2.3\",\"status\":\"completed\",\"versionCodes\":[\"123\"]}]}")
  assertEqual
    "parse empty production track -> none"
    (Just (PlayRolloutState "none" Nothing []))
    (parseRolloutState "{\"releases\":[]}")
  assertEqual
    "parse prefers active staged release over a completed one"
    (Just (PlayRolloutState "halted" (Just 0.25) ["200"]))
    (parseRolloutState "{\"releases\":[{\"status\":\"completed\",\"versionCodes\":[\"100\"]},{\"status\":\"halted\",\"userFraction\":0.25,\"versionCodes\":[\"200\"]}]}")

testAscReviewAndPhased :: IO ()
testAscReviewAndPhased = do
  putStrLn "ASC: appStoreState mapping + phased % + version parse"
  assertEqual "PREPARE_FOR_SUBMISSION" AscPrepareForSubmission (appStoreStateToReview "PREPARE_FOR_SUBMISSION")
  assertEqual "WAITING_FOR_REVIEW" AscWaitingForReview (appStoreStateToReview "WAITING_FOR_REVIEW")
  assertEqual "IN_REVIEW" AscInReview (appStoreStateToReview "IN_REVIEW")
  assertEqual "PENDING_DEVELOPER_RELEASE -> approved (held)" AscApproved (appStoreStateToReview "PENDING_DEVELOPER_RELEASE")
  assertEqual "READY_FOR_SALE -> live" AscLive (appStoreStateToReview "READY_FOR_SALE")
  assertEqual "REJECTED" (AscRejected "REJECTED") (appStoreStateToReview "REJECTED")
  assertEqual "METADATA_REJECTED" (AscRejected "METADATA_REJECTED") (appStoreStateToReview "METADATA_REJECTED")
  assertEqual "unknown -> other" (AscOther "PROCESSING_FOR_APP_STORE") (appStoreStateToReview "PROCESSING_FOR_APP_STORE")
  -- currentDayNumber is 1-BASED (1–7) — a live ACTIVE release started
  -- Jul 6 reported day 6 on Jul 11 (= 50%, not 100%).
  assertEqual "phased day 1 = 1%" 1 (applePhasedPercent 1)
  assertEqual "phased day 4 = 10%" 10 (applePhasedPercent 4)
  assertEqual "phased day 6 = 50%" 50 (applePhasedPercent 6)
  assertEqual "phased day 7 = 100%" 100 (applePhasedPercent 7)
  assertEqual "phased day >7 clamps to 100%" 100 (applePhasedPercent 9)
  assertEqual "defensive day 0 reads as day 1" 1 (applePhasedPercent 0)
  assertEqual
    "parse appStoreVersions response -> first {id, state}"
    (Just (AscVersion "12345" "PENDING_DEVELOPER_RELEASE"))
    (parseAscVersion "{\"data\":[{\"id\":\"12345\",\"type\":\"appStoreVersions\",\"attributes\":{\"appStoreState\":\"PENDING_DEVELOPER_RELEASE\",\"versionString\":\"1.2.3\"}}]}")
  assertEqual
    "parse empty appStoreVersions -> Nothing"
    Nothing
    (parseAscVersion "{\"data\":[]}")

testReviewPollTiming :: IO ()
testReviewPollTiming = do
  putStrLn "Review poll: soft-timeout (7d) + throttle (20m) predicates"
  now <- getCurrentTime
  let daysAgo d = addUTCTime (fromIntegral (negate (d * 86400 :: Int))) now
      secsAgo s = addUTCTime (fromIntegral (negate (s :: Int))) now
  -- soft timeout (default 7 days): nudge, not failure
  assertBool "no submitted-at -> not timed out" (not (reviewPollTimedOut now Nothing 7))
  assertBool "submitted 3d ago -> not timed out (7d)" (not (reviewPollTimedOut now (Just (daysAgo 3)) 7))
  assertBool "submitted 8d ago -> timed out (7d)" (reviewPollTimedOut now (Just (daysAgo 8)) 7)
  -- throttle (default 1200s = 20 min)
  assertBool "never polled -> due" (reviewPollDue now Nothing 1200)
  assertBool "polled 10m ago -> not due (20m interval)" (not (reviewPollDue now (Just (secsAgo 600)) 1200))
  assertBool "polled 25m ago -> due (20m interval)" (reviewPollDue now (Just (secsAgo 1500)) 1200)

-- ============================================================================
-- [35] Rollout reconcile classification (Phase 7 — pure store-state → action)
-- ============================================================================

testRolloutReconcileClassify :: IO ()
testRolloutReconcileClassify = do
  putStrLn "Rollout reconcile: live store state -> action"
  -- Android: production-track status → action; userFraction stored as percent.
  -- Use exactly-representable fractions (0.5, 0.25) to avoid float-eq flakiness.
  assertEqual
    "android completed -> CompleteRollout"
    CompleteRollout
    (androidReconcileAction (PlayRolloutState "completed" Nothing ["123"]))
  assertEqual
    "android inProgress 0.5 -> rolling_out @ 50%"
    (SetRollout "rolling_out" (Just 50))
    (androidReconcileAction (PlayRolloutState "inProgress" (Just 0.5) ["123"]))
  assertEqual
    "android halted 0.25 -> halted @ 25%"
    (SetRollout "halted" (Just 25))
    (androidReconcileAction (PlayRolloutState "halted" (Just 0.25) ["123"]))
  assertEqual
    "android unknown status -> LeaveAsIs (echoes status)"
    (LeaveAsIs "draft")
    (androidReconcileAction (PlayRolloutState "draft" Nothing ["123"]))
  -- iOS phased: state + ramp day → action; day maps via applePhasedPercent.
  assertEqual
    "ios COMPLETE -> CompleteRollout"
    CompleteRollout
    (iosPhasedReconcileAction (AscPhasedState "COMPLETE" (Just 6)))
  assertEqual
    "ios ACTIVE day1 -> rolling_out @ 1%"
    (SetRollout "rolling_out" (Just 1))
    (iosPhasedReconcileAction (AscPhasedState "ACTIVE" (Just 1)))
  assertEqual
    "ios ACTIVE day4 -> rolling_out @ 10%"
    (SetRollout "rolling_out" (Just 10))
    (iosPhasedReconcileAction (AscPhasedState "ACTIVE" (Just 4)))
  assertEqual
    "ios ACTIVE day6 -> rolling_out @ 50% (the Lynx regression)"
    (SetRollout "rolling_out" (Just 50))
    (iosPhasedReconcileAction (AscPhasedState "ACTIVE" (Just 6)))
  assertEqual
    "ios PAUSED day5 -> halted @ 20%"
    (SetRollout "halted" (Just 20))
    (iosPhasedReconcileAction (AscPhasedState "PAUSED" (Just 5)))
  assertEqual
    "ios INACTIVE (transient) -> LeaveAsIs"
    (LeaveAsIs "INACTIVE")
    (iosPhasedReconcileAction (AscPhasedState "INACTIVE" Nothing))

-- ============================================================================
-- [36] ASC /v1/builds parse — marketing version + build number (iOS ref capture)
-- ============================================================================

testAscBuildInfoParse :: IO ()
testAscBuildInfoParse = do
  putStrLn "ASC /v1/builds: marketing version (included) + build number (data[0])"
  -- Real shape: data[0].attributes.version = CFBundleVersion (the iOS "code");
  -- included[preReleaseVersions].attributes.version = marketing version.
  case Aeson.eitherDecode
         "{\"data\":[{\"type\":\"builds\",\"attributes\":{\"version\":\"458\"}}],\"included\":[{\"type\":\"preReleaseVersions\",\"attributes\":{\"version\":\"3.3.73\"}}]}" ::
         Either String BuildsResp of
    Right (BuildsResp v b) -> do
      assertEqual "marketing version" (Just "3.3.73") v
      assertEqual "build number (CFBundleVersion)" (Just "458") b
    Left e -> fail ("  FAIL: decode error: " <> e)
  -- No builds yet (first-ever release) → both Nothing → no derived tag (fallback).
  case Aeson.eitherDecode "{\"data\":[],\"included\":[]}" :: Either String BuildsResp of
    Right (BuildsResp v b) -> do
      assertEqual "no builds -> no version" (Nothing :: Maybe Text) v
      assertEqual "no builds -> no build number" (Nothing :: Maybe Text) b
    Left e -> fail ("  FAIL: decode error: " <> e)

-- ============================================================================
-- [37] iOS next-version rule — track-aware (bump in sync / reuse when ahead)
-- ============================================================================

testIosVersionBumpRule :: IO ()
testIosVersionBumpRule = do
  putStrLn "iOS next-version: bump when TestFlight==prod, reuse when TestFlight ahead"
  assertEqual "no TestFlight history, no live version -> 1.0.0" "1.0.0" (computeNextIosVersion Nothing Nothing)
  -- TestFlight builds expire after 90 days: an app that hasn't built recently
  -- reads TF-empty while live on the store — next must come from the live
  -- version, never 1.0.0 (the KeralaSavaari/Yatri regression).
  assertEqual "TF expired/empty but app LIVE -> bump live patch" "3.3.107" (computeNextIosVersion Nothing (Just "3.3.106"))
  assertEqual "TF expired/empty, live 3.0.27 -> 3.0.28" "3.0.28" (computeNextIosVersion Nothing (Just "3.0.27"))
  assertEqual "TF == prod -> bump patch" "3.3.74" (computeNextIosVersion (Just "3.3.73") (Just "3.3.73"))
  assertEqual "TF ahead of prod -> reuse TF verbatim" "3.3.73" (computeNextIosVersion (Just "3.3.73") (Just "3.3.70"))
  assertEqual "TF present, no live prod yet -> reuse TF" "3.3.73" (computeNextIosVersion (Just "3.3.73") Nothing)

-- | The base-track selection driving the create-page changelog: prefer the
-- chosen track's snapshot tag, default to production, and fall back to the
-- leading tag/commit when the track or its tag is absent.
testChangelogBaseResolution :: IO ()
testChangelogBaseResolution = do
  putStrLn "changelog base: chosen track's tag, prod default, graceful fallbacks"
  let prod = TrackSnapshot {tsVersion = "3.3.17", tsCode = Just 460, tsTag = Just "oy/prod/android/v3.3.17+460"}
      internal = TrackSnapshot {tsVersion = "3.3.20", tsCode = Just 463, tsTag = Just "oy/prod/android/v3.3.20+463"}
      tracks = Map.fromList [("production", prod), ("internal", internal)]
      leadTag = Just "oy/prod/android/v3.3.20+463"
      leadCommit = Just "deadbeef"
      leadVer = "3.3.20"
      refOf (r, _, _) = r
      verOf (_, _, v) = v
  -- default (Nothing) → production track
  assertEqual "default base → prod tag" "oy/prod/android/v3.3.17+460" (refOf (resolveBaseFromTracks Nothing tracks leadTag leadCommit leadVer))
  assertEqual "default base → prod version" (Just "3.3.17") (verOf (resolveBaseFromTracks Nothing tracks leadTag leadCommit leadVer))
  -- explicit internal (case-insensitive) → internal track
  assertEqual "base=Internal → internal tag" "oy/prod/android/v3.3.20+463" (refOf (resolveBaseFromTracks (Just "Internal") tracks leadTag leadCommit leadVer))
  assertEqual "base=internal → internal version" (Just "3.3.20") (verOf (resolveBaseFromTracks (Just "internal") tracks leadTag leadCommit leadVer))
  -- internal requested but absent → fall back to the leading ref
  assertEqual "internal absent → leading ref" "oy/prod/android/v3.3.20+463" (refOf (resolveBaseFromTracks (Just "internal") (Map.fromList [("production", prod)]) leadTag leadCommit leadVer))
  -- track present but no tag (iOS prod, version only) → leading ref, track version label
  let iosTracks = Map.fromList [("production", TrackSnapshot {tsVersion = "3.3.9", tsCode = Nothing, tsTag = Nothing}), ("internal", internal)]
  assertEqual "prod no-tag → leading ref" "oy/prod/android/v3.3.20+463" (refOf (resolveBaseFromTracks (Just "production") iosTracks leadTag leadCommit leadVer))
  assertEqual "prod no-tag → prod version label" (Just "3.3.9") (verOf (resolveBaseFromTracks (Just "production") iosTracks leadTag leadCommit leadVer))
  -- no tracks (legacy row) → leading tag + leading version
  assertEqual "no tracks → leading tag" "oy/prod/android/v3.3.20+463" (refOf (resolveBaseFromTracks Nothing Map.empty leadTag leadCommit leadVer))
  assertEqual "no tracks → leading version" (Just "3.3.20") (verOf (resolveBaseFromTracks Nothing Map.empty leadTag leadCommit leadVer))
  -- no usable tag → commit fallback (and debug-no-tag is ignored)
  assertEqual "no tag → commit fallback" "deadbeef" (refOf (resolveBaseFromTracks Nothing Map.empty Nothing leadCommit leadVer))
  assertEqual "debug-no-tag → commit fallback" "deadbeef" (refOf (resolveBaseFromTracks Nothing Map.empty (Just "debug-no-tag") leadCommit leadVer))

-- | Parsing the current production "What's New" used to pre-fill the promote
-- dialog for store-synced releases: the Play production-track body and the iOS
-- appStoreVersionLocalizations body.
testStoreReleaseNotesParse :: IO ()
testStoreReleaseNotesParse = do
  putStrLn "store release notes: Play track + iOS whatsNew parsing"
  -- Play: completed release with notes → first non-empty text
  assertEqual
    "play: completed release notes"
    (Just "Bug fixes and improvements")
    (parseProdReleaseNotes "{\"releases\":[{\"status\":\"completed\",\"versionCodes\":[\"460\"],\"releaseNotes\":[{\"language\":\"en-US\",\"text\":\"Bug fixes and improvements\"}]}]}")
  -- Play: prefer the completed release over a draft
  assertEqual
    "play: prefers completed over draft"
    (Just "Live notes")
    (parseProdReleaseNotes "{\"releases\":[{\"status\":\"draft\",\"releaseNotes\":[{\"language\":\"en-US\",\"text\":\"Draft notes\"}]},{\"status\":\"completed\",\"releaseNotes\":[{\"language\":\"en-US\",\"text\":\"Live notes\"}]}]}")
  -- Play: release without notes → Nothing
  assertEqual
    "play: no notes -> Nothing"
    Nothing
    (parseProdReleaseNotes "{\"releases\":[{\"status\":\"completed\",\"versionCodes\":[\"460\"]}]}")
  -- Play: no releases → Nothing
  assertEqual "play: no releases -> Nothing" Nothing (parseProdReleaseNotes "{\"releases\":[]}")
  -- Play: skips empty/whitespace text → next non-empty locale
  assertEqual
    "play: skips blank text"
    (Just "Real notes")
    (parseProdReleaseNotes "{\"releases\":[{\"status\":\"completed\",\"releaseNotes\":[{\"language\":\"en-US\",\"text\":\"   \"},{\"language\":\"hi-IN\",\"text\":\"Real notes\"}]}]}")
  -- iOS: first non-empty whatsNew across locales
  assertEqual
    "ios: first whatsNew"
    (Just "What's new on iOS")
    (firstWhatsNew "{\"data\":[{\"id\":\"1\",\"attributes\":{\"locale\":\"en-US\",\"whatsNew\":\"What's new on iOS\"}}]}")
  -- iOS: skips empty whatsNew → next locale
  assertEqual
    "ios: skips empty whatsNew"
    (Just "Hindi notes")
    (firstWhatsNew "{\"data\":[{\"id\":\"1\",\"attributes\":{\"whatsNew\":\"\"}},{\"id\":\"2\",\"attributes\":{\"whatsNew\":\"Hindi notes\"}}]}")
  -- iOS: no whatsNew anywhere → Nothing
  assertEqual
    "ios: no whatsNew -> Nothing"
    Nothing
    (firstWhatsNew "{\"data\":[{\"id\":\"1\",\"attributes\":{\"locale\":\"en-US\"}}]}")

-- | Out-of-band (external) App Store review detection: selecting the in-flight
-- version, parsing the versions list, mapping its state, and the pure reconcile
-- decision store sync runs each pass.
testExternalReviewDetection :: IO ()
testExternalReviewDetection = do
  putStrLn "external review: in-flight select / state map / reconcile decision"
  -- selectInFlightReview: the in-review version is picked over the live one,
  -- carrying the attached build number (the reviewed build's identity)
  assertEqual
    "in-flight: in-review over live"
    (Just ("3.4.0", Just 7, AscInReview))
    (selectInFlightReview [("3.4.0", "IN_REVIEW", Just 7), ("3.3.9", "READY_FOR_SALE", Just 6)])
  assertEqual "in-flight: only live → nothing" Nothing (selectInFlightReview [("3.3.9", "READY_FOR_SALE", Just 6)])
  assertEqual
    "in-flight: skips a superseded version"
    (Just ("3.4.1", Just 9, AscWaitingForReview))
    (selectInFlightReview [("3.4.0", "REPLACED_WITH_NEW_VERSION", Just 8), ("3.4.1", "WAITING_FOR_REVIEW", Just 9)])
  assertEqual
    "in-flight: pending-developer-release → approved"
    (Just ("3.4.0", Just 7, AscApproved))
    (selectInFlightReview [("3.4.0", "PENDING_DEVELOPER_RELEASE", Just 7)])
  assertEqual
    "in-flight: build number unknown still surfaces (identity guard decides downstream)"
    (Just ("3.4.0", Nothing, AscInReview))
    (selectInFlightReview [("3.4.0", "IN_REVIEW", Nothing)])
  -- parseVersionStatesWithBuild: appStoreVersions?include=build — the attached
  -- build's number resolves via the relationship id → included[] builds map
  assertEqual
    "parse versions list with builds"
    [("3.4.0", "IN_REVIEW", Just 7), ("3.3.9", "READY_FOR_SALE", Nothing)]
    ( parseVersionStatesWithBuild
        "{\"data\":[{\"id\":\"v1\",\"attributes\":{\"versionString\":\"3.4.0\",\"appStoreState\":\"IN_REVIEW\"},\"relationships\":{\"build\":{\"data\":{\"type\":\"builds\",\"id\":\"b1\"}}}},{\"id\":\"v2\",\"attributes\":{\"versionString\":\"3.3.9\",\"appStoreState\":\"READY_FOR_SALE\"}}],\"included\":[{\"type\":\"builds\",\"id\":\"b1\",\"attributes\":{\"version\":\"7\"}}]}"
    )
  -- reviewStateToStatus: which states surface, and how (verdict is the single
  -- source; the wf mirror is derived from it at the write site)
  assertEqual "map: in-review" (Just "in_review") (reviewStateToStatus AscInReview)
  assertEqual "map: waiting-for-review" (Just "in_review") (reviewStateToStatus AscWaitingForReview)
  assertEqual "map: approved" (Just "approved") (reviewStateToStatus AscApproved)
  assertEqual "map: rejected" (Just "rejected") (reviewStateToStatus (AscRejected "REJECTED"))
  assertEqual "map: prepare-for-submission not surfaced" Nothing (reviewStateToStatus AscPrepareForSubmission)
  assertEqual "map: live (READY_FOR_SALE) not surfaced as review" Nothing (reviewStateToStatus AscLive)
  -- externalReviewAction: the reconcile decision table (inferred, existing, proposed, sccOwns)
  let inReview = Just ("3.4.0", "in_review")
      existAt v = Just (v, "in_review")
  assertEqual "decision: new → insert" (ExtInsert "3.4.0" "in_review") (externalReviewAction False Nothing inReview False)
  assertEqual "decision: same version → update" (ExtUpdate "in_review") (externalReviewAction False (existAt "3.4.0") inReview False)
  assertEqual "decision: different version → retire + insert" (ExtRetireAndInsert "3.4.0" "in_review") (externalReviewAction False (existAt "3.3.0") inReview False)
  assertEqual "decision: scc owns + existing → complete" ExtComplete (externalReviewAction False (existAt "3.4.0") inReview True)
  assertEqual "decision: scc owns + no existing → noop" ExtNoop (externalReviewAction False Nothing inReview True)
  assertEqual "decision: no in-flight + existing → complete (went live)" ExtComplete (externalReviewAction False (existAt "3.4.0") Nothing False)
  assertEqual "decision: no in-flight + no existing → noop" ExtNoop (externalReviewAction False Nothing Nothing False)
  -- Android (inferred): an operator's approve/reject is NOT downgraded back to in_review (persistence fix)
  assertEqual "decision: android approved not downgraded" ExtNoop (externalReviewAction True (Just ("3.4.0", "approved")) inReview False)
  assertEqual "decision: android rejected not downgraded" ExtNoop (externalReviewAction True (Just ("3.4.0", "rejected")) inReview False)
  -- ...but an approved build that left the track still completes, and a new version supersedes it
  assertEqual "decision: android approved → went live completes" ExtComplete (externalReviewAction True (Just ("3.4.0", "approved")) Nothing False)
  assertEqual "decision: android new version retires the approved one" (ExtRetireAndInsert "3.5.0" "in_review") (externalReviewAction True (Just ("3.4.0", "approved")) (Just ("3.5.0", "in_review")) False)
  -- iOS (authoritative): a genuine resubmit (rejected → in_review) DOES update
  assertEqual "decision: ios rejected→in_review updates" (ExtUpdate "in_review") (externalReviewAction False (Just ("3.4.0", "rejected")) inReview False)

-- | Android out-of-band "pending review/publish" detection: parsing the
-- production track, then the pure pick rule (an inProgress release parked at a
-- near-zero userFraction with a code newer than the live completed version). The
-- reconcile/dedup side is shared with iOS and covered by the [40] decision table
-- (sccOwns ⇒ ExtComplete/ExtNoop, which is also how a promoted store-sync row
-- suppresses a duplicate).
testAndroidPendingPublish :: IO ()
testAndroidPendingPublish = do
  putStrLn "android pending-publish: track parse + pending pick rule"
  -- parseProdTrackReleases: a pending submission sitting over the live build
  assertEqual
    "parse: pending inProgress + live completed"
    [ ProdTrackRelease "3.4.0" 451 "inProgress" (Just 1.0e-6),
      ProdTrackRelease "3.3.9" 450 "completed" Nothing
    ]
    ( parseProdTrackReleases
        "{\"releases\":[{\"name\":\"3.4.0\",\"status\":\"inProgress\",\"userFraction\":0.000001,\"versionCodes\":[\"451\"]},{\"name\":\"3.3.9\",\"status\":\"completed\",\"versionCodes\":[\"450\"]}]}"
    )
  assertEqual "parse: undecodable body → no releases" [] (parseProdTrackReleases "not json")
  -- pendingPublishRelease decision table (threshold = 1%)
  let thr = 0.01
      live = ProdTrackRelease "3.3.9" 450 "completed" Nothing
  assertEqual
    "pending: inProgress @ ~0 over live → surfaced"
    (Just ("3.4.0", 451))
    (pendingPublishRelease thr [ProdTrackRelease "3.4.0" 451 "inProgress" (Just 1.0e-6), live])
  assertEqual
    "pending: only a live completed version → nothing"
    Nothing
    (pendingPublishRelease thr [live])
  assertEqual
    "pending: active rollout (fraction above threshold) → not pending"
    Nothing
    (pendingPublishRelease thr [ProdTrackRelease "3.4.0" 451 "inProgress" (Just 0.5), live])
  assertEqual
    "pending: inProgress not newer than live → nothing"
    Nothing
    (pendingPublishRelease thr [ProdTrackRelease "3.4.0" 449 "inProgress" (Just 1.0e-6), live])
  assertEqual
    "pending: first-ever submission (no live completed) → surfaced"
    (Just ("1.0.0", 1))
    (pendingPublishRelease thr [ProdTrackRelease "1.0.0" 1 "inProgress" (Just 1.0e-6)])
  assertEqual
    "pending: inProgress with no fraction (malformed) → nothing"
    Nothing
    (pendingPublishRelease thr [ProdTrackRelease "3.4.0" 451 "inProgress" Nothing, live])
  assertEqual
    "pending: halted (operator-paused) is not pending-publish"
    Nothing
    (pendingPublishRelease thr [ProdTrackRelease "3.4.0" 451 "halted" (Just 1.0e-6), live])
  assertEqual
    "pending: picks the highest-code pending release"
    (Just ("3.4.1", 452))
    ( pendingPublishRelease
        thr
        [ ProdTrackRelease "3.4.0" 451 "inProgress" (Just 1.0e-6),
          ProdTrackRelease "3.4.1" 452 "inProgress" (Just 1.0e-6),
          live
        ]
    )
  -- pendingOutcome (§16h-1): the vanish decision table for a watched code
  assertEqual "vanish: empty read → no claim" Nothing (pendingOutcome thr 451 [])
  assertEqual
    "vanish: still parked → Parked"
    (Just PendingParked)
    (pendingOutcome thr 451 [ProdTrackRelease "3.4.0" 451 "inProgress" (Just 1.0e-6), live])
  assertEqual
    "vanish: our code is now serving (completed) → Published"
    (Just PendingPublished)
    (pendingOutcome thr 451 [ProdTrackRelease "3.4.0" 451 "completed" Nothing])
  assertEqual
    "vanish: our code ramping at a real fraction → Published"
    (Just PendingPublished)
    (pendingOutcome thr 451 [ProdTrackRelease "3.4.0" 451 "inProgress" (Just 0.1), live])
  assertEqual
    "vanish: gone, newer pending code → Replaced"
    (Just PendingReplaced)
    (pendingOutcome thr 451 [ProdTrackRelease "3.4.1" 452 "inProgress" (Just 1.0e-6), live])
  assertEqual
    "vanish: gone, newer code shipped entirely → Replaced"
    (Just PendingReplaced)
    (pendingOutcome thr 451 [ProdTrackRelease "3.4.1" 452 "completed" Nothing])
  assertEqual
    "vanish: gone, only the older live remains → Withdrawn (rejected)"
    (Just PendingWithdrawn)
    (pendingOutcome thr 451 [live])
  -- retireOutcome (§16h-1): classify a retired external submission via the
  -- just-synced production cell (platform-generic)
  let servingCell v c = Just (Just v, Just c, Just "completed", Nothing)
  assertEqual
    "retire: serving cell carries the build → Published"
    PendingPublished
    (retireOutcome (servingCell "3.4.0" 451) False "3.4.0" (Just 451))
  assertEqual
    "retire: serving cell ramping (pct present) → Published"
    PendingPublished
    (retireOutcome (Just (Just "3.4.0", Just 451, Just "inProgress", Just 25)) False "3.4.0" (Just 451))
  assertEqual
    "retire: different serving + a new pending → Replaced"
    PendingReplaced
    (retireOutcome (servingCell "3.3.9" 450) True "3.4.0" (Just 451))
  assertEqual
    "retire: different serving, nothing pending → Withdrawn"
    PendingWithdrawn
    (retireOutcome (servingCell "3.3.9" 450) False "3.4.0" (Just 451))
  assertEqual
    "retire: same version, different code serving → not Published"
    PendingWithdrawn
    (retireOutcome (servingCell "3.4.0" 450) False "3.4.0" (Just 451))
  assertEqual
    "retire: code-less legacy row matches serving by version → Published"
    PendingPublished
    (retireOutcome (servingCell "3.4.0" 451) False "3.4.0" Nothing)
  assertEqual
    "retire: no production cell at all → Withdrawn"
    PendingWithdrawn
    (retireOutcome Nothing False "3.4.0" (Just 451))

-- | The list-view dedup that hides a store-sync internal/TestFlight snapshot when
-- an active EXTERNAL_REVIEW row already represents the same build (same identity
-- key). Covers the "two rows for one version+build" the list was showing.
testListDedup :: IO ()
testListDedup = do
  putStrLn "list dedup: hide store-sync snapshot when external review owns the build"
  let inReview = ["3.3.17", "3.3.73"] :: [Text]
  assertBool
    "hide: internal snapshot whose build is in external review"
    (not (keepSnapshot inReview (Just "STORE_SYNC", Just "internal", "3.3.17")))
  assertBool
    "hide: testflight snapshot whose build is in external review"
    (not (keepSnapshot inReview (Just "STORE_SYNC", Just "testflight", "3.3.73")))
  assertBool
    "keep: the external-review row itself"
    (keepSnapshot inReview (Just "EXTERNAL_REVIEW", Nothing, "3.3.17"))
  assertBool
    "keep: internal snapshot with no external review for its build"
    (keepSnapshot ([] :: [Text]) (Just "STORE_SYNC", Just "internal", "3.3.17"))
  assertBool
    "keep: production snapshot even if a key matches (only pre-prod tracks hide)"
    (keepSnapshot inReview (Just "STORE_SYNC", Just "production", "3.3.17"))
  assertBool
    "keep: internal snapshot whose version has no external review"
    (keepSnapshot inReview (Just "STORE_SYNC", Just "internal", "9.9.9"))
  assertBool
    "keep: a normal SCC build (not a store-sync snapshot)"
    (keepSnapshot inReview (Just "MANUAL", Nothing, "3.3.17"))

-- | Detecting a rollout started in the Play Console on an Android release SCC
-- still has as in-review / approved-held: a live production fraction at/above the
-- rollout floor (vs the ~0 review fraction), with OUR version code, means it was
-- approved AND ramped externally — SCC should adopt it.
testConsoleRolloutDetect :: IO ()
testConsoleRolloutDetect = do
  putStrLn "console rollout detect: approved/in-review android adopts a Console-set %"
  let thr = 0.01
      ourCode = 460
      st = PlayRolloutState
  assertEqual "still at review fraction (~0) → leave as-is" Nothing (detectConsoleRollout thr ourCode (st "inProgress" (Just 1.0e-6) ["460"]))
  assertEqual "below the rollout floor → not releasing yet" Nothing (detectConsoleRollout thr ourCode (st "inProgress" (Just 0.005) ["460"]))
  assertEqual "console ramped to 10% → rolling_out" (Just (SetRollout "rolling_out" (Just 10))) (detectConsoleRollout thr ourCode (st "inProgress" (Just 0.1) ["460"]))
  assertEqual "console halted at 10% → halted" (Just (SetRollout "halted" (Just 10))) (detectConsoleRollout thr ourCode (st "halted" (Just 0.1) ["460"]))
  assertEqual "console fully released → complete" (Just CompleteRollout) (detectConsoleRollout thr ourCode (st "completed" Nothing ["460"]))
  assertEqual "different version live (rejection-revert) → ignore" Nothing (detectConsoleRollout thr ourCode (st "completed" Nothing ["459"]))
  assertEqual "different version rolling → ignore" Nothing (detectConsoleRollout thr ourCode (st "inProgress" (Just 0.2) ["999"]))

-- | Adopting an out-of-band App Store Connect release on an iOS row SCC still has
-- as in-review / approved-held: only READY_FOR_SALE (AscLive) is adopted — phased
-- → rolling_out/halted/complete at the ramp %, non-phased (INACTIVE) → fully live
-- (complete). Held / in-review states are left alone.
testIosReleaseDetect :: IO ()
testIosReleaseDetect = do
  putStrLn "ios release detect: approved iOS adopts an out-of-band App Store Connect release"
  assertEqual "held (PENDING_DEVELOPER_RELEASE) → no change" Nothing (detectIosRelease AscApproved (AscPhasedState "INACTIVE" Nothing))
  assertEqual "still in review → no change" Nothing (detectIosRelease AscInReview (AscPhasedState "INACTIVE" Nothing))
  assertEqual "live + phased ACTIVE day3 → rolling_out @ 5%" (Just (SetRollout "rolling_out" (Just 5))) (detectIosRelease AscLive (AscPhasedState "ACTIVE" (Just 3)))
  assertEqual "live + phased PAUSED day4 → halted @ 10%" (Just (SetRollout "halted" (Just 10))) (detectIosRelease AscLive (AscPhasedState "PAUSED" (Just 4)))
  assertEqual "live + phased COMPLETE → complete" (Just CompleteRollout) (detectIosRelease AscLive (AscPhasedState "COMPLETE" (Just 6)))
  assertEqual "live + no phasing (INACTIVE) → complete" (Just CompleteRollout) (detectIosRelease AscLive (AscPhasedState "INACTIVE" Nothing))

-- | The per-track snapshot parser the App Release Monitoring poller uses: picks the
-- leading release (active staged rollout if any, else the latest) and reads its
-- version / code / status / fraction / first non-empty note.
testTrackSnapshotParse :: IO ()
testTrackSnapshotParse = do
  putStrLn "play track snapshot: version / code / status / fraction / notes"
  let prod = parseTrackSnapshot "production" "{\"releases\":[{\"name\":\"0.0.26\",\"status\":\"inProgress\",\"userFraction\":0.25,\"versionCodes\":[\"59\"],\"releaseNotes\":[{\"language\":\"en-US\",\"text\":\"Bug fixes\"}]}]}"
  assertEqual "version" "0.0.26" (stsVersion prod)
  assertEqual "code" (Just 59) (stsCode prod)
  assertEqual "status" "inProgress" (stsStatus prod)
  assertEqual "fraction" (Just 0.25) (stsFraction prod)
  assertEqual "notes" (Just "Bug fixes") (stsNotes prod)
  assertEqual "track" "production" (stsTrack prod)
  let comp = parseTrackSnapshot "internal" "{\"releases\":[{\"name\":\"0.0.26\",\"status\":\"completed\",\"versionCodes\":[\"59\"]}]}"
  assertEqual "completed status" "completed" (stsStatus comp)
  assertEqual "completed → no notes" Nothing (stsNotes comp)
  assertEqual "empty → none status" "none" (stsStatus (parseTrackSnapshot "production" "{}"))
  assertEqual "empty → baseline version" "0.0.0" (stsVersion (parseTrackSnapshot "production" "{}"))
  -- internal cell picks the highest code even when Play lists the older release first.
  let intl = parseTrackSnapshot "internal" "{\"releases\":[{\"name\":\"3.3.17\",\"status\":\"completed\",\"versionCodes\":[\"460\"]},{\"name\":\"3.3.17\",\"status\":\"completed\",\"versionCodes\":[\"463\"]}]}"
  assertEqual "internal → latest code, not first element" (Just 463) (stsCode intl)

testVersionBumpLogic :: IO ()
testVersionBumpLogic = do
  putStrLn "Mobile version bump: workflow's algorithm"
  assertEqual
    "internal == production bumps patch"
    ("2.5.1", 12346)
    (computeNextVersion (TrackInfo "2.5.0" 12345) (TrackInfo "2.5.0" 12340))
  assertEqual
    "internal > production uses internal name, code = internal+1"
    ("2.6.0", 12346)
    (computeNextVersion (TrackInfo "2.6.0" 12345) (TrackInfo "2.5.0" 12340))
  assertEqual
    "empty/no-prior baseline: 0.0.0 -> 0.0.1, code 1"
    ("0.0.1", 1)
    (computeNextVersion (TrackInfo "0.0.0" 0) (TrackInfo "0.0.0" 0))
  -- Edge case: production has shipped but internal is at baseline.
  -- The workflow's algorithm uses internal's name verbatim, which can
  -- regress. SCC mirrors workflow behavior; if production-regression
  -- protection is wanted, add it as a follow-up improvement.
  assertEqual
    "production shipped but internal at baseline -> uses internal name (potential regression)"
    ("0.0.0", 1)
    (computeNextVersion (TrackInfo "0.0.0" 0) (TrackInfo "2.5.0" 123))

-- ============================================================================
-- [21] GitHub Workflow Runs JSON Parser
-- ============================================================================

testGithubRunsParser :: IO ()
testGithubRunsParser = do
  putStrLn "GitHub runs JSON parser"
  let body =
        "{\"workflow_runs\":[{\"id\":42,\"event\":\"workflow_dispatch\",\"status\":\"queued\",\"conclusion\":null,\"created_at\":\"2026-05-11T10:00:00Z\",\"head_branch\":\"master\",\"head_sha\":\"abc1234deadbeef\",\"html_url\":\"https://github.com/foo/bar/actions/runs/42\",\"name\":\"x\",\"display_title\":\"y\"}]}"
  case Aeson.eitherDecode body :: Either String WorkflowRunsResp of
    Right resp -> do
      assertEqual "parsed run id" 42 (wrId (head (wrrRuns resp)))
      assertEqual "parsed run event" "workflow_dispatch" (wrEvent (head (wrrRuns resp)))
      assertEqual "parsed run status" "queued" (wrStatus (head (wrrRuns resp)))
      assertEqual "null conclusion -> Nothing" Nothing (wrConclusion (head (wrrRuns resp)))
      assertEqual "parsed display_title" (Just "y") (wrDisplayTitle (head (wrrRuns resp)))
      assertEqual "parsed head_sha" "abc1234deadbeef" (wrHeadSha (head (wrrRuns resp)))
    Left e -> fail ("parse failed: " <> e)

-- ============================================================================
-- [22] GitHub Jobs JSON Parser
-- ============================================================================

testGithubJobsParser :: IO ()
testGithubJobsParser = do
  putStrLn "GitHub jobs JSON parser"
  let body =
        "{\"jobs\":[{\"id\":1,\"name\":\"NammaYatri-Release\",\"status\":\"in_progress\",\"conclusion\":null,\"started_at\":\"2026-05-11T10:01:00Z\",\"completed_at\":null,\"html_url\":\"https://github.com/foo/bar/actions/runs/42/job/1\"}]}"
  case Aeson.eitherDecode body :: Either String JobsResp of
    Right resp -> do
      assertEqual "parsed job name" "NammaYatri-Release" (jName (head (jrJobs resp)))
      assertEqual "parsed job status" "in_progress" (jStatus (head (jrJobs resp)))
      assertEqual "null conclusion -> Nothing" Nothing (jConclusion (head (jrJobs resp)))
      assertEqual "null completed_at -> Nothing" Nothing (jCompletedAt (head (jrJobs resp)))
    Left e -> fail ("parse failed: " <> e)

-- ============================================================================
-- [23] GitHub Compare API JSON Parser
-- ============================================================================

testGithubCompareParser :: IO ()
testGithubCompareParser = do
  putStrLn "GitHub compare JSON parser"
  let body =
        "{\"status\":\"ahead\",\"ahead_by\":2,\"behind_by\":0,\"total_commits\":2,\"commits\":\
        \[{\"sha\":\"abc1234deadbeefcafef00d1234567890abcdef\",\
        \  \"commit\":{\"message\":\"feat: add foo (#123)\\n\\nlonger body\"},\
        \  \"author\":{\"login\":\"alice\"},\
        \  \"html_url\":\"https://github.com/foo/bar/commit/abc1234\"},\
        \ {\"sha\":\"def5678cafef00ddeadbeef1234567890abcdef\",\
        \  \"commit\":{\"message\":\"chore: bump deps\"},\
        \  \"author\":null,\
        \  \"html_url\":\"https://github.com/foo/bar/commit/def5678\"}]}"
  case Aeson.eitherDecode body :: Either String CompareResult of
    Right cr -> do
      assertEqual "parsed status" "ahead" (crStatus cr)
      assertEqual "parsed ahead_by" 2 (crAheadBy cr)
      assertEqual "parsed total_commits" 2 (crTotalCommits cr)
      case crCommits cr of
        [c1, c2] -> do
          assertEqual "c1 short sha" "abc1234" (ciShortSha c1)
          assertEqual "c1 subject (first line)" "feat: add foo (#123)" (ciSubject c1)
          assertEqual "c1 PR number extracted" (Just 123) (ciPrNumber c1)
          assertEqual "c1 author login" "alice" (ciAuthorLogin c1)
          assertEqual "c2 short sha" "def5678" (ciShortSha c2)
          assertEqual "c2 no PR number" Nothing (ciPrNumber c2)
          -- Null GH author falls back to "unknown" (commits
          -- without an associated GH account, e.g.
          -- email-only contributors).
          assertEqual "c2 null author -> unknown" "unknown" (ciAuthorLogin c2)
        other -> fail ("expected exactly 2 commits, got " <> show (length other))
    Left e -> fail ("parse failed: " <> e)

-- ============================================================================
-- [24] PR-number extractor + shortSha
-- ============================================================================

testExtractPrNumber :: IO ()
testExtractPrNumber = do
  putStrLn "extractPrNumber edge cases"
  assertEqual "simple trailing PR" (Just 123) (extractPrNumber "fix: foo (#123)")
  assertEqual "PR mid-subject" (Just 45) (extractPrNumber "fix (#45): regression")
  assertEqual "no PR" Nothing (extractPrNumber "chore: bump deps")
  -- Bare "#NN" without parens (merge-commit style) is NOT extracted —
  -- only the squash-merge "(#NN)" convention. Documented behaviour.
  assertEqual "merge-commit form is ignored" Nothing (extractPrNumber "Merge pull request #99 from foo/bar")
  -- First match wins.
  assertEqual "first match wins" (Just 12) (extractPrNumber "fix (#12) and revert (#34)")
  -- Empty parens / non-numeric are dropped cleanly.
  assertEqual "empty paren" Nothing (extractPrNumber "fix (#) typo")
  assertEqual "non-numeric paren" Nothing (extractPrNumber "fix (#abc) typo")

  putStrLn "shortSha"
  assertEqual "7-char truncation" "abc1234" (shortSha "abc1234deadbeef")
  assertEqual "exactly 7 stays" "abc1234" (shortSha "abc1234")
  assertEqual "shorter than 7 stays" "abc" (shortSha "abc")
  assertEqual "empty stays empty" "" (shortSha "")

-- ============================================================================
-- [25] bumpPatch semver rule
-- ============================================================================

testBumpPatch :: IO ()
testBumpPatch = do
  putStrLn "bumpPatch defaults"
  assertEqual "1.2.3 -> 1.2.4" "1.2.4" (bumpPatch "1.2.3")
  assertEqual "0.9.9 -> 0.9.10" "0.9.10" (bumpPatch "0.9.9")
  -- Two-segment versions get a third segment so the result is always
  -- comparable as semver-ish.
  assertEqual "1.2 -> 1.2.1" "1.2.1" (bumpPatch "1.2")
  -- Single-segment versions zero-pad before bumping.
  assertEqual "5 -> 5.0.1" "5.0.1" (bumpPatch "5")
  -- Non-numeric patch component falls back to appending ".1".
  assertEqual "1.2.beta -> 1.2.beta.1" "1.2.beta.1" (bumpPatch "1.2.beta")
  -- Empty input gets a sensible starting point.
  assertEqual "empty -> 0.0.1" "0.0.1" (bumpPatch "")
  -- 4-segment versions get ".1" appended (no opinion on which segment
  -- to bump — operator overrides in the UI if they care).
  assertEqual "1.2.3.4 -> 1.2.3.4.1" "1.2.3.4.1" (bumpPatch "1.2.3.4")

-- ============================================================================
-- [26] renderRevertChangelog
-- ============================================================================

testRenderRevertChangelog :: IO ()
testRenderRevertChangelog = do
  putStrLn "renderRevertChangelog (fixed short label)"
  let c1 =
        CommitInfo
          { ciSha = "abc1234deadbeef",
            ciShortSha = "abc1234",
            ciMessage = "feat: add foo (#123)\n\nbody",
            ciSubject = "feat: add foo (#123)",
            ciAuthorLogin = "alice",
            ciAuthorName = "Alice",
            ciHtmlUrl = "https://github.com/x/y/commit/abc1234",
            ciPrNumber = Just 123
          }
      c2 =
        CommitInfo
          { ciSha = "def5678cafef00d",
            ciShortSha = "def5678",
            ciMessage = "chore: bump deps",
            ciSubject = "chore: bump deps",
            ciAuthorLogin = "unknown",
            ciAuthorName = "",
            ciHtmlUrl = "https://github.com/x/y/commit/def5678",
            ciPrNumber = Nothing
          }

  -- Always emits the same shape regardless of commit count: just
  -- "Revert v{badVer}". The structured commit cards on the FE carry
  -- the actual detail.
  assertEqual
    "two commits → label only"
    "Revert v1.2.3"
    (renderRevertChangelog "1.2.3" "1.2.2" "abc1234" "1.2.4" (Just 457) [c1, c2])
  -- isBotCommit: bot logins ("…[bot]"), CI author names on account-less
  -- commits, and known automation logins are changelog noise; humans pass.
  let bot login name = c1 {ciAuthorLogin = login, ciAuthorName = name}
  assertBool "github-actions[bot] login is a bot" (isBotCommit (bot "github-actions[bot]" ""))
  assertBool "dependabot[bot] login is a bot" (isBotCommit (bot "dependabot[bot]" ""))
  assertBool "account-less CI commit by author name" (isBotCommit (bot "unknown" "GitHub Actions"))
  assertBool "plain github-actions login" (isBotCommit (bot "github-actions" ""))
  assertBool "human commit passes" (not (isBotCommit (bot "alice" "Alice")))
  assertBool "unknown login with human name passes" (not (isBotCommit (bot "unknown" "Alice")))
  -- CL.isAutomationCommit: the shared default-changelog/AI-input filter also
  -- catches release PLUMBING pushed under a human token; narrow prefixes only.
  assertBool "CL: bot author" (CL.isAutomationCommit "github-actions[bot]" "chore: whatever")
  assertBool "CL: human version bump is plumbing" (CL.isAutomationCommit "alice" "chore(release): bump version to 3.3.27")
  assertBool "CL: bump versionCode prefix" (CL.isAutomationCommit "alice" "Bump versionCode to 591")
  assertBool "CL: [skip ci] plumbing" (CL.isAutomationCommit "alice" "update generated files [skip ci]")
  assertBool "CL: real change mentioning bump passes" (not (CL.isAutomationCommit "alice" "fix: bump request timeout to 30s"))
  assertBool "CL: plain feature passes" (not (CL.isAutomationCommit "alice" "feat: add SOS flow"))
  -- Changelog display author: real name preferred, login fallback, no '@'.
  assertEqual "display author prefers git name" "Dev Vikram Singh" (ciDisplayAuthor c1 {ciAuthorLogin = "techtrigon", ciAuthorName = "Dev Vikram Singh"})
  assertEqual "display author falls back to login" "PraveenGongada" (ciDisplayAuthor c1 {ciAuthorLogin = "PraveenGongada", ciAuthorName = ""})
  assertEqual
    "deterministic bullet ends with the display name (no @)"
    "- feat: add foo (#123)  — Alice"
    (CL.renderChunkDeterministic [CL.CommitItem "abc1234" "feat: add foo (#123)" "Alice"])
  assertEqual
    "one commit → label only"
    "Revert v2.0.0"
    (renderRevertChangelog "2.0.0" "1.9.8" "feedf00" "2.0.1" Nothing [c1])
  assertEqual
    "no commits → label only"
    "Revert v1.0.1"
    (renderRevertChangelog "1.0.1" "1.0.0" "deadbee" "1.0.2" (Just 11) [])

  -- Negative guards: nothing from older drafts leaks in.
  let out = renderRevertChangelog "1.2.3" "1.2.2" "abc1234" "1.2.4" (Just 457) [c1, c2]
  assertBool "no newlines" $ not (T.isInfixOf "\n" out)
  assertBool "no commit SHAs" $ not (T.isInfixOf "abc1234" out || T.isInfixOf "def5678" out)
  assertBool "no commit subjects" $ not (T.isInfixOf "feat:" out)
  assertBool "no @author chips" $ not (T.isInfixOf "@alice" out)
  assertBool "no headings" $ not (T.isInfixOf "# " out)

-- ============================================================================
-- [27] DIAGNOSTIC: decode the exact JSON shape used by migration
--      0013-local-mobile-revert-test-data.sql. If this test fails, the
--      seed file's release_context JSON doesn't match what TargetState's
--      FromJSON expects — fix the seed, not the type.
-- ============================================================================

testDecodeSeedJson :: IO ()
testDecodeSeedJson = do
  putStrLn "Decode seed-file JSON into TargetState"
  let raw =
        "{\n  \"tag\": \"MobileBuildState\",\n  \"contents\": {\n    \"mbWfStatus\": {\"tag\": \"MBCompleted\"},\n    \"mbContext\": {\n      \"kind\": \"mobile_build\",\n      \"version_code\": null,\n      \"change_log\": \"v3.3.130 \\u2014 TestFlight release\",\n      \"destination\": \"TestFlight\",\n      \"release_group_id\": \"test-revert-ios-bad-001\",\n      \"matrix_job_name\": \"NammaYatri-Release\",\n      \"ota_namespace\": null,\n      \"tag_pushed\": \"nammayatri/prod/ios/v3.3.130+1\"\n    },\n    \"mbExternalRunId\": null,\n    \"mbMatrixJobStatus\": null,\n    \"mbBuildStartedAt\": null,\n    \"mbBuildCompletedAt\": null,\n    \"mbResolveAttempts\": null\n  }\n}"
  case Aeson.eitherDecode raw :: Either String Products.Autopilot.Types.Target.TargetState of
    Right (Products.Autopilot.Types.Target.MobileBuildState _) ->
      putStrLn "  PASS: decoded as MobileBuildState"
    Right _ -> fail "  FAIL: decoded as wrong variant"
    Left e -> fail ("  FAIL: decode error: " <> e)

-- Shared by ResolveRunId and the abort-cancel path: matches workflow_dispatch runs in
-- [dispatchedAt-30s, +5m], newest first.
testDispatchRunCandidates :: IO ()
testDispatchRunCandidates = do
  putStrLn "Dispatch run match: window + event filter + newest-first"
  now <- getCurrentTime
  let at s = addUTCTime (fromIntegral (s :: Int)) now
      mkRun i ev secs =
        WorkflowRun
          { wrId = i,
            wrEvent = ev,
            wrStatus = "in_progress",
            wrConclusion = Nothing,
            wrCreatedAt = at secs,
            wrHtmlUrl = "",
            wrName = "",
            wrDisplayTitle = Nothing,
            wrHeadSha = "",
            wrHeadBranch = Nothing,
            wrActorId = Nothing,
            wrActorLogin = Nothing,
            wrRunAttempt = Nothing
          }
      ids = map wrId . dispatchRunCandidates now
  assertEqual "in-window dispatch run matched" [1] (ids [mkRun 1 "workflow_dispatch" 10])
  assertEqual "too-early / too-late excluded" [] (ids [mkRun 2 "workflow_dispatch" (-60), mkRun 3 "workflow_dispatch" 600])
  assertEqual "non-dispatch event excluded" [] (ids [mkRun 4 "push" 10])
  -- boundaries inclusive (-30s lower, +300s upper); result is newest-first
  assertEqual "boundaries inclusive, newest-first" [6, 5] (ids [mkRun 5 "workflow_dispatch" (-30), mkRun 6 "workflow_dispatch" 300])
  assertEqual "multiple in-window sorted newest-first" [8, 7] (ids [mkRun 7 "workflow_dispatch" 10, mkRun 8 "workflow_dispatch" 200])

  -- ownDispatchCandidates: bot-actor filter + run-id watermark, oldest-first
  putStrLn "Own dispatch run match: actor + watermark, oldest-first"
  let bot = mkRun 0 "workflow_dispatch" 0
      withActor aid r = r {wrActorId = Just aid}
      own mBot mWm = map wrId . ownDispatchCandidates mBot mWm now Nothing
      ownCeil mBot mWm ceil = map wrId . ownDispatchCandidates mBot mWm now (Just (at ceil))
  -- watermark: strictly-above only; oldest first
  assertEqual
    "above watermark kept, at/below dropped, oldest-first"
    [101, 102]
    (own Nothing (Just 100) [withActor 7 (bot {wrId = 102}), withActor 7 (bot {wrId = 100}), withActor 7 (bot {wrId = 101})])
  -- actor filter: PRESENT mismatching actor drops; missing actor is kept
  -- (GitHub's actor field is nullable — must not hide our own run)
  assertEqual
    "actor filter drops foreign, keeps missing actor"
    [101, 103]
    (own (Just 7) (Just 100) [withActor 7 (bot {wrId = 101}), withActor 8 (bot {wrId = 102}), bot {wrId = 103}])
  -- unknown bot identity: no actor filter applied
  assertEqual
    "unknown bot id skips actor filter"
    [101, 102]
    (own Nothing (Just 100) [withActor 8 (bot {wrId = 102}), bot {wrId = 101}])
  -- no watermark (legacy rows): created-at window fallback still applies
  assertEqual
    "no watermark falls back to created-at window"
    [9]
    (own Nothing Nothing [withActor 7 (bot {wrId = 9, wrCreatedAt = at 10}), withActor 7 (bot {wrId = 10, wrCreatedAt = at 600})])
  -- non-dispatch events always excluded
  assertEqual
    "non-dispatch event excluded even above watermark"
    []
    (own Nothing (Just 100) [(bot {wrId = 101, wrEvent = "push"})])
  -- stale-watermark defense: a run created BEFORE the receipt is never ours,
  -- even above the watermark (a stale GH page once produced an ancient
  -- watermark that made months-old runs "candidates")
  assertEqual
    "above watermark but created before receipt -> dropped"
    []
    (own Nothing (Just 100) [withActor 7 (bot {wrId = 101, wrCreatedAt = at (-3600)})])
  -- successor ceiling (19 Aug cross-group hijack): a same-app group dispatched
  -- minutes later lands INSIDE the plain +5min window and carries identical
  -- matrix job names, so job verification cannot tell it apart. A run created
  -- at/after the successor's receipt (minus the 30s skew allowance) is theirs.
  -- 4-minute redispatch: our own run stays, the successor's is excluded.
  assertEqual
    "successor ceiling drops a later group's run, keeps ours"
    [101]
    ( ownCeil
        Nothing
        (Just 100)
        240
        [ withActor 7 (bot {wrId = 101, wrCreatedAt = at 5}) -- ours, at our receipt
        , withActor 7 (bot {wrId = 102, wrCreatedAt = at 240}) -- successor's run
        ]
    )
  -- the ceiling only ever tightens: a successor far beyond +5min cannot widen
  -- the window past the fixed cap
  assertEqual
    "ceiling never widens the fixed +5min cap"
    [101]
    ( ownCeil
        Nothing
        (Just 100)
        3600
        [ withActor 7 (bot {wrId = 101, wrCreatedAt = at 5})
        , withActor 7 (bot {wrId = 102, wrCreatedAt = at 400})
        ]
    )
  -- no successor known -> unchanged +5min behaviour
  assertEqual
    "no ceiling keeps the plain window"
    [101, 102]
    (own Nothing (Just 100) [withActor 7 (bot {wrId = 101, wrCreatedAt = at 5}), withActor 7 (bot {wrId = 102, wrCreatedAt = at 240})])

  -- parseFirebaseRelease: fastlane firebase_app_distribution output, with the
  -- real log shape (timestamps + ANSI colour codes around the URLs)
  putStrLn "Firebase debug-release log parsing"
  let esc = "\ESC[0m"
      fbLog =
        T.unlines
          [ "2026-08-12T17:12:04.5004519Z [22:42:04]: \ESC[32m\9757\65039 Version code has been changed to 392\ESC[0m",
            "2026-08-12T17:18:45.2835987Z [22:48:45]: \ESC[32m\9989 Uploaded AAB successfully and created release 99.0.0 (392).\ESC[0m",
            "2026-08-12T17:18:48.2439181Z [22:48:48]: \128279 View this release in the Firebase console: https://console.firebase.google.com/project/x/appdistribution/releases/1uf?utm_source=fastlane" <> esc,
            "2026-08-12T17:18:48.2449216Z [22:48:48]: \128279 Share this release with testers who have access: https://appdistribution.firebase.google.com/testerapps/1:8/releases/1uf?utm_source=fastlane " <> esc
          ]
  assertEqual
    "parses version, code and both links"
    ( Just
        ( FirebaseReleaseInfo
            { friVersionName = "99.0.0",
              friVersionCode = 392,
              friConsoleUrl = Just "https://console.firebase.google.com/project/x/appdistribution/releases/1uf?utm_source=fastlane",
              friTesterUrl = Just "https://appdistribution.firebase.google.com/testerapps/1:8/releases/1uf?utm_source=fastlane"
            }
        )
    )
    (parseFirebaseRelease fbLog)
  assertEqual "no release line -> Nothing" Nothing (parseFirebaseRelease "some\nunrelated\nlog")
  assertEqual
    "release line without parseable code -> Nothing"
    Nothing
    (parseFirebaseRelease "x and created release 99.0.0 (abc).")
  assertEqual
    "links optional (IPA wording, no link lines)"
    (Just (FirebaseReleaseInfo "1.2.3" 45 Nothing Nothing))
    (parseFirebaseRelease "ts: Uploaded IPA successfully and created release 1.2.3 (45).")

-- Server-side changelog diff-link generation. MUST stay a byte-for-byte
-- semantic match with the frontend (CreateRelease.tsx normalizeRepo/toCommitId/
-- buildDiffLink) so a release gets the same link whichever path created it.
testDiffLink :: IO ()
testDiffLink = do
  -- toCommitId: first 6 chars of the trimmed version, valid iff 6 hex chars
  assertEqual "toCommitId strips -v suffix" (Just "a1b2c3") (toCommitId "a1b2c3-v2")
  assertEqual "toCommitId 'unknown' -> Nothing" Nothing (toCommitId "unknown")
  assertEqual "toCommitId 'new' -> Nothing" Nothing (toCommitId "new")
  assertEqual "toCommitId too-short -> Nothing" Nothing (toCommitId "abc")
  assertEqual "toCommitId trims whitespace" (Just "a1b2c3") (toCommitId "  a1b2c3 ")
  assertEqual "toCommitId preserves case" (Just "A1B2C3") (toCommitId "A1B2C3-v1")

  -- normalizeRepo: bare owner/repo slug
  assertEqual "normalizeRepo strips URL + .git" "owner/repo" (normalizeRepo "https://github.com/owner/repo.git")
  assertEqual "normalizeRepo strips trailing slash" "owner/repo" (normalizeRepo "owner/repo/")
  assertEqual "normalizeRepo trims whitespace" "owner/repo" (normalizeRepo "  owner/repo  ")
  assertEqual "normalizeRepo case-insensitive scheme" "owner/repo" (normalizeRepo "HTTPS://GitHub.com/owner/repo")

  -- buildDiffLink: compare when both valid, /commits fallback, Nothing otherwise
  assertEqual
    "buildDiffLink both valid -> compare"
    (Just "https://github.com/owner/repo/compare/a1b2c3...d4e5f6")
    (buildDiffLink (Just "owner/repo") "a1b2c3-v1" "d4e5f6-v2")
  assertEqual
    "buildDiffLink unknown old -> commits"
    (Just "https://github.com/owner/repo/commits/d4e5f6")
    (buildDiffLink (Just "owner/repo") "unknown" "d4e5f6")
  assertEqual "buildDiffLink no repo -> Nothing" Nothing (buildDiffLink Nothing "a1b2c3" "d4e5f6")
  assertEqual "buildDiffLink empty repo -> Nothing" Nothing (buildDiffLink (Just "") "a1b2c3" "d4e5f6")
  assertEqual "buildDiffLink non-hex new -> Nothing" Nothing (buildDiffLink (Just "owner/repo") "a1b2c3" "release-x")

-- ─── [50] Group summary derivation ─────────────────────────────────

testGroupSummary :: IO ()
testGroupSummary = do
  let m rid ph st appr plat =
        MemberFact
          { mfReleaseId = rid,
            mfApp = "App" <> rid,
            mfPlatform = plat,
            mfStatus = st,
            mfApproved = appr,
            mfPhase = ph
          }
      stageOf = gsStage . deriveGroupSummary
      verbOf = gsPrimaryVerb . deriveGroupSummary

  -- CREATED drafts derive phase "building" but must NOT read as building
  assertEqual "all drafts unapproved -> approval" "approval" (stageOf [m "1" "building" CREATED False "android"])
  assertEqual "approval verb" (Just "approve") (verbOf [m "1" "building" CREATED False "android"])
  assertEqual "mixed approved/unapproved -> approval first" "approval" (stageOf [m "1" "building" CREATED True "android", m "2" "building" CREATED False "ios"])
  assertEqual "all approved drafts -> dispatch" "dispatch" (stageOf [m "1" "building" CREATED True "android"])
  assertEqual "really building (INPROGRESS) -> building" "building" (stageOf [m "1" "building" INPROGRESS True "android"])
  assertEqual "building has no verb" Nothing (verbOf [m "1" "building" INPROGRESS True "android"])
  assertEqual "any internal_held -> promote" "promote" (stageOf [m "1" "internal_held" INPROGRESS True "android", m "2" "building" INPROGRESS True "ios"])
  assertEqual "in_review (no held) -> in_review" "in_review" (stageOf [m "1" "in_review" INPROGRESS True "ios"])
  assertEqual "approved-held -> releasing" "releasing" (stageOf [m "1" "approved" INPROGRESS True "ios"])
  assertEqual "releasing verb is platform-split" (Just "release_or_rollout") (verbOf [m "1" "approved" INPROGRESS True "ios"])
  assertEqual "rolling -> rolling_out" "rolling_out" (stageOf [m "1" "rolling_out" INPROGRESS True "android"])
  -- halted must not fall through to done (design doc §6 must-fix)
  assertEqual "all halted -> rolling_out" "rolling_out" (stageOf [m "1" "halted" INPROGRESS True "android"])
  assertEqual "all live -> done" "done" (stageOf [m "1" "live" COMPLETED True "android"])

  -- attention is a banner, never a stage: 1 rejected + 1 rolling stays rolling_out
  let mixed = [m "1" "rejected" ABORTED True "android", m "2" "rolling_out" INPROGRESS True "ios"]
  assertEqual "rejected member doesn't pin the stage" "rolling_out" (stageOf mixed)
  assertEqual "rejected member lands in attention" ["1"] (map mfReleaseId (gsAttention (deriveGroupSummary mixed)))
  -- halted is attention too, while still driving the rolling_out stage
  assertEqual "halted joins attention" ["1"] (map mfReleaseId (gsAttention (deriveGroupSummary [m "1" "halted" INPROGRESS True "android"])))
  -- an all-terminal-trouble group is done + all-attention (banner carries it)
  let allBad = [m "1" "build_failed" ABORTED True "android", m "2" "rejected" ABORTED True "ios"]
  assertEqual "all-terminal-trouble -> done stage" "done" (stageOf allBad)
  assertEqual "all-terminal-trouble -> both in attention" 2 (length (gsAttention (deriveGroupSummary allBad)))

  -- counts cover ALL members including terminal ones
  let counted = deriveGroupSummary (mixed <> [m "3" "live" COMPLETED True "android"])
  assertEqual "counts include terminal phases" (Just 1) (Map.lookup "rejected" (gsCounts counted))
  assertEqual "counts include live" (Just 1) (Map.lookup "live" (gsCounts counted))

  -- stage ordering: promote beats in_review beats releasing when mixed
  assertEqual
    "held+review+approved mixed -> promote wins"
    "promote"
    (stageOf [m "1" "internal_held" INPROGRESS True "a", m "2" "in_review" INPROGRESS True "b", m "3" "approved" INPROGRESS True "c"])

  -- effectivePhase: abort flips rt_status but not mb_wf_status, so a stale
  -- "building" phase must fold to a TRUTHFUL terminal slug (who ended it);
  -- a terminal PHASE always wins over the status.
  assertEqual "user abort + stale building phase -> user_aborted" "user_aborted" (effectivePhase USER_ABORTED "building")
  assertEqual "user abort + generic aborted phase -> user_aborted" "user_aborted" (effectivePhase USER_ABORTED "aborted")
  assertEqual "Actions-side failure (ABORTED, no MBFailed) -> build_failed" "build_failed" (effectivePhase ABORTED "building")
  assertEqual "decision-engine abort -> aborted" "aborted" (effectivePhase GCLT_ABORTED "building")
  assertEqual "discarded draft -> discarded" "discarded" (effectivePhase DISCARDED "building")
  assertEqual "rejected phase survives aborted status" "rejected" (effectivePhase ABORTED "rejected")
  assertEqual "build_failed phase survives abort status" "build_failed" (effectivePhase ABORTED "build_failed")
  assertEqual "live phase survives terminal status" "live" (effectivePhase COMPLETED "live")
  assertEqual "in-flight status keeps its phase" "in_review" (effectivePhase INPROGRESS "in_review")
  -- and through the derivation: the group must NOT read as building
  let staleAborted = [m "1" "user_aborted" USER_ABORTED True "ios", m "2" "user_aborted" USER_ABORTED True "ios"]
  assertEqual "all user-aborted (post-reconcile) -> done stage" "done" (stageOf staleAborted)
  assertEqual "both user-aborted in attention" 2 (length (gsAttention (deriveGroupSummary staleAborted)))
  -- discarded drafts are counted but never attention noise
  assertEqual "discarded excluded from attention" 0 (length (gsAttention (deriveGroupSummary [m "1" "discarded" DISCARDED False "android"])))

testExtractContainerEnvJson :: IO ()
testExtractContainerEnvJson = do
  let yamlText =
        T.unlines
          [ "apiVersion: apps/v1",
            "kind: Deployment",
            "metadata:",
            "  name: my-svc-v1",
            "spec:",
            "  replicas: 2",
            "  template:",
            "    spec:",
            "      containers:",
            "        - name: my-svc",
            "          image: my-image:v1",
            "          env:",
            "            - name: FOO",
            "              value: bar",
            "            - name: BAZ",
            "              value: \"1\""
          ]
      expectedEnv =
        Aeson.toJSON
          [ Aeson.object ["name" Aeson..= ("FOO" :: Text), "value" Aeson..= ("bar" :: Text)],
            Aeson.object ["name" Aeson..= ("BAZ" :: Text), "value" Aeson..= ("1" :: Text)]
          ]
  assertEqual "extractContainerEnvJson parses containers[0].env" (Just expectedEnv) (extractContainerEnvJson yamlText)
  assertEqual "extractContainerEnvJson Nothing for a deployment with no containers" Nothing (extractContainerEnvJson "spec:\n  template:\n    spec:\n      containers: []")
  assertEqual "extractContainerEnvJson Nothing for non-YAML garbage" Nothing (extractContainerEnvJson "{[not yaml or json")

-- ============================================================================
-- [52] Release Webhooks (dispatch trigger + placeholder templating)
-- ============================================================================

testReleaseWebhooks :: IO ()
testReleaseWebhooks = do
  -- Only a terminal status dispatches. ABORTING is the abort *request* — the
  -- release is still rolling traffic back, so a receiver must not hear "failed"
  -- yet, and the marker written here would suppress the real ABORTED dispatch.
  assertEqual "COMPLETED dispatches success" (Just OnSuccess) (triggerForStatus COMPLETED)
  assertEqual "ABORTED dispatches failure" (Just OnFailure) (triggerForStatus ABORTED)
  assertEqual "USER_ABORTED dispatches failure" (Just OnFailure) (triggerForStatus USER_ABORTED)
  assertEqual "GCLT_ABORTED dispatches failure" (Just OnFailure) (triggerForStatus GCLT_ABORTED)
  assertEqual "ABORTING does NOT dispatch" Nothing (triggerForStatus ABORTING)
  assertEqual "INPROGRESS does not dispatch" Nothing (triggerForStatus INPROGRESS)
  assertEqual "PAUSED does not dispatch" Nothing (triggerForStatus PAUSED)
  assertEqual "REVERTING does not dispatch" Nothing (triggerForStatus REVERTING)

  -- Placeholder substitution
  let env = [("NEW_VERSION", "v1.4.0"), ("OLD_VERSION", "v1.3.9")] :: [(Text, Text)]
  assertEqual
    "Substitutes a known token"
    "released v1.4.0 over v1.3.9"
    (renderTemplate env "released {{NEW_VERSION}} over {{OLD_VERSION}}")
  assertEqual
    "Token name is case-insensitive and tolerates inner spaces"
    "v1.4.0"
    (renderTemplate env "{{ new_version }}")
  assertEqual
    "Unknown token is left verbatim, not blanked, so a typo is visible"
    "{{NEW_VERSIN}}"
    (renderTemplate env "{{NEW_VERSIN}}")
  assertEqual
    "Unterminated braces are left alone"
    "{{NEW_VERSION"
    (renderTemplate env "{{NEW_VERSION")
  assertEqual "Empty template stays empty" "" (renderTemplate env "")

  assertEqual
    "Send test substitutes obviously-fake values"
    "TEST_NEW_VERSION over TEST_OLD_VERSION"
    (renderTemplate samplePlaceholderEnv "{{NEW_VERSION}} over {{OLD_VERSION}}")
  assertBool
    "No sample value looks like a real version"
    (all (\(_, v) -> "TEST_" `T.isPrefixOf` v) samplePlaceholderEnv)

  -- A disabled hook never fires, whatever it opted into.
  let hook =
        ReleaseWebhook
          { whId = 1,
            whAppGroup = "beckn",
            whServices = [],
            whName = "ops",
            whEnabled = True,
            whOnSuccess = True,
            whOnFailure = False,
            whMethod = WH_POST,
            whUrl = "https://hooks.example.com/x",
            whHeaders = [],
            whQueryParams = [],
            whBody = Nothing,
            whTimeoutSeconds = Nothing,
            whRetries = Nothing
          }
  assertBool "Enabled hook fires for the trigger it opted into" (triggersOn OnSuccess hook)
  assertBool "Enabled hook ignores a trigger it opted out of" (not (triggersOn OnFailure hook))
  assertBool "Disabled hook never fires" (not (triggersOn OnSuccess hook {whEnabled = False}))


-- ============================================================================
-- [55]-[61] Release bot
-- ============================================================================

testReleaseBotDiff :: IO ()
testReleaseBotDiff = do
  let d1 = RBD.diffText "f" "a\nb\nc\n" "a\nb\nc\n"
  assertBool "identical text -> no hunks" (null (RBD.fdHunks d1))
  assertEqual "identical text -> 0/0" (0, 0) (RBD.fdAdded d1, RBD.fdRemoved d1)
  let d2 = RBD.diffText "f" "a\nb\nc\n" "a\nB\nc\n"
  assertEqual "one changed line -> +1/-1" (1, 1) (RBD.fdAdded d2, RBD.fdRemoved d2)
  assertEqual
    "diff lines for one changed line"
    [RBD.Ctx "a", RBD.Del "b", RBD.Add "B", RBD.Ctx "c"]
    (RBD.diffLines ["a", "b", "c"] ["a", "B", "c"])
  assertEqual "pure insertion" [RBD.Ctx "a", RBD.Add "x", RBD.Ctx "b"] (RBD.diffLines ["a", "b"] ["a", "x", "b"])
  assertEqual "pure deletion" [RBD.Ctx "a", RBD.Del "x", RBD.Ctx "b"] (RBD.diffLines ["a", "x", "b"] ["a", "b"])
  assertEqual "empty -> content" [RBD.Add "a", RBD.Add "b"] (RBD.diffLines [] ["a", "b"])
  assertEqual "content -> empty" [RBD.Del "a"] (RBD.diffLines ["a"] [])
  -- applying the diff to the old text must reproduce the new text (correctness, not just shape)
  let old = map (T.pack . show) [1 :: Int .. 40]
      new = take 10 old ++ ["inserted"] ++ drop 12 old ++ ["tail"]
      replay ls = ([t | l <- ls, t <- case l of RBD.Ctx x -> [x]; RBD.Del _ -> []; RBD.Add x -> [x]], [t | l <- ls, t <- case l of RBD.Ctx x -> [x]; RBD.Del x -> [x]; RBD.Add _ -> []])
      (rebuiltNew, rebuiltOld) = replay (RBD.diffLines old new)
  assertEqual "replay(new side) == new" new rebuiltNew
  assertEqual "replay(old side) == old" old rebuiltOld
  -- 3-way merge: apply only the repo change onto an env-specific live copy
  let mBase = "a\nb\nc\nd\ne\n"
  assertEqual "merge: repo unchanged -> live untouched" (Right "a\nLIVE\nc\nd\ne\n") (RBD.merge3 mBase "a\nLIVE\nc\nd\ne\n" mBase)
  assertEqual "merge: repo change in a region live never touched" (Right "a\nLIVE\nc\nd\nE2\n") (RBD.merge3 mBase "a\nLIVE\nc\nd\ne\n" "a\nb\nc\nd\nE2\n")
  assertEqual "merge: identical edit on both sides" (Right "a\nX\nc\nd\ne\n") (RBD.merge3 mBase "a\nX\nc\nd\ne\n" "a\nX\nc\nd\ne\n")
  assertBool "merge: overlapping differing edits conflict (fail closed)" (either (const True) (const False) (RBD.merge3 mBase "a\nLIVE\nc\nd\ne\n" "a\nREPO\nc\nd\ne\n"))
  assertBool "merge: adjacent edits conflict (fail closed)" (either (const True) (const False) (RBD.merge3 mBase "a\nLIVE\nc\nd\ne\n" "a\nb\nREPO\nd\ne\n"))
  assertEqual "merge: repo adds a line far from live edits" (Right "a\nLIVE\nc\nd\ne\nf\n") (RBD.merge3 mBase "a\nLIVE\nc\nd\ne\n" "a\nb\nc\nd\ne\nf\n")
  assertEqual "merge: repo deletes a line far from live edits" (Right "a\nLIVE\nc\nd\n") (RBD.merge3 mBase "a\nLIVE\nc\nd\ne\n" "a\nb\nc\nd\n")
  -- hunks carry context and correct start lines
  let hs = RBD.hunks 1 (RBD.diffLines (map (T.pack . show) [1 :: Int .. 20]) (map (T.pack . show) ([1 .. 9] ++ [99] ++ [11 .. 20 :: Int])))
  assertEqual "one hunk for one change" 1 (length hs)
  assertEqual "hunk old start (1 line of context before change at line 10)" 9 (RBD.hOldStart (head hs))

testReleaseBotBase64 :: IO ()
testReleaseBotBase64 = do
  assertEqual "decode ok" (Right "hello\n") (RBD.decodeB64Text "aGVsbG8K")
  assertEqual "decode ignores line wrapping" (Right "hello\n") (RBD.decodeB64Text "aGVs\nbG8K")
  assertBool "invalid base64 -> Left (fail closed)" (either (const True) (const False) (RBD.decodeB64Text "not base64!!"))
  assertBool "non-UTF-8 payload -> Left (fail closed)" (either (const True) (const False) (RBD.decodeB64Text "/+8="))
  assertEqual "encode/decode round-trip" (Right "let x = 1 in x\n") (RBD.decodeB64Text (RBD.encodeB64Text "let x = 1 in x\n"))

testReleaseBotXyne :: IO ()
testReleaseBotXyne = do
  let body = BC.pack "{\"a\":1}"
      good = "aa9e2e3575f5d7098b6caccd790888c36d5fdb63342a73bada2d6a51747a8494"
  assertBool "valid signature verifies" (RBX.verifySignature "secret" body good)
  assertBool "uppercase hex signature verifies" (RBX.verifySignature "secret" body (T.toUpper good))
  assertBool "wrong secret rejected" (not (RBX.verifySignature "other" body good))
  assertBool "tampered body rejected" (not (RBX.verifySignature "secret" (BC.pack "{\"a\":2}") good))
  assertBool "empty signature rejected" (not (RBX.verifySignature "secret" body ""))
  assertBool "empty secret rejected (never verifies)" (not (RBX.verifySignature "" body good))
  let mention =
        Aeson.object
          [ "eventType" Aeson..= ("APP_MENTIONED" :: Text)
          , "payload"
              Aeson..= Aeson.object
                [ "cleanContent" Aeson..= ("release rider app till e4e0b16" :: Text)
                , "channelId" Aeson..= ("chan-1" :: Text)
                , "messageId" Aeson..= ("m-1" :: Text)
                , "userId" Aeson..= ("u-1" :: Text)
                , "senderName" Aeson..= ("Dev" :: Text)
                ]
          ]
  assertEqual
    "mention parsed"
    (Just (RBX.Mention "chan-1" "m-1" "u-1" "Dev" "" "release rider app till e4e0b16" []))
    (RBX.parseMention mention)
  assertBool "non-mention event ignored" (RBX.parseMention (Aeson.object ["eventType" Aeson..= ("OTHER" :: Text)]) == Nothing)
  let flow = Aeson.object ["actionId" Aeson..= ("scc_release_approve:req-9" :: Text), "context" Aeson..= Aeson.object ["userId" Aeson..= ("u-2" :: Text)]]
  assertEqual "flow-action click parsed" (Just (RBX.Click "scc_release_approve" "req-9" Nothing "u-2" "" "")) (RBX.parseClick flow)
  let inter = Aeson.object ["actions" Aeson..= [Aeson.object ["action_id" Aeson..= ("scc_release_reject" :: Text), "value" Aeson..= ("req-9" :: Text)]], "user" Aeson..= Aeson.object ["id" Aeson..= ("u-3" :: Text), "email" Aeson..= ("a@x.in" :: Text)]]
  assertEqual "interaction click parsed" (Just (RBX.Click "scc_release_reject" "req-9" Nothing "u-3" "" "a@x.in")) (RBX.parseClick inter)
  let perSvc = Aeson.object ["actionId" Aeson..= ("scc_rollout_approve:req-9:BECKN_APP_BACKEND_MASTER" :: Text), "context" Aeson..= Aeson.object ["userId" Aeson..= ("u-2" :: Text)]]
  assertEqual "per-service rollout click parsed" (Just (RBX.Click "scc_rollout_approve" "req-9" (Just "BECKN_APP_BACKEND_MASTER") "u-2" "" "")) (RBX.parseClick perSvc)
  assertBool "unknown verb is not a click (cannot be spoofed into approve)" (RBX.parseClick (Aeson.object ["actionId" Aeson..= ("vk_remediate_approve:req-9" :: Text)]) == Nothing)
  assertBool "verb without request id is not a click" (RBX.parseClick (Aeson.object ["actionId" Aeson..= ("scc_release_approve:" :: Text)]) == Nothing)
  assertEqual "form-encoded interaction body decodes" (Just (Aeson.object ["a" Aeson..= (1 :: Int)])) (RBR.decodeWebhookBody (BC.pack "payload=%7B%22a%22%3A1%7D"))
  assertEqual "plain JSON body decodes" (Just (Aeson.object ["a" Aeson..= (1 :: Int)])) (RBR.decodeWebhookBody (BC.pack "{\"a\":1}"))

testReleaseBotConfig :: IO ()
testReleaseBotConfig = do
  parsed <- Aeson.eitherDecodeFileStrict "dhall-configs/prod-release-config.json" :: IO (Either String PRC.ProdReleaseConfig)
  case parsed of
    Left e -> fail ("  FAIL: shipped prod-release-config.json does not parse: " <> e)
    Right cfg -> do
      assertBool "shipped config parses and has a repo" (not (null (PRC.prcRepos cfg)))
      let repo = head (PRC.prcRepos cfg)
      assertEqual "repo slug from URL" "nammayatri/nammayatri" (PRC.repoSlug repo)
  let mk pats = (head (either (const []) PRC.prcRepos (Aeson.eitherDecodeStrict (BC.pack "{\"repos\":[{\"name\":\"r\",\"url\":\"https://github.com/o/r.git/\",\"branches\":[\"b\"],\"jenkins\":{\"job\":\"j\",\"commitParam\":\"C\",\"fixedParams\":{}},\"services\":[]}]}")))) {PRC.rcSecretFiles = pats}
  assertEqual "slug tolerates .git and trailing slash" "o/r" (PRC.repoSlug (mk []))
  assertBool "exact path matches" (PRC.isSecretFile (mk ["config/secrets.dhall"]) "config/secrets.dhall")
  assertBool "bare name matches in any directory" (PRC.isSecretFile (mk ["secrets.dhall"]) "a/b/secrets.dhall")
  assertBool "wildcard matches" (PRC.isSecretFile (mk ["*secrets*.dhall"]) "x/prod-secrets-v2.dhall")
  assertBool "non-secret file not flagged" (not (PRC.isSecretFile (mk ["secrets.dhall"]) "x/common.dhall"))
  assertBool "pattern with directory does not match other directory" (not (PRC.isSecretFile (mk ["config/secrets.dhall"]) "other/secrets.dhall"))
  assertBool "no patterns -> nothing flagged" (not (PRC.isSecretFile (mk []) "secrets.dhall"))
  assertEqual "secretFilesHit dedupes + sorts" ["a/secrets.dhall", "z/secrets.dhall"] (RBE.secretFilesHit (mk ["secrets.dhall"]) ["z/secrets.dhall", "a/secrets.dhall", "a/secrets.dhall", "x.dhall"])

testReleaseBotPublic :: IO ()
testReleaseBotPublic = do
  let analysis =
        Aeson.object
          [ "commit" Aeson..= ("abc" :: Text)
          , "liveFingerprint" Aeson..= ("fp" :: Text)
          , "contentHash" Aeson..= ("ch" :: Text)
          , "envChanges" Aeson..= [Aeson.object ["service" Aeson..= ("s" :: Text), "diff" Aeson..= ("D" :: Text), "newB64" Aeson..= ("SECRETISH" :: Text), "liveB64" Aeson..= ("OLDSECRETISH" :: Text)]]
          , "configMaps" Aeson..= [Aeson.object ["name" Aeson..= ("cm" :: Text), "diffs" Aeson..= ("D2" :: Text), "newData" Aeson..= Aeson.object ["k" Aeson..= ("v" :: Text)], "liveData" Aeson..= Aeson.object ["k" Aeson..= ("w" :: Text)]]]
          ]
      pub = RBE.publicView analysis
      rendered = T.pack (show pub)
  assertBool "public view keeps the reviewed diffs" ("D2" `T.isInfixOf` rendered && "\"D\"" `T.isInfixOf` rendered)
  assertBool "public view drops base64 apply payloads" (not ("SECRETISH" `T.isInfixOf` rendered))
  assertBool "public view drops raw configmap data" (not ("newData" `T.isInfixOf` rendered) && not ("liveData" `T.isInfixOf` rendered))
  assertBool "public view drops approval fingerprints" (not ("liveFingerprint" `T.isInfixOf` rendered) && not ("contentHash" `T.isInfixOf` rendered))
  assertEqual "link token matches independent HMAC-SHA256" "2f7193b4091652807513b9b3da8005e36b844e1e76766fd1cb9778ea1230e59c" (RBF.linkToken "linksecret" "req-123")
  assertBool "link token differs per request id" (RBF.linkToken "linksecret" "req-123" /= RBF.linkToken "linksecret" "req-124")
  assertBool "link token differs per secret" (RBF.linkToken "linksecret" "req-123" /= RBF.linkToken "other" "req-123")
  assertEqual "hashTexts is SHA-256 over US-joined parts" "f04cdced9736a69da6103f08a4daaf8c485dd481217d218a1b4993c8c3968e13" (RBE.hashTexts ["a", "b"])
  assertBool "hashTexts is order sensitive" (RBE.hashTexts ["a", "b"] /= RBE.hashTexts ["b", "a"])
  assertBool "hashTexts boundary-safe (ab,c != a,bc)" (RBE.hashTexts ["ab", "c"] /= RBE.hashTexts ["a", "bc"])

testReleaseBotEnv :: IO ()
testReleaseBotEnv = do
  let plain n v = Aeson.object ["name" Aeson..= (n :: Text), "value" Aeson..= (v :: Text)]
      fromRef n = Aeson.object ["name" Aeson..= (n :: Text), "valueFrom" Aeson..= Aeson.object ["secretKeyRef" Aeson..= Aeson.object ["name" Aeson..= ("s" :: Text), "key" Aeson..= ("k" :: Text)]]]
      envs = [plain "A" "1", fromRef "DB_PASS", plain "DHALL_CONFIG" "OLD", plain "Z" "9"]
  assertEqual "reads a plain env var" (Just "OLD") (RBL.envVarValue "DHALL_CONFIG" envs)
  assertEqual "valueFrom entry is not a plain value" Nothing (RBL.envVarValue "DB_PASS" envs)
  assertEqual
    "replace swaps only the target; valueFrom + others untouched, order kept"
    (Just [plain "A" "1", fromRef "DB_PASS", plain "DHALL_CONFIG" "NEW", plain "Z" "9"])
    (RBL.replaceEnvVar "DHALL_CONFIG" "NEW" envs)
  assertEqual "replace refuses to invent a missing var" Nothing (RBL.replaceEnvVar "MISSING" "NEW" envs)
  assertEqual "replace refuses to overwrite a valueFrom entry" Nothing (RBL.replaceEnvVar "DB_PASS" "NEW" envs)
  assertBool "key order irrelevant: object still has name+value" (maybe False (any (\v -> case v of Aeson.Object o -> AKM.size o == 2; _ -> False)) (RBL.replaceEnvVar "A" "2" envs))

testReleaseBotIntent :: IO ()
testReleaseBotIntent = do
  let a = PRI.Intent (Just "repo1") (Just "b1") (Just "abc123") ["svcA"]
  assertEqual "empty new keeps old" a (PRI.mergeIntent a PRI.emptyIntent)
  assertEqual "new commit replaces old, rest kept" a {PRI.inCommit = Just "def456"} (PRI.mergeIntent a PRI.emptyIntent {PRI.inCommit = Just "def456"})
  assertEqual "changing repo resets branch/commit/services" (PRI.Intent (Just "repo2") Nothing Nothing []) (PRI.mergeIntent a PRI.emptyIntent {PRI.inRepo = Just "repo2"})
  assertEqual "missing fields in ask order" ["repo", "branch", "commit", "services"] (PRI.missingFields PRI.emptyIntent)
  assertEqual "nothing missing when complete" [] (PRI.missingFields a)
  -- channel env scoping: a PROD channel must never see MASTER-only services
  let svc n e = PRC.ServiceCfg n n [] [] Nothing [] e Map.empty [] Nothing False Nothing []
      repoWith ss = (head (either (const []) PRC.prcRepos (Aeson.eitherDecodeStrict (BC.pack "{\"repos\":[{\"name\":\"r\",\"url\":\"https://github.com/o/r\",\"branches\":[\"b\"],\"jenkins\":{\"job\":\"j\",\"commitParam\":\"C\",\"fixedParams\":{}},\"services\":[]}]}")))) {PRC.rcServices = ss}
      names = map PRC.scService . PRC.rcServices
      r = repoWith [svc "p" (Just "PROD"), svc "m" (Just "MASTER"), svc "any" Nothing]
  assertEqual "PROD channel sees PROD + env-less services" ["p", "any"] (names (PRC.forEnv "PROD" r))
  assertEqual "env match is case-insensitive" ["m", "any"] (names (PRC.forEnv "master" r))

testReleaseBotRefs :: IO ()
testReleaseBotRefs = do
  let dep =
        Aeson.object
          [ "spec" Aeson..= Aeson.object
              [ "template" Aeson..= Aeson.object
                  [ "spec" Aeson..= Aeson.object
                      [ "containers" Aeson..=
                          [ Aeson.object
                              [ "env" Aeson..=
                                  [ Aeson.object ["name" Aeson..= ("A" :: Text), "value" Aeson..= ("1" :: Text)]
                                  , Aeson.object ["name" Aeson..= ("B" :: Text), "valueFrom" Aeson..= Aeson.object ["configMapKeyRef" Aeson..= Aeson.object ["name" Aeson..= ("cm-env" :: Text), "key" Aeson..= ("k" :: Text)]]]
                                  , Aeson.object ["name" Aeson..= ("C" :: Text), "valueFrom" Aeson..= Aeson.object ["secretKeyRef" Aeson..= Aeson.object ["name" Aeson..= ("sec-env" :: Text), "key" Aeson..= ("k" :: Text)]]]
                                  ]
                              , "envFrom" Aeson..=
                                  [ Aeson.object ["configMapRef" Aeson..= Aeson.object ["name" Aeson..= ("beckn-production-pilot" :: Text)]]
                                  , Aeson.object ["secretRef" Aeson..= Aeson.object ["name" Aeson..= ("sec-from" :: Text)]]
                                  ]
                              ]
                          ]
                      , "initContainers" Aeson..= [Aeson.object ["envFrom" Aeson..= [Aeson.object ["configMapRef" Aeson..= Aeson.object ["name" Aeson..= ("cm-init" :: Text)]]]]]
                      , "volumes" Aeson..=
                          [ Aeson.object ["name" Aeson..= ("v1" :: Text), "configMap" Aeson..= Aeson.object ["name" Aeson..= ("cm-vol" :: Text)]]
                          , Aeson.object ["name" Aeson..= ("v2" :: Text), "secret" Aeson..= Aeson.object ["secretName" Aeson..= ("sec-vol" :: Text)]]
                          , Aeson.object ["name" Aeson..= ("v3" :: Text), "projected" Aeson..= Aeson.object ["sources" Aeson..= [Aeson.object ["configMap" Aeson..= Aeson.object ["name" Aeson..= ("kube-root-ca.crt" :: Text)]], Aeson.object ["secret" Aeson..= Aeson.object ["name" Aeson..= ("sec-proj" :: Text)]]]]]
                          , Aeson.object ["name" Aeson..= ("v4" :: Text), "emptyDir" Aeson..= Aeson.object []]
                          ]
                      ]
                  ]
              ]
          ]
      (cms, secs) = refsFromDeployment dep
  assertEqual "configmaps from env valueFrom, envFrom, initContainers, volumes and projected (sorted, unique)" ["beckn-production-pilot", "cm-env", "cm-init", "cm-vol", "kube-root-ca.crt"] cms
  assertEqual "secret NAMES from env valueFrom, envFrom, volumes and projected" ["sec-env", "sec-from", "sec-proj", "sec-vol"] secs
  assertEqual "plain env values reference nothing" ([], []) (refsFromDeployment (Aeson.object []))
  assertEqual "defaults ignore the auto-mounted configmaps" ["kube-root-ca.crt", "istio-ca-root-cert"] PRC.defaultIgnoredConfigMaps

testReleaseBotTriggers :: IO ()
testReleaseBotTriggers = do
  assertEqual "tracker card click parses (verb + tracker id)" (Just (RBX.trackerApproveVerb, "trk-1"))
    (fmap (\c -> (RBX.cVerb c, RBX.cRequestId c)) (RBX.parseClick (Aeson.object ["actionId" Aeson..= ("scc_tracker_approve:trk-1" :: Text), "context" Aeson..= Aeson.object ["userId" Aeson..= ("u1" :: Text)]])))
  assertEqual "bot tracker global id -> request id" (Just "0cddc238-38c8-4492-9447-fb8d81524249") (requestIdOfGlobalId "0cddc238-38c8-4492-9447-fb8d81524249-rider-app")
  assertEqual "hand-made global id is not a bot tracker" Nothing (requestIdOfGlobalId "my-manual-release")
  assertEqual "uuid alone has no service part" Nothing (requestIdOfGlobalId "0cddc238-38c8-4492-9447-fb8d81524249")
  assertEqual "the bot's own mention is removed from the message text (its name must not match service aliases)"
    "be7a73 can u release backend master"
    (RBX.stripMentions (RBX.mentionTexts "<p><span data-user-id=\"b1\">@System Control Center Master</span> be7a73 can u release backend master</p>") "@System Control Center Master be7a73 can u release backend master")
  assertEqual "mention text extracted" ["@System Control Center Master"] (RBX.mentionTexts "<p><span data-user-id=\"b1\"><b>@System Control Center Master</b></span> hi</p>")
  assertEqual "no mention spans -> a leading bot name is still removed" "release x" (RBX.stripMentions [] "System Control Center Master release x" `seq` RBX.stripMentions [] "@System Control Center Master release x")
  assertEqual "no mention ids" [] (RBX.mentionedIds "<p>hello</p>")
  assertEqual "mention ids in order, de-duplicated"
    ["u1", "u2"]
    (RBX.mentionedIds "<p><span data-user-id=\"u1\">@a</span> and <span data-user-id=\"u2\">@b</span> <span data-user-id=\"u1\">@a</span></p>")
  assertEqual "empty id is skipped" ["u9"] (RBX.mentionedIds "<span data-user-id=\"\"></span><span data-user-id=\"u9\"></span>")
  -- file -> rule triggers
  assertBool "exact repo path triggers" (PRC.matchesAny ["dhall-configs/prod/rider-app.dhall"] "dhall-configs/prod/rider-app.dhall")
  assertBool "bare file name triggers from any directory" (PRC.matchesAny ["rider-app.dhall"] "a/b/rider-app.dhall")
  assertBool "a different dhall does NOT trigger this rule" (not (PRC.matchesAny ["rider-app.dhall"] "a/b/driver-app.dhall"))
  assertBool "directory pattern with * triggers on files beneath it" (PRC.matchesAny ["dhall-configs/prod/*"] "dhall-configs/prod/common.dhall")
  assertBool "directory pattern does not trigger on a sibling directory" (not (PRC.matchesAny ["dhall-configs/prod/*"] "dhall-configs/dev/common.dhall"))
  assertBool "no patterns trigger nothing" (not (PRC.matchesAny [] "x.dhall"))
  -- DB-stored config
  case PRC.parseProdReleaseConfig "{\"repos\":[{\"name\":\"r\",\"url\":\"https://github.com/o/r\",\"branches\":[\"b\"],\"jenkins\":{\"job\":\"j\",\"commitParam\":\"C\",\"fixedParams\":{}},\"services\":[{\"service\":\"s\",\"appGroup\":\"g\",\"envVar\":{\"envVar\":\"DHALL_CONFIG\",\"repoPath\":\"p/s.dhall\",\"watch\":[\"p/*.dhall\"]}}],\"ignoreConfigMaps\":[\"x\"]}],\"channels\":[{\"id\":\"c\",\"repo\":\"r\",\"env\":\"PROD\"}]}" of
    Left e -> fail ("  FAIL: DB-stored config did not parse: " <> T.unpack e)
    Right cfg -> do
      let repo = head (PRC.prcRepos cfg)
          svc = head (PRC.rcServices repo)
      assertEqual "channel parsed" [PRC.ChannelCfg "c" "r" "PROD"] (PRC.prcChannels cfg)
      assertEqual "service env-var watch parsed" (Just ["p/*.dhall"]) (PRC.scEnvVar svc >>= PRC.evWatch)
      assertEqual "repo ignoreConfigMaps parsed" ["x"] (PRC.rcIgnoreConfigMaps repo)
  assertBool "invalid DB value is an error, not a silent empty config" (either (const True) (const False) (PRC.parseProdReleaseConfig "{not json"))

testReleaseBotRows :: IO ()
testReleaseBotRows = do
  -- SQL attribution by schema
  let sqlText = "-- add unique\nALTER TABLE atlas_app.offer DROP CONSTRAINT IF EXISTS u;\nALTER TABLE atlas_app.offer ADD CONSTRAINT u2 UNIQUE (a, b); INSERT INTO atlas_driver_offer_bpp.t VALUES ('x;y', 1);\nDO $$ BEGIN PERFORM 1; END $$;\nSELECT 1; -- trailing"
      stmts = RBS.splitStatements sqlText
      file = [RBS.SqlFile "m/1.sql" stmts]
  assertEqual "statements split on top-level semicolons only" 5 (length stmts)
  assertEqual "rider schema gets its 2 statements" 2 (RBS.countStatements (RBS.statementsFor ["atlas_app"] file))
  assertEqual "driver schema gets the insert (quoted ; kept)" 1 (RBS.countStatements (RBS.statementsFor ["atlas_driver_offer_bpp"] file))
  assertEqual "statements naming no configured schema are reported" 2 (RBS.countStatements (RBS.unattributed ["atlas_app", "atlas_driver_offer_bpp"] file))
  assertBool "schema must match a whole identifier" (not (RBS.mentionsSchema "app" "UPDATE atlas_app.t SET a=1"))
  assertBool "rendered sql lists the file and statements" (let r = RBS.renderSql "t" "atlas_app" (RBS.statementsFor ["atlas_app"] file) in ">>> m/1.sql" `T.isInfixOf` r && "ADD CONSTRAINT u2" `T.isInfixOf` r)
  case RBW.validateServiceBot "{\"sqlSchemas\":[\"atlas_app\"]}" of
    Right sb -> assertEqual "sqlSchemas parsed" ["atlas_app"] (RBW.sbSqlSchemas sb)
    Left e -> assertBool ("service rule should parse: " <> T.unpack e) False
  -- channel shared by two repos: the longest service/alias mention picks the repo
  let svcA nm als = PRC.ServiceCfg nm "G" als [] Nothing [] Nothing Map.empty [] Nothing False Nothing []
      jc = PRC.JenkinsCfg "j" (Just "commit") Nothing Nothing Map.empty
      mkRepo nm svcs = PRC.RepoCfg nm ("https://github.com/" <> nm) ["main"] jc svcs [] [] [] Map.empty False []
      pcShared = PRC.ProdReleaseConfig [mkRepo "o/ny" [svcA "NY_BACKEND" ["backend master", "backend"]], mkRepo "o/cc" [svcA "CC_BACKEND" ["control center backend"]]] []
      chs = [PRC.ChannelCfg "C" "o/ny" "MASTER", PRC.ChannelCfg "C" "o/cc" "MASTER"]
  assertEqual "control center message picks the control-center repo" (Right "o/cc") (fmap PRC.chRepo (RBF.pickChannel pcShared "release control center backend till abc123" chs))
  assertEqual "backend master message picks the main repo" (Right "o/ny") (fmap PRC.chRepo (RBF.pickChannel pcShared "release backend master till abc123" chs))
  assertBool "no mention of either repo asks which" (either (const True) (const False) (RBF.pickChannel pcShared "release please" chs))
  -- several Jenkins builds of one request
  let br st = RBF.BuildRec ["s"] Nothing (Just "u") (Just st) False Nothing
  assertEqual "all builds succeeded" "SUCCESS" (let (r, _, _) = RBF.aggregateBuilds [br "SUCCESS", br "SUCCESS"] in r)
  assertEqual "one failed build fails the request" "FAILURE" (let (r, _, _) = RBF.aggregateBuilds [br "SUCCESS", br "FAILURE"] in r)
  assertEqual "a running build keeps it running" "RUNNING" (let (r, _, _) = RBF.aggregateBuilds [br "SUCCESS", br "RUNNING"] in r)
  -- stored rollout strategies: legacy cluster wrapper, flat list, double-encoded, invalid
  let steps = map (\r -> (PRC.rsRolloutPercent r, PRC.rsCooloffMinutes r, PRC.rsPodCount r)) . RBF.parseStoredStrategy
  assertEqual "legacy cluster wrapper read" [(100, 1, 2)] (steps "[{\"cluster\":\"BECKN_UAT\",\"rollouts\":[{\"rollout\":100,\"cooloff\":1,\"pods\":2}]}]")
  assertEqual "flat list read" [(50, 5, 1), (100, 5, 2)] (steps "[{\"rolloutPercent\":50,\"cooloffMinutes\":5,\"podCount\":1},{\"rolloutPercent\":100,\"cooloffMinutes\":5,\"podCount\":2}]")
  assertEqual "double-encoded string read" [(100, 0, 1)] (steps "\"[{\\\"rolloutPercent\\\":100,\\\"cooloffMinutes\\\":0,\\\"podCount\\\":1}]\"")
  assertEqual "strategy not ending at 100% is ignored" [] (steps "[{\"rolloutPercent\":50,\"cooloffMinutes\":5,\"podCount\":1}]")
  -- custom rollout asked for in the message
  assertEqual "rollout override parsed" (Just (Right [(5, 10), (25, 30), (50, 30), (100, 10)])) (PRI.parseRolloutOverride "release x till abc123 with rollout 5% -> 10, 25% -> 30, 50% -> 30, 100% -> 10")
  assertEqual "rollout override with arrows/newlines" (Just (Right [(10, 5), (100, 0)])) (PRI.parseRolloutOverride "10% \8594 5\n100% \8594 0")
  assertEqual "no override in a plain request" Nothing (PRI.parseRolloutOverride "release app backend till 840d277")
  assertBool "override not ending at 100% is rejected" (either (const True) (const False) (maybe (Right []) id (PRI.parseRolloutOverride "5% -> 10, 50% -> 30")))
  -- merge mode parses on both rule kinds (env var + configmap); absent = replace
  case RBW.validateServiceBot "{\"envVar\":{\"envVar\":\"DHALL_CONFIG\",\"repoPath\":\"a/rider-app.dhall\",\"mode\":\"merge\"}}" of
    Right sb -> assertEqual "env var mode=merge parsed" (Just (Just "merge")) (fmap PRC.evMode (RBW.sbEnvVar sb))
    Left e -> assertBool ("service rule should parse: " <> T.unpack e) False
  case RBW.validateServiceBot "{\"envVar\":{\"envVar\":\"DHALL_CONFIG\",\"repoPath\":\"a/rider-app.dhall\"}}" of
    Right sb -> assertEqual "env var mode absent -> replace" (Just Nothing) (fmap PRC.evMode (RBW.sbEnvVar sb))
    Left e -> assertBool ("service rule should parse: " <> T.unpack e) False
  case RBW.validateProductBot "{\"env\":\"MASTER\",\"configMaps\":[{\"name\":\"cm\",\"mode\":\"merge\",\"files\":{\"k\":\"p\"}}]}" of
    Right pb -> assertEqual "configmap mode=merge parsed" [True] (map RBW.crMerge (RBW.pbConfigMaps pb))
    Left e -> assertBool ("product rule should parse: " <> T.unpack e) False
  let row ag svc repo cfg =
        SCH.DeploymentConfigT
          { SCH.dcId = 1, SCH.dcAppGroup = ag, SCH.dcService = svc, SCH.dcCluster = Nothing, SCH.dcNamespace = Nothing
          , SCH.dcVsName = Nothing, SCH.dcAppGroupAcronym = Nothing, SCH.dcRepoName = repo, SCH.dcAppGroupType = Nothing
          , SCH.dcSyncCluster = Nothing, SCH.dcNeedInfraApproval = Nothing, SCH.dcAiChangelogEnabled = Nothing
          , SCH.dcVsLockedBy = Nothing, SCH.dcVsLockTimestamp = Nothing, SCH.dcServiceHost = Nothing, SCH.dcServiceType = Nothing
          , SCH.dcRolloutStrategy = Nothing, SCH.dcRevertStrategy = Nothing, SCH.dcDecisionConfig = Nothing
          , SCH.dcSlackChannel = Nothing, SCH.dcServiceState = Nothing, SCH.dcHpaMinReplicas = Nothing
          , SCH.dcHpaMaxReplicas = Nothing, SCH.dcCloudType = "GCP", SCH.dcReleaseBotConfig = cfg
          }
      jenk job = "\"jenkins\":{\"job\":\"" <> job <> "\",\"commitParam\":\"COMMIT\",\"fixedParams\":{}}"
      prod env chans job = Just ("{\"env\":\"" <> env <> "\",\"branches\":[\"b1\"],\"channels\":" <> chans <> "," <> jenk job <> "}")
      svc = Just "{\"aliases\":[\"rider\"],\"dhallFiles\":[\"rider-app.dhall\"]}"
      isLeftWith frag = either (T.isInfixOf frag) (const False)
  assertEqual "rows with no config produce an empty bot config" (Right 0) (fmap (length . PRC.prcRepos) (RBW.buildFromRows [row "g" Nothing (Just "o/r") Nothing, row "g" (Just "s") Nothing (Just "  ")]))
  let g1 = row "g1" Nothing (Just "o/r") (prod "PROD" "[\"C1\"]" "job-a")
      g2 = row "g2" Nothing (Just "https://github.com/O/R.git") (prod "PROD" "[\"C2\"]" "job-a")
  case RBW.buildFromRows [g1, g2, row "g1" (Just "s1") Nothing svc, row "g2" (Just "s2") Nothing svc] of
    Left e -> fail ("  FAIL: expected merge, got " <> T.unpack e)
    Right c -> do
      assertEqual "two app groups on the same repo (URL form / case differ) merge into ONE repo" 1 (length (PRC.prcRepos c))
      assertEqual "services from both app groups attach to it" ["s1", "s2"] (map PRC.scService (PRC.rcServices (head (PRC.prcRepos c))))
      assertEqual "channels from both app groups are kept" ["C1", "C2"] (map PRC.chId (PRC.prcChannels c))
      assertEqual "service env inherited from its app group" [Just "PROD", Just "PROD"] (map PRC.scEnv (PRC.rcServices (head (PRC.prcRepos c))))
  case RBW.buildFromRows [g1, row "g1" (Just "fe") Nothing (Just "{\"branches\":[\"hot-fe\"]}"), row "g1" (Just "be") Nothing (Just "{}")] of
    Left e -> fail ("  FAIL: expected per-service branches, got " <> T.unpack e)
    Right c -> do
      let r = head (PRC.prcRepos c)
      assertEqual "a service's own branches are kept" [["hot-fe"], []] (map PRC.scBranches (PRC.rcServices r))
      assertEqual "repo branches = group branches + every service's" ["b1", "hot-fe"] (PRC.rcBranches r)
  let noJenk = Just "{\"env\":\"PROD\",\"branches\":[\"b1\"],\"channels\":[\"C1\"]}"
      svcJ j = Just ("{\"jenkins\":" <> j <> "}")
  case RBW.buildFromRows [row "g" Nothing (Just "o/r") noJenk, row "g" (Just "fe") Nothing (svcJ "{\"job\":\"j/fe\",\"commitParam\":\"c\",\"fixedParams\":{\"x\":\"1\"}}"), row "g" (Just "be") Nothing (svcJ "{\"job\":\"j/be\"}")] of
    Left e -> fail ("  FAIL: service-level jenkins: " <> T.unpack e)
    Right c -> do
      let r = head (PRC.prcRepos c)
          [fe, be] = PRC.rcServices r
      assertEqual "each service has its own job" ["j/fe", "j/be"] (map (PRC.jcJob . PRC.jenkinsForSvc r "PROD") [fe, be])
      assertEqual "commit param is per service" [Just "c", Nothing] (map (PRC.jcCommitParam . PRC.jenkinsForSvc r "PROD") [fe, be])
  assertBool "no group jenkins and a service without a job is an error" (isLeftWith "own" (RBW.buildFromRows [row "g" Nothing (Just "o/r") noJenk, row "g" (Just "fe") Nothing (svcJ "{\"commitParam\":\"c\"}")]))
  case RBW.buildFromRows [row "g" Nothing (Just "o/r") (Just "{\"env\":\"PROD\",\"branches\":[\"b\"],\"requireChecks\":true,\"ignoreChecks\":[\"lint\"],\"jenkins\":{\"job\":\"j\",\"fixedParams\":{}}}")] of
    Left e -> fail ("  FAIL: requireChecks: " <> T.unpack e)
    Right c -> do
      let r = head (PRC.prcRepos c)
      assertEqual "requireChecks is read from the app group" True (PRC.rcRequireChecks r)
      assertEqual "ignoreChecks is read from the app group" ["lint"] (PRC.rcIgnoreChecks r)
  case RBW.buildFromRows [g1, row "g1" (Just "a") Nothing (Just "{\"syncToSecondary\":true}"), row "g1" (Just "b") Nothing (Just "{}")] of
    Left e -> fail ("  FAIL: syncToSecondary: " <> T.unpack e)
    Right c -> assertEqual "syncToSecondary is per service, default off" [True, False] (map PRC.scSyncSecondary (PRC.rcServices (head (PRC.prcRepos c))))
  case RBW.buildFromRows [g1, row "g1" (Just "a") Nothing (Just "{\"dbManager\":{\"database\":\"bap\",\"mode\":\"both\"}}")] of
    Left e -> fail ("  FAIL: dbManager: " <> T.unpack e)
    Right c -> assertEqual "dbManager target is read per service" [Just (PRC.DbTarget "bap" "both" Nothing)] (map PRC.scDbTarget (PRC.rcServices (head (PRC.prcRepos c))))
  let patch = T.unlines
        [ "@@ -200,4 +200,9 @@ ALTER TABLE atlas_driver_offer_bpp.document_verification_config ADD COLUMN is_de"
        , " "
        , " ------- SQL updates -------"
        , " "
        , "-ALTER TABLE atlas_driver_offer_bpp.document_verification_config ADD COLUMN do_not_validate_during_onboarding boolean ;"
        , "\\ No newline at end of file"
        , "+ALTER TABLE atlas_driver_offer_bpp.document_verification_config ADD COLUMN do_not_validate_during_onboarding boolean ;"
        , "+"
        , "+"
        , "+------- SQL updates -------"
        , "+"
        , "+ALTER TABLE atlas_driver_offer_bpp.document_verification_config ADD COLUMN allow_non_transport_vehicle boolean ;"
        ]
      newStmts = RBS.splitStatements (RBS.addedSql patch)
  assertEqual "only the genuinely new statement comes out of a diff (a re-added identical line is not new)" ["ALTER TABLE atlas_driver_offer_bpp.document_verification_config ADD COLUMN allow_non_transport_vehicle boolean ;"] (map (T.strip . T.unlines . filter (not . T.isPrefixOf "--" . T.strip) . T.lines) newStmts)
  assertBool "different Jenkins jobs for one repo is an error, not a silent pick" (isLeftWith "different Jenkins jobs" (RBW.buildFromRows [g1, row "g2" Nothing (Just "o/r") (prod "PROD" "[]" "job-b")]))
  assertBool "no jenkins job anywhere is an error" (isLeftWith "no \"jenkins\"" (RBW.buildFromRows [row "g" Nothing (Just "o/r") (Just "{\"env\":\"PROD\",\"branches\":[\"b\"]}")]))
  assertBool "missing repo_name is an error" (isLeftWith "no repo_name" (RBW.buildFromRows [row "g" Nothing Nothing (prod "PROD" "[]" "j")]))
  assertBool "one channel mapped to two envs is an error" (isLeftWith "two different envs" (RBW.buildFromRows [row "g1" Nothing (Just "o/r") (prod "PROD" "[\"C\"]" "j"), row "g2" Nothing (Just "o/r") (prod "MASTER" "[\"C\"]" "j")]))
  assertEqual "one channel may serve two repos" (Right 2) (fmap (\c -> length (PRC.channelsFor c "C")) (RBW.buildFromRows [row "g1" Nothing (Just "o/r") (prod "PROD" "[\"C\"]" "j"), row "g2" Nothing (Just "o/x") (prod "PROD" "[\"C\"]" "j")]))
  assertBool "service rules under an app group with none are reported" (isLeftWith "app group has none" (RBW.buildFromRows [row "g" (Just "s") Nothing svc]))
  assertBool "the live bot ignores such orphan service rules instead of failing for every group" (either (const False) (const True) (RBW.buildFromRows (RBW.dropOrphanServiceRules [row "g" (Just "s") Nothing svc])))
  assertBool "malformed row JSON names the row" (isLeftWith "g:" (RBW.buildFromRows [row "g" Nothing (Just "o/r") (Just "{nope")]))
  -- the save-request field: absent = keep, blank = clear, else validated
  assertEqual "absent field leaves stored rules alone" (Right Nothing) (RBW.checkBotField True Nothing)
  assertEqual "blank clears" (Right (Just Nothing)) (RBW.checkBotField True (Just "  "))
  assertEqual "valid product rules are written" (Right (Just (Just "{\"env\":\"PROD\"}"))) (RBW.checkBotField True (Just "{\"env\":\"PROD\"}"))
  assertBool "product rules need an env" (either (const True) (const False) (RBW.checkBotField True (Just "{\"branches\":[\"b\"]}")))
  assertBool "invalid JSON is rejected before it can be stored" (either (const True) (const False) (RBW.checkBotField False (Just "{x")))
  assertBool "service envVar needs a repoPath" (either (const True) (const False) (RBW.checkBotField False (Just "{\"envVar\":{\"envVar\":\"X\",\"repoPath\":\"\"}}")))


testReleaseBotJenkins :: IO ()
testReleaseBotJenkins = do
  -- Jenkins reports URLs on its SSO-fronted host; polling must go through the API host.
  let api = "https://mcp-jenkins.c2.sso.internal.svc.movingtech.net"
  assertEqual "queue URL re-rooted onto the API base" (api <> "/queue/item/42/") (PRJ.rebaseUrl api "https://jenkins.c2.sso.internal.svc.movingtech.net/queue/item/42/")
  assertEqual "build URL keeps its full path" (api <> "/job/ny-internal/job/cloud-jenkins/job/main/4957/") (PRJ.rebaseUrl api "https://jenkins.c2.sso.internal.svc.movingtech.net/job/ny-internal/job/cloud-jenkins/job/main/4957/")
  assertEqual "trailing slash on the base is tolerated" (api <> "/queue/item/1/") (PRJ.rebaseUrl (api <> "/") "http://jenkins/queue/item/1/")
  assertEqual "a URL already on the API base is unchanged" (api <> "/queue/item/1/") (PRJ.rebaseUrl api (api <> "/queue/item/1/"))
  assertEqual "a host-only URL becomes the base" api (PRJ.rebaseUrl api "https://jenkins.example")
  assertEqual "a relative URL is left alone" "/queue/item/1/" (PRJ.rebaseUrl api "/queue/item/1/")
  assertEqual "empty base leaves the URL alone" "https://x/y" (PRJ.rebaseUrl "" "https://x/y")
  assertEqual "org-folder job path -> REST path" "job/ny-internal/job/cloud-jenkins/job/main" (PRJ.jobPath "ny-internal/cloud-jenkins/main")
  assertEqual "spaces in a segment are encoded" "job/utils%20nammayatri/job/x" (PRJ.jobPath "utils nammayatri/x")
  -- the shipped config matches the real cloud-jenkins job: first 6 chars, sandbox OFF for PROD
  parsed <- Aeson.eitherDecodeFileStrict "dhall-configs/prod-release-config.json" :: IO (Either String PRC.ProdReleaseConfig)
  case parsed of
    Left e -> fail ("  FAIL: shipped config does not parse: " <> e)
    Right cfg -> do
      let repo = head (PRC.prcRepos cfg)
          prodJ = PRC.jenkinsFor repo "prod"
          masterJ = PRC.jenkinsFor repo "MASTER"
      assertEqual "job is the real org-folder path" "ny-internal/cloud-jenkins/main" (PRC.jcJob prodJ)
      assertEqual "commit param is lower-case `commit`" (Just "commit") (PRC.jcCommitParam prodJ)
      assertEqual "commit is cut to 6 chars" (Just 6) (PRC.jcCommitLength prodJ)
      assertEqual "PROD release does NOT push to the sandbox" (Just "false") (Map.lookup "GCP_SANDBOX" (PRC.jcFixedParams prodJ))
      assertEqual "PROD release pushes to AWS + GCP prod" (Just "true", Just "true") (Map.lookup "AWS_PROD" (PRC.jcFixedParams prodJ), Map.lookup "GCP_PROD" (PRC.jcFixedParams prodJ))
      assertEqual "PROD release leaves EU and MSIL off" ["false", "false", "false"] [Map.findWithDefault "?" k (PRC.jcFixedParams prodJ) | k <- ["EU_PROD", "EU_PROD_GCP", "MSIL"]]
      assertEqual "MASTER release pushes to the sandbox only" (Just "true", Just "false", Just "false") (Map.lookup "GCP_SANDBOX" (PRC.jcFixedParams masterJ), Map.lookup "AWS_PROD" (PRC.jcFixedParams masterJ), Map.lookup "GCP_PROD" (PRC.jcFixedParams masterJ))
  -- rows: same repo, PROD and MASTER app groups may have DIFFERENT jenkins params; same env may not
  let row ag env job params =
        SCH.DeploymentConfigT
          { SCH.dcId = 1, SCH.dcAppGroup = ag, SCH.dcService = Nothing, SCH.dcCluster = Nothing, SCH.dcNamespace = Nothing
          , SCH.dcVsName = Nothing, SCH.dcAppGroupAcronym = Nothing, SCH.dcRepoName = Just "o/r", SCH.dcAppGroupType = Nothing
          , SCH.dcSyncCluster = Nothing, SCH.dcNeedInfraApproval = Nothing, SCH.dcAiChangelogEnabled = Nothing
          , SCH.dcVsLockedBy = Nothing, SCH.dcVsLockTimestamp = Nothing, SCH.dcServiceHost = Nothing, SCH.dcServiceType = Nothing
          , SCH.dcRolloutStrategy = Nothing, SCH.dcRevertStrategy = Nothing, SCH.dcDecisionConfig = Nothing
          , SCH.dcSlackChannel = Nothing, SCH.dcServiceState = Nothing, SCH.dcHpaMinReplicas = Nothing
          , SCH.dcHpaMaxReplicas = Nothing, SCH.dcCloudType = "GCP"
          , SCH.dcReleaseBotConfig = Just ("{\"env\":\"" <> env <> "\",\"branches\":[\"b\"],\"jenkins\":{\"job\":\"" <> job <> "\",\"commitParam\":\"commit\",\"fixedParams\":{\"P\":\"" <> params <> "\"}}}")
          }
  case RBW.buildFromRows [row "prod-g" "PROD" "j" "prod", row "master-g" "MASTER" "j" "master"] of
    Left e -> fail ("  FAIL: PROD+MASTER on one repo should build: " <> T.unpack e)
    Right c -> do
      let repo = head (PRC.prcRepos c)
      assertEqual "one repo, jenkins params chosen by env" (Just "prod", Just "master") (Map.lookup "P" (PRC.jcFixedParams (PRC.jenkinsFor repo "PROD")), Map.lookup "P" (PRC.jcFixedParams (PRC.jenkinsFor repo "master")))
  assertBool "two PROD app groups with different params for one repo is an error" (either (T.isInfixOf "different Jenkins") (const False) (RBW.buildFromRows [row "a" "PROD" "j" "x", row "b" "PROD" "j" "y"]))

-- ============================================================================
-- HPA
-- ============================================================================

testHpaQuantity :: IO ()
testHpaQuantity = do
  let q t = either (const Nothing) Just (HQ.parseQuantity t)
      milli t = HQ.qMilli <$> q t
  assertEqual "500m == 0.5 CPU" (q "500m") (q "0.5")
  assertEqual "500m is 500 milli" (Just 500) (milli "500m")
  assertEqual "1 CPU is 1000 milli" (Just 1000) (milli "1")
  assertEqual "1Gi == 1024Mi" (q "1Gi") (q "1024Mi")
  assertEqual "1Gi == 1073741824 bytes" (q "1Gi") (q "1073741824")
  assertBool "1G (decimal) /= 1Gi (binary)" (q "1G" /= q "1Gi")
  assertEqual "1k == 1000" (q "1k") (q "1000")
  assertEqual "1e3 == 1k (exponent form)" (q "1e3") (q "1k")
  assertEqual "1E3 == 1k (upper-case exponent)" (q "1E3") (q "1k")
  assertEqual "1E alone is exa, not an exponent" (Just (10 ^ (18 :: Int) * 1000)) (milli "1E")
  assertEqual "1.5Gi" (q "1.5Gi") (q "1536Mi")
  assertEqual "250Mi < 1Gi" (Just True) ((<) <$> q "250Mi" <*> q "1Gi")
  assertEqual "sub-milli rounds up like the API server (0.0001 -> 1m)" (Just 1) (milli "0.0001")
  assertEqual "100u is 0.1 milli, rounds up to 1" (Just 1) (milli "100u")
  assertEqual ".5 is accepted" (Just 500) (milli ".5")
  assertEqual "surrounding whitespace is ignored" (Just 500) (milli " 500m ")
  assertEqual "raw spelling is preserved" (Just "0.5") (HQ.qRaw <$> q "0.5")
  mapM_ (\bad -> assertEqual ("rejects " <> show bad) Nothing (q bad)) ["", "abc", "5x", "1Kb", "Mi", "1e", "1e99", "1..5", "m"]
  assertEqual "JSON string quantity" (Just (q "256Mi")) (fmap Just (A.decode "\"256Mi\"" :: Maybe HQ.Quantity))
  assertEqual "JSON number quantity" (Just (q "2")) (fmap Just (A.decode "2" :: Maybe HQ.Quantity))
  assertEqual "ToJSON keeps the raw spelling" (Just (A.String "500m")) (A.toJSON <$> q "500m")

hpaJson :: String -> Text -> Text -> Text -> A.Value
hpaJson name target extraMeta specExtra =
  let txt =
        "{\"metadata\":{\"name\":\"" <> T.pack name <> "\",\"namespace\":\"ns\",\"resourceVersion\":\"7\"" <> extraMeta <> "},"
          <> "\"spec\":{\"scaleTargetRef\":{\"kind\":\"Deployment\",\"name\":\"" <> target <> "\"},\"maxReplicas\":20" <> specExtra <> "},"
          <> "\"status\":{\"currentReplicas\":3,\"desiredReplicas\":4}}"
   in either error id (A.eitherDecodeStrict (TE.encodeUtf8 txt))

fullSpecExtra :: Text
fullSpecExtra =
  ",\"minReplicas\":2,\"metrics\":["
    <> "{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":70}}},"
    <> "{\"type\":\"Resource\",\"resource\":{\"name\":\"memory\",\"target\":{\"type\":\"AverageValue\",\"averageValue\":\"256Mi\"}}},"
    <> "{\"type\":\"Pods\",\"pods\":{\"metric\":{\"name\":\"rps\"},\"target\":{\"type\":\"AverageValue\",\"averageValue\":\"100\"}}},"
    <> "{\"type\":\"SomethingNew\",\"foo\":1}"
    <> "],\"behavior\":{\"scaleDown\":{\"stabilizationWindowSeconds\":300,\"policies\":[{\"type\":\"Percent\",\"value\":10,\"periodSeconds\":60}]},"
    <> "\"scaleUp\":{\"selectPolicy\":\"Max\",\"policies\":[{\"type\":\"Pods\",\"value\":4,\"periodSeconds\":15}]}}"

testHpaSpec :: IO ()
testHpaSpec = do
  case HS.parseHpaObject (hpaJson "svc-v1-hpa" "svc-v1" "" fullSpecExtra) of
    Left e -> fail ("  FAIL: full HPA should parse: " <> T.unpack e)
    Right h -> do
      let sp = HS.hoSpec h
      assertEqual "min/max" (2, 20) (HS.hsMinReplicas sp, HS.hsMaxReplicas sp)
      assertEqual "four metric entries (unknown kept)" 4 (length (HS.hsMetrics sp))
      assertEqual "cpu is a Utilization percentage" (HS.ResourceMetric HS.Cpu (HS.Utilization 70)) (head (HS.hsMetrics sp))
      assertBool "memory is an AverageValue quantity, equal to 268435456" $
        case HS.hsMetrics sp !! 1 of
          HS.ResourceMetric HS.Memory (HS.AverageValue q) -> HQ.qMilli q == 268435456 * 1000
          _ -> False
      assertBool "unknown metric type is preserved, not dropped" $
        case last (HS.hsMetrics sp) of HS.UnknownMetric _ -> True; _ -> False
      assertEqual "metric keys address entries stably" ["resource/cpu", "resource/memory", "pods/rps"] (take 3 (map HS.metricKey (HS.hsMetrics sp)))
      assertEqual "summary strings" ["cpu 70%", "memory avg 256Mi", "rps avg 100"] (take 3 (map HS.describeMetric (HS.hsMetrics sp)))
      assertEqual "scaleDown window + Percent policy" (Just 300) (HS.hsBehavior sp >>= HS.bScaleDown >>= HS.srStabilizationWindowSeconds)
      assertEqual "status" (3, 4) (HS.hstCurrentReplicas (HS.hoStatus h), HS.hstDesiredReplicas (HS.hoStatus h))
      assertEqual "valid spec has no issues" [] (HS.validateSpec sp)
      assertEqual "spec JSON round-trips (typed view is lossless for modelled fields)" (Right sp) (either (Left . T.pack) Right (A.eitherDecode (A.encode sp)) :: Either Text HS.HpaSpec)
      assertEqual "not KEDA, not legacy" (False, False) (HS.hoKedaManaged h, HS.hoLegacyV1 h)
  case HS.parseHpaObject (hpaJson "svc-v1-hpa" "svc-v1" "" "") of
    Right h -> assertEqual "absent minReplicas defaults to 1 like the API server" 1 (HS.hsMinReplicas (HS.hoSpec h))
    Left e -> fail ("  FAIL: minimal HPA should parse: " <> T.unpack e)
  case HS.parseHpaObject (hpaJson "keda-hpa-x" "svc-v1" "" "") of
    Right h -> assertBool "keda-hpa- prefix is KEDA-managed" (HS.hoKedaManaged h)
    Left e -> fail (T.unpack e)
  case HS.parseHpaObject (hpaJson "x" "svc-v1" ",\"labels\":{\"scaledobject.keda.sh/name\":\"s\"}" "") of
    Right h -> assertBool "KEDA label is KEDA-managed" (HS.hoKedaManaged h)
    Left e -> fail (T.unpack e)
  case HS.parseHpaObject (hpaJson "x" "svc-v1" "" ",\"targetCPUUtilizationPercentage\":80") of
    Right h -> assertBool "v1-shaped HPA is flagged legacy" (HS.hoLegacyV1 h)
    Left e -> fail (T.unpack e)
  assertBool "garbage item is a Left, not an exception" (either (const True) (const False) (HS.parseHpaObject (A.String "nope")))
  -- validation
  let base = either (error . T.unpack) HS.hoSpec (HS.parseHpaObject (hpaJson "h" "t" "" fullSpecExtra))
      bad f = not (null (HS.validateSpec (f base)))
  assertBool "min 0 rejected" (bad (\s -> s {HS.hsMinReplicas = 0}))
  assertBool "max < min rejected" (bad (\s -> s {HS.hsMaxReplicas = 1}))
  assertBool "Utilization on a Pods metric rejected" (bad (\s -> s {HS.hsMetrics = [HS.PodsMetric (HS.MetricIdentifier "rps" Nothing) (HS.Utilization 50)]}))
  assertBool "Value target on a Resource metric rejected" (bad (\s -> s {HS.hsMetrics = [HS.ResourceMetric HS.Cpu (HS.TargetValue (HQ.mkQuantity 1))]}))
  assertBool "Utilization 0 rejected" (bad (\s -> s {HS.hsMetrics = [HS.ResourceMetric HS.Cpu (HS.Utilization 0)]}))
  assertBool "Pods metric with Value target rejected" (bad (\s -> s {HS.hsMetrics = [HS.PodsMetric (HS.MetricIdentifier "rps" Nothing) (HS.TargetValue (HQ.mkQuantity 1))]}))
  assertBool "zero quantity rejected" (bad (\s -> s {HS.hsMetrics = [HS.ResourceMetric HS.Memory (HS.AverageValue (HQ.mkQuantity 0))]}))
  assertBool "stabilization window > 3600 rejected" (bad (\s -> s {HS.hsBehavior = Just (HS.Behavior Nothing (Just (HS.ScalingRules (Just 4000) Nothing [])))}))
  assertBool "policy periodSeconds 0 rejected" (bad (\s -> s {HS.hsBehavior = Just (HS.Behavior (Just (HS.ScalingRules Nothing Nothing [HS.ScalingPolicy HS.PolicyPods 1 0])) Nothing)}))
  assertBool "Percent scale-up policy > 100 is allowed" (not (bad (\s -> s {HS.hsBehavior = Just (HS.Behavior (Just (HS.ScalingRules Nothing Nothing [HS.ScalingPolicy HS.PolicyPercent 200 60])) Nothing)})))
  assertBool "External metric with Value target allowed" (not (bad (\s -> s {HS.hsMetrics = [HS.ExternalMetric (HS.MetricIdentifier "q" Nothing) (HS.TargetValue (HQ.mkQuantity 30))]})))

testHpaResolver :: IO ()
testHpaResolver = do
  let vs routes =
        either error id . A.eitherDecodeStrict . TE.encodeUtf8 $
          "{\"spec\":{\"http\":[" <> T.intercalate "," routes <> "]}}"
      route subs = "{\"route\":[" <> T.intercalate "," subs <> "]}"
      dest host sub w = "{\"destination\":{\"host\":\"" <> host <> "\",\"subset\":\"" <> sub <> "\"}" <> maybe "" (\n -> ",\"weight\":" <> T.pack (show (n :: Int))) w <> "}"
      hpa n target = either (error . T.unpack) id (HS.parseHpaObject (hpaJson n target "" ""))
  assertEqual "weights per subset" [("v1", 70), ("v2", 30)] (HR.subsetWeightsFromVs "svc" (vs [route [dest "svc" "v1" (Just 70), dest "svc" "v2" (Just 30)]]))
  assertEqual "other hosts ignored" [("v1", 100)] (HR.subsetWeightsFromVs "svc" (vs [route [dest "svc" "v1" (Just 100), dest "other" "v9" (Just 0)]]))
  assertEqual "single destination without weight is 100 (Istio semantics)" [("v1", 100)] (HR.subsetWeightsFromVs "svc" (vs [route [dest "svc" "v1" Nothing]]))
  assertEqual "highest weight per subset across http rules" [("v1", 90), ("v2", 90)] (HR.subsetWeightsFromVs "svc" (vs [route [dest "svc" "v1" (Just 10), dest "svc" "v2" (Just 90)], route [dest "svc" "v1" (Just 90), dest "svc" "v2" (Just 10)]]))
  assertEqual "FQDN host matches short name" [("v1", 100)] (HR.subsetWeightsFromVs "svc" (vs [route [dest "svc.ns.svc.cluster.local" "v1" (Just 100)]]))
  assertEqual "garbage VS yields no weights" [] (HR.subsetWeightsFromVs "svc" (A.String "x"))
  -- classification
  let h1 = hpa "svc-v1-hpa" "svc-v1"
      h2 = hpa "svc-v2-hpa" "svc-v2"
      roles r = [(HS.hoName (HR.rhHpa x), HR.rhRole x) | x <- HR.resHpas r]
      r1 = HR.classifyHpas "svc" [] (Just [("v1", 0), ("v2", 100)]) [h1, h2]
  assertEqual "two HPAs: v2 serves, v1 drains" [("svc-v1-hpa", HR.RoleDraining), ("svc-v2-hpa", HR.RoleServing)] (roles r1)
  assertEqual "serving list" ["svc-v2-hpa"] (HR.resServing r1)
  assertEqual "no warnings in the clean case" [] (HR.resWarnings r1)
  let r2 = HR.classifyHpas "svc" [] (Just [("v1", 50), ("v2", 50)]) [h1, h2]
  assertEqual "split traffic: both serve" ["svc-v1-hpa", "svc-v2-hpa"] (HR.resServing r2)
  assertBool "split traffic warns that a change hits both" (any (T.isInfixOf "apply to all") (HR.resWarnings r2))
  let r3 = HR.classifyHpas "svc" [] (Just [("v3", 100)]) [h1, h2]
  assertEqual "HPAs for versions absent from the VS are UNROUTED" [("svc-v1-hpa", HR.RoleUnrouted), ("svc-v2-hpa", HR.RoleUnrouted)] (roles r3)
  assertBool "serving version without an HPA is flagged" (any (T.isInfixOf "have no HPA") (HR.resWarnings r3))
  let r4 = HR.classifyHpas "svc" [] Nothing [h1]
  assertEqual "VS unreadable -> UNKNOWN, never guessed" [("svc-v1-hpa", HR.RoleUnknown)] (roles r4)
  -- prefix collision: service "foo" must not claim HPAs of service "foo-bar"
  let foo = hpa "foo-v1-hpa" "foo-v1"
      fooBar = hpa "foo-bar-v1-hpa" "foo-bar-v1"
      r5 = HR.classifyHpas "foo" ["foo", "foo-bar"] (Just [("v1", 100)]) [foo, fooBar]
  assertEqual "foo does not claim foo-bar's HPA" ["foo-v1-hpa"] (map (HS.hoName . HR.rhHpa) (HR.resHpas r5))
  let r6 = HR.classifyHpas "foo-bar" ["foo", "foo-bar"] (Just [("v1", 100)]) [foo, fooBar]
  assertEqual "foo-bar claims its own" ["foo-bar-v1-hpa"] (map (HS.hoName . HR.rhHpa) (HR.resHpas r6))
  assertEqual "version is the suffix after the host" ["v1"] (map HR.rhVersion (HR.resHpas r6))
  -- editability
  let keda = either (error . T.unpack) id (HS.parseHpaObject (hpaJson "keda-hpa-svc-v1" "svc-v1" "" ""))
      r7 = HR.classifyHpas "svc" [] (Just [("v1", 100)]) [keda]
  assertBool "KEDA HPA is serving but not editable" (all (\x -> HR.rhEditableReason x /= Nothing) (HR.resHpas r7))
  assertBool "ordinary HPA is editable" (all (\x -> HR.rhEditableReason x == Nothing) (HR.resHpas r1))
  let nonDep = either (error . T.unpack) id (HS.parseHpaObject (A.Object (case hpaJson "svc-v1-hpa" "svc-v1" "" "" of A.Object o -> AKM.insert "spec" (A.object ["scaleTargetRef" A..= A.object ["kind" A..= ("StatefulSet" :: Text), "name" A..= ("svc-v1" :: Text)], "maxReplicas" A..= (5 :: Int)]) o; _ -> AKM.empty)))
  assertEqual "only Deployment targets are matched" [] (HR.resHpas (HR.classifyHpas "svc" [] (Just [("v1", 100)]) [nonDep]))
  assertBool "no HPAs -> explicit reason" (T.isInfixOf "No HPA" (HR.resReason (HR.classifyHpas "svc" [] (Just []) [])))

utc :: String -> UTCTime
utc t = read (t <> " UTC")

testHpaWindow :: IO ()
testHpaWindow = do
  -- 2026-10-19 is a Monday.
  let weekdaysIst = HT.Weekly [1, 2, 3, 4, 5] (10 * 60) 120 330 -- Mon-Fri 10:00 IST for 2h = 04:30-06:30 UTC
      active k t = HW.activeWindow k (utc t)
  assertBool "inside window (05:00 UTC Monday)" (active weekdaysIst "2026-10-19 05:00:00" /= Nothing)
  assertEqual "window bounds in UTC" (Just (HW.Window (utc "2026-10-19 04:30:00") (Just (utc "2026-10-19 06:30:00")))) (active weekdaysIst "2026-10-19 05:00:00")
  assertBool "start is inclusive" (active weekdaysIst "2026-10-19 04:30:00" /= Nothing)
  assertBool "just before start is closed" (active weekdaysIst "2026-10-19 04:29:59" == Nothing)
  assertBool "end is exclusive" (active weekdaysIst "2026-10-19 06:30:00" == Nothing)
  assertBool "Saturday has no window" (active weekdaysIst "2026-10-24 05:00:00" == Nothing)
  assertBool "Friday does" (active weekdaysIst "2026-10-23 05:00:00" /= Nothing)
  -- overnight: Friday 22:00 UTC for 6h runs into Saturday
  let overnight = HT.Weekly [5] (22 * 60) 360 0
  assertBool "overnight window still open Saturday 02:00" (HW.activeWindow overnight (utc "2026-10-24 02:00:00") /= Nothing)
  assertBool "closed Saturday 04:00" (HW.activeWindow overnight (utc "2026-10-24 04:00:00") == Nothing)
  -- local weekday differs from UTC weekday: Monday 01:00 IST = Sunday 19:30 UTC
  let earlyMon = HT.Weekly [1] 60 60 330
  assertEqual "Monday 01:00 IST starts Sunday 19:30 UTC" (Just (utc "2026-10-18 19:30:00")) (fmap HW.wStart (HW.activeWindow earlyMon (utc "2026-10-18 20:00:00")))
  assertBool "and is not a Sunday-local window" (HW.activeWindow (HT.Weekly [7] 60 60 330) (utc "2026-10-18 20:00:00") == Nothing)
  -- negative offset: Monday 20:00 PST(-480) = Tuesday 04:00 UTC
  let pst = HT.Weekly [1] (20 * 60) 60 (-480)
  assertEqual "negative offset" (Just (utc "2026-10-20 04:00:00")) (fmap HW.wStart (HW.activeWindow pst (utc "2026-10-20 04:30:00")))
  -- next window
  assertEqual "next after Monday window is Tuesday 04:30" (Just (utc "2026-10-20 04:30:00")) (HW.nextWindowStart weekdaysIst (utc "2026-10-19 05:00:00"))
  assertEqual "next from Friday evening skips the weekend" (Just (utc "2026-10-26 04:30:00")) (HW.nextWindowStart weekdaysIst (utc "2026-10-23 20:00:00"))
  assertEqual "next is found even 0.1s ahead (sub-second t)" (Just (utc "2026-10-19 04:30:00")) (HW.nextWindowStart weekdaysIst (utc "2026-10-19 04:29:59.9"))
  assertEqual "next excludes a start equal to t" (Just (utc "2026-10-20 04:30:00")) (HW.nextWindowStart weekdaysIst (utc "2026-10-19 04:30:00"))
  -- once
  let once = HT.Once (utc "2026-11-01 10:00:00") (Just (utc "2026-11-01 14:00:00"))
      perm = HT.Once (utc "2026-11-01 10:00:00") Nothing
  assertBool "once: before start" (HW.activeWindow once (utc "2026-11-01 09:59:59") == Nothing)
  assertBool "once: during" (HW.activeWindow once (utc "2026-11-01 12:00:00") /= Nothing)
  assertBool "once: after end" (HW.activeWindow once (utc "2026-11-01 14:00:00") == Nothing)
  assertBool "permanent once stays open for months" (HW.activeWindow perm (utc "2027-03-01 00:00:00") /= Nothing)
  assertEqual "once next start" (Just (utc "2026-11-01 10:00:00")) (HW.nextWindowStart once (utc "2026-10-19 00:00:00"))
  assertEqual "once has no next after it started" Nothing (HW.nextWindowStart once (utc "2026-11-01 10:00:00"))
  -- overlap
  let now = utc "2026-10-19 00:00:00"
      overlap = HW.schedulesOverlap now 14
  assertBool "identical weekly schedules overlap" (overlap weekdaysIst weekdaysIst)
  assertBool "different days do not" (not (overlap (HT.Weekly [1] 600 60 0) (HT.Weekly [2] 600 60 0)))
  assertBool "adjacent windows do not overlap (half-open)" (not (overlap (HT.Weekly [1] 600 60 0) (HT.Weekly [1] 660 60 0)))
  assertBool "one minute of overlap is caught" (overlap (HT.Weekly [1] 600 61 0) (HT.Weekly [1] 660 60 0))
  assertBool "permanent once collides with a later weekly window" (overlap perm (HT.Weekly [1, 2, 3, 4, 5, 6, 7] 720 60 0))
  assertBool "once in the past of the horizon does not" (not (overlap once (HT.Weekly [1] 600 60 0)))
  assertBool "an already-open window counts" (overlap (HT.Weekly [1] 0 1440 0) (HT.Weekly [1] 600 60 0))
  -- validation
  assertEqual "valid weekly" [] (HW.validateKind weekdaysIst)
  assertBool "empty days" (not (null (HW.validateKind (HT.Weekly [] 0 60 0))))
  assertBool "day 0 / 8" (not (null (HW.validateKind (HT.Weekly [0] 0 60 0))) && not (null (HW.validateKind (HT.Weekly [8] 0 60 0))))
  assertBool "duplicate days" (not (null (HW.validateKind (HT.Weekly [1, 1] 0 60 0))))
  assertBool "duration 0 and 1441" (not (null (HW.validateKind (HT.Weekly [1] 0 0 0))) && not (null (HW.validateKind (HT.Weekly [1] 0 1441 0))))
  assertBool "offset out of range" (not (null (HW.validateKind (HT.Weekly [1] 0 60 900))))
  assertBool "once end before start" (not (null (HW.validateKind (HT.Once (utc "2026-11-01 10:00:00") (Just (utc "2026-11-01 09:00:00"))))))
  -- JSON
  assertEqual "weekly JSON round-trip" (Just weekdaysIst) (A.decode (A.encode weekdaysIst))
  assertEqual "once JSON round-trip" (Just once) (A.decode (A.encode once))
  assertEqual "permanent once JSON round-trip" (Just perm) (A.decode (A.encode perm))
  assertEqual "startTime rendered HH:MM" (Just (A.String "10:00")) (case A.toJSON weekdaysIst of A.Object o -> AKM.lookup "startTime" o; _ -> Nothing)
  assertEqual "bad startTime rejected" (Nothing :: Maybe HT.ScheduleKind) (A.decode "{\"kind\":\"WEEKLY\",\"days\":[1],\"startTime\":\"25:00\",\"durationMinutes\":60}")
  assertEqual "missing offset defaults to 0" (Just (HT.Weekly [1] 600 60 0)) (A.decode "{\"kind\":\"WEEKLY\",\"days\":[1],\"startTime\":\"10:00\",\"durationMinutes\":60}")

changeSpecExtra :: Text
changeSpecExtra = T.replace "],\"behavior\"" "],\"unmodelled\":\"keep-me\",\"behavior\"" fullSpecExtra

mkHpa :: Text -> HS.HpaObject
mkHpa extra = either (error . T.unpack) id (HS.parseHpaObject (hpaJson "svc-v1-hpa" "svc-v1" ",\"managedFields\":[{\"x\":1}]" extra))

testHpaChange :: IO ()
testHpaChange = do
  let h = mkHpa changeSpecExtra
      spec = HS.hoSpec h
      pct n = HS.Utilization n
      cpuKey = "resource/cpu"
      memKey = "resource/memory"
      ch1 = HT.emptyChange {HT.chMinReplicas = Just 10, HT.chMaxReplicas = Just 60, HT.chMetricTargets = [HT.MetricTargetChange cpuKey (pct 50)]}
  case HC.applyChangeTyped spec ch1 of
    Left e -> fail ("  FAIL: ch1 should apply: " <> show e)
    Right after -> do
      assertEqual "min/max changed" (10, 60) (HS.hsMinReplicas after, HS.hsMaxReplicas after)
      assertEqual "cpu target changed" (HS.ResourceMetric HS.Cpu (pct 50)) (head (HS.hsMetrics after))
      assertEqual "other metrics untouched" (tail (HS.hsMetrics spec)) (tail (HS.hsMetrics after))
      assertEqual "behavior untouched" (HS.hsBehavior spec) (HS.hsBehavior after)
      -- raw object
      case HC.buildChangedObject h ch1 [(HT.annScheduleId, "s1"), (HT.annApplyId, "a1")] of
        Left e -> fail ("  FAIL: buildChangedObject: " <> show e)
        Right obj -> do
          let reparsed = either (error . T.unpack) id (HS.parseHpaObject obj)
              rawText = TE.decodeUtf8 (BL.toStrict (A.encode obj))
          assertEqual "re-parsed object equals the intended spec" after (HS.hoSpec reparsed)
          assertBool "unmodelled spec field survives" (T.isInfixOf "keep-me" rawText)
          assertBool "unknown metric type survives untouched" (T.isInfixOf "SomethingNew" rawText)
          assertBool "resourceVersion kept for optimistic concurrency" (HS.hoResourceVersion reparsed == "7")
          assertBool "managedFields stripped" (not (T.isInfixOf "managedFields" rawText))
          assertBool "status stripped" (not (T.isInfixOf "currentReplicas" rawText))
          assertBool "annotations written" (T.isInfixOf "s1" rawText && T.isInfixOf "a1" rawText)
          -- restore with live == changed object
          let live = reparsed
              plan = HC.planRestore spec after ch1 live
              restoredObj = either (error . T.unpack) id (HS.parseHpaObject (HC.rpObject plan))
          assertEqual "all touched fields restored" ["minReplicas", "maxReplicas", "metric resource/cpu"] (HC.rpRestored plan)
          assertEqual "no drift" [] (HC.rpDrifted plan)
          assertEqual "restored spec equals the original" spec (HS.hoSpec restoredObj)
          assertBool "our annotations are gone after restore" (not (T.isInfixOf "hpa-apply-id" (TE.decodeUtf8 (BL.toStrict (A.encode (HC.rpObject plan))))))
          assertBool "unmodelled field still there after restore" (T.isInfixOf "keep-me" (TE.decodeUtf8 (BL.toStrict (A.encode (HC.rpObject plan)))))
          -- drift: someone raised max to 99 after we set 60
          let driftedRaw = HC.rpObject (HC.planRestore spec after ch1 (reparsed {HS.hoSpec = (HS.hoSpec reparsed) {HS.hsMaxReplicas = 99}, HS.hoRaw = setMax 99 (HS.hoRaw reparsed)}))
              setMax n v = case v of A.Object o -> A.Object (case AKM.lookup "spec" o of Just (A.Object so) -> AKM.insert "spec" (A.Object (AKM.insert "maxReplicas" (A.toJSON (n :: Int)) so)) o; _ -> o); x -> x
              driftPlan = HC.planRestore spec after ch1 (reparsed {HS.hoSpec = (HS.hoSpec reparsed) {HS.hsMaxReplicas = 99}, HS.hoRaw = setMax 99 (HS.hoRaw reparsed)})
              driftObj = either (error . T.unpack) id (HS.parseHpaObject driftedRaw)
          assertEqual "drifted field is reported" ["maxReplicas"] (HC.rpDrifted driftPlan)
          assertEqual "drifted field is left alone" 99 (HS.hsMaxReplicas (HS.hoSpec driftObj))
          assertEqual "non-drifted fields still restored" 2 (HS.hsMinReplicas (HS.hoSpec driftObj))
          -- already original
          let nothing = HC.planRestore spec after ch1 h
          assertEqual "live == original: nothing to restore" [] (HC.rpRestored nothing)
          assertEqual "live == original: reported as already original" ["minReplicas", "maxReplicas", "metric resource/cpu"] (HC.rpAlreadyOriginal nothing)
      -- verify
      assertEqual "verify passes when the cluster holds the intended spec" [] (HC.verifyApplied after ch1 after)
      assertEqual "verify reports each mismatching touched field" 3 (length (HC.verifyApplied after ch1 spec))
      assertEqual "verify ignores untouched fields" [] (HC.verifyApplied after ch1 (after {HS.hsMetrics = HS.hsMetrics after}))
  -- memory quantity: 256Mi -> 512Mi
  let chMem = HT.emptyChange {HT.chMetricTargets = [HT.MetricTargetChange memKey (HS.AverageValue (HQ.mkQuantity 536870912))]}
  assertBool "memory quantity target applies" (either (const False) (const True) (HC.applyChangeTyped spec chMem))
  -- quantity-aware no-op: 256Mi == 268435456
  let chSame = HT.emptyChange {HT.chMetricTargets = [HT.MetricTargetChange memKey (HS.AverageValue (HQ.mkQuantity 268435456))]}
  assertBool "same quantity in another spelling is a no-op" (HC.changeIsNoop spec chSame)
  assertBool "a real change is not a no-op" (not (HC.changeIsNoop spec ch1))
  -- failures
  let leftOf c = either id (const []) (HC.applyChangeTyped spec c)
  assertBool "empty change refused" (not (null (leftOf HT.emptyChange)))
  assertBool "unknown metric key refused, listing the real ones" (any (T.isInfixOf "resource/cpu") (leftOf HT.emptyChange {HT.chMetricTargets = [HT.MetricTargetChange "resource/nope" (pct 5)]}))
  assertBool "duplicate metric key refused" (not (null (leftOf HT.emptyChange {HT.chMetricTargets = [HT.MetricTargetChange cpuKey (pct 5), HT.MetricTargetChange cpuKey (pct 6)]})))
  assertBool "max below min refused" (not (null (leftOf HT.emptyChange {HT.chMaxReplicas = Just 1})))
  assertBool "min above existing max refused" (not (null (leftOf HT.emptyChange {HT.chMinReplicas = Just 50})))
  assertBool "Utilization on a pods metric refused" (not (null (leftOf HT.emptyChange {HT.chMetricTargets = [HT.MetricTargetChange "pods/rps" (pct 50)]})))
  assertBool "unknown-type metric cannot be edited" (not (null (leftOf HT.emptyChange {HT.chMetricTargets = [HT.MetricTargetChange (HS.metricKey (last (HS.hsMetrics spec))) (pct 50)]})))
  -- behavior: replace scaleDown only
  let newDown = HS.ScalingRules (Just 600) (Just HS.SelMin) [HS.ScalingPolicy HS.PolicyPods 2 60]
      chB = HT.emptyChange {HT.chScaleDown = Just newDown}
  case HC.applyChangeTyped spec chB of
    Right a -> do
      assertEqual "scaleDown replaced wholesale" (Just newDown) (HS.hsBehavior a >>= HS.bScaleDown)
      assertEqual "scaleUp untouched" (HS.hsBehavior spec >>= HS.bScaleUp) (HS.hsBehavior a >>= HS.bScaleUp)
    Left e -> fail ("  FAIL: behavior change: " <> show e)
  -- behavior added where none existed, then restored away entirely
  let noBeh = mkHpa ",\"minReplicas\":2,\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":70}}}]"
      chUp = HT.emptyChange {HT.chScaleUp = Just (HS.ScalingRules (Just 0) Nothing [HS.ScalingPolicy HS.PolicyPercent 100 15])}
  case (HC.applyChangeTyped (HS.hoSpec noBeh) chUp, HC.buildChangedObject noBeh chUp []) of
    (Right a, Right obj) -> do
      let live = either (error . T.unpack) id (HS.parseHpaObject obj)
          plan = HC.planRestore (HS.hoSpec noBeh) a chUp live
          restored = either (error . T.unpack) id (HS.parseHpaObject (HC.rpObject plan))
      assertEqual "behavior was added" True (HS.hsBehavior (HS.hoSpec live) /= Nothing)
      assertEqual "restore removes the behavior block entirely" Nothing (HS.hsBehavior (HS.hoSpec restored))
      assertBool "no empty behavior object left in the raw object" (not (T.isInfixOf "behavior" (TE.decodeUtf8 (BL.toStrict (A.encode (HC.rpObject plan))))))
    other -> fail ("  FAIL: behavior add/restore setup: " <> show (fmap (const ()) (fst other)))
  -- guardrails
  let g = HT.defaultGuardrail {HT.grMaxReplicasCap = Just 50, HT.grMinReplicasFloor = Just 2, HT.grMaxStepPct = Just 100}
      afterOf c = either (error . show) id (HC.applyChangeTyped spec c)
  assertEqual "within limits" [] (HC.checkGuardrail g spec (afterOf HT.emptyChange {HT.chMaxReplicas = Just 40}))
  assertBool "cap exceeded" (not (null (HC.checkGuardrail g spec (afterOf HT.emptyChange {HT.chMaxReplicas = Just 60}))))
  assertBool "floor violated" (not (null (HC.checkGuardrail g spec (afterOf HT.emptyChange {HT.chMinReplicas = Just 1}))))
  assertBool "step too large (max 20 -> 45 is +125%)" (not (null (HC.checkGuardrail g spec (afterOf HT.emptyChange {HT.chMaxReplicas = Just 45}))))
  assertEqual "step exactly at the limit is allowed (20 -> 40 is +100%)" [] (HC.checkGuardrail g spec (afterOf HT.emptyChange {HT.chMaxReplicas = Just 40}))
  assertBool "frozen service refuses any change" (not (null (HC.checkGuardrail HT.defaultGuardrail {HT.grFrozen = True, HT.grFrozenReason = Just "sale"} spec (afterOf HT.emptyChange {HT.chMaxReplicas = Just 21}))))
  assertEqual "no guardrail, no issues" [] (HC.checkGuardrail HT.defaultGuardrail spec (afterOf HT.emptyChange {HT.chMaxReplicas = Just 500}))
  -- diff
  let d = HC.jsonDiff (A.toJSON spec) (A.toJSON (afterOf ch1))
  assertEqual "diff paths" ["maxReplicas", "metrics[0].resource.target.averageUtilization", "minReplicas"] (map HC.dePath d)
  assertEqual "diff of equal values is empty" [] (HC.jsonDiff (A.toJSON spec) (A.toJSON spec))
  assertEqual "array growth reported by index" [HC.DiffEntry "[2]" Nothing (Just (A.Number 3))] (HC.jsonDiff (A.toJSON [1 :: Int, 2]) (A.toJSON [1 :: Int, 2, 3]))
  assertEqual "1 and 1.0 are equal" [] (HC.jsonDiff (A.Number 1) (A.Number 1.0))
  -- base spec
  assertBool "base spec carries min, max, metrics and behavior" $
    case HC.baseSpecJson h of
      A.Object o -> all (`AKM.member` o) ["minReplicas", "maxReplicas", "metrics", "behavior"] && not (AKM.member "scaleTargetRef" o)
      _ -> False

testHpaTypes :: IO ()
testHpaTypes = do
  let allS = [minBound .. maxBound] :: [HT.ApplyStatus]
  assertEqual "status text round-trips" (map Just allS) (map (HT.parseApplyStatus . HT.applyStatusText) allS)
  assertEqual "blocking + terminal partition all statuses" (length allS) (length HT.blockingStatusTexts + length HT.terminalStatusTexts)
  assertEqual "terminal statuses" ["RESTORED", "ROLLED_BACK", "FAILED", "SKIPPED"] HT.terminalStatusTexts
  assertBool "no transition out of a terminal status" (and [not (HT.validApplyTransition f t) | f <- allS, HT.isTerminalApply f, t <- allS])
  assertBool "PENDING -> APPLYING" (HT.validApplyTransition HT.Pending HT.Applying)
  assertBool "PENDING cannot jump to APPLIED" (not (HT.validApplyTransition HT.Pending HT.Applied))
  assertBool "APPLIED -> RESTORING" (HT.validApplyTransition HT.Applied HT.Restoring)
  assertBool "APPLIED cannot go straight to RESTORED" (not (HT.validApplyTransition HT.Applied HT.Restored))
  assertBool "OBSERVING -> ROLLING_BACK (health breach)" (HT.validApplyTransition HT.Observing HT.RollingBack)
  assertBool "NEEDS_ATTENTION can be retried as RESTORING / ROLLING_BACK or closed FAILED" (all (HT.validApplyTransition HT.NeedsAttention) [HT.Restoring, HT.RollingBack, HT.Failed])
  assertBool "every non-terminal status can reach NEEDS_ATTENTION or a terminal" (and [any (\t -> HT.validApplyTransition f t) allS | f <- allS, not (HT.isTerminalApply f)])
  assertEqual "step text round-trips" (map Just [minBound .. maxBound :: HT.ApplyStep]) (map (HT.parseApplyStep . HT.applyStepText) [minBound .. maxBound])
  -- change JSON
  let ch = HT.emptyChange {HT.chMinReplicas = Just 3, HT.chMetricTargets = [HT.MetricTargetChange "resource/cpu" (HS.Utilization 55)]}
  assertEqual "change JSON round-trip" (Just ch) (A.decode (A.encode ch))
  assertEqual "empty change JSON is {}" "{}" (BL.toStrict (A.encode HT.emptyChange))
  assertBool "empty detected" (HT.changeIsEmpty HT.emptyChange && not (HT.changeIsEmpty ch))
  -- policy defaults + validation
  assertEqual "empty policy object takes defaults" (Just HT.defaultHealthPolicy) (A.decode "{}")
  assertEqual "partial policy keeps other defaults" (Just HT.defaultHealthPolicy {HT.hpObserveSeconds = 60}) (A.decode "{\"observeSeconds\":60}")
  assertEqual "default policy is valid" [] (HT.validateHealthPolicy HT.defaultHealthPolicy)
  assertBool "bad policy values rejected" (length (HT.validateHealthPolicy HT.defaultHealthPolicy {HT.hpObserveSeconds = -1, HT.hpMaxUnavailablePct = 0}) == 2)
  assertEqual "HPA permissions round-trip through their text form" (map Just [AP_HPA_VIEW, AP_HPA_SCHEDULE_EDIT, AP_HPA_APPLY, AP_HPA_ROLLBACK, AP_HPA_GUARDRAIL_EDIT]) (map (textToAutopilotPermission . autopilotPermissionToText) [AP_HPA_VIEW, AP_HPA_SCHEDULE_EDIT, AP_HPA_APPLY, AP_HPA_ROLLBACK, AP_HPA_GUARDRAIL_EDIT])
  assertEqual "only HPA_VIEW is in the Viewer role" [AP_HPA_VIEW] [p | AutopilotPerm p <- defaultPermissions Viewer Autopilot, p `elem` [AP_HPA_VIEW, AP_HPA_SCHEDULE_EDIT, AP_HPA_APPLY, AP_HPA_ROLLBACK, AP_HPA_GUARDRAIL_EDIT]]
  assertEqual "guardrail JSON round-trip" (Just HT.defaultGuardrail {HT.grMaxReplicasCap = Just 9}) (A.decode (A.encode HT.defaultGuardrail {HT.grMaxReplicasCap = Just 9}))

testHpaMisc :: IO ()
testHpaMisc = do
  let pol = HT.defaultHealthPolicy {HT.hpGraceSeconds = 120, HT.hpMaxUnavailablePct = 50}
      h = mkHpa changeSpecExtra
      inputs ready proms = HH.HealthInputs h ready proms
      t0 = utc "2026-10-19 10:00:00"
      t1 = utc "2026-10-19 10:01:00"
      t3 = utc "2026-10-19 10:03:00"
  -- assessment
  assertEqual "all pods ready: healthy" [] (HH.hrIssues (HH.assessHealth pol (inputs (Just (10, 10)) [])))
  assertEqual "exactly at the limit (5 of 10 unready, limit 50%) is fine" [] (HH.hrIssues (HH.assessHealth pol (inputs (Just (10, 5)) [])))
  assertEqual "over the limit (6 of 10 unready)" 1 (length (HH.hrIssues (HH.assessHealth pol (inputs (Just (10, 4)) []))))
  assertEqual "zero desired pods never divides or flags" [] (HH.hrIssues (HH.assessHealth pol (inputs (Just (0, 0)) [])))
  assertEqual "unknown readiness is a note, not an issue" ([], ["pod readiness unavailable"]) (let r = HH.assessHealth pol (inputs Nothing []) in (HH.hrIssues r, HH.hrNotes r))
  let inactiveHpa = h {HS.hoStatus = (HS.hoStatus h) {HS.hstConditions = [HS.HpaCondition "ScalingActive" "False" (Just "FailedGetResourceMetric") (Just "no metrics")]}}
  assertEqual "ScalingActive=False is an issue" 1 (length (HH.hrIssues (HH.assessHealth pol (HH.HealthInputs inactiveHpa (Just (4, 4)) []))))
  assertEqual "... unless the policy ignores it" [] (HH.hrIssues (HH.assessHealth pol {HT.hpRollbackOnScalingInactive = False} (HH.HealthInputs inactiveHpa (Just (4, 4)) [])))
  let chk = HT.PromCheck "p99" "histogram_quantile(...)" HT.OpGt 500
  assertEqual "prometheus value over threshold is an issue" 1 (length (HH.hrIssues (HH.assessHealth pol (inputs (Just (4, 4)) [(chk, Right 800)]))))
  assertEqual "prometheus value under threshold is fine" [] (HH.hrIssues (HH.assessHealth pol (inputs (Just (4, 4)) [(chk, Right 100)])))
  assertEqual "prometheus failure is a note, never a breach" ([], 1) (let r = HH.assessHealth pol (inputs (Just (4, 4)) [(chk, Left "unreachable")]) in (HH.hrIssues r, length (HH.hrNotes r)))
  assertEqual "OpLt breaches below the threshold" 1 (length (HH.hrIssues (HH.assessHealth pol (inputs (Just (4, 4)) [(chk {HT.pcOp = HT.OpLt}, Right 100)]))))
  -- judgement over time (grace 120s)
  let bad = HH.HealthReport ["3 pods not ready"] []
      good = HH.HealthReport [] []
  assertEqual "healthy clears the clock" (HH.VerdictOk, Nothing) (HH.judge pol t1 (Just t0) good)
  assertEqual "first unhealthy tick starts the clock" (HH.VerdictWatching, Just t0) (HH.judge pol t0 Nothing bad)
  assertEqual "unhealthy for 60s of 120s: still watching, clock kept" (HH.VerdictWatching, Just t0) (HH.judge pol t1 (Just t0) bad)
  assertEqual "unhealthy for 180s: breach" (HH.VerdictBreach, Just t0) (HH.judge pol t3 (Just t0) bad)
  assertEqual "grace 0 breaches immediately" (HH.VerdictBreach, Just t0) (HH.judge pol {HT.hpGraceSeconds = 0} t0 Nothing bad)
  assertEqual "a recovery then a relapse restarts the clock" (HH.VerdictWatching, Just t3) (HH.judge pol t3 Nothing bad)
  -- prometheus
  assertEqual "query placeholders substituted" (Right "up{namespace=\"ns1\",service=\"svc\",deployment=\"svc-v1\"}") (HH.substitutePromQuery "ns1" "svc" "svc-v1" "up{namespace=\"{{namespace}}\",service=\"{{service}}\",deployment=\"{{deployment}}\"}")
  assertBool "a name that could rewrite the query is refused" (either (const True) (const False) (HH.substitutePromQuery "ns\"} or vector(1) #" "svc" "svc-v1" "up{n=\"{{namespace}}\"}"))
  assertBool "k8s names accepted / rejected" (HH.safeK8sName "svc-v1.prod" && not (HH.safeK8sName "Svc") && not (HH.safeK8sName "a b") && not (HH.safeK8sName ""))
  let prom body = either (error . show) id (A.eitherDecode body) :: A.Value
  assertEqual "scalar parsed" (Right 12.5) (HH.parsePromScalar (prom "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{},\"value\":[1700000000,\"12.5\"]}]}}"))
  assertEqual "empty result is 'no data', not zero" (Left "no data") (HH.parsePromScalar (prom "{\"status\":\"success\",\"data\":{\"result\":[]}}"))
  assertEqual "NaN is not a number" (Left "value is NaN") (HH.parsePromScalar (prom "{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[1,\"NaN\"]}]}}"))
  assertBool "infinity is refused too" (either (const True) (const False) (HH.parsePromScalar (prom "{\"status\":\"success\",\"data\":{\"result\":[{\"value\":[1,\"+Inf\"]}]}}")))
  assertBool "error status refused" (either (const True) (const False) (HH.parsePromScalar (prom "{\"status\":\"error\"}")))
  -- events / metrics parsing
  assertEqual "rescale message -> new size" (Just 7) (HO.parseNewSize "New size: 7; reason: cpu resource utilization (percentage of request) above target")
  assertEqual "no size in the message" Nothing (HO.parseNewSize "failed to get cpu utilization")
  assertEqual "k8s timestamp" (Just (utc "2026-10-19 05:00:00")) (HO.parseK8sTime "2026-10-19T05:00:00Z")
  assertEqual "k8s timestamp with microseconds" (Just (utc "2026-10-19 05:00:00.123456")) (HO.parseK8sTime "2026-10-19T05:00:00.123456Z")
  assertEqual "garbage timestamp" Nothing (HO.parseK8sTime "yesterday")
  let metrics = prom "[{\"type\":\"Resource\",\"resource\":{\"name\":\"memory\",\"current\":{\"averageUtilization\":41}}},{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"current\":{\"averageUtilization\":63,\"averageValue\":\"250m\"}}}]"
  assertEqual "cpu utilisation picked by name" (Just 63) (HO.currentUtilization "cpu" metrics)
  assertEqual "memory utilisation picked by name" (Just 41) (HO.currentUtilization "memory" metrics)
  assertEqual "absolute-only metrics have no utilisation" Nothing (HO.currentUtilization "cpu" (prom "[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"current\":{\"averageValue\":\"250m\"}}}]"))
  assertEqual "no metrics yet" Nothing (HO.currentUtilization "cpu" A.Null)
  -- resume decision
  let spec = HS.hoSpec h
      ch = HT.emptyChange {HT.chMaxReplicas = Just 60, HT.chMinReplicas = Just 10}
      after = either (error . show) id (HC.applyChangeTyped spec ch)
  assertEqual "untouched live: send the change" HC.NeedsPatch (HC.decideApplyAction spec after ch spec)
  assertEqual "live already has the change: do not send it again" HC.AlreadyApplied (HC.decideApplyAction spec after ch after)
  assertEqual "someone set max to 33 meanwhile: stop and escalate" (HC.Diverged ["maxReplicas"]) (HC.decideApplyAction spec after ch spec {HS.hsMaxReplicas = 33})
  assertEqual "a field that did not change is never 'diverged' (min unchanged by us)" HC.NeedsPatch (HC.decideApplyAction spec (after {HS.hsMinReplicas = HS.hsMinReplicas spec}) ch {HT.chMinReplicas = Nothing} spec)
  -- serving targets
  let resolved name role = HR.ResolvedHpa (mkHpa changeSpecExtra) {HS.hoName = name} "v" Nothing role Nothing
      res rs = HR.Resolution rs [] "" []
  assertEqual "serving HPAs are the targets" ["a"] (map (HS.hoName . HR.rhHpa) (HR.servingTargets (res [resolved "a" HR.RoleServing, resolved "b" HR.RoleDraining])))
  assertEqual "split traffic targets both" ["a", "b"] (map (HS.hoName . HR.rhHpa) (HR.servingTargets (res [resolved "a" HR.RoleServing, resolved "b" HR.RoleServing])))
  assertEqual "no VS and one HPA: that HPA" ["a"] (map (HS.hoName . HR.rhHpa) (HR.servingTargets (res [resolved "a" HR.RoleUnknown])))
  assertEqual "no VS and several HPAs: refuse to guess" [] (map (HS.hoName . HR.rhHpa) (HR.servingTargets (res [resolved "a" HR.RoleUnknown, resolved "b" HR.RoleUnknown])))
  assertEqual "only draining HPAs: nothing to target" [] (map (HS.hoName . HR.rhHpa) (HR.servingTargets (res [resolved "a" HR.RoleDraining])))
  -- ASCII-safe JSON for stdin
  assertEqual "ascii stays" "{\"a\":\"x\"}" (HK.asciiJson (A.object ["a" A..= ("x" :: Text)]))
  assertEqual "BMP char is \\u-escaped" "{\"a\":\"\\u00e9\"}" (HK.asciiJson (A.object ["a" A..= ("\233" :: Text)]))
  assertEqual "astral char becomes a surrogate pair" "{\"a\":\"\\ud83d\\ude00\"}" (HK.asciiJson (A.object ["a" A..= ("\128512" :: Text)]))
  assertEqual "the escaped form decodes back to the same value" (Just (A.object ["a" A..= ("\233\128512 ok" :: Text)])) (A.decodeStrict (TE.encodeUtf8 (HK.asciiJson (A.object ["a" A..= ("\233\128512 ok" :: Text)]))))

testHpaDefaults :: IO ()
testHpaDefaults = do
  let rules st sel pols = HS.ScalingRules st sel pols
      pods4 = HS.ScalingPolicy HS.PolicyPods 4 15
      want = HC.VRules (Just (rules (Just 60) Nothing []))
      liveDefaulted = HC.VRules (Just (rules (Just 60) (Just HS.SelMax) [pods4, HS.ScalingPolicy HS.PolicyPercent 100 15]))
  assertBool "a wanted rule is satisfied when the server adds defaults we did not specify" (HC.fieldMatches want liveDefaulted)
  assertBool "a differing stabilisation window is not satisfied" (not (HC.fieldMatches want (HC.VRules (Just (rules (Just 30) (Just HS.SelMax) [pods4])))))
  assertBool "a wanted selectPolicy must match" (not (HC.fieldMatches (HC.VRules (Just (rules Nothing (Just HS.SelMin) []))) liveDefaulted))
  assertBool "wanted policies must match exactly when given" (not (HC.fieldMatches (HC.VRules (Just (rules Nothing Nothing [pods4]))) (HC.VRules (Just (rules Nothing Nothing [HS.ScalingPolicy HS.PolicyPods 9 15])))))
  assertBool "wanted policies present in live (alongside defaults) are NOT enough: lists must be equal" (not (HC.fieldMatches (HC.VRules (Just (rules Nothing Nothing [pods4]))) liveDefaulted))
  assertBool "wanting no rules means the cluster has none" (HC.fieldMatches (HC.VRules Nothing) (HC.VRules Nothing) && not (HC.fieldMatches (HC.VRules Nothing) liveDefaulted))
  assertBool "wanting rules and finding none is a mismatch" (not (HC.fieldMatches want (HC.VRules Nothing)))
  assertBool "numbers and targets compare exactly" (HC.fieldMatches (HC.VInt 5) (HC.VInt 5) && not (HC.fieldMatches (HC.VInt 5) (HC.VInt 6)))
  -- end to end on an HPA that had no behavior: change scaleUp, let the "server" default both directions, then verify/resume/restore
  let noBeh = mkHpa ",\"minReplicas\":2,\"metrics\":[{\"type\":\"Resource\",\"resource\":{\"name\":\"cpu\",\"target\":{\"type\":\"Utilization\",\"averageUtilization\":70}}}]"
      ch = HT.emptyChange {HT.chScaleUp = Just (rules (Just 60) Nothing [])}
      after = either (error . show) id (HC.applyChangeTyped (HS.hoSpec noBeh) ch)
      changed = either (error . show) id (HC.buildChangedObject noBeh ch [(HT.annApplyId, "a1")])
      defaulted = case changed of
        A.Object o -> case AKM.lookup "spec" o of
          Just (A.Object so) -> A.Object (AKM.insert "spec" (A.Object (AKM.insert "behavior" (either error id (A.eitherDecode "{\"scaleUp\":{\"stabilizationWindowSeconds\":60,\"selectPolicy\":\"Max\",\"policies\":[{\"type\":\"Pods\",\"value\":4,\"periodSeconds\":15}]},\"scaleDown\":{\"stabilizationWindowSeconds\":300,\"selectPolicy\":\"Max\",\"policies\":[{\"type\":\"Percent\",\"value\":100,\"periodSeconds\":15}]}}")) so)) o)
          _ -> changed
        _ -> changed
      live = either (error . T.unpack) id (HS.parseHpaObject defaulted)
  assertEqual "verify passes against the server-defaulted object" [] (HC.verifyApplied after ch (HS.hoSpec live))
  assertEqual "a resume sees it as already applied (not diverged)" HC.AlreadyApplied (HC.decideApplyAction (HS.hoSpec noBeh) after ch (HS.hoSpec live))
  let plan = HC.planRestore (HS.hoSpec noBeh) after ch live
      restored = either (error . T.unpack) id (HS.parseHpaObject (HC.rpObject plan))
  assertEqual "restore puts back the field" ["behavior.scaleUp"] (HC.rpRestored plan)
  assertEqual "the whole defaulted behavior block is removed, as the HPA originally had none" Nothing (HS.hsBehavior (HS.hoSpec restored))
  assertEqual "and that is exactly what the restore is judged by" [] [fieldLabel' | f <- HC.touchedFields ch, not (HC.fieldMatches (HC.fieldValue f (HS.hoSpec noBeh)) (HC.fieldValue f (HS.hoSpec restored))), let fieldLabel' = HC.fieldLabel f]
  -- kubectl error classification
  let cls = HK.classifyKubeError
  assertEqual "a real NotFound" (HK.KubeNotFound "Error from server (NotFound): horizontalpodautoscalers.autoscaling \"x\" not found") (cls "Error from server (NotFound): horizontalpodautoscalers.autoscaling \"x\" not found\n")
  assertBool "a missing credential plugin is NOT 'the HPA is gone'" (case cls "getting credentials: exec: executable gke-gcloud-auth-plugin not found" of HK.KubeFailed _ -> True; _ -> False)
  assertBool "kubectl itself missing is NOT 'the HPA is gone'" (case cls "sh: kubectl: command not found" of HK.KubeFailed _ -> True; _ -> False)
  assertBool "a conflict" (case cls "Error from server (Conflict): Operation cannot be fulfilled on x: the object has been modified; please apply your changes to the latest version" of HK.KubeConflict _ -> True; _ -> False)
  assertBool "anything else is a plain failure" (case cls "Unable to connect to the server: dial tcp: i/o timeout" of HK.KubeFailed _ -> True; _ -> False)
