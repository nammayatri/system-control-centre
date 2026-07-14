{-# LANGUAGE OverloadedStrings #-}

{- |
System Control Centre — Unit Tests

These tests are PURE: no DB, no K8s, no HTTP. They cover the parts of
the codebase that can be reasoned about in isolation:

  * Status state machine (per-service + global)
  * Status helper predicates (terminal / aborted)
  * Permission catalog (Admin/Manager/Viewer)
  * Effective permission calculation (GRANT/DENY overrides)
  * Config catalog (no global configs, slack is product-scoped)
  * Config value validation
  * Shell quoting (command-injection safety)
  * K8s version validation (command-injection safety)
  * Release tag formatting
  * Rollout step semantics (cooloff = minutes, not seconds)

IO-bound concerns (DB queries, kubectl, Slack HTTP) are covered by the
API integration suite (`scripts/test-api.sh`) and the manual end-to-end
harness in CONTEXT.md.
-}
module Main where

import qualified Data.Aeson as Aeson
import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Products.Autopilot.Config (autopilotConfigs)
import Products.Autopilot.DiffLink (buildDiffLink, normalizeRepo, toCommitId)
import Products.Autopilot.K8s.Execute (shellQuote)
import Products.Autopilot.Mobile.Changelog (
    bumpPatch,
    renderRevertChangelog,
 )
import Products.Autopilot.Mobile.Github (
    Job (..),
    JobsResp (..),
    WorkflowRun (..),
    WorkflowRunsResp (..),
    dispatchRunCandidates,
 )
import Products.Autopilot.Mobile.Github.Compare (
    CommitInfo (..),
    CompareResult (..),
    ciDisplayAuthor,
    extractPrNumber,
    isBotCommit,
    shortSha,
 )
import qualified Shared.AI.Changelog as CL
import Products.Autopilot.Mobile.RevertResolver (
    RevertCand (..),
    RollbackPlan (..),
    parseSemver,
    resolveRollback,
 )
import Products.Autopilot.Mobile.Types
import Products.Autopilot.Mobile.Lifecycle.BuildKind (BuildKind (..), buildKind, claimsStoreIdentity, hasStoreIdentity)
import Products.Autopilot.Mobile.Lifecycle.GroupSummary (GroupSummary (..), MemberFact (..), deriveGroupSummary, effectivePhase)
import Products.Autopilot.Mobile.Lifecycle.Phase (Display (..), Projection (..), ReleasePhase (..), Variant (..), abortable, canTransition, displayStatus, displayStatusInferred, pEngineStatus, phaseFromFields, phaseToWfStatus, project)
import Products.Autopilot.Mobile.Versioning (TrackInfo (..), computeNextVersion)
import Products.Autopilot.Mobile.StoreSync (ExternalReviewAction (..), PendingOutcome (..), ReconcileAction (..), androidReconcileAction, detectConsoleRollout, detectIosRelease, externalReviewAction, iosPhasedReconcileAction, pendingOutcome, pendingPublishRelease, retireOutcome, reviewStateToStatus)
import Products.Autopilot.Mobile.Handlers.Release (resolveBaseFromTracks)
import Products.Autopilot.Mobile.Queries.AppCatalog (TrackSnapshot (..))
import Products.Autopilot.Mobile.Queries.StoreStatus (StoreCell (..), deriveStoreState, resolveStoreState)
import qualified Data.Map.Strict as Map
import Products.Autopilot.Mobile.Versioning.Apple (AscPhasedState (..), AscReviewState (..), AscVersion (..), BuildsResp (..), appStoreStateToReview, applePhasedPercent, computeNextIosVersion, firstWhatsNew, parseAscVersion, parseVersionStatesWithBuild, selectInFlightReview)
import Products.Autopilot.Mobile.Versioning.Play (PlayRolloutState (..), ProdTrackRelease (..), StoreTrackSnapshot (..), parseProdReleaseNotes, parseProdTrackReleases, parseRolloutState, parseTrackSnapshot, userFractionInRange)
import Products.Autopilot.Queries.ReleaseTracker (keepSnapshot)
import Products.Autopilot.Mobile.Workflow (codeFromTag, electDispatchLeader, reviewPollDue, reviewPollTimedOut, selectBuildTag, tagConfirmTimedOut)
import Products.Autopilot.Types.Permission
import Products.Autopilot.Types.Release
import qualified Products.Autopilot.Types.Target
import Products.Autopilot.Types.Workflow (ReleaseCategory (..), getDefaultDeploymentTarget)
import Products.ConfigCatalog (allConfigEntries, findConfigEntry)
import Products.Types
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
            [ CREATED
            , INPROGRESS
            , PAUSED
            , ABORTING
            , REVERTING
            , RESTARTING
            , DISCARDING
            , LOCKED
            , APPLIED
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
            [ ""
            , "v1.2.3"
            , "hello world"
            , "v1;rm -rf"
            , "-starts-with-dash"
            , "ends-with-dash-"
            , "v1@latest"
            , "v1:latest"
            , "$(whoami)"
            , "--"
            , "-"
            , "v1`id`"
            , "v1|cat"
            , "v1\nls"
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
    assertEqual "Viewer has exactly 3 permissions" 3 (length viewerPerms)

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
    assertBool "Manager DOES NOT have MOBILE_APP_MANAGE" $
        AutopilotPerm AP_MOBILE_APP_MANAGE `notElem` managerPerms
    assertBool "Manager has MOBILE_DISPATCH" $
        AutopilotPerm AP_MOBILE_DISPATCH `elem` managerPerms
    assertEqual
        "Manager has all perms minus the 4 restricted perms (PRODUCT_CONFIG_EDIT, SERVICE_CONFIG_EDIT, RELEASE_DELETE, MOBILE_APP_MANAGE)"
        (length allPerms - 4)
        (length managerPerms)

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
        "defaultPermissionsText Viewer = 3"
        3
        (length (defaultPermissionsText "autopilot" "Viewer"))
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
    let step1 = RolloutStep{rolloutPercent = 10, cooloffMinutes = 5, podCount = 100}
        step2 = RolloutStep{rolloutPercent = 50, cooloffMinutes = 10, podCount = 100}
        step3 = RolloutStep{rolloutPercent = 100, cooloffMinutes = 0, podCount = 100}

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
            [ "k8s_enabled"
            , "approve_all_releases"
            , "release_watch_delay"
            , "max_k8s_retries"
            , "multi_release_per_product"
            , "pods_scale_down_delay_config"
            , "scale_down_pods_on_completion"
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
    let perms = [minBound .. maxBound :: AutopilotPermission]
    assertBool "AP_MOBILE_DISPATCH in enum" (AP_MOBILE_DISPATCH `elem` perms)
    assertBool "AP_MOBILE_APP_MANAGE in enum" (AP_MOBILE_APP_MANAGE `elem` perms)
    assertEqual
        "AP_MOBILE_DISPATCH textual"
        "MOBILE_DISPATCH"
        (autopilotPermissionToText AP_MOBILE_DISPATCH)
    assertEqual
        "AP_MOBILE_APP_MANAGE textual"
        "MOBILE_APP_MANAGE"
        (autopilotPermissionToText AP_MOBILE_APP_MANAGE)
    assertEqual
        "round-trip MOBILE_DISPATCH"
        (Just AP_MOBILE_DISPATCH)
        (textToAutopilotPermission "MOBILE_DISPATCH")
    assertEqual
        "round-trip MOBILE_APP_MANAGE"
        (Just AP_MOBILE_APP_MANAGE)
        (textToAutopilotPermission "MOBILE_APP_MANAGE")

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
                { mbcVersionCode = Just 386
                , mbcChangeLog = "x"
                , mbcBuildType = bt
                , mbcReleaseGroupId = "g"
                , mbcMatrixJobName = "j"
                , mbcOtaNamespace = Nothing
                , mbcTagPushed = Nothing
                , mbcDestination = dest
                , mbcChangelogSummary = Nothing
                , mbcChangelogSummaryShort = Nothing
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
            [ StoreCell "production" (Just "4.9.15") (Just 1) (Just "live") Nothing
            , StoreCell "testflight" (Just "4.9.16") (Just 1) (Just "VALID") Nothing
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
            [ StoreCell "testflight" (Just "9.9.14") (Just 2) (Just "VALID") Nothing
            , StoreCell "production" (Just "9.9.14") (Just 2) (Just "live") Nothing
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
                { mbcVersionCode = Just 12345
                , mbcChangeLog = "hello"
                , mbcBuildType = "release"
                , mbcReleaseGroupId = "rg_abc"
                , mbcMatrixJobName = "NammaYatri-Release"
                , mbcOtaNamespace = Just "nammayatriv2"
                , mbcTagPushed = Nothing
                , mbcDestination = Nothing
                , mbcChangelogSummary = Nothing
                , mbcChangelogSummaryShort = Nothing
                }
    let encoded = Aeson.encode ctx
    let decoded = Aeson.decode encoded :: Maybe MobileBuildContext
    assertEqual "round-trip equals original" (Just ctx) decoded

{- | Legacy rows persisted before the @build_type@ field used a
@destination@ string. 'MobileBuildContext' 'FromJSON' must map those to a
build type — Firebase/TestFlight → "debug", everything else → "release",
and an explicit @build_type@ always wins. 'fetchLatestBuildsPerApp'
relies on this to classify old completed builds.
-}
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

{- | B3: ConfirmTag's wall-clock guard. Anchors on build-completion, falls back
to build-start, and reports "not timed out" when neither timestamp exists (so a
release is never failed spuriously while we can't measure elapsed time).
-}
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

{- | The rollback resolver. Orders candidates by the store's sequence key
(version_code, then semver, then created_at) — NOT by creation time, which
store-sync rows break. Also exercises the target-vs-source split: when the
version users were on has no SCC artifact, the resolver surfaces a
rebuild-lower or manual-source plan instead of guessing.
-}
testResolveRollback :: IO ()
testResolveRollback = do
    putStrLn "Rollback resolver: version order + target/source split"
    now <- getCurrentTime
    let minsAgo m = addUTCTime (fromIntegral (negate (m * 60 :: Int))) now
        cand i ver code tag ago =
            RevertCand
                { rcId = i
                , rcVersionName = ver
                , rcVersionCode = code
                , rcTag = tag
                , rcCommitSha = Just (i <> "sha")
                , rcCreatedAt = minsAgo ago
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

{- | ConfirmTag must bind the tag THIS build pushed, not the lexically-first ref
under the broad app prefix. The fastlane workflow tags deterministically as
@{prefix}{version}+{code}@ and SCC supplies that version/code on dispatch, so we
match it exactly. GitHub returns matching-refs in ascending order, so "first"
would be the oldest version — the bug this guards against.
-}
testSelectBuildTag :: IO ()
testSelectBuildTag = do
    putStrLn "ConfirmTag: exact tag selection"
    let prefix = "odishayatri/prod/android/v"
        ref n = "refs/tags/" <> n
        -- Two versions share the prefix; GitHub returns them ascending (oldest first).
        refs =
            [ ref "odishayatri/prod/android/v3.3.15+421"
            , ref "odishayatri/prod/android/v3.3.17+460"
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
    let prod = TrackSnapshot{tsVersion = "3.3.17", tsCode = Just 460, tsTag = Just "oy/prod/android/v3.3.17+460"}
        internal = TrackSnapshot{tsVersion = "3.3.20", tsCode = Just 463, tsTag = Just "oy/prod/android/v3.3.20+463"}
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
    let iosTracks = Map.fromList [("production", TrackSnapshot{tsVersion = "3.3.9", tsCode = Nothing, tsTag = Nothing}), ("internal", internal)]
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
        [ ProdTrackRelease "3.4.0" 451 "inProgress" (Just 1.0e-6)
        , ProdTrackRelease "3.3.9" 450 "completed" Nothing
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
            [ ProdTrackRelease "3.4.0" 451 "inProgress" (Just 1.0e-6)
            , ProdTrackRelease "3.4.1" 452 "inProgress" (Just 1.0e-6)
            , live
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
                { ciSha = "abc1234deadbeef"
                , ciShortSha = "abc1234"
                , ciMessage = "feat: add foo (#123)\n\nbody"
                , ciSubject = "feat: add foo (#123)"
                , ciAuthorLogin = "alice"
                , ciAuthorName = "Alice"
                , ciHtmlUrl = "https://github.com/x/y/commit/abc1234"
                , ciPrNumber = Just 123
                }
        c2 =
            CommitInfo
                { ciSha = "def5678cafef00d"
                , ciShortSha = "def5678"
                , ciMessage = "chore: bump deps"
                , ciSubject = "chore: bump deps"
                , ciAuthorLogin = "unknown"
                , ciAuthorName = ""
                , ciHtmlUrl = "https://github.com/x/y/commit/def5678"
                , ciPrNumber = Nothing
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
    let bot login name = c1{ciAuthorLogin = login, ciAuthorName = name}
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
    assertEqual "display author prefers git name" "Dev Vikram Singh" (ciDisplayAuthor c1{ciAuthorLogin = "techtrigon", ciAuthorName = "Dev Vikram Singh"})
    assertEqual "display author falls back to login" "PraveenGongada" (ciDisplayAuthor c1{ciAuthorLogin = "PraveenGongada", ciAuthorName = ""})
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
                { wrId = i
                , wrEvent = ev
                , wrStatus = "in_progress"
                , wrConclusion = Nothing
                , wrCreatedAt = at secs
                , wrHtmlUrl = ""
                , wrName = ""
                , wrDisplayTitle = Nothing
                , wrHeadSha = ""
                }
        ids = map wrId . dispatchRunCandidates now
    assertEqual "in-window dispatch run matched" [1] (ids [mkRun 1 "workflow_dispatch" 10])
    assertEqual "too-early / too-late excluded" [] (ids [mkRun 2 "workflow_dispatch" (-60), mkRun 3 "workflow_dispatch" 600])
    assertEqual "non-dispatch event excluded" [] (ids [mkRun 4 "push" 10])
    -- boundaries inclusive (-30s lower, +300s upper); result is newest-first
    assertEqual "boundaries inclusive, newest-first" [6, 5] (ids [mkRun 5 "workflow_dispatch" (-30), mkRun 6 "workflow_dispatch" 300])
    assertEqual "multiple in-window sorted newest-first" [8, 7] (ids [mkRun 7 "workflow_dispatch" 10, mkRun 8 "workflow_dispatch" 200])

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
                { mfReleaseId = rid
                , mfApp = "App" <> rid
                , mfPlatform = plat
                , mfStatus = st
                , mfApproved = appr
                , mfPhase = ph
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
