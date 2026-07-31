{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Per-app permission checks for mobile verbs (unified grant model).

A grant is one sc_person_deployment_access row
(product_slug=mobile, app_group=\"\<name\>\/\<platform\>\") whose role may
carry both MB_* and OTA_* permissions. 'requireAppPerm' passes for holders
of that grant AND for product-level mobile role holders — the fallback
to the product baseline lives in 'computeEffectivePermissionsForAppGroup',
so a fleet-wide role needs no special-casing here.
-}
module Products.Autopilot.Mobile.Auth (
    requireAppPerm,
    requireAppPermAll,
    requireProductPerm,
) where

import Control.Monad (forM_, unless)
import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), KnownPermission (..), requireDeploymentPermissionScopes)
import Core.Auth.Queries (computeEffectivePermissions, findPersonById)
import Core.Auth.Types (ProductAccess (..))
import Core.Environment (MonadFlow)
import Data.List (find)
import Data.Proxy (Proxy)
import Data.Text (Text)
import Products.Autopilot.Mobile.Queries.AppCatalog (appGrantKey)

-- | Permission on one (app name, platform) — 403 names the app on refusal.
requireAppPerm ::
    forall perm m. (KnownPermission perm, MonadFlow m) => Proxy perm -> AuthedPerson -> Text -> Text -> m ()
requireAppPerm proxy ap name platform =
    requireDeploymentPermissionScopes proxy ap [("mobile", appGrantKey name platform)]

{- | Multi-target operations: every (name, platform) must be granted; the
first refusal aborts naming the offending app, so a partially-granted
selection never half-executes.
-}
requireAppPermAll ::
    forall perm m. (KnownPermission perm, MonadFlow m) => Proxy perm -> AuthedPerson -> [(Text, Text)] -> m ()
requireAppPermAll proxy ap targets =
    forM_ targets $ \(name, platform) -> requireAppPerm proxy ap name platform

{- | PRODUCT-level grant required — the per-app deployment fallback that the
route-level check accepts is deliberately ignored. For fleet-level admin
verbs (e.g. creating catalog apps) where a per-app Admin must not qualify.
Mirrors AirborneOta's requireProductLevelAppManage.
-}
requireProductPerm ::
    forall perm m. (KnownPermission perm, MonadFlow m) => Proxy perm -> AuthedPerson -> m ()
requireProductPerm proxy ap
    | apIsSuperadmin ap = pure ()
    | otherwise = do
        let slug = permissionProduct proxy
            permText = permissionName proxy
        granted <- case find ((== slug) . paProductSlug) (apProductAccesses ap) of
            Nothing -> pure False
            Just pa -> do
                mPerson <- findPersonById (apPersonId ap)
                case mPerson of
                    Nothing -> pure False
                    Just person -> (permText `elem`) <$> computeEffectivePermissions person slug (paRoleId pa)
        unless granted $
            throwM (Forbidden (permText <> " requires a product-level grant (per-app access does not qualify)"))
