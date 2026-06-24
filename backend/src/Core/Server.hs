{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

module Core.Server where

import Control.Applicative ((<|>))
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
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as AK
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.Wai (requestHeaders)
import Network.Wai.Handler.Warp (run)
import Network.Wai.Middleware.Cors
  ( CorsResourcePolicy (..),
    cors,
    simpleCorsResourcePolicy,
  )
import Products.Autopilot.Routes (CoreAPI, coreServer)
import Servant

type FullAPI =
  "auth" :> AuthAPI
    :<|> "admin" :> AdminAPI
    :<|> "pomerium-email"
      :> Header "X-Forwarded-Email" Text
      :> Header "x-pomerium-jwt-assertion" Text
      :> Get '[JSON] Value
    :<|> CoreAPI

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
              { corsOrigins = fmap (\o -> ([o], True)) origin,
                corsMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
                corsRequestHeaders = ["Content-Type", "Authorization", "X-Forwarded-Email", "x-pomerium-jwt-assertion", "x-requested-with"]
              }

fullServer :: ServerT FullAPI Flow
fullServer = authServer :<|> adminServer :<|> pomeriumEmailH :<|> coreServer

pomeriumEmailH :: Maybe Text -> Maybe Text -> Flow Value
pomeriumEmailH mXFE mJwt =
  let fromHeader = nonEmpty mXFE
      fromJwt = mJwt >>= extractEmailFromJwt
      email = fromHeader <|> fromJwt
   in pure $ object ["email" .= email]

nonEmpty :: Maybe Text -> Maybe Text
nonEmpty (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
nonEmpty _ = Nothing

extractEmailFromJwt :: Text -> Maybe Text
extractEmailFromJwt jwt =
  case T.splitOn "." jwt of
    (_ : payload : _) ->
      let decoded = B64.decodeLenient (TE.encodeUtf8 (padBase64 payload))
       in case A.decode (LBS.fromStrict decoded) of
            Just (A.Object obj) ->
              case KM.lookup (AK.fromText "email") obj of
                Just (A.String e) | not (T.null (T.strip e)) -> Just (T.strip e)
                _ -> Nothing
            _ -> Nothing
    _ -> Nothing

padBase64 :: Text -> Text
padBase64 t =
  let m = T.length t `mod` 4
   in if m == 0 then t else t <> T.replicate (4 - m) "="

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
