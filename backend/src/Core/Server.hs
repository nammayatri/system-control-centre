{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Core.Server where

import Control.Monad.Reader (runReaderT)
import Control.Monad.Trans.Except (ExceptT (..))
import Core.Admin.Routes (AdminAPI, adminServer)
import Core.Auth.Middleware (authMiddleware, findRoutePermission, isPublicRoute, knownDynamicRoutes)
import Core.Auth.RouteCheck (HasRoutes, findUnmappedRoutes, formatRoute, listRoutes)
import Core.Auth.Routes (AuthAPI, authServer)
import Core.Config (port)
import Core.Environment (AppState (..))
import Core.Utils.FlowMonad (Flow)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import Network.Wai (Application, requestHeaders)
import Network.Wai.Handler.Warp (run)
import System.Exit (exitFailure)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy,
  )
import Products.Autopilot.Routes (CoreAPI, coreServer)
import Products.Registry (ProductPermission (..), allProductPermissions)
import Servant

type FullAPI = "auth" :> AuthAPI :<|> "admin" :> AdminAPI :<|> CoreAPI

fullApi :: Proxy FullAPI
fullApi = Proxy

serverLoop :: AppState -> IO ()
serverLoop st = do
  -- Phase 2: hard-fail on any route that has no permission mapping.
  -- Missing mapping = a route that passes auth with no RBAC check — a security
  -- hole. We refuse to start the server so a broken wiring cannot ship.
  assertAllRoutesMapped fullApi
  -- Self-test: the two sides of route→permission matching must agree.
  -- 'RouteCheck' emits Capture segments as literal ":name" while
  -- 'findRoutePermission' uses wildcard '_' / prefix matching. This check
  -- proves the two conventions actually interoperate, so the Phase 2 check
  -- above can never silently pass because of a pattern-convention drift.
  assertRouteLookupSelfTest
  run (port (config st)) (mkApp st)

-- | Startup assertion: every API route must resolve to a permission (or fall
-- into the public / @admin/@ / @auth/@ scopes that the middleware handles
-- without a product permission). If any route is unmapped, print the full
-- list and @exitFailure@ — the server will not start.
assertAllRoutesMapped :: HasRoutes api => Proxy api -> IO ()
assertAllRoutesMapped p = do
  let allRoutes = listRoutes p
      unmapped = findUnmappedRoutes isRouteMapped allRoutes
  if null unmapped
    then TIO.putStrLn "[startup] All API routes have a permission mapping. ✓"
    else do
      TIO.putStrLn "[startup] FATAL: the following routes have NO permission mapping:"
      mapM_ (\r -> TIO.putStrLn ("  - " <> formatRoute r)) unmapped
      TIO.putStrLn "[startup] Refusing to start: every API route must be mapped in Core.Auth.Middleware.findRoutePermission."
      exitFailure

-- | Does the given route resolve to a permission, OR fall into a scope that
-- the middleware handles without a product permission (public, admin, auth)?
isRouteMapped :: Text -> [Text] -> Bool
isRouteMapped method pathSegs
  | isPublicRoute method pathSegs = True
  | isAdminOrAuthScope pathSegs = True
  | otherwise = isJust (findRoutePermission method pathSegs)
  where
    isAdminOrAuthScope ("admin" : _) = True
    isAdminOrAuthScope ("auth" : _) = True
    isAdminOrAuthScope _ = False

-- | Self-test: feed every explicitly-listed mapping (from
-- 'knownDynamicRoutes' and 'allProductPermissions') through 'isRouteMapped'
-- and assert they all resolve. Catches divergence between the @:name@ Capture
-- convention used by 'Core.Auth.RouteCheck' and the @_@ wildcard / prefix
-- convention used by 'Core.Auth.Middleware.findRoutePermission'.
assertRouteLookupSelfTest :: IO ()
assertRouteLookupSelfTest = do
  let dynamicChecks = knownDynamicRoutes
      registryChecks = map (\pp -> (ppMethod pp, ppPathSegments pp)) allProductPermissions
      allChecks = dynamicChecks <> registryChecks
      failures = filter (\(m, ps) -> not (isRouteMapped m ps)) allChecks
  if null failures
    then TIO.putStrLn "[startup] Route lookup self-test passed. ✓"
    else do
      TIO.putStrLn "[startup] FATAL: the following known-mapped routes failed isRouteMapped:"
      mapM_ (\r -> TIO.putStrLn ("  - " <> formatRoute r)) failures
      TIO.putStrLn "[startup] findRoutePermission and isRouteMapped disagree — a mapping table is out of sync with the lookup logic."
      exitFailure

mkApp :: AppState -> Application
mkApp st =
  cors corsForRequest $
    authMiddleware (dbEnv st) $
      serve fullApi $
        hoistServer fullApi (toHandler st) fullServer
  where
    corsForRequest req =
      let origin = lookup "Origin" (requestHeaders req)
       in Just $
            simpleCorsResourcePolicy
              { corsOrigins = fmap (\o -> ([o], True)) origin,
                corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
                corsRequestHeaders = ["Content-Type", "Authorization", "X-Forwarded-Email", "x-pomerium-jwt-assertion", "x-requested-with"]
              }

fullServer :: ServerT FullAPI Flow
fullServer = authServer :<|> adminServer :<|> coreServer

toHandler :: AppState -> Flow a -> Handler a
toHandler st flow = Handler $ ExceptT $ Right <$> runReaderT flow st
