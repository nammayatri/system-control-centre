{-# LANGUAGE OverloadedStrings #-}

-- | Low-level kubectl command execution with retry and idempotency detection.
module Products.Autopilot.K8s.Execute (
    K8sError (..),
    K8sResult (..),
    runCmd,
    executeWithRetry,
    isIdempotentSuccess,
    isConflictError,
    shellQuote,
    jsonToText,
    withKubectx,
)
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Core.Config (Config (..))
import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

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
    result <- timeout (300 * 1000000) $ try (readProcessWithExitCode "sh" ["-c", cmd] "") :: IO (Maybe (Either SomeException (ExitCode, String, String)))
    case result of
        Nothing -> pure (Left (K8sError "kubectl command timed out after 5 minutes"))
        Just (Left e) -> pure (Left (K8sError (T.pack (show e))))
        Just (Right (ExitSuccess, out, _)) -> pure (Right (K8sResult (T.pack out)))
        Just (Right (ExitFailure _, _, err)) -> pure (Left (K8sError (T.pack err)))

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
    let low = T.toLower e
     in any (`T.isInfixOf` low) ["alreadyexists", "already exists", "unchanged", "configured"]

-- | Detect K8s 409 Conflict error (resourceVersion mismatch during replace)
isConflictError :: K8sError -> Bool
isConflictError (K8sError e) =
    let low = T.toLower e
     in any (`T.isInfixOf` low) ["conflict", "the object has been modified", "please apply your changes to the latest version"]
