{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Actions.ABValidation
  ( getValidABStatusesH,
    updateABValidationH,
    getABMetricsH,
  )
where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Protected (AuthedPerson (..), requireDeploymentPermission)
import Core.Environment (Flow)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Products.Autopilot.Queries.ReleaseTracker
  ( conditionalUpdateTracker,
    findReleaseTracker,
    insertReleaseEvent,
    listReleaseTrackersByDateRange,
    releaseStatusToText,
  )
import Products.Autopilot.Types qualified as NT
import Products.Autopilot.Types.ABValidation
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.Release (ReleaseStatus (..), ReleaseTracker (..), isTerminalStatus)
import Products.Autopilot.Types.Target (TargetState)
import Shared.API.Response (APIResponse (..))

-- ── Helpers ───────────────────────────────────────────────────────────────────

getStr :: Text -> KM.KeyMap Value -> Maybe Text
getStr k obj = case KM.lookup (K.fromText k) obj of
  Just (String t) | not (T.null t) -> Just t
  _ -> Nothing

getBool :: Text -> KM.KeyMap Value -> Bool
getBool k obj = case KM.lookup (K.fromText k) obj of
  Just (Bool b) -> b
  Just (Number n) -> n > 0
  Just (String t) -> t `elem` ["true", "1", "True", "yes"]
  _ -> False

currentABStatus :: ReleaseTracker -> ABValidationStatus
currentABStatus rt =
  fromMaybe UNASSIGNED $
    NT.abValidationStatus rt >>= textToABValidationStatus

-- ── Handlers ──────────────────────────────────────────────────────────────────

-- | GET /releases/:id/ab
-- Returns the list of valid AB statuses the caller can set for this tracker,
-- based on both the tracker's release status and current AB validation status.
getValidABStatusesH :: AuthedPerson -> Text -> Flow Value
getValidABStatusesH _ap rid = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ object ["statusList" .= ([] :: [Text])]
    Just (rt, _) -> do
      let trackerStatuses = validABStatusesForTracker (NT.status rt)
          curABStatus = currentABStatus rt
          transitionTargets = validABTransitions curABStatus
          valid =
            if isTerminalForABValidation curABStatus
              then []
              else nub (filter (`elem` transitionTargets) trackerStatuses)
      pure $
        object
          [ "statusList" .= map abValidationStatusToText valid,
            "currentStatus" .= abValidationStatusToText curABStatus,
            "isApproved" .= maybe False abvIsApproved (parseABValidation rt)
          ]

-- | Parse the stored ABValidation JSON from a tracker.
parseABValidation :: ReleaseTracker -> Maybe ABValidation
parseABValidation rt = case NT.abValidation rt of
  Just v -> case A.fromJSON v of
    A.Success abv -> Just abv
    _ -> Nothing
  Nothing -> Nothing

-- | PUT /releases/:id/ab
-- Update the AB validation status for a completed/aborted/reverted release.
-- Body: { status, is_approved, rca_description }
updateABValidationH :: AuthedPerson -> Text -> Value -> Flow APIResponse
updateABValidationH ap rid body = do
  m <- findReleaseTracker rid
  case m of
    Nothing -> pure $ APIResponse "ERROR" "Release not found"
    Just (rt, mts) -> do
      requireDeploymentPermission (Proxy :: Proxy 'AP_AB_VALIDATION_EDIT) ap (NT.appGroup rt)
      case body of
        Object obj -> do
          -- Gate: only terminal releases can be AB-validated.
          if not (isTerminalStatus (NT.status rt))
            then pure $ APIResponse "ERROR" "AB validation is only allowed on terminal releases (COMPLETED / ABORTED / REVERTED)"
            else do
              let newStatusText = fromMaybe "" (getStr "status" obj)
              case textToABValidationStatus newStatusText of
                Nothing ->
                  pure $ APIResponse "ERROR" ("Unknown AB validation status: " <> newStatusText)
                Just newStatus -> do
                  let curABStatus = currentABStatus rt
                  -- Validate transition.
                  if isTerminalForABValidation curABStatus
                    then pure $ APIResponse "ERROR" "AB status INVALID is terminal — no further changes allowed"
                    else
                      if newStatus `notElem` validABTransitions curABStatus
                        then
                          pure $
                            APIResponse
                              "ERROR"
                              ( "Invalid AB transition: "
                                  <> abValidationStatusToText curABStatus
                                  <> " → "
                                  <> abValidationStatusToText newStatus
                              )
                        else do
                          -- Validate against tracker status.
                          let allowed = validABStatusesForTracker (NT.status rt)
                          if newStatus `notElem` allowed
                            then
                              pure $
                                APIResponse
                                  "ERROR"
                                  ( "Status "
                                      <> abValidationStatusToText newStatus
                                      <> " is not valid for a "
                                      <> T.pack (show (NT.status rt))
                                      <> " release"
                                  )
                            else do
                              let isApproved = getBool "is_approved" obj
                                  rcaDesc = getStr "rca_description" obj
                                  changedBy = apEmail ap
                              -- RCA is required for non-VERIFIED statuses on aborted/reverted releases.
                              let needsRca =
                                    newStatus /= VERIFIED
                                      && NT.status rt
                                        `elem` [ABORTED, USER_ABORTED, GCLT_ABORTED, REVERTED]
                              if needsRca && null (maybe "" T.unpack rcaDesc)
                                then pure $ APIResponse "ERROR" "RCA description is required for this status"
                                else applyABValidation rt mts newStatus isApproved rcaDesc changedBy
        _ -> pure $ APIResponse "ERROR" "Invalid JSON body"

applyABValidation ::
  ReleaseTracker ->
  Maybe TargetState ->
  ABValidationStatus ->
  Bool ->
  Maybe Text ->
  Text ->
  Flow APIResponse
applyABValidation rt mts newStatus isApproved rcaDesc changedBy = do
  now <- liftIO getCurrentTime
  let nowText = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      -- Build the new history entry.
      newEntry =
        ABValidationEntry
          { abveStatus = newStatus,
            abveChangedBy = changedBy,
            abveIsApproved = isApproved,
            abveRcaDesc = rcaDesc,
            abveUpdatedAt = nowText
          }
      -- Merge with existing history.
      oldHistory = maybe [] abvHistory (parseABValidation rt)
      newValidation =
        ABValidation
          { abvStatus = newStatus,
            abvIsApproved = isApproved,
            abvRcaDesc = rcaDesc,
            abvHistory = oldHistory <> [newEntry]
          }
      updated =
        rt
          { NT.abValidationStatus = Just (abValidationStatusToText newStatus),
            NT.abValidation = Just (toJSON newValidation)
          }
  casOk <- conditionalUpdateTracker updated mts (releaseStatusToText (NT.status rt))
  if not casOk
    then pure $ APIResponse "ERROR" "Concurrent modification — please refresh and try again"
    else do
      insertReleaseEvent
        (NT.releaseId rt)
        "BUSINESS"
        "AB_VALIDATION_UPDATED"
        ( object
            [ "status" .= abValidationStatusToText newStatus,
              "changed_by" .= changedBy,
              "is_approved" .= isApproved,
              "rca_description" .= rcaDesc
            ]
        )
      pure $ APIResponse "SUCCESS" "AB validation updated"

-- | GET /releases/abstatus
-- AB validation metrics: counts, percentages, success rate per status.
-- Query params: from (ISO8601), to (ISO8601), optional product filter.
getABMetricsH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
getABMetricsH _ap mFrom mTo mProduct = do
  now <- liftIO getCurrentTime
  let tryParse t = case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" (T.unpack t) of
        Just v -> Just v
        Nothing -> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack t)
      from = fromMaybe (addUTCTime (-2592000) now) (mFrom >>= tryParse)
      to = fromMaybe now (mTo >>= tryParse)
  pairs <- listReleaseTrackersByDateRange from to
  let trackers = map fst pairs
      -- Filter to terminal-only releases (the only ones that can have AB status).
      terminal = filter (isTerminalStatus . NT.status) trackers
      -- Apply product filter.
      filtered = case mProduct of
        Nothing -> terminal
        Just p -> filter (\rt -> NT.appGroup rt == p) terminal
      total = length filtered
      -- Count by AB status.
      counts = map (countByStatus filtered) [minBound .. maxBound :: ABValidationStatus]
      -- INVALID + UNASSIGNED excluded from the AB success rate denominator.
      validTotal = length (filter (\rt -> currentABStatus rt `notElem` [UNASSIGNED, INVALID]) filtered)
  pure $
    object
      [ "total_releases" .= total,
        "list" .= map (toMetricObject total validTotal) counts
      ]

countByStatus :: [ReleaseTracker] -> ABValidationStatus -> (ABValidationStatus, Int)
countByStatus trackers s =
  (s, length (filter ((== s) . currentABStatus) trackers))

toMetricObject :: Int -> Int -> (ABValidationStatus, Int) -> Value
toMetricObject total validTotal (s, count) =
  let pct :: Double
      pct = if total == 0 then 0 else fromIntegral count * 100.0 / fromIntegral total
      abSr :: Maybe Double
      abSr =
        if s `elem` [UNASSIGNED, INVALID]
          then Nothing
          else
            if validTotal == 0
              then Just 0
              else Just (fromIntegral count * 100.0 / fromIntegral validTotal)
   in object $
        [ "status" .= abValidationStatusToText s,
          "count" .= count,
          "percentage" .= pct
        ]
          <> maybe [] (\v -> ["ab_success_rate" .= v]) abSr
