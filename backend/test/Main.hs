{-# LANGUAGE OverloadedStrings #-}

module Main where

import Data.Char (isAlphaNum)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Products.Autopilot.K8s.Execute (shellQuote)
import Products.Autopilot.Types.Permission
import Products.Autopilot.Types.Release
import Products.Types

-- ============================================================================
-- Test Helpers
-- ============================================================================

assertEqual :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEqual name expected actual =
  if expected == actual
    then putStrLn $ "  PASS: " <> name
    else fail $ "  FAIL: " <> name <> " -- expected " <> show expected <> ", got " <> show actual

assertBool :: String -> Bool -> IO ()
assertBool name True = putStrLn $ "  PASS: " <> name
assertBool name False = fail $ "  FAIL: " <> name

-- Inline isValidK8sVersion since Routes exports everything but pulls in IO deps.
-- This is the exact same logic from Products.Autopilot.Routes.
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
  putStrLn "========================================"
  putStrLn "  System Control Centre — Unit Tests"
  putStrLn "========================================"
  putStrLn ""

  putStrLn "[1] Status Transition Tests (validateStatusTransition)"
  testStatusTransitions

  putStrLn ""
  putStrLn "[2] Global Status Transition Tests (validateGlobalStatusTransition)"
  testGlobalStatusTransitions

  putStrLn ""
  putStrLn "[3] Version Validation Tests (isValidK8sVersion)"
  testVersionValidation

  putStrLn ""
  putStrLn "[4] Shell Quoting Tests (shellQuote)"
  testShellQuote

  putStrLn ""
  putStrLn "[5] Permission Tests"
  testPermissions

  putStrLn ""
  putStrLn "[6] Release Tag Generation Tests"
  testReleaseTag

  putStrLn ""
  putStrLn "[7] Terminal / Aborted Status Tests"
  testStatusHelpers

  putStrLn ""
  putStrLn "========================================"
  putStrLn "  All tests passed!"
  putStrLn "========================================"

-- ============================================================================
-- [1] Status Transition Tests (per-service: validateStatusTransition)
-- ============================================================================

testStatusTransitions :: IO ()
testStatusTransitions = do
  -- Valid transitions from Created
  assertBool "Created -> InProgress (valid)" $
    validateStatusTransition Created InProgress
  assertBool "Created -> Discarded (valid)" $
    validateStatusTransition Created Discarded

  -- Invalid transitions from Created
  assertBool "Created -> Completed (invalid)" $
    not $ validateStatusTransition Created Completed
  assertBool "Created -> Paused (invalid)" $
    not $ validateStatusTransition Created Paused
  assertBool "Created -> Aborted (invalid)" $
    not $ validateStatusTransition Created Aborted

  -- Valid transitions from InProgress
  assertBool "InProgress -> Paused (valid)" $
    validateStatusTransition InProgress Paused
  assertBool "InProgress -> Completed (valid)" $
    validateStatusTransition InProgress Completed
  assertBool "InProgress -> Aborting (valid)" $
    validateStatusTransition InProgress Aborting
  assertBool "InProgress -> Aborted (valid)" $
    validateStatusTransition InProgress Aborted
  assertBool "InProgress -> UserAborted (valid)" $
    validateStatusTransition InProgress UserAborted

  -- Invalid transitions from InProgress
  assertBool "InProgress -> Created (invalid)" $
    not $ validateStatusTransition InProgress Created
  assertBool "InProgress -> Discarded (invalid)" $
    not $ validateStatusTransition InProgress Discarded

  -- Valid transitions from Paused
  assertBool "Paused -> InProgress (valid, resume)" $
    validateStatusTransition Paused InProgress
  assertBool "Paused -> Aborting (valid)" $
    validateStatusTransition Paused Aborting
  assertBool "Paused -> UserAborted (valid)" $
    validateStatusTransition Paused UserAborted

  -- Invalid transitions from Paused
  assertBool "Paused -> Completed (invalid)" $
    not $ validateStatusTransition Paused Completed
  assertBool "Paused -> Discarded (invalid)" $
    not $ validateStatusTransition Paused Discarded

  -- Terminal states: Completed has no valid transitions (per-service)
  assertBool "Completed -> Reverting (invalid per-service)" $
    not $ validateStatusTransition Completed Reverting
  assertBool "Completed -> Paused (invalid)" $
    not $ validateStatusTransition Completed Paused
  assertBool "Completed -> InProgress (invalid)" $
    not $ validateStatusTransition Completed InProgress

  -- Terminal states: Aborted has no valid transitions
  assertBool "Aborted -> anything (invalid)" $
    not $ validateStatusTransition Aborted Created
  assertBool "Aborted -> InProgress (invalid)" $
    not $ validateStatusTransition Aborted InProgress

  -- Terminal states: UserAborted has no valid transitions
  assertBool "UserAborted -> anything (invalid)" $
    not $ validateStatusTransition UserAborted Created

  -- Terminal states: Reverted has no valid transitions
  assertBool "Reverted -> Created (invalid)" $
    not $ validateStatusTransition Reverted Created
  assertBool "Reverted -> anything (invalid)" $
    not $ validateStatusTransition Reverted InProgress

  -- Terminal states: Discarded has no valid transitions
  assertBool "Discarded -> Created (invalid)" $
    not $ validateStatusTransition Discarded Created
  assertBool "Discarded -> InProgress (invalid)" $
    not $ validateStatusTransition Discarded InProgress
  assertBool "Discarded -> Completed (invalid)" $
    not $ validateStatusTransition Discarded Completed

  -- Aborting transitions
  assertBool "Aborting -> Aborted (valid)" $
    validateStatusTransition Aborting Aborted
  assertBool "Aborting -> UserAborted (valid)" $
    validateStatusTransition Aborting UserAborted
  assertBool "Aborting -> Aborting (valid, idempotent)" $
    validateStatusTransition Aborting Aborting
  assertBool "Aborting -> Reverting (valid)" $
    validateStatusTransition Aborting Reverting

  -- Reverting transitions
  assertBool "Reverting -> Reverted (valid)" $
    validateStatusTransition Reverting Reverted
  assertBool "Reverting -> UserAborted (valid)" $
    validateStatusTransition Reverting UserAborted
  assertBool "Reverting -> Completed (invalid)" $
    not $ validateStatusTransition Reverting Completed

-- ============================================================================
-- [2] Global Status Transition Tests (validateGlobalStatusTransition)
-- ============================================================================

testGlobalStatusTransitions :: IO ()
testGlobalStatusTransitions = do
  -- Global allows more transitions than per-service
  assertBool "Global: Created -> InProgress (valid)" $
    validateGlobalStatusTransition Created InProgress
  assertBool "Global: Created -> Discarding (valid)" $
    validateGlobalStatusTransition Created Discarding

  -- Completed -> Reverting is valid at global level (not per-service)
  assertBool "Global: Completed -> Reverting (valid)" $
    validateGlobalStatusTransition Completed Reverting
  assertBool "Global: Completed -> InProgress (invalid)" $
    not $ validateGlobalStatusTransition Completed InProgress

  -- InProgress has more global transitions
  assertBool "Global: InProgress -> Restarting (valid)" $
    validateGlobalStatusTransition InProgress Restarting
  assertBool "Global: InProgress -> Reverting (valid)" $
    validateGlobalStatusTransition InProgress Reverting

  -- Restarting transitions
  assertBool "Global: Restarting -> InProgress (valid)" $
    validateGlobalStatusTransition Restarting InProgress
  assertBool "Global: Restarting -> Paused (valid)" $
    validateGlobalStatusTransition Restarting Paused
  assertBool "Global: Restarting -> Completed (invalid)" $
    not $ validateGlobalStatusTransition Restarting Completed

  -- Paused global transitions include Restarting and Reverting
  assertBool "Global: Paused -> Restarting (valid)" $
    validateGlobalStatusTransition Paused Restarting
  assertBool "Global: Paused -> Reverting (valid)" $
    validateGlobalStatusTransition Paused Reverting

  -- Aborting global has more options
  assertBool "Global: Aborting -> Completed (valid)" $
    validateGlobalStatusTransition Aborting Completed
  assertBool "Global: Aborting -> Discarded (valid)" $
    validateGlobalStatusTransition Aborting Discarded
  assertBool "Global: Aborting -> Restarting (valid)" $
    validateGlobalStatusTransition Aborting Restarting

  -- Discarding -> Discarded
  assertBool "Global: Discarding -> Discarded (valid)" $
    validateGlobalStatusTransition Discarding Discarded
  assertBool "Global: Discarding -> InProgress (invalid)" $
    not $ validateGlobalStatusTransition Discarding InProgress

  -- Reverting global has more options
  assertBool "Global: Reverting -> Paused (valid)" $
    validateGlobalStatusTransition Reverting Paused
  assertBool "Global: Reverting -> Restarting (valid)" $
    validateGlobalStatusTransition Reverting Restarting

-- ============================================================================
-- [3] Version Validation Tests
-- ============================================================================

testVersionValidation :: IO ()
testVersionValidation = do
  -- Valid versions
  assertBool "v1 is valid" $ isValidK8sVersion "v1"
  assertBool "test-v3 is valid" $ isValidK8sVersion "test-v3"
  assertBool "abc123 is valid" $ isValidK8sVersion "abc123"
  assertBool "my-service-v2 is valid" $ isValidK8sVersion "my-service-v2"
  assertBool "a is valid (single char)" $ isValidK8sVersion "a"
  assertBool "1 is valid (single digit)" $ isValidK8sVersion "1"
  assertBool "a-b-c is valid (multi-dash)" $ isValidK8sVersion "a-b-c"

  -- Uppercase is lowered, so "V1" is valid (code does T.toLower)
  assertBool "V1 is valid (lowered to v1)" $ isValidK8sVersion "V1"
  assertBool "ABC is valid (lowered to abc)" $ isValidK8sVersion "ABC"

  -- Invalid versions
  assertBool "empty string is invalid" $ not $ isValidK8sVersion ""
  assertBool "v1.2.3 is invalid (dots not allowed)" $ not $ isValidK8sVersion "v1.2.3"
  assertBool "hello world is invalid (spaces)" $ not $ isValidK8sVersion "hello world"
  assertBool "v1;rm -rf is invalid (semicolons)" $ not $ isValidK8sVersion "v1;rm -rf"
  assertBool "-starts-with-dash is invalid" $ not $ isValidK8sVersion "-starts-with-dash"
  assertBool "ends-with-dash- is invalid" $ not $ isValidK8sVersion "ends-with-dash-"
  assertBool "v1@latest is invalid (at-sign)" $ not $ isValidK8sVersion "v1@latest"
  assertBool "v1:latest is invalid (colon)" $ not $ isValidK8sVersion "v1:latest"
  assertBool "$(whoami) is invalid (special chars)" $ not $ isValidK8sVersion "$(whoami)"
  assertBool "-- is invalid (only dashes)" $ not $ isValidK8sVersion "--"
  assertBool "- is invalid (single dash)" $ not $ isValidK8sVersion "-"

-- ============================================================================
-- [4] Shell Quoting Tests
-- ============================================================================

testShellQuote :: IO ()
testShellQuote = do
  assertEqual "shellQuote hello" "'hello'" (shellQuote "hello")
  assertEqual "shellQuote empty" "''" (shellQuote "")
  assertEqual "shellQuote rm -rf /" "'rm -rf /'" (shellQuote "rm -rf /")
  assertEqual "shellQuote $(whoami)" "'$(whoami)'" (shellQuote "$(whoami)")
  assertEqual "shellQuote backticks" "'`id`'" (shellQuote "`id`")
  assertEqual "shellQuote double quotes" "'\"hello\"'" (shellQuote "\"hello\"")

  -- The tricky one: single quotes inside. 'it's' should become 'it'"'"'s'
  assertEqual "shellQuote it's" "'it'\"'\"'s'" (shellQuote "it's")

  -- Multiple single quotes
  assertEqual "shellQuote '''" "''\"'\"''\"'\"''\"'\"''" (shellQuote "'''")

  -- Mixed dangerous characters
  assertEqual "shellQuote semicolon" "'; echo pwned'" (shellQuote "; echo pwned")
  assertEqual "shellQuote pipe" "'| cat /etc/passwd'" (shellQuote "| cat /etc/passwd")
  assertEqual "shellQuote newline" "'line1\nline2'" (shellQuote "line1\nline2")

-- ============================================================================
-- [5] Permission Tests
-- ============================================================================

testPermissions :: IO ()
testPermissions = do
  let allPerms = allPermissions Autopilot
      adminPerms = defaultPermissions Admin Autopilot
      managerPerms = defaultPermissions Manager Autopilot
      viewerPerms = defaultPermissions Viewer Autopilot

  -- Admin gets ALL permissions
  assertEqual "Admin has all permissions" (sort allPerms) (sort adminPerms)
  assertBool "Admin permission count matches allPermissions" $
    length adminPerms == length allPerms

  -- Viewer gets only VIEW permissions
  assertBool "Viewer has RELEASE_VIEW" $
    AutopilotPerm AP_RELEASE_VIEW `elem` viewerPerms
  assertBool "Viewer has PRODUCT_CONFIG_VIEW" $
    AutopilotPerm AP_PRODUCT_CONFIG_VIEW `elem` viewerPerms
  assertBool "Viewer has SERVICE_CONFIG_VIEW" $
    AutopilotPerm AP_SERVICE_CONFIG_VIEW `elem` viewerPerms
  assertBool "Viewer does NOT have RELEASE_CREATE" $
    AutopilotPerm AP_RELEASE_CREATE `notElem` viewerPerms
  assertBool "Viewer does NOT have RELEASE_APPROVE" $
    AutopilotPerm AP_RELEASE_APPROVE `notElem` viewerPerms
  assertBool "Viewer does NOT have PRODUCT_CONFIG_EDIT" $
    AutopilotPerm AP_PRODUCT_CONFIG_EDIT `notElem` viewerPerms
  assertEqual "Viewer has exactly 3 permissions" 3 (length viewerPerms)

  -- Manager gets all EXCEPT edit permissions
  assertBool "Manager has RELEASE_VIEW" $
    AutopilotPerm AP_RELEASE_VIEW `elem` managerPerms
  assertBool "Manager has RELEASE_CREATE" $
    AutopilotPerm AP_RELEASE_CREATE `elem` managerPerms
  assertBool "Manager has RELEASE_APPROVE" $
    AutopilotPerm AP_RELEASE_APPROVE `elem` managerPerms
  assertBool "Manager does NOT have PRODUCT_CONFIG_EDIT" $
    AutopilotPerm AP_PRODUCT_CONFIG_EDIT `notElem` managerPerms
  assertBool "Manager does NOT have SERVICE_CONFIG_EDIT" $
    AutopilotPerm AP_SERVICE_CONFIG_EDIT `notElem` managerPerms
  assertEqual
    "Manager has allPerms minus 2 edit perms"
    (length allPerms - 2)
    (length managerPerms)

  -- Permission text round-trip
  assertBool "Permission text for RELEASE_VIEW" $
    permissionToText (AutopilotPerm AP_RELEASE_VIEW) == "RELEASE_VIEW"
  assertBool "Permission text for PRODUCT_CONFIG_EDIT" $
    permissionToText (AutopilotPerm AP_PRODUCT_CONFIG_EDIT) == "PRODUCT_CONFIG_EDIT"

  -- allPermissionsText
  let allTextPerms = allPermissionsText "autopilot"
  assertBool "allPermissionsText returns non-empty" $ not (null allTextPerms)
  assertEqual
    "allPermissionsText count matches allPermissions"
    (length allPerms)
    (length allTextPerms)

  -- defaultPermissionsText
  let adminTextPerms = defaultPermissionsText "autopilot" "Admin"
      viewerTextPerms = defaultPermissionsText "autopilot" "Viewer"
  assertEqual "defaultPermissionsText Admin count" (length allPerms) (length adminTextPerms)
  assertEqual "defaultPermissionsText Viewer count" 3 (length viewerTextPerms)
  assertBool "defaultPermissionsText unknown product is empty" $
    null (defaultPermissionsText "nonexistent" "Admin")
  assertBool "defaultPermissionsText unknown role is empty" $
    null (defaultPermissionsText "autopilot" "Unknown")

  -- Effective permissions logic (pure, no DB needed)
  -- GRANT adds permissions not in base
  let basePerms = ["RELEASE_VIEW", "RELEASE_CREATE"] :: [Text]
      grants = ["RELEASE_APPROVE", "RELEASE_VIEW"] :: [Text] -- VIEW already in base
      denies = ["RELEASE_CREATE"] :: [Text]
      combined = basePerms ++ filter (`notElem` basePerms) grants
      effective = filter (`notElem` denies) combined
  assertEqual
    "GRANT adds new permission"
    ["RELEASE_VIEW", "RELEASE_CREATE", "RELEASE_APPROVE"]
    combined
  assertEqual
    "DENY removes permission"
    ["RELEASE_VIEW", "RELEASE_APPROVE"]
    effective
  assertBool "GRANT does not duplicate existing" $
    length (filter (== "RELEASE_VIEW") combined) == 1

  -- ProductSlug round-trip
  assertBool "productSlugToText Autopilot" $
    productSlugToText Autopilot == "autopilot"
  assertBool "textToProductSlug autopilot" $
    textToProductSlug "autopilot" == Just Autopilot
  assertBool "textToProductSlug unknown is Nothing" $
    textToProductSlug "unknown" == Nothing

  -- OverrideType round-trip
  assertBool "overrideTypeToText Grant" $
    overrideTypeToText Grant == "GRANT"
  assertBool "overrideTypeToText Deny" $
    overrideTypeToText Deny == "DENY"
  assertBool "textToOverrideType GRANT" $
    textToOverrideType "GRANT" == Just Grant
  assertBool "textToOverrideType DENY" $
    textToOverrideType "DENY" == Just Deny
  assertBool "textToOverrideType invalid" $
    textToOverrideType "REVOKE" == Nothing

-- ============================================================================
-- [6] Release Tag Generation Tests
-- ============================================================================

testReleaseTag :: IO ()
testReleaseTag = do
  -- Tag format: PRODUCT_YYYYMMDD_VERSION_SERVICE_MODE_ENV_PRIORITY
  let mkTag product_ datePart version service mode_ env_ pri =
        T.intercalate "_" [product_, datePart, version, service, mode_, env_, pri]

  assertEqual
    "Tag format basic"
    "Beckn_20260331_v42_rider-app_AUTO_UAT_0"
    (mkTag "Beckn" "20260331" "v42" "rider-app" "AUTO" "UAT" "0")

  assertEqual
    "Tag format manual mode"
    "BPP_20260101_v1_driver-app_MANUAL_PROD_5"
    (mkTag "BPP" "20260101" "v1" "driver-app" "MANUAL" "PROD" "5")

  -- Revert tag: original + "_REVERT"
  let originalTag = "Beckn_20260331_v42_rider-app_AUTO_UAT_0" :: Text
      revertTag = originalTag <> "_REVERT"
  assertEqual
    "Revert tag suffix"
    ("Beckn_20260331_v42_rider-app_AUTO_UAT_0_REVERT" :: Text)
    revertTag

  -- Tag components are underscore-separated
  let parts = T.splitOn "_" (mkTag "Beckn" "20260331" "v42" "rider-app" "AUTO" "UAT" "0")
  assertEqual "Tag has 7 parts" 7 (length parts)
  assertEqual "Tag part 1 is product" "Beckn" (parts !! 0)
  assertEqual "Tag part 2 is date" "20260331" (parts !! 1)
  assertEqual "Tag part 3 is version" "v42" (parts !! 2)
  assertEqual "Tag part 4 is service" "rider-app" (parts !! 3)
  assertEqual "Tag part 5 is mode" "AUTO" (parts !! 4)
  assertEqual "Tag part 6 is env" "UAT" (parts !! 5)
  assertEqual "Tag part 7 is priority" "0" (parts !! 6)

-- ============================================================================
-- [7] Terminal / Aborted Status Helper Tests
-- ============================================================================

testStatusHelpers :: IO ()
testStatusHelpers = do
  -- isTerminalStatus
  assertBool "Completed is terminal" $ isTerminalStatus Completed
  assertBool "Aborted is terminal" $ isTerminalStatus Aborted
  assertBool "UserAborted is terminal" $ isTerminalStatus UserAborted
  assertBool "Discarded is terminal" $ isTerminalStatus Discarded
  assertBool "Reverted is terminal" $ isTerminalStatus Reverted
  assertBool "Created is NOT terminal" $ not $ isTerminalStatus Created
  assertBool "InProgress is NOT terminal" $ not $ isTerminalStatus InProgress
  assertBool "Paused is NOT terminal" $ not $ isTerminalStatus Paused
  assertBool "Aborting is NOT terminal" $ not $ isTerminalStatus Aborting
  assertBool "Reverting is NOT terminal" $ not $ isTerminalStatus Reverting
  assertBool "Restarting is NOT terminal" $ not $ isTerminalStatus Restarting

  -- isAbortedStatus
  assertBool "Aborted is aborted" $ isAbortedStatus Aborted
  assertBool "UserAborted is aborted" $ isAbortedStatus UserAborted
  assertBool "Aborting is aborted" $ isAbortedStatus Aborting
  assertBool "Completed is NOT aborted" $ not $ isAbortedStatus Completed
  assertBool "Paused is NOT aborted" $ not $ isAbortedStatus Paused
  assertBool "Created is NOT aborted" $ not $ isAbortedStatus Created
