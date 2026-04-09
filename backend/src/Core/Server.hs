{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Core.Server where

import Control.Exception (SomeException, fromException, try)
import Control.Monad.Reader (runReaderT)
import Control.Monad.Trans.Except (ExceptT (..))
import Core.Admin.Routes (AdminAPI, adminServer)
import Core.AppError (AppException (..), ToAppError (..), errorResponseJSON)
import Core.Auth.Routes (AuthAPI, authServer)
import Core.Config (port)
import Core.Environment (AppState (..), Flow)
import Core.Logging (logErrorIO, logInfoIO)
import Core.Middleware.RequestId (requestIdMiddleware)
import Data.Text (Text)
import qualified Data.Text as T
import Network.Wai (requestHeaders)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors (
    CorsResourcePolicy (..),
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
    logInfoIO (loggerEnv st) "[startup] Phase 3: route permissions enforced at compile time via Protected combinator."
    run (port (config st)) (mkApp st)

serverContext :: AppState -> Context '[AppState]
serverContext st = st :. EmptyContext

mkApp :: AppState -> Application
mkApp st =
    requestIdMiddleware (loggerEnv st) $
        cors corsForRequest $
            serveWithContext fullApi (serverContext st) $
                hoistServerWithContext
                    fullApi
                    (Proxy :: Proxy '[AppState])
                    (toHandler st)
                    fullServer
  where
    corsForRequest req =
        let origin = lookup "Origin" (requestHeaders req)
         in Just $
                simpleCorsResourcePolicy
                    { corsOrigins = fmap (\o -> ([o], True)) origin
                    , corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
                    , corsRequestHeaders = ["Content-Type", "Authorization", "X-Forwarded-Email", "x-pomerium-jwt-assertion", "x-requested-with"]
                    }

fullServer :: ServerT FullAPI Flow
fullServer = authServer :<|> adminServer :<|> coreServer

{- | Global handler: catches all exceptions. 'AppException' dispatches
via 'toServantError'; anything else becomes a generic 500.
-}
toHandler :: AppState -> Flow a -> Handler a
toHandler st flow = Handler . ExceptT $ do
    result <- try (runReaderT flow st)
    case result of
        Right a -> pure (Right a)
        Left (ex :: SomeException) -> do
            logErrorIO (loggerEnv st) $ "[ERROR] " <> formatExceptionLog ex
            pure . Left $ exceptionToServantError ex

exceptionToServantError :: SomeException -> ServerError
exceptionToServantError ex
    | Just (AppException inner) <- fromException ex =
        toServantError inner
    | otherwise =
        ServerError
            500
            "Internal Server Error"
            (errorResponseJSON "ERROR" "INTERNAL_ERROR" (T.pack (show ex)) "UnhandledException")
            [("Content-Type", "application/json")]

formatExceptionLog :: SomeException -> Text
formatExceptionLog ex
    | Just (AppException inner) <- fromException ex =
        "[" <> toErrorTag inner <> ":" <> toErrorCode inner <> "] " <> toErrorMessage inner
    | otherwise =
        "[UnhandledException:INTERNAL_ERROR] " <> T.pack (show ex)
