{-# LANGUAGE OverloadedStrings #-}

{- | Product Registry — route-to-permission mappings for all products.
The product slug MUST match ProductSlug ADT → productSlugToText.
-}
module Products.Registry (
    allProductPermissions,
    ProductPermission (..),
)
where

import Data.Text (Text)

data ProductPermission = ProductPermission
    { ppMethod :: Text
    , ppPathSegments :: [Text]
    , ppPermission :: Text
    , ppProduct :: Text -- must match productSlugToText (e.g., "autopilot")
    }
    deriving (Show)

-- | All route-permission mappings across all products.
allProductPermissions :: [ProductPermission]
allProductPermissions = autopilotPermissions

-- ── Product: Autopilot (Backend Releases + ConfigMaps + Server Config) ──

autopilotPermissions :: [ProductPermission]
autopilotPermissions =
    -- Releases
    [ pp "GET" ["releases"] "RELEASE_VIEW"
    , pp "POST" ["releases", "create"] "RELEASE_CREATE"
    , -- Products & services
      pp "GET" ["products"] "PRODUCT_CONFIG_VIEW"
    , pp "POST" ["products"] "PRODUCT_CONFIG_EDIT"
    , pp "POST" ["services"] "PRODUCT_CONFIG_EDIT"
    , -- Server config
      pp "GET" ["server-config"] "SERVICE_CONFIG_VIEW"
    , pp "POST" ["server-config"] "SERVICE_CONFIG_EDIT"
    , -- Envs
      pp "GET" ["envs"] "RELEASE_VIEW"
    , -- ConfigMap (all under autopilot product now)
      pp "GET" ["configmap"] "RELEASE_VIEW"
    , pp "GET" ["tracker", "configmap"] "RELEASE_VIEW"
    , pp "POST" ["tracker", "configmap"] "RELEASE_CREATE"
    , pp "PUT" ["tracker", "configmap"] "RELEASE_UPDATE"
    ]
  where
    pp m p perm = ProductPermission m p perm "autopilot"
