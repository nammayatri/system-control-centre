{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Products.Autopilot.Types.ABValidation
  ( ABValidationStatus (..),
    ABValidationEntry (..),
    ABValidation (..),
    abValidationStatusToText,
    textToABValidationStatus,
    validABStatusesForTracker,
    validABTransitions,
    isTerminalForABValidation,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Products.Autopilot.Types.Release (ReleaseStatus (..))

-- | Post-release AB test outcome classification (mirrors ny-autopilot).
data ABValidationStatus
  = UNASSIGNED
  | VERIFIED
  | MISSED_ABORT
  | FALSE_ABORT
  | TRUE_ABORT
  | INVALID
  deriving (Eq, Show, Read, Generic, Enum, Bounded)

instance ToJSON ABValidationStatus

instance FromJSON ABValidationStatus

abValidationStatusToText :: ABValidationStatus -> Text
abValidationStatusToText UNASSIGNED = "UNASSIGNED"
abValidationStatusToText VERIFIED = "VERIFIED"
abValidationStatusToText MISSED_ABORT = "MISSED_ABORT"
abValidationStatusToText FALSE_ABORT = "FALSE_ABORT"
abValidationStatusToText TRUE_ABORT = "TRUE_ABORT"
abValidationStatusToText INVALID = "INVALID"

textToABValidationStatus :: Text -> Maybe ABValidationStatus
textToABValidationStatus "UNASSIGNED" = Just UNASSIGNED
textToABValidationStatus "VERIFIED" = Just VERIFIED
textToABValidationStatus "MISSED_ABORT" = Just MISSED_ABORT
textToABValidationStatus "FALSE_ABORT" = Just FALSE_ABORT
textToABValidationStatus "TRUE_ABORT" = Just TRUE_ABORT
textToABValidationStatus "INVALID" = Just INVALID
textToABValidationStatus _ = Nothing

-- | Which AB statuses are meaningful for a given tracker status.
validABStatusesForTracker :: ReleaseStatus -> [ABValidationStatus]
validABStatusesForTracker COMPLETED = [VERIFIED, MISSED_ABORT, FALSE_ABORT, INVALID]
validABStatusesForTracker ABORTED = [FALSE_ABORT, TRUE_ABORT, INVALID]
validABStatusesForTracker USER_ABORTED = [FALSE_ABORT, TRUE_ABORT, INVALID]
validABStatusesForTracker GCLT_ABORTED = [FALSE_ABORT, TRUE_ABORT, INVALID]
validABStatusesForTracker REVERTED = [TRUE_ABORT, FALSE_ABORT, MISSED_ABORT, VERIFIED, INVALID]
validABStatusesForTracker _ = []

-- | Valid AB status transitions (what you can move TO from the current AB status).
validABTransitions :: ABValidationStatus -> [ABValidationStatus]
validABTransitions UNASSIGNED = [VERIFIED, MISSED_ABORT, FALSE_ABORT, TRUE_ABORT, INVALID]
validABTransitions VERIFIED = [MISSED_ABORT, FALSE_ABORT, TRUE_ABORT, INVALID]
validABTransitions MISSED_ABORT = [VERIFIED, FALSE_ABORT, TRUE_ABORT, INVALID]
validABTransitions FALSE_ABORT = [VERIFIED, MISSED_ABORT, TRUE_ABORT, INVALID]
validABTransitions TRUE_ABORT = [VERIFIED, MISSED_ABORT, FALSE_ABORT, INVALID]
validABTransitions INVALID = []

-- | INVALID is a terminal AB status — no further transitions allowed.
isTerminalForABValidation :: ABValidationStatus -> Bool
isTerminalForABValidation INVALID = True
isTerminalForABValidation _ = False

-- | One entry in the AB validation audit history.
data ABValidationEntry = ABValidationEntry
  { abveStatus :: ABValidationStatus,
    abveChangedBy :: Text,
    abveIsApproved :: Bool,
    abveRcaDesc :: Maybe Text,
    abveUpdatedAt :: Text
  }
  deriving (Eq, Show, Generic)

instance ToJSON ABValidationEntry

instance FromJSON ABValidationEntry

-- | Current AB validation state + full history.
data ABValidation = ABValidation
  { abvStatus :: ABValidationStatus,
    abvIsApproved :: Bool,
    abvRcaDesc :: Maybe Text,
    abvHistory :: [ABValidationEntry]
  }
  deriving (Eq, Show, Generic)

instance ToJSON ABValidation

instance FromJSON ABValidation
