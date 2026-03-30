{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Shared.Queries.ReleaseConfig
  ( -- * Service/release config CRUD
    upsertService
  , findServiceByProductAndName
  , listReleaseConfigByProduct
  , listSchedulerServicesByProduct

  -- * Service config extractors
  , getServiceHost
  ) where

-- Re-export service/release-config queries from the original module
import NammaAP.Products.Autopilot.Queries.ProductService
  ( upsertService
  , findServiceByProductAndName
  , listReleaseConfigByProduct
  , listSchedulerServicesByProduct
  , getServiceHost
  )
