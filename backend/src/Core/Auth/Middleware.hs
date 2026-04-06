{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Auth.Middleware
  ( authMiddleware,
    findRoutePermission,
    isPublicRoute,
    knownDynamicRoutes,
  )
where

import Core.Auth.Queries
import Core.Auth.Types (PersonAuth (..), ProductAccess (..))
import Core.Environment (DBEnv)
import qualified Data.Aeson as A
import Data.List (find, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import Network.HTTP.Types (hContentType, status401, status403)
import Network.Wai (Middleware, Request (..), Response, responseLBS)
import Products.Registry (ProductPermission (..), allProductPermissions)

-- | Public routes that do not require authentication
publicRoutes :: [(Text, [Text])]
publicRoutes =
  [ ("POST", ["auth", "login"]),
    ("POST", ["auth", "verify"]),
    ("GET", ["health"])
  ]

isPublicRoute :: Text -> [Text] -> Bool
isPublicRoute method pathSegs =
  any (\(m, p) -> m == method && p `isPrefixOf` pathSegs) publicRoutes

-- | Find the required permission for a given request.
-- First checks dynamic path patterns (e.g., /releases/:id/approve),
-- then falls back to prefix match from the product registry.
findRoutePermission :: Text -> [Text] -> Maybe ProductPermission
findRoutePermission method pathSegs =
  -- Dynamic path patterns (routes with path parameters)
  let dynamicMatch = case (method, pathSegs) of
        -- Release actions
        ("GET", ["releases", _, "events"]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("GET", ["releases", _]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("POST", ["releases", _, "approve"]) -> Just $ mkPP "RELEASE_APPROVE" "autopilot"
        ("POST", ["releases", _, "rollback"]) -> Just $ mkPP "RELEASE_REVERT" "autopilot"
        ("POST", ["releases", _, "revert"]) -> Just $ mkPP "RELEASE_REVERT" "autopilot"
        ("POST", ["releases", _, "discard"]) -> Just $ mkPP "RELEASE_DISCARD" "autopilot"
        ("POST", ["releases", _, "delete"]) -> Just $ mkPP "RELEASE_DELETE" "autopilot"
        ("POST", ["releases", _, "update"]) -> Just $ mkPP "RELEASE_UPDATE" "autopilot"
        ("POST", ["releases", _, "trigger"]) -> Just $ mkPP "RELEASE_CREATE" "autopilot"
        -- Diff, pods, immediate revert, restart, fast-forward
        ("GET", ["releases", _, "diff"]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("GET", ["releases", _, "pods", "health"]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("POST", ["releases", _, "revert", "immediate"]) -> Just $ mkPP "RELEASE_REVERT" "autopilot"
        -- Cross-cluster revert by global_id (sync endpoints) — specific before general
        ("PUT", ["release", "revert", "immediate", "global", _]) -> Just $ mkPP "RELEASE_REVERT" "autopilot"
        ("PUT", ["release", "revert", "global", _]) -> Just $ mkPP "RELEASE_REVERT" "autopilot"
        ("POST", ["releases", _, "restart"]) -> Just $ mkPP "RELEASE_CREATE" "autopilot"
        ("POST", ["releases", _, "fast-forward"]) -> Just $ mkPP "RELEASE_UPDATE" "autopilot"
        ("GET", ["releases", _, "rollout-history"]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("GET", ["releases", _, "logslink"]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("DELETE", ["server-config", _]) -> Just $ mkPP "SERVICE_CONFIG_EDIT" "autopilot"
        -- Product services
        ("GET", ("products" : _ : "services" : _)) -> Just $ mkPP "PRODUCT_CONFIG_VIEW" "autopilot"
        -- Envs
        ("GET", ("envs" : "secondary" : _)) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        -- ConfigMap secondary
        ("GET", ("configmap" : "secondary" : _)) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        -- ConfigMap tracker with ID
        ("GET", ["tracker", "configmap", _]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("PUT", ["tracker", "configmap", _]) -> Just $ mkPP "RELEASE_UPDATE" "autopilot"
        -- Product Config CRUD with ID
        ("GET", ["products", "config", _]) -> Just $ mkPP "PRODUCT_CONFIG_VIEW" "autopilot"
        ("PUT", ["products", "config", _]) -> Just $ mkPP "PRODUCT_CONFIG_EDIT" "autopilot"
        ("DELETE", ["products", "config", _]) -> Just $ mkPP "PRODUCT_CONFIG_EDIT" "autopilot"
        -- Release Config CRUD with ID
        ("GET", ["services", "config", _]) -> Just $ mkPP "PRODUCT_CONFIG_VIEW" "autopilot"
        ("PUT", ["services", "config", _]) -> Just $ mkPP "PRODUCT_CONFIG_EDIT" "autopilot"
        ("DELETE", ["services", "config", _]) -> Just $ mkPP "PRODUCT_CONFIG_EDIT" "autopilot"
        -- VS Edit Tracker static paths (force-unlock MUST come before
        -- the generic ["vs-edit-tracker", _] capture, otherwise the wildcard
        -- claims it as a GET/PUT-by-id match and permission resolution is wrong)
        ("POST", ["vs-edit-tracker", "force-unlock"]) -> Just $ mkPP "FORCE_UNLOCK" "autopilot"
        -- VS Edit Tracker with ID
        ("GET", ["vs-edit-tracker", _]) -> Just $ mkPP "RELEASE_VIEW" "autopilot"
        ("PUT", ["vs-edit-tracker", _]) -> Just $ mkPP "RELEASE_UPDATE" "autopilot"
        ("PUT", ["vs-edit-tracker", "revert", _]) -> Just $ mkPP "RELEASE_REVERT" "autopilot"
        _ -> Nothing
   in case dynamicMatch of
        Just pp -> Just pp
        -- Fall back to prefix match from product registry
        Nothing -> find (\pp -> ppMethod pp == method && ppPathSegments pp `isPrefixOf` pathSegs) allProductPermissions
  where
    mkPP perm prod = ProductPermission method [] perm prod

-- | Representative inputs for every dynamic case in 'findRoutePermission',
-- with @":id"@ placeholders in Capture positions. Used by the startup
-- self-test in 'Core.Server' to verify that the lookup function agrees with
-- the shape 'Core.Auth.RouteCheck' emits from Servant API types (Capture as
-- @":name"@). If you add a case to 'findRoutePermission', add a mirror entry
-- here so the self-test keeps covering it.
knownDynamicRoutes :: [(Text, [Text])]
knownDynamicRoutes =
  [ ("GET", ["releases", ":id", "events"]),
    ("GET", ["releases", ":id"]),
    ("POST", ["releases", ":id", "approve"]),
    ("POST", ["releases", ":id", "rollback"]),
    ("POST", ["releases", ":id", "revert"]),
    ("POST", ["releases", ":id", "discard"]),
    ("POST", ["releases", ":id", "delete"]),
    ("POST", ["releases", ":id", "update"]),
    ("POST", ["releases", ":id", "trigger"]),
    ("GET", ["releases", ":id", "diff"]),
    ("GET", ["releases", ":id", "pods", "health"]),
    ("POST", ["releases", ":id", "revert", "immediate"]),
    ("PUT", ["release", "revert", "immediate", "global", ":globalId"]),
    ("PUT", ["release", "revert", "global", ":globalId"]),
    ("POST", ["releases", ":id", "restart"]),
    ("POST", ["releases", ":id", "fast-forward"]),
    ("GET", ["releases", ":id", "rollout-history"]),
    ("GET", ["releases", ":id", "logslink"]),
    ("DELETE", ["server-config", ":id"]),
    ("GET", ["products", ":product", "services", ":service"]),
    ("GET", ["envs", "secondary", ":anything"]),
    ("GET", ["configmap", "secondary", ":anything"]),
    ("GET", ["tracker", "configmap", ":id"]),
    ("PUT", ["tracker", "configmap", ":id"]),
    ("GET", ["products", "config", ":id"]),
    ("PUT", ["products", "config", ":id"]),
    ("DELETE", ["products", "config", ":id"]),
    ("GET", ["services", "config", ":id"]),
    ("PUT", ["services", "config", ":id"]),
    ("DELETE", ["services", "config", ":id"]),
    ("GET", ["vs-edit-tracker", ":id"]),
    ("PUT", ["vs-edit-tracker", ":id"]),
    ("PUT", ["vs-edit-tracker", "revert", ":id"]),
    ("POST", ["vs-edit-tracker", "force-unlock"])
  ]

-- | WAI middleware that enforces RBAC on all routes.
-- Flow: extract token → validate → check permission → allow/deny
authMiddleware :: DBEnv -> Middleware
authMiddleware db app req respond = do
  let method = TE.decodeUtf8 (requestMethod req)
      pathSegs = pathInfo req
  -- Public routes bypass auth entirely
  if isPublicRoute method pathSegs
    then app req respond
    else case pathSegs of
      -- Admin routes: validate token (superadmin check is in handler)
      ("admin" : _) -> handleAuth db app req respond Nothing
      -- Auth routes (logout, me): validate token only
      ("auth" : _) -> handleAuth db app req respond Nothing
      -- All other routes: validate token + check product permission.
      -- Fallback is DENY (403) — a missing mapping is a security bug, not a free pass.
      _ -> case findRoutePermission method pathSegs of
        Nothing ->
          respond $
            jsonError 403 ("No permission mapping for route: " <> method <> " /" <> T.intercalate "/" pathSegs)
        Just pp -> handleAuth db app req respond (Just pp)

-- | Core auth handler: validates token, optionally checks permission
handleAuth ::
  DBEnv ->
  (Request -> (Response -> IO a) -> IO a) ->
  Request ->
  (Response -> IO a) ->
  Maybe ProductPermission ->
  IO a
handleAuth db app req respond mPermission = do
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
                Just person
                  | not (personIsActive person) ->
                    respond $ jsonError 401 "Account deactivated"
                  | Nothing <- mPermission ->
                    app req respond -- Token valid, no specific permission needed
                  | Just pp <- mPermission ->
                    if personIsSuperadmin person
                      then app req respond -- Superadmins bypass permission checks
                      else checkProductPermission db app req respond person pp

-- | Check if person has the required permission for the product
checkProductPermission ::
  DBEnv ->
  (Request -> (Response -> IO a) -> IO a) ->
  Request ->
  (Response -> IO a) ->
  PersonAuth ->
  ProductPermission ->
  IO a
checkProductPermission db app req respond person pp = do
  accesses <- findProductAccessForPerson db (personId person)
  case find (\pa -> paProductSlug pa == ppProduct pp) accesses of
    Nothing -> respond $ jsonError 403 ("No access to product: " <> ppProduct pp)
    Just pa -> do
      perms <- computeEffectivePermissions db person (paProductSlug pa) (paRoleId pa)
      if ppPermission pp `elem` perms
        then app req respond
        else respond $ jsonError 403 ("Permission denied: " <> ppPermission pp)

-- | JSON error response helper
jsonError :: Int -> Text -> Response
jsonError code msg =
  let status = if code == 401 then status401 else status403
      body = A.encode $ A.object ["error" A..= msg]
   in responseLBS status [(hContentType, "application/json")] body
