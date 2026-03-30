{-# LANGUAGE OverloadedStrings #-}

module Shared.Queries.ProductConfig (
    -- * Product CRUD
    upsertProduct,
    findProductByName,
    findProductByNameAndCluster,
    listProductsByName,
    listProducts,
    findProductConfigById,
    deleteProductConfig,

    -- * Product config extractors
    getK8sProductConfig,
    getProductCluster,
    getProductNamespace,
    getProductVsName,
    getProductSyncCluster,
    getProductVsLockedBy,
)
where

-- Re-export product-related queries from the original module
import Products.Autopilot.Queries.ProductService (
    findProductByName,
    findProductByNameAndCluster,
    getK8sProductConfig,
    getProductCluster,
    getProductNamespace,
    getProductSyncCluster,
    getProductVsLockedBy,
    getProductVsName,
    listProducts,
    listProductsByName,
    upsertProduct,
 )

import Products.Autopilot.Queries.VsEditTracker (
    findProductConfigById,
    deleteProductConfig,
 )
