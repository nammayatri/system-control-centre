{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Products.Types (
    ProductSlug (..),
    productSlugToText,
    textToProductSlug,
    Permission (..),
    permissionToText,
    allPermissions,
    allPermissionsText,
    defaultPermissions,
    defaultPermissionsText,
    isViewPerm,
    IsProduct (..),
    SystemRole (..),
    OverrideType (..),
    overrideTypeToText,
    textToOverrideType,
)
where

import Data.Proxy (Proxy)
import Data.Text (Text)
import Products.Autopilot.Types.Permission

-- | All known products in the system.
data ProductSlug
    = Autopilot
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

productSlugToText :: ProductSlug -> Text
productSlugToText Autopilot = "autopilot"

textToProductSlug :: Text -> Maybe ProductSlug
textToProductSlug "autopilot" = Just Autopilot
textToProductSlug _ = Nothing

-- | Union of all product permissions.
data Permission
    = AutopilotPerm AutopilotPermission
    deriving (Show, Read, Eq, Ord)

permissionToText :: Permission -> Text
permissionToText (AutopilotPerm p) = autopilotPermissionToText p

-- | All permissions for a given product.
allPermissions :: ProductSlug -> [Permission]
allPermissions Autopilot = map AutopilotPerm [minBound .. maxBound]

-- | All permissions as Text for a product.
allPermissionsText :: Text -> [Text]
allPermissionsText slug = case textToProductSlug slug of
    Just p -> map permissionToText (allPermissions p)
    Nothing -> []

-- | Default permissions as Text for a system role on a product.
defaultPermissionsText :: Text -> Text -> [Text]
defaultPermissionsText productSlug roleName = case (textToProductSlug productSlug, textToSystemRole roleName) of
    (Just p, Just r) -> map permissionToText (defaultPermissions r p)
    _ -> []

textToSystemRole :: Text -> Maybe SystemRole
textToSystemRole "Admin" = Just Admin
textToSystemRole "Manager" = Just Manager
textToSystemRole "Viewer" = Just Viewer
textToSystemRole _ = Nothing

-- | System roles that cannot be deleted.
data SystemRole = Admin | Manager | Viewer
    deriving (Show, Read, Eq, Ord, Enum, Bounded)

data OverrideType = Grant | Deny
    deriving (Show, Read, Eq, Ord)

overrideTypeToText :: OverrideType -> Text
overrideTypeToText Grant = "GRANT"
overrideTypeToText Deny = "DENY"

textToOverrideType :: Text -> Maybe OverrideType
textToOverrideType "GRANT" = Just Grant
textToOverrideType "DENY" = Just Deny
textToOverrideType _ = Nothing

isViewPerm :: Permission -> Bool
isViewPerm (AutopilotPerm p) = p `elem` [AP_RELEASE_VIEW, AP_PRODUCT_CONFIG_VIEW, AP_SERVICE_CONFIG_VIEW]

defaultPermissions :: SystemRole -> ProductSlug -> [Permission]
defaultPermissions Admin p = allPermissions p
defaultPermissions Viewer p = filter isViewPerm (allPermissions p)
defaultPermissions Manager p = filter (not . isEditPerm) (allPermissions p)

isEditPerm :: Permission -> Bool
isEditPerm (AutopilotPerm p) = p `elem` [AP_PRODUCT_CONFIG_EDIT, AP_SERVICE_CONFIG_EDIT]

-- | Product typeclass - each product must implement this.
class IsProduct (p :: ProductSlug) where
    routePermissions :: Proxy p -> [(Text, [Text], Permission)]
    permDescriptions :: Proxy p -> [(Permission, Text)]
    productRunner :: Proxy p -> Maybe (IO ())
    productRunner _ = Nothing
