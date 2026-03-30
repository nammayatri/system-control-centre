{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Shared.Queries.ReleaseEvents
  ( listReleaseEvents
  , insertReleaseEvent
  ) where

-- Re-export from the release tracker queries
import NammaAP.Products.Autopilot.Queries.ReleaseTracker
  ( listReleaseEvents
  , insertReleaseEvent
  )
