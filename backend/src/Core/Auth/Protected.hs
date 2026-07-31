{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Compile-time RBAC Servant combinator.
--
-- @Protected \'AP_RELEASE_VIEW :> ...@ attaches a permission tag to a
-- route; the 'HasServer' instance validates the bearer token, checks the
-- permission (or superadmin), and passes an 'AuthedPerson' to the handler
-- on success. Failures become typed 401/403 JSON. Product-agnostic: @perm@
-- is poly-kinded and 'KnownPermission' instances live in the owning
-- product so Core never imports Products.
module Core.Auth.Protected
  ( Protected,
    ServiceProtected,
    KnownPermission (..),
    AuthedPerson (..),
    requireDeploymentPermission,
    requireDeploymentPermissionScopes,
    checkPersonPermission,
  )
where

import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (AuthError (..))
import Core.Auth.Permission (KnownPermission (..))
import Core.Auth.Queries
  ( computeEffectivePermissions,
    computeEffectivePermissionsForAppGroup,
    findPersonById,
    findProductAccessForPerson,
    findTokenByValue,
    hasAnyDeploymentPermission,
    trExpiresAt,
    trPersonId,
  )
import Core.Auth.Types
  ( PersonAuth (..),
    ProductAccess (..),
  )
import Core.Config (Config (..))
import Core.Environment (AppState, MonadFlow, getConfig, runFlow)
import Data.Aeson (object, (.=))
import Data.Aeson qualified as A
import Data.ByteString qualified as B
import Data.List (find)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Data.UUID (UUID, nil)
import GHC.Generics (Generic)
import Network.HTTP.Types (hContentType)
import Network.Wai (Request, requestHeaders)
import Servant
  ( HasContextEntry,
    HasServer (..),
    ServerError (..),
    err401,
    err403,
    getContextEntry,
    (:>),
  )
import Servant.Server.Internal.Delayed (addAuthCheck)
import Servant.Server.Internal.DelayedIO (DelayedIO, delayedFailFatal, withRequest)

-- | Combinator carrying a compile-time permission tag (poly-kinded @perm@).
data Protected (perm :: k)

-- | Authenticated principal handed to every 'Protected' handler.
data AuthedPerson = AuthedPerson
  { apPersonId :: UUID,
    apEmail :: Text,
    apIsSuperadmin :: Bool,
    apProductAccesses :: [ProductAccess]
  }
  deriving (Show, Generic)

instance
  ( KnownPermission perm,
    HasServer api context,
    HasContextEntry context AppState
  ) =>
  HasServer (Protected (perm :: k) :> api) context
  where
  type ServerT (Protected perm :> api) m = AuthedPerson -> ServerT api m

  hoistServerWithContext _ pc nt s =
    \p -> hoistServerWithContext (Proxy :: Proxy api) pc nt (s p)

  route _ context subserver =
    route (Proxy :: Proxy api) context (subserver `addAuthCheck` check)
    where
      st :: AppState
      st = getContextEntry context
      prodSlug :: Text
      prodSlug = permissionProduct (Proxy :: Proxy perm)
      permText :: Text
      permText = permissionName (Proxy :: Proxy perm)

      check :: DelayedIO AuthedPerson
      check = withRequest $ \req -> do
        result <- liftIO (runFlow st (checkPermission prodSlug permText req))
        case result of
          Right ap -> pure ap
          Left (status, msg) -> delayedFailFatal (jsonError status msg)

data ServiceProtected (perm :: k)

instance
  ( KnownPermission perm,
    HasServer api context,
    HasContextEntry context AppState
  ) =>
  HasServer (ServiceProtected (perm :: k) :> api) context
  where
  type ServerT (ServiceProtected perm :> api) m = AuthedPerson -> ServerT api m

  hoistServerWithContext _ pc nt s =
    \p -> hoistServerWithContext (Proxy :: Proxy api) pc nt (s p)

  route _ context subserver =
    route (Proxy :: Proxy api) context (subserver `addAuthCheck` check)
    where
      st :: AppState
      st = getContextEntry context
      prodSlug :: Text
      prodSlug = permissionProduct (Proxy :: Proxy perm)
      permText :: Text
      permText = permissionName (Proxy :: Proxy perm)

      check :: DelayedIO AuthedPerson
      check = withRequest $ \req -> do
        result <- liftIO (runFlow st (checkServiceOrUser prodSlug permText req))
        case result of
          Right ap -> pure ap
          Left (status, msg) -> delayedFailFatal (jsonError status msg)

checkServiceOrUser ::
  (MonadFlow m) =>
  Text ->
  Text ->
  Request ->
  m (Either (ServerError, Text) AuthedPerson)
checkServiceOrUser prodSlug permText req =
  case lookup "X-Sync-Api-Key" (requestHeaders req) of
    Nothing -> checkPermission prodSlug permText req
    Just provided -> do
      cfg <- getConfig
      let configured = T.pack (syncClusterApiKey cfg)
      if not (T.null configured) && TE.decodeUtf8 provided == configured
        then
          pure $
            Right
              AuthedPerson
                { apPersonId = nil,
                  apEmail = T.pack (syncReleaseManager cfg),
                  apIsSuperadmin = True,
                  apProductAccesses = []
                }
        else pure $ Left (err401, "Invalid API key")

-- | Validate the bearer token and check @permText@ for @prodSlug@.
-- Returns Right on success, Left @(status, msg)@ for 401/403 JSON.
checkPermission ::
  (MonadFlow m) =>
  Text ->
  Text ->
  Request ->
  m (Either (ServerError, Text) AuthedPerson)
checkPermission prodSlug permText req = do
  case extractBearer (lookup "Authorization" (requestHeaders req)) of
    Nothing -> pure $ Left (err401, "Missing Authorization header")
    Just token -> do
      mTok <- findTokenByValue token
      case mTok of
        Nothing -> pure $ Left (err401, "Invalid or expired token")
        Just tokRow -> do
          now <- liftIO getCurrentTime
          if trExpiresAt tokRow < now
            then pure $ Left (err401, "Token expired")
            else do
              mPerson <- findPersonById (trPersonId tokRow)
              case mPerson of
                Nothing -> pure $ Left (err401, "Person not found")
                Just person -> checkPersonPermission prodSlug permText person

checkPersonPermission ::
  (MonadFlow m) =>
  Text ->
  Text ->
  PersonAuth ->
  m (Either (ServerError, Text) AuthedPerson)
checkPersonPermission prodSlug permText person
  | not (personIsActive person) =
      pure $ Left (err401, "Account deactivated")
  | personIsSuperadmin person = do
      accesses <- findProductAccessForPerson (personId person)
      pure $
        Right
          AuthedPerson
            { apPersonId = personId person,
              apEmail = personEmail person,
              apIsSuperadmin = True,
              apProductAccesses = accesses
            }
  | otherwise = do
      accesses <- findProductAccessForPerson (personId person)
      productGranted <- case find (\pa -> paProductSlug pa == prodSlug) accesses of
        Nothing -> pure False
        Just pa -> (permText `elem`) <$> computeEffectivePermissions person prodSlug (paRoleId pa)
      if productGranted
        then
          pure $
            Right
              AuthedPerson
                { apPersonId = personId person,
                  apEmail = personEmail person,
                  apIsSuperadmin = False,
                  apProductAccesses = accesses
                }
        else do
          -- An alias product's grant may carry this product's permissions
          -- (unified model: mobile roles carry OTA_*). PRODUCT-LEVEL alias
          -- access must count — a fleet-wide mobile Admin holds OTA_* for
          -- every app, so this gate opens without any scoped row. Then the
          -- deployment (scoped) grants under the product itself or an alias.
          let slugs = prodSlug : aliasGrantSlugs prodSlug
          deploymentGranted <-
            orM $
              [ (permText `elem`) <$> computeEffectivePermissions person s (paRoleId pa)
                | s <- aliasGrantSlugs prodSlug,
                  pa <- filter (\a -> paProductSlug a == s) accesses
              ]
                <> [hasAnyDeploymentPermission (personId person) s permText | s <- slugs]
          if deploymentGranted
            then
              pure $
                Right
                  AuthedPerson
                    { apPersonId = personId person,
                      apEmail = personEmail person,
                      apIsSuperadmin = False,
                      apProductAccesses = accesses
                    }
            else
              if any (\pa -> paProductSlug pa == prodSlug) accesses
                then pure $ Left (err403, "Permission denied: " <> permText)
                else pure $ Left (err403, "No access to product: " <> prodSlug)
  where
    orM [] = pure False
    orM (m : ms) = m >>= \b -> if b then pure True else orM ms

-- | Products whose grants may satisfy another product's permission check.
-- Sole case today: airborne-ota permissions carried by a mobile grant —
-- product-level, or per-app (\"\<name\>\/\<platform\>\").
aliasGrantSlugs :: Text -> [Text]
aliasGrantSlugs "airborne-ota" = ["mobile"]
aliasGrantSlugs _ = []

requireDeploymentPermission ::
  (KnownPermission perm, MonadFlow m) =>
  Proxy perm ->
  AuthedPerson ->
  Text ->
  m ()
requireDeploymentPermission proxy ap appGroup =
  requireDeploymentPermissionScopes proxy ap [(permissionProduct proxy, appGroup)]

-- | Multi-scope variant: the permission may be satisfied under ANY of the
-- given (product_slug, app_group) scopes. Used where one grant vocabulary
-- aliases another — e.g. an OTA check accepts the legacy per-ref
-- airborne-ota grant OR the unified per-app autopilot grant
-- (\"\<name\>\/\<platform\>\").
requireDeploymentPermissionScopes ::
  (KnownPermission perm, MonadFlow m) =>
  Proxy perm ->
  AuthedPerson ->
  [(Text, Text)] ->
  m ()
requireDeploymentPermissionScopes proxy ap scopes
  | apIsSuperadmin ap = pure ()
  | otherwise = go scopes
  where
    permText = permissionName proxy
    denied = T.intercalate " | " (map snd scopes) <> ": " <> permText
    go [] = throwM (PermissionDenied denied)
    go ((slug, key) : rest) = do
      perms <- computeEffectivePermissionsForAppGroup (apPersonId ap) slug key
      if permText `elem` perms then pure () else go rest

-- | Extract the bearer token; accepts @"Bearer xyz"@ or bare @"xyz"@.
extractBearer :: Maybe B.ByteString -> Maybe Text
extractBearer Nothing = Nothing
extractBearer (Just bs) =
  let raw = T.strip (TE.decodeUtf8 bs)
   in case T.stripPrefix "Bearer " raw of
        Just t -> Just (T.strip t)
        Nothing -> Just raw

-- | 'ServerError' with JSON @{"error": msg}@ body.
jsonError :: ServerError -> Text -> ServerError
jsonError template msg =
  template
    { errBody = A.encode (object ["error" .= msg]),
      errHeaders = [(hContentType, "application/json")]
    }
