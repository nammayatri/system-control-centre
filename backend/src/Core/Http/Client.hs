{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Pooled HTTP client used by every product for outbound calls.

== Why this exists

Before this module, every external call (Slack, Prometheus, AB engine,
HS engine, sync cluster, ConfigMap proxy) was implemented as a separate
copy of:

@
result <- try (readProcessWithExitCode \"curl\" curlArgs \"\")
case result of
  Right (ExitSuccess, out, _) -&gt; ...
  Right (ExitFailure _, _, err) -&gt; ...
  Left e -&gt; ...
-- + manual retry on the next 30 lines
@

…each spawning a new @curl@ subprocess, with no connection pooling and
hand-rolled retry that drifted between modules.

This module replaces all of that with a single 'httpJson' / 'httpRaw'
call that:

  * uses a process-wide pooled @http-client@ Manager (TLS reused across calls)
  * supports retry with linear backoff
  * has a configurable timeout
  * logs every request via 'Core.Logging.logInfoG' (auto-includes 'withLogTag' context)

Multiple products can use it without any product-specific glue.
-}
module Core.Http.Client (
    -- * Request DSL
    HttpReq (..),
    Method (..),
    defaultReq,

    -- * Response
    HttpError (..),
    HttpResponse (..),

    -- * Calls
    httpJson,
    httpRaw,

    -- * Manager lifecycle (called from Main)
    initHttpManager,
)
where

import qualified Control.Concurrent as Conc
import Control.Exception (SomeException, try)
import Core.Logging (logErrorG, logInfoG)
import Core.Types.Time (Seconds (..), toMicros)
import Data.Aeson (FromJSON, eitherDecode)
import qualified Data.ByteString.Lazy as LBS
import Data.CaseInsensitive (mk)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.HTTP.Client (
    HttpException,
    Manager,
    Request (..),
    RequestBody (RequestBodyLBS),
    Response (..),
    httpLbs,
    newManager,
    parseRequest,
    responseTimeoutMicro,
 )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import System.IO.Unsafe (unsafePerformIO)

-- ── Request DSL ──────────────────────────────────────────────────

data Method = GET | POST | PUT | DELETE | PATCH
    deriving (Show, Eq)

methodBS :: Method -> LBS.ByteString
methodBS GET = "GET"
methodBS POST = "POST"
methodBS PUT = "PUT"
methodBS DELETE = "DELETE"
methodBS PATCH = "PATCH"

-- | A single HTTP request. Build with 'defaultReq' and override fields.
data HttpReq = HttpReq
    { reqMethod :: Method
    , reqUrl :: Text
    , reqHeaders :: [(Text, Text)]
    , reqBody :: Maybe LBS.ByteString
    , reqTimeout :: Seconds
    -- ^ Total request timeout. Default: 30s.
    , reqRetries :: Int
    -- ^ Number of retries on failure (excluding the first attempt). Default: 1.
    , reqLogTag :: Text
    -- ^ Short tag for log lines (e.g. "slack", "prometheus"). Default: "http".
    }

-- | Default request: GET, no headers, 30s timeout, 1 retry.
defaultReq :: Text -> HttpReq
defaultReq url =
    HttpReq
        { reqMethod = GET
        , reqUrl = url
        , reqHeaders = []
        , reqBody = Nothing
        , reqTimeout = Seconds 30
        , reqRetries = 1
        , reqLogTag = "http"
        }

-- ── Response ─────────────────────────────────────────────────────

data HttpResponse = HttpResponse
    { respStatus :: Int
    , respBody :: LBS.ByteString
    }
    deriving (Show)

data HttpError
    = HttpExceptionError Text
    | HttpStatusError Int LBS.ByteString
    | HttpDecodeError String
    deriving (Show)

-- ── Manager (process-wide singleton) ─────────────────────────────

{-# NOINLINE managerRef #-}
managerRef :: IORef (Maybe Manager)
managerRef = unsafePerformIO (newIORef Nothing)

{- | Initialise the shared TLS-enabled HTTP manager. Call once from Main.
If not called, 'getManager' will create one on first use (lazy fallback).
-}
initHttpManager :: IO ()
initHttpManager = do
    mgr <- newManager tlsManagerSettings
    writeIORef managerRef (Just mgr)

getManager :: IO Manager
getManager = do
    m <- readIORef managerRef
    case m of
        Just mgr -> pure mgr
        Nothing -> do
            mgr <- newManager tlsManagerSettings
            writeIORef managerRef (Just mgr)
            pure mgr

-- ── Calls ────────────────────────────────────────────────────────

{- | Make an HTTP call and return the raw response (status + body).
Retries on network exceptions and 5xx responses with linear 0.5s backoff.
-}
httpRaw :: HttpReq -> IO (Either HttpError HttpResponse)
httpRaw req = go (reqRetries req)
  where
    go attempts = do
        result <- doOne req
        case result of
            Right r | respStatus r < 500 -> pure (Right r)
            _ | attempts <= 0 -> pure result
            _ -> do
                logErrorG $
                    "["
                        <> reqLogTag req
                        <> "] retry "
                        <> T.pack (show (reqRetries req - attempts + 1))
                        <> "/"
                        <> T.pack (show (reqRetries req))
                Conc.threadDelay 500_000 -- 0.5s linear backoff
                go (attempts - 1)

doOne :: HttpReq -> IO (Either HttpError HttpResponse)
doOne HttpReq{..} = do
    logInfoG $ "[" <> reqLogTag <> "] " <> T.pack (show reqMethod) <> " " <> reqUrl
    mgr <- getManager
    parseResult <- try (parseRequest (T.unpack reqUrl)) :: IO (Either SomeException Request)
    case parseResult of
        Left e -> pure (Left (HttpExceptionError (T.pack (show e))))
        Right baseReq -> do
            let req =
                    baseReq
                        { method = LBS.toStrict (methodBS reqMethod)
                        , requestHeaders =
                            map (\(k, v) -> (mk (TE.encodeUtf8 k), TE.encodeUtf8 v)) reqHeaders
                        , requestBody = maybe (RequestBodyLBS "") RequestBodyLBS reqBody
                        , responseTimeout = responseTimeoutMicro (toMicros reqTimeout)
                        }
            result <- try (httpLbs req mgr) :: IO (Either HttpException (Response LBS.ByteString))
            case result of
                Left e -> do
                    logErrorG $ "[" <> reqLogTag <> "] exception: " <> T.pack (show e)
                    pure (Left (HttpExceptionError (T.pack (show e))))
                Right r ->
                    pure $
                        Right
                            HttpResponse
                                { respStatus = statusCode (responseStatus r)
                                , respBody = responseBody r
                                }

{- | Make an HTTP call expecting a JSON response. Decodes the body to @a@.

@
result <- httpJson @SyncResp $ (defaultReq url)
  { reqMethod  = POST
  , reqHeaders = [(\"Authorization\", \"Bearer \" <> token)]
  , reqBody    = Just (encode body)
  , reqLogTag  = \"sync\"
  }
@
-}
httpJson :: (FromJSON a) => HttpReq -> IO (Either HttpError a)
httpJson req = do
    raw <- httpRaw req
    pure $ case raw of
        Left e -> Left e
        Right HttpResponse{respStatus = s, respBody = b}
            | s >= 400 -> Left (HttpStatusError s b)
            | otherwise -> case eitherDecode b of
                Left err -> Left (HttpDecodeError err)
                Right v -> Right v
