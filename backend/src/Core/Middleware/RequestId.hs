module Core.Middleware.RequestId (requestIdMiddleware) where

import Core.Logging (LoggerEnv, logInfoIO)
import qualified Data.ByteString.Char8 as BS8
import Data.CaseInsensitive (mk)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID4
import Network.Wai (Middleware, mapResponseHeaders, rawPathInfo, requestHeaders, requestMethod)

requestIdMiddleware :: LoggerEnv -> Middleware
requestIdMiddleware logEnv app req respond = do
  reqId <- case lookup (mk "X-Request-Id") (requestHeaders req) of
    Just existing -> pure (BS8.unpack existing)
    Nothing -> do
      uuid <- UUID4.nextRandom
      pure (UUID.toString uuid)
  let reqIdBS = BS8.pack reqId
      method = BS8.unpack (requestMethod req)
      path = BS8.unpack (rawPathInfo req)
      addHeader = mapResponseHeaders ((mk "X-Request-Id", reqIdBS) :)
  app req $ \response -> do
    let tagged = addHeader response
    logInfoIO logEnv $
      T.pack $
        "[req-" <> reqId <> "] " <> method <> " " <> path
    respond tagged
