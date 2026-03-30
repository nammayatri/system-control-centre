{-# LANGUAGE OverloadedStrings #-}

-- | Product Registry
-- Every product registers its route-permission mappings here.
-- To add a new product:
--   1. Create a folder under Products/ (e.g., Products/MyProduct/)
--   2. Define routes + handlers in Products/MyProduct/Routes.hs
--   3. Add route-permission mappings in Products/MyProduct/Permissions.hs
--   4. Import and add to `allProductPermissions` below
--   5. Add the product's API type to FullAPI in Server.hs
--   6. Seed permissions in DB: scripts/rbac_seed.sql
--   7. Frontend: add products/my-product/ folder

module NammaAP.Products.Registry
  ( allProductPermissions
  , ProductPermission (..)
  ) where

import Data.Text (Text)

-- | A single route-to-permission mapping
data ProductPermission = ProductPermission
  { ppMethod :: Text          -- HTTP method: GET, POST, PUT, DELETE
  , ppPathSegments :: [Text]  -- path segments to match (prefix match)
  , ppPermission :: Text      -- required permission action
  , ppProduct :: Text         -- product slug (matches sc_product.slug)
  } deriving (Show)

-- | All product permission mappings — import from each product
-- When adding a new product, add its permissions here.
allProductPermissions :: [ProductPermission]
allProductPermissions = concat
  [ releasePermissions
  , configManagerPermissions
  -- , myNewProductPermissions   ← add new products here
  ]

-- ── Product: backend-releases ─────────────────────────────────────

releasePermissions :: [ProductPermission]
releasePermissions =
  -- Releases
  [ pp "GET"  ["releases"]              "RELEASE_VIEW"
  , pp "POST" ["releases", "create"]    "RELEASE_CREATE"
  -- Products & services
  , pp "GET"  ["products"]              "PRODUCT_CONFIG_VIEW"
  , pp "POST" ["products"]              "PRODUCT_CONFIG_EDIT"
  , pp "POST" ["services"]              "PRODUCT_CONFIG_EDIT"
  -- Server config
  , pp "GET"  ["server-config"]         "SERVICE_CONFIG_VIEW"
  , pp "POST" ["server-config"]         "SERVICE_CONFIG_EDIT"
  -- Envs
  , pp "GET"  ["envs"]                  "RELEASE_VIEW"
  ]
  where pp m p perm = ProductPermission m p perm "backend-releases"

-- ── Product: config-manager ──────────────────────────────────────

configManagerPermissions :: [ProductPermission]
configManagerPermissions =
  [ pp "GET"  ["configmap"]             "CONFIG_VIEW"
  , pp "GET"  ["tracker", "configmap"]  "CONFIG_VIEW"
  , pp "POST" ["tracker", "configmap"]  "CONFIG_CREATE"
  , pp "PUT"  ["tracker", "configmap"]  "CONFIG_UPDATE"
  ]
  where pp m p perm = ProductPermission m p perm "config-manager"

-- ── Template for new product ─────────────────────────────────────
--
-- myNewProductPermissions :: [ProductPermission]
-- myNewProductPermissions =
--   [ pp "GET"  ["my-endpoint"]        "MY_VIEW"
--   , pp "POST" ["my-endpoint"]        "MY_CREATE"
--   ]
--   where pp m p perm = ProductPermission m p perm "my-product-slug"
