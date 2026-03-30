module NammaAP.Server where

import Control.Monad.Trans.Except (ExceptT (..))
import Control.Monad.Reader (runReaderT)
import Network.Wai (Application)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy
  )
import NammaAP.App.Routes.Core (CoreAPI, coreServer)
import NammaAP.Auth.Routes (AuthAPI, authServer)
import NammaAP.Auth.Middleware (authMiddleware)
import NammaAP.Admin.Routes (AdminAPI, adminServer)
import NammaAP.Environment (AppState (..))
import NammaAP.Config (port)
import NammaAP.Utils.FlowMonad (Flow)
import Servant

type FullAPI = "auth" :> AuthAPI :<|> "admin" :> AdminAPI :<|> CoreAPI

fullApi :: Proxy FullAPI
fullApi = Proxy

serverLoop :: AppState -> IO ()
serverLoop st = run (port (config st)) (mkApp st)

mkApp :: AppState -> Application
mkApp st =
  cors (const (Just corsPolicy))
    $ authMiddleware (dbEnv st)
    $ serve fullApi
    $ hoistServer fullApi (toHandler st) fullServer

fullServer :: ServerT FullAPI Flow
fullServer = authServer :<|> adminServer :<|> coreServer

corsPolicy :: CorsResourcePolicy
corsPolicy =
  simpleCorsResourcePolicy
    { corsOrigins = Nothing,
      corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
      corsRequestHeaders = ["Content-Type", "Authorization", "X-Forwarded-Email", "x-pomerium-jwt-assertion", "x-requested-with"]
    }

toHandler :: AppState -> Flow a -> Handler a
toHandler st flow = Handler $ ExceptT $ Right <$> runReaderT flow st
