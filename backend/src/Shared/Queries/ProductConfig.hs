{-# LANGUAGE OverloadedStrings #-}

module Shared.Queries.ProductConfig
  ( -- * Product CRUD
    upsertProduct,
    findProductByName,
    findProductByNameAndCluster,
    listProductsByName,
    listProducts,
    findProductConfigById,
    deleteProductConfig,

    -- * Product config extractors
    getProductCluster,
    getProductNamespace,
    getProductVsName,
    getProductSyncCluster,
    getProductVsLockedBy,
  )
where

-- Re-export product-related queries from the unified module
import Products.Autopilot.Queries.ProductService
  ( deleteProductConfig,
    findProductByName,
    findProductByNameAndCluster,
    findProductConfigById,
    getProductCluster,
    getProductNamespace,
    getProductSyncCluster,
    getProductVsLockedBy,
    getProductVsName,
    listProducts,
    listProductsByName,
    upsertProduct,
  )
