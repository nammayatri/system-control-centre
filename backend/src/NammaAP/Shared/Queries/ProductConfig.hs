{-# LANGUAGE OverloadedStrings #-}

module NammaAP.Shared.Queries.ProductConfig
  ( -- * Product CRUD
    upsertProduct
  , findProductByName
  , findProductByNameAndCluster
  , listProductsByName
  , listProducts

  -- * Product config extractors
  , getK8sProductConfig
  , getProductCluster
  , getProductNamespace
  , getProductVsName
  , getProductSyncCluster
  , getProductVsLockedBy
  ) where

-- Re-export product-related queries from the original module
import NammaAP.Products.Autopilot.Queries.ProductService
  ( upsertProduct
  , findProductByName
  , findProductByNameAndCluster
  , listProductsByName
  , listProducts
  , getK8sProductConfig
  , getProductCluster
  , getProductNamespace
  , getProductVsName
  , getProductSyncCluster
  , getProductVsLockedBy
  )
