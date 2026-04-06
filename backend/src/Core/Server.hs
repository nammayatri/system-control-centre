{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Core.Server where

import Control.Exception (SomeException, fromException, try)
import Control.Monad.Reader (runReaderT)
import Control.Monad.Trans.Except (ExceptT (..))
import Core.Admin.Routes (AdminAPI, adminServer)
import Core.AppError (AppException (..))
import Core.Auth.Routes (AuthAPI, authServer)
import Core.Config (port)
import Core.Environment (AppState (..), DBEnv)
import Core.Logging (logErrorIO, logInfoIO)
import Core.Utils.FlowMonad (Flow)
import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import qualified Data.Text as T
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
  logInfoIO (loggerEnv st) "[startup] Phase 3: route permissions enforced at compile time via Protected combinator."
  run (port (config st)) (mkApp st)

-- | The Servant 'Context' threaded through 'serveWithContext'.
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

-- | Global error handler. Catches all exceptions from handlers and
-- converts them to structured JSON responses.
--
-- Exception hierarchy:
--   * 'AppException' → typed error with correct HTTP status + JSON body
--   * 'APIError' (via AppException) → 400/403/404/409/422/500
--   * 'DBError' (via AppException) → 500 with context
--   * 'WorkflowError' (via AppException) → 500 with step info
--   * Any other exception → generic 500 with "INTERNAL_ERROR"
--
-- NammaYatri does this in @withFlowHandlerAPI@ + @apiHandler@ across
-- multiple modules. Ours is a single function.
toHandler :: AppState -> Flow a -> Handler a
toHandler st flow = Handler . ExceptT $ do
  result <- try (runReaderT flow st)
  case result of
    Right a -> pure (Right a)
    Left ex -> do
      -- Log the error
      logErrorIO (loggerEnv st) $ "[ERROR] " <> T.pack (show ex)
      -- Convert to structured Servant error
      pure . Left $ exceptionToServantError ex

exceptionToServantError :: SomeException -> ServerError
exceptionToServantError ex
  -- Our typed exception hierarchy: AppException carries ToAppError constraint
  | Just (AppException inner) <- fromException ex = toServantError inner
  -- Anything else: generic 500
  | otherwise = generic500 (T.pack (show ex))

generic500 :: Text -> ServerError
generic500 msg =
  ServerError
    500
    "Internal Server Error"
    ( encode $
        object
          [ "status" .= ("ERROR" :: Text),
            "code" .= ("INTERNAL_ERROR" :: Text),
            "message" .= msg
          ]
    )
    [("Content-Type", "application/json")]
