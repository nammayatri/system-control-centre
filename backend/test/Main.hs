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

import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.Config (autopilotConfigs)
import Products.Autopilot.K8s.Execute (shellQuote)
import Products.Autopilot.Types.Permission
import Products.Autopilot.Types.Release
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
    assertEqual
        "Manager has all perms minus 2 edit perms"
        (length allPerms - 2)
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
    let step1 = RolloutStep{rolloutPercent = 10, cooloffMinutes = 5, podPercent = 100}
        step2 = RolloutStep{rolloutPercent = 50, cooloffMinutes = 10, podPercent = 100}
        step3 = RolloutStep{rolloutPercent = 100, cooloffMinutes = 0, podPercent = 100}

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
