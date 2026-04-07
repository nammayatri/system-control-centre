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

{- | Compile-time RBAC enforcement via a Servant combinator.

Usage in the API type:

> type CoreAPI =
>        "releases" :> Protected 'AP_RELEASE_VIEW :> Get '[JSON] [ReleaseTracker]
>   :<|> "releases" :> Protected 'AP_RELEASE_CREATE :> "create"
>          :> ReqBody '[JSON] K8sCreateReleaseReq :> Post '[JSON] APIResponse

At request time, the 'HasServer' instance below:

  1. Reads the @Authorization: Bearer <token>@ header.
  2. Looks up the token in @sc_registration_token@ and the person in @sc_person@.
  3. Checks the person has @perm@ on the product specified by the
     'KnownPermission' instance — or is a superadmin.
  4. Passes an 'AuthedPerson' record to the handler as a fresh first argument.

On any failure (missing header, expired token, deactivated account, no
product access, permission denied) it fails the route with a 401/403 JSON
response matching the format previously emitted by 'Core.Auth.Middleware'.

== Layer policy

This module is deliberately product-agnostic. 'Protected' is indexed by a
poly-kinded @perm@, and 'KnownPermission' instances live in the owning
product module (e.g. "Products.Autopilot.Types.Permission") so that Core
never imports from Products.
-}
module Core.Auth.Protected (
    Protected,
    KnownPermission (..),
    AuthedPerson (..),
)
where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Permission (KnownPermission (..))
import Core.Auth.Queries (
    computeEffectivePermissions,
    findPersonById,
    findProductAccessForPerson,
    findTokenByValue,
    trExpiresAt,
    trPersonId,
 )
import Core.Auth.Types (
    PersonAuth (..),
    ProductAccess (..),
 )
import Core.Environment (AppState, MonadFlow, runFlow)
import Data.Aeson (object, (.=))
import qualified Data.Aeson as A
import qualified Data.ByteString as B
import Data.List (find)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Network.HTTP.Types (hContentType)
import Network.Wai (Request, requestHeaders)
import Servant (
    HasContextEntry,
    HasServer (..),
    ServerError (..),
    err401,
    err403,
    getContextEntry,
    (:>),
 )
import Servant.Server.Internal.Delayed (addAuthCheck)
import Servant.Server.Internal.DelayedIO (DelayedIO, delayedFailFatal, withRequest)

-- ============================================================================
-- Public types
-- ============================================================================

{- | Combinator carrying a compile-time permission tag. The @perm@ kind is
intentionally polymorphic so each product can use its own permission
data kind (e.g. @AutopilotPermission@) without Core knowing about it.
-}
data Protected (perm :: k)

{- | The authenticated principal, handed to every 'Protected' handler as a
fresh first argument — a type-level proof that the check ran.
-}
data AuthedPerson = AuthedPerson
    { apPersonId :: UUID
    , apEmail :: Text
    , apIsSuperadmin :: Bool
    , apProductAccesses :: [ProductAccess]
    }
    deriving (Show, Generic)

-- ============================================================================
-- HasServer instance — the actual check
-- ============================================================================

instance
    ( KnownPermission perm
    , HasServer api context
    , HasContextEntry context AppState
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

-- ============================================================================
-- The permission check itself
-- ============================================================================

{- | Validate the token and check the required permission for the request.
Returns the authenticated person on success; a @(ServerError-template, msg)@
pair on failure that is turned into a 401/403 JSON response.
-}
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
                                Just person
                                    | not (personIsActive person) ->
                                        pure $ Left (err401, "Account deactivated")
                                    | personIsSuperadmin person -> do
                                        accesses <- findProductAccessForPerson (personId person)
                                        pure $
                                            Right
                                                AuthedPerson
                                                    { apPersonId = personId person
                                                    , apEmail = personEmail person
                                                    , apIsSuperadmin = True
                                                    , apProductAccesses = accesses
                                                    }
                                    | otherwise -> do
                                        accesses <- findProductAccessForPerson (personId person)
                                        case find (\pa -> paProductSlug pa == prodSlug) accesses of
                                            Nothing ->
                                                pure $ Left (err403, "No access to product: " <> prodSlug)
                                            Just pa -> do
                                                perms <- computeEffectivePermissions person prodSlug (paRoleId pa)
                                                if permText `elem` perms
                                                    then
                                                        pure $
                                                            Right
                                                                AuthedPerson
                                                                    { apPersonId = personId person
                                                                    , apEmail = personEmail person
                                                                    , apIsSuperadmin = False
                                                                    , apProductAccesses = accesses
                                                                    }
                                                    else pure $ Left (err403, "Permission denied: " <> permText)

{- | Pull the bearer token out of an @Authorization@ header value. Accepts
both @"Bearer xyz"@ and a bare @"xyz"@ for compatibility with the previous
middleware implementation.
-}
extractBearer :: Maybe B.ByteString -> Maybe Text
extractBearer Nothing = Nothing
extractBearer (Just bs) =
    let raw = T.strip (TE.decodeUtf8 bs)
     in case T.stripPrefix "Bearer " raw of
            Just t -> Just (T.strip t)
            Nothing -> Just raw

{- | Build a 'ServerError' with a JSON @{"error": "..."}@ body matching the
format that 'Core.Auth.Middleware' used pre-Phase 3, so wire compatibility
with the frontend is preserved.
-}
jsonError :: ServerError -> Text -> ServerError
jsonError template msg =
    template
        { errBody = A.encode (object ["error" .= msg])
        , errHeaders = [(hContentType, "application/json")]
        }
