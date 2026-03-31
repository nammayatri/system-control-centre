{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Core.Auth.Middleware (
    authMiddleware,
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
    [ ("POST", ["auth", "login"])
    , ("POST", ["auth", "verify"])
    , ("GET", ["health"])
    ]

isPublicRoute :: Text -> [Text] -> Bool
isPublicRoute method pathSegs =
    any (\(m, p) -> m == method && p `isPrefixOf` pathSegs) publicRoutes

{- | Find the required permission for a given request.
First checks dynamic path patterns (e.g., /releases/:id/approve),
then falls back to prefix match from the product registry.
-}
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
            ("POST", ["releases", _, "restart"]) -> Just $ mkPP "RELEASE_CREATE" "autopilot"
            ("POST", ["releases", _, "fast-forward"]) -> Just $ mkPP "RELEASE_UPDATE" "autopilot"
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

{- | WAI middleware that enforces RBAC on all routes.
Flow: extract token → validate → check permission → allow/deny
-}
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
            -- All other routes: validate token + check product permission
            _ -> case findRoutePermission method pathSegs of
                Nothing -> app req respond -- Unknown routes pass through (will 404 via Servant)
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
