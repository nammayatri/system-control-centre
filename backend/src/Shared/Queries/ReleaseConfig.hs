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

-- Re-export service/release-config queries from the unified module
import Products.Autopilot.Queries.ProductService (
    findServiceByProductAndName,
    getServiceHost,
    listReleaseConfigByProduct,
    listSchedulerServicesByProduct,
    upsertService,
    listAllReleaseConfigs,
    findReleaseConfigById,
    deleteReleaseConfig,
 )
