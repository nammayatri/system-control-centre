{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Shared.Queries.ReleaseTracker
  ( -- * CRUD
    insertReleaseTracker
  , findReleaseTracker
  , listReleaseTrackers
  , listReleaseEvents
  , insertReleaseEvent
  , findReleaseTrackerByGlobalId

  -- * Query helpers
  , findRunnableReleaseTrackers
  , findCleanupScheduledTrackers
  , findAbortingReleaseTrackers
  , findOngoingReleaseTrackers
  , findTrackersWithStatusAndTime
  , findApprovedReleasesWithStatus
  , findReleaseTrackersByCategory

  -- * Row conversion
  , toRow
  , fromRow
  , TrackerWithTarget

  -- * Parsing / encoding helpers
  , parseReleaseCategory
  , parseReleaseWFStatus
  , parseReleaseStatus
  , parseMode
  , parseDecisionEngineHSStatus
  , encodeJsonText
  , parseJsonTextOr
  , parseJsonTextMaybe
  , safeHead
  ) where

-- Re-export everything from the original module
import NammaAP.Products.Autopilot.Queries.ReleaseTracker
