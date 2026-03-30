{-# LANGUAGE OverloadedStrings #-}

-- | Low-level kubectl command execution with retry and idempotency detection.
module NammaAP.Products.Autopilot.K8s.Execute
  ( K8sError (..)
  , K8sResult (..)
  , runCmd
  , executeWithRetry
  , isIdempotentSuccess
  , shellQuote
  , jsonToText
  , withKubectx
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BSL
import Data.Char (toLower)
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import NammaAP.Core.Config (Config (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data K8sError = K8sError Text deriving (Eq, Show)
data K8sResult = K8sResult Text deriving (Eq, Show)

jsonToText :: Value -> Text
jsonToText = TE.decodeUtf8 . BSL.toStrict . A.encode

withKubectx :: Text -> String -> String
withKubectx ctx cmd = "kubectx " <> T.unpack ctx <> " && " <> cmd

shellQuote :: Text -> String
shellQuote t = "'" <> T.unpack (T.replace "'" "'\"'\"'" t) <> "'"

runCmd :: String -> IO (Either K8sError K8sResult)
runCmd cmd = do
  res <- try (readProcessWithExitCode "sh" ["-c", cmd] "") :: IO (Either SomeException (ExitCode, String, String))
  case res of
    Left e -> pure (Left (K8sError (T.pack (show e))))
    Right (ExitSuccess, out, _) -> pure (Right (K8sResult (T.pack out)))
    Right (ExitFailure _, _, err) -> pure (Left (K8sError (T.pack err)))

executeWithRetry :: Config -> String -> IO (Either K8sError K8sResult)
executeWithRetry cfg cmd = go 1
  where
    go n = do
      res <- runCmd cmd
      case res of
        Right ok -> pure (Right ok)
        Left err ->
          if n >= maxK8sRetries cfg || isIdempotentSuccess err
            then
              if isIdempotentSuccess err
                then pure (Right (K8sResult "idempotent-success"))
                else pure (Left err)
            else do
              threadDelay (n * 1000000)
              go (n + 1)

isIdempotentSuccess :: K8sError -> Bool
isIdempotentSuccess (K8sError e) =
  any (`isInfixOf` lowerMsg) ["alreadyexists", "already exists", "unchanged", "configured"]
  where
    lowerMsg = map toLower (T.unpack e)
