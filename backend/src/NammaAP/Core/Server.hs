{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module NammaAP.Core.Server where

import Control.Monad.Trans.Except (ExceptT (..))
import Control.Monad.Reader (runReaderT)
import Network.Wai (Application, requestHeaders)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy
  )
import NammaAP.Products.Autopilot.Routes (CoreAPI, coreServer)
import NammaAP.Core.Auth.Routes (AuthAPI, authServer)
import NammaAP.Core.Auth.Middleware (authMiddleware)
import NammaAP.Core.Admin.Routes (AdminAPI, adminServer)
import NammaAP.Core.Environment (AppState (..))
import NammaAP.Core.Config (port)
import NammaAP.Core.Utils.FlowMonad (Flow)
import Servant

type FullAPI = "auth" :> AuthAPI :<|> "admin" :> AdminAPI :<|> CoreAPI

fullApi :: Proxy FullAPI
fullApi = Proxy

serverLoop :: AppState -> IO ()
serverLoop st = run (port (config st)) (mkApp st)

mkApp :: AppState -> Application
mkApp st =
  cors corsForRequest
    $ authMiddleware (dbEnv st)
    $ serve fullApi
    $ hoistServer fullApi (toHandler st) fullServer
  where
    corsForRequest req =
      let origin = lookup "Origin" (requestHeaders req)
      in Just $ simpleCorsResourcePolicy
        { corsOrigins = fmap (\o -> ([o], True)) origin,
          corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
          corsRequestHeaders = ["Content-Type", "Authorization", "X-Forwarded-Email", "x-pomerium-jwt-assertion", "x-requested-with"]
        }

fullServer :: ServerT FullAPI Flow
fullServer = authServer :<|> adminServer :<|> coreServer

toHandler :: AppState -> Flow a -> Handler a
toHandler st flow = Handler $ ExceptT $ Right <$> runReaderT flow st
