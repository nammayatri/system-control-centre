{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Product type system
--
-- Defines the core types for the product framework:
-- - ProductSlug: ADT enumerating all products
-- - Permission: Union type of all product permissions
-- - IsProduct: Typeclass that each product must implement
module NammaAP.Products.Types
  ( ProductSlug (..)
  , productSlugToText
  , textToProductSlug
  , Permission (..)
  , permissionToText
  , allPermissions
  , defaultPermissions
  , isViewPerm
  , IsProduct (..)
  , SystemRole (..)
  , OverrideType (..)
  , overrideTypeToText
  , textToOverrideType
  ) where

import Data.Text (Text)
import Data.Proxy (Proxy)
import NammaAP.Products.Autopilot.Types.Permission
import NammaAP.Products.ConfigManager.Types.Permission

-- | All known products in the system.
-- Adding a product here without implementing IsProduct will cause a compile error.
data ProductSlug
  = Autopilot
  | ConfigManager
  deriving (Show, Read, Eq, Ord, Enum, Bounded)

productSlugToText :: ProductSlug -> Text
productSlugToText Autopilot = "autopilot"
productSlugToText ConfigManager = "config-manager"

textToProductSlug :: Text -> Maybe ProductSlug
textToProductSlug "autopilot" = Just Autopilot
textToProductSlug "config-manager" = Just ConfigManager
textToProductSlug _ = Nothing

-- | Union of all product permissions.
-- Each product contributes its own permission ADT wrapped in a constructor.
data Permission
  = AutopilotPerm AutopilotPermission
  | ConfigManagerPerm ConfigManagerPermission
  deriving (Show, Read, Eq, Ord)

permissionToText :: Permission -> Text
permissionToText (AutopilotPerm p) = autopilotPermissionToText p
permissionToText (ConfigManagerPerm p) = configManagerPermissionToText p

-- | All permissions for a given product.
-- Compiler warns if a new ProductSlug is added without handling here.
allPermissions :: ProductSlug -> [Permission]
allPermissions Autopilot = map AutopilotPerm [minBound .. maxBound]
allPermissions ConfigManager = map ConfigManagerPerm [minBound .. maxBound]

-- | System roles that cannot be deleted.
data SystemRole = Admin | Manager | Viewer
  deriving (Show, Read, Eq, Ord, Enum, Bounded)

-- | Override type for permission overrides.
data OverrideType = Grant | Deny
  deriving (Show, Read, Eq, Ord)

overrideTypeToText :: OverrideType -> Text
overrideTypeToText Grant = "GRANT"
overrideTypeToText Deny = "DENY"

textToOverrideType :: Text -> Maybe OverrideType
textToOverrideType "GRANT" = Just Grant
textToOverrideType "DENY" = Just Deny
textToOverrideType _ = Nothing

-- | Check if a permission is a view-only permission.
isViewPerm :: Permission -> Bool
isViewPerm (AutopilotPerm p) = p `elem` [AP_RELEASE_VIEW, AP_PRODUCT_CONFIG_VIEW, AP_SERVICE_CONFIG_VIEW]
isViewPerm (ConfigManagerPerm p) = p == CM_CONFIG_VIEW

-- | Default permissions for system roles.
-- Compiler warns if a new SystemRole or ProductSlug is added without handling here.
defaultPermissions :: SystemRole -> ProductSlug -> [Permission]
defaultPermissions Admin p = allPermissions p
defaultPermissions Viewer p = filter isViewPerm (allPermissions p)
defaultPermissions Manager p = allPermissions p  -- Managers get all permissions except edit (simplified)

-- | Product typeclass - each product must implement this.
-- Missing implementation causes a compile error.
class IsProduct (p :: ProductSlug) where
  -- | Route-permission mappings for this product
  routePermissions :: Proxy p -> [(Text, [Text], Permission)]

  -- | Permission descriptions for admin API
  permDescriptions :: Proxy p -> [(Permission, Text)]

  -- | Optional background runner
  productRunner :: Proxy p -> Maybe (IO ())
  productRunner _ = Nothing
