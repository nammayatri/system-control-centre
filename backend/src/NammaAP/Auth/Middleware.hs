{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module NammaAP.Auth.Middleware
  ( authMiddleware
  , RoutePermission (..)
  , routePermissions
  ) where

import Data.List (find, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import Network.Wai (Middleware, Request (..), Response, responseLBS)
import Network.HTTP.Types (status401, status403, hContentType)
import qualified Data.Aeson as A
import NammaAP.Environment (DBEnv)
import NammaAP.Auth.Queries
import NammaAP.Auth.Types (PersonAuth (..))

-- | Route-to-permission mapping
data RoutePermission = RoutePermission
  { rpMethod :: Text
  , rpPathPrefix :: [Text]  -- path segments to match
  , rpPermission :: Text
  , rpProduct :: Text       -- which product's permissions to check
  } deriving (Show)

-- | Public routes that do not require authentication
publicRoutes :: [(Text, [Text])]
publicRoutes =
  [ ("POST", ["auth", "login"])
  , ("POST", ["auth", "verify"])
  , ("GET",  ["health"])
  ]

isPublicRoute :: Text -> [Text] -> Bool
isPublicRoute method pathSegs =
  any (\(m, p) -> m == method && p `isPrefixOf` pathSegs) publicRoutes

-- | Route-to-permission mapping
routePermissions :: [RoutePermission]
routePermissions =
  -- Releases (backend-releases product)
  [ RoutePermission "GET"  ["releases"]             "RELEASE_VIEW"        "backend-releases"
  , RoutePermission "POST" ["releases", "create"]    "RELEASE_CREATE"      "backend-releases"
  -- GET /releases/:id and /releases/:id/events are handled by prefix match
  , RoutePermission "POST" ["releases"]              "RELEASE_CREATE"      "backend-releases"  -- fallback for POST /releases/*
  -- Products & services (backend-releases product)
  , RoutePermission "GET"  ["products"]              "PRODUCT_CONFIG_VIEW" "backend-releases"
  , RoutePermission "POST" ["products"]              "PRODUCT_CONFIG_EDIT" "backend-releases"
  , RoutePermission "POST" ["services"]              "PRODUCT_CONFIG_EDIT" "backend-releases"
  -- Server config (backend-releases product)
  , RoutePermission "GET"  ["server-config"]         "SERVICE_CONFIG_VIEW" "backend-releases"
  , RoutePermission "POST" ["server-config"]         "SERVICE_CONFIG_EDIT" "backend-releases"
  -- Envs (backend-releases product)
  , RoutePermission "GET"  ["envs"]                  "RELEASE_VIEW"        "backend-releases"
  -- ConfigMap tracker (config-manager product)
  , RoutePermission "GET"  ["configmap"]             "CONFIG_VIEW"         "config-manager"
  , RoutePermission "GET"  ["tracker", "configmap"]  "CONFIG_VIEW"         "config-manager"
  , RoutePermission "POST" ["tracker", "configmap"]  "CONFIG_CREATE"       "config-manager"
  , RoutePermission "PUT"  ["tracker", "configmap"]  "CONFIG_UPDATE"       "config-manager"
  ]

-- | Find the required permission for a given request
findRoutePermission :: Text -> [Text] -> Maybe RoutePermission
findRoutePermission method pathSegs =
  -- First try exact-ish matches for known action paths
  let specificMatch = case (method, pathSegs) of
        ("GET",  ["releases", _, "events"]) -> Just $ RoutePermission "GET" [] "RELEASE_VIEW" "backend-releases"
        ("GET",  ["releases", _])           -> Just $ RoutePermission "GET" [] "RELEASE_VIEW" "backend-releases"
        ("POST", ["releases", _, "approve"]) -> Just $ RoutePermission "POST" [] "RELEASE_APPROVE" "backend-releases"
        ("POST", ["releases", _, "rollback"]) -> Just $ RoutePermission "POST" [] "RELEASE_REVERT" "backend-releases"
        ("POST", ["releases", _, "revert"]) -> Just $ RoutePermission "POST" [] "RELEASE_REVERT" "backend-releases"
        ("POST", ["releases", _, "discard"]) -> Just $ RoutePermission "POST" [] "RELEASE_DISCARD" "backend-releases"
        ("POST", ["releases", _, "update"]) -> Just $ RoutePermission "POST" [] "RELEASE_UPDATE" "backend-releases"
        ("POST", ["releases", _, "trigger"]) -> Just $ RoutePermission "POST" [] "RELEASE_CREATE" "backend-releases"
        ("GET",  ("products" : _ : "services" : _)) -> Just $ RoutePermission "GET" [] "PRODUCT_CONFIG_VIEW" "backend-releases"
        ("GET",  ("envs" : "secondary" : _)) -> Just $ RoutePermission "GET" [] "RELEASE_VIEW" "backend-releases"
        ("GET",  ("configmap" : "secondary" : _)) -> Just $ RoutePermission "GET" [] "CONFIG_VIEW" "config-manager"
        _ -> Nothing
  in case specificMatch of
    Just rp -> Just rp
    Nothing -> find (\rp -> rpMethod rp == method && rpPathPrefix rp `isPrefixOf` pathSegs) routePermissions

-- | WAI middleware that enforces RBAC
authMiddleware :: DBEnv -> Middleware
authMiddleware db app req respond = do
  let method = TE.decodeUtf8 (requestMethod req)
      pathSegs = pathInfo req
  -- Allow public routes
  if isPublicRoute method pathSegs
    then app req respond
    -- Allow admin routes with their own auth (checked at handler level)
    else case pathSegs of
      ("admin" : _) -> handleAuth db app req respond pathSegs method Nothing
      -- Allow auth routes that aren't login/verify (logout, me)
      ("auth" : _) -> handleAuth db app req respond pathSegs method Nothing
      _ -> case findRoutePermission method pathSegs of
        Nothing -> app req respond  -- Unknown routes pass through (will 404 via Servant)
        Just rp -> handleAuth db app req respond pathSegs method (Just rp)

handleAuth :: DBEnv -> (Request -> (Response -> IO a) -> IO a) -> Request -> (Response -> IO a) -> [Text] -> Text -> Maybe RoutePermission -> IO a
handleAuth db app req respond _pathSegs _method mRoutePermission = do
  let authHeader = lookup "Authorization" (requestHeaders req)
  case authHeader of
    Nothing -> respond $ jsonError 401 "Missing Authorization header"
    Just tokenBS -> do
      let token = T.strip $ case T.stripPrefix "Bearer " (TE.decodeUtf8 tokenBS) of
            Just t -> t
            Nothing -> TE.decodeUtf8 tokenBS
      mToken <- findTokenByValue db token
      case mToken of
        Nothing -> respond $ jsonError 401 "Invalid or expired token"
        Just tokenRow -> do
          now <- getCurrentTime
          if trExpiresAt tokenRow < now
            then respond $ jsonError 401 "Token expired"
            else do
              mPerson <- findPersonById db (trPersonId tokenRow)
              case mPerson of
                Nothing -> respond $ jsonError 401 "Person not found"
                Just person ->
                  if not (personIsActive person)
                    then respond $ jsonError 401 "Account deactivated"
                    else case mRoutePermission of
                      Nothing -> app req respond  -- No specific permission needed (auth/admin routes)
                      Just rp -> do
                        if personIsSuperadmin person
                          then app req respond  -- Superadmins bypass permission checks
                          else do
                            accesses <- findProductAccessForPerson db (personId person)
                            case find (\pa -> paProductSlug pa == rpProduct rp) accesses of
                              Nothing -> respond $ jsonError 403 ("No access to product: " <> rpProduct rp)
                              Just pa -> do
                                perms <- computeEffectivePermissions db person (paProductSlug pa) (paRoleId pa)
                                if rpPermission rp `elem` perms
                                  then app req respond
                                  else respond $ jsonError 403 ("Permission denied: " <> rpPermission rp)

jsonError :: Int -> Text -> Response
jsonError code msg =
  let status = if code == 401 then status401 else status403
      body = A.encode $ A.object ["error" A..= msg]
  in responseLBS status [(hContentType, "application/json")] body
