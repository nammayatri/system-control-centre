{-# LANGUAGE OverloadedStrings #-}

{- | Secret values (private keys, service-account JSON, API keys) are read
from the process __environment__ — never from the database or any
client-facing surface. In production the env vars are injected from a k8s
Secret (@valueFrom.secretKeyRef@); in local dev they come from
@backend/dev/local-mobile-secrets.env@, sourced by the dev shell.

This keeps secrets out of @server_config@ (and therefore out of the
@GET \/server-config@ API and the frontend entirely).

Multi-line blobs (PEM private keys, JSON) are stored __base64-encoded__ so
each env var is a single line — robust across shells, @.env@ files, and k8s
manifests. Use 'lookupEnvSecretB64' for those and 'lookupEnvSecret' for plain
short values (ids).
-}
module Core.Secrets (
    lookupEnvSecret,
    lookupEnvSecretB64,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Environment (lookupEnv)

{- | Read a plain secret from the named env var. Trimmed; 'Nothing' when the
var is unset or blank.
-}
lookupEnvSecret :: (MonadIO m) => String -> m (Maybe Text)
lookupEnvSecret name = do
    mv <- liftIO (lookupEnv name)
    pure $ case T.strip . T.pack <$> mv of
        Just v | not (T.null v) -> Just v
        _ -> Nothing

{- | Read a base64-encoded secret from the named env var and decode it to text.
Use for multi-line blobs (PEM keys, JSON) kept single-line as base64.
'Nothing' when the var is unset/blank or the value is not valid base64/UTF-8.
-}
lookupEnvSecretB64 :: (MonadIO m) => String -> m (Maybe Text)
lookupEnvSecretB64 name = do
    mRaw <- lookupEnvSecret name
    pure (mRaw >>= decode)
  where
    decode b64 = case B64.decode (TE.encodeUtf8 b64) of
        Right bs -> either (const Nothing) Just (TE.decodeUtf8' bs)
        Left _ -> Nothing
