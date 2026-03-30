{-# LANGUAGE OverloadedStrings #-}

module Shared.Queries.ReleaseConfig (
    -- * Service/release config CRUD
    upsertService,
    findServiceByProductAndName,
    listReleaseConfigByProduct,
    listSchedulerServicesByProduct,
    listAllReleaseConfigs,
    findReleaseConfigById,
    deleteReleaseConfig,

    -- * Service config extractors
    getServiceHost,
)
where

-- Re-export service/release-config queries from the original module
import Products.Autopilot.Queries.ProductService (
    findServiceByProductAndName,
    getServiceHost,
    listReleaseConfigByProduct,
    listSchedulerServicesByProduct,
    upsertService,
 )

import Products.Autopilot.Queries.VsEditTracker (
    listAllReleaseConfigs,
    findReleaseConfigById,
    deleteReleaseConfig,
 )
