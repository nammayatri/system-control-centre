{-# LANGUAGE OverloadedStrings #-}

module Shared.Queries.ReleaseEvents
  ( listReleaseEvents,
    insertReleaseEvent,
  )
where

-- Re-export from the release tracker queries
import Products.Autopilot.Queries.ReleaseTracker
  ( insertReleaseEvent,
    listReleaseEvents,
  )
