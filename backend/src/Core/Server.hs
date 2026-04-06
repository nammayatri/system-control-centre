{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Core.Server where

import Control.Monad.Reader (runReaderT)
import Control.Monad.Trans.Except (ExceptT (..))
import Core.Admin.Routes (AdminAPI, adminServer)
import Core.Auth.Routes (AuthAPI, authServer)
import Core.Config (port)
import Core.Environment (AppState (..), DBEnv)
import Core.Utils.FlowMonad (Flow)
import qualified Data.Text.IO as TIO
import Network.Wai (requestHeaders)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy,
  )
import Products.Autopilot.Routes (CoreAPI, coreServer)
import Servant

type FullAPI = "auth" :> AuthAPI :<|> "admin" :> AdminAPI :<|> CoreAPI

fullApi :: Proxy FullAPI
fullApi = Proxy

serverLoop :: AppState -> IO ()
serverLoop st = do
  -- Phase 3: every product route carries its required permission as a
  -- 'Protected perm' combinator in the Servant API type. The 'HasServer'
  -- instance in 'Core.Auth.Protected' validates the bearer token and the
  -- required permission before the handler runs, and a missing mapping is
  -- impossible by construction — a handler that forgets its permission
  -- annotation would fail to typecheck because 'ServerT' would demand an
  -- 'AuthedPerson' argument the handler does not accept. No runtime route
  -- walker or startup assertion is required any more.
  TIO.putStrLn "[startup] Phase 3: route permissions enforced at compile time via Protected combinator."
  run (port (config st)) (mkApp st)

-- | The Servant 'Context' threaded through 'serveWithContext'.
--
-- 'Core.Auth.Protected' reads the 'DBEnv' out of the context via
-- 'HasContextEntry' so the permission check can query
-- @sc_registration_token@ / @sc_person@ / @sc_person_product_access@.
-- Admin + Auth routes do not touch the context — they validate their own
-- tokens inside each handler — but the 'DBEnv' entry must still be present
-- because all three sub-APIs are served through the same context.
serverContext :: AppState -> Context '[DBEnv]
serverContext st = dbEnv st :. EmptyContext

mkApp :: AppState -> Application
mkApp st =
  cors corsForRequest $
    serveWithContext fullApi (serverContext st) $
      hoistServerWithContext
        fullApi
        (Proxy :: Proxy '[DBEnv])
        (toHandler st)
        fullServer
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
