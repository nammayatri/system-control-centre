{-# LANGUAGE OverloadedStrings #-}

-- | The only place the HPA scheduler talks to the cluster.
--
-- Differences from the older shell-string helpers in "Products.Autopilot.K8s":
--
-- * arguments are passed as a list, never through @sh -c@, so a service name can
--  never inject shell;
-- * the request body goes on stdin, as JSON with every non-ASCII character escaped,
--  so it does not depend on the process locale;
-- * the runner is a plain record ('Kube'), so tests substitute an in-memory cluster.
--
-- Uses whatever kubectl context the process runs under, exactly like the rest of
-- the backend (@SC_KUBECTL_BIN@, one cluster per runner).
module Products.Autopilot.Hpa.Kube
  ( Kube (..),
    KubeErr (..),
    kubeErrText,
    classifyKubeError,
    mkKube,
    getHpa,
    listHpas,
    replaceHpa,
    getDeploymentReadiness,
    getVirtualService,
    listHpaEvents,
    asciiJson,
  )
where

import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (void)
import Core.Config (Config (..))
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAscii, ord)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Vector qualified as V
import Numeric (showHex)
import Products.Autopilot.Hpa.Spec (HpaObject, parseHpaList, parseHpaObject)
import System.Exit (ExitCode (..))
import System.IO (hClose, hGetContents, hPutStr, hSetEncoding, mkTextEncoding)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)
import System.Timeout (timeout)

-- | Run kubectl with these arguments and optional stdin; @Left@ carries stderr.
newtype Kube = Kube {runKubectl :: [String] -> Maybe Text -> IO (Either Text Text)}

data KubeErr
  = KubeNotFound Text
  | -- | resourceVersion mismatch: someone else edited the object.
    KubeConflict Text
  | KubeFailed Text
  deriving (Eq, Show)

kubeErrText :: KubeErr -> Text
kubeErrText (KubeNotFound t) = t
kubeErrText (KubeConflict t) = t
kubeErrText (KubeFailed t) = t

classifyKubeError :: Text -> KubeErr
classifyKubeError = classify

classify :: Text -> KubeErr
classify err
  -- kubectl prints "Error from server (NotFound): ..." for a missing object. A bare "not found" can be
  -- a missing credential plugin or binary, which must never be read as "the HPA is gone".
  | "(notfound)" `T.isInfixOf` low = KubeNotFound (T.strip err)
  | any (`T.isInfixOf` low) ["conflict", "the object has been modified", "please apply your changes to the latest version"] =
      KubeConflict (T.strip err)
  | otherwise = KubeFailed (T.strip err)
  where
    low = T.toLower err

mkKube :: Config -> Kube
mkKube cfg = Kube $ \args stdin -> do
  r <-
    timeout (90 * 1000000) . try $ do
      (code, out, err) <- readProcessUtf8 (kubectlBin cfg) args (maybe "" T.unpack stdin)
      -- Force both streams here so a decoding error is caught by this 'try'.
      _ <- evaluate (length out + length err)
      pure (code, out, err)
  pure $ case r of
    Nothing -> Left "kubectl timed out after 90s"
    Just (Left e) -> Left (T.pack (show (e :: SomeException)))
    Just (Right (ExitSuccess, out, _)) -> Right (T.pack out)
    Just (Right (ExitFailure _, _, err)) -> Left (T.pack err)

readProcessUtf8 :: FilePath -> [String] -> String -> IO (ExitCode, String, String)
readProcessUtf8 bin args input = do
  enc <- mkTextEncoding "UTF-8//ROUNDTRIP"
  (mIn, mOut, mErr, ph) <- createProcess (proc bin args) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  case (mIn, mOut, mErr) of
    (Just hin, Just hout, Just herr) -> do
      mapM_ (`hSetEncoding` enc) [hin, hout, herr]
      let slurp h = do
            s <- hGetContents h
            void (evaluate (length s))
            pure s
          feed = do
            _ <- try (hPutStr hin input) :: IO (Either SomeException ())
            void (try (hClose hin) :: IO (Either SomeException ()))
      ((out, err), _) <- concurrently (concurrently (slurp hout) (slurp herr)) feed
      code <- waitForProcess ph
      pure (code, out, err)
    _ -> ioError (userError "could not open pipes to kubectl")

-- | JSON as ASCII-only text: every non-ASCII char becomes a @\\uXXXX@ escape (surrogate pairs above the BMP).
asciiJson :: Value -> Text
asciiJson v = T.concatMap esc (decodeUtf8 (LBS.toStrict (A.encode v)))
  where
    esc ch
      | isAscii ch = T.singleton ch
      | n > 0xFFFF =
          let m = n - 0x10000
           in u (0xD800 + m `div` 0x400) <> u (0xDC00 + m `mod` 0x400)
      | otherwise = u n
      where
        n = ord ch
    u x = "\\u" <> T.justifyRight 4 '0' (T.pack (showHex x ""))

decodeJson :: Text -> Either KubeErr Value
decodeJson t = maybe (Left (KubeFailed "kubectl returned invalid JSON")) Right (A.decodeStrict' (encodeUtf8 t))

hpaResource :: String
hpaResource = "horizontalpodautoscalers.v2.autoscaling"

getHpa :: Kube -> Text -> Text -> IO (Either KubeErr HpaObject)
getHpa k ns name = do
  r <- runKubectl k ["-n", T.unpack ns, "get", hpaResource, T.unpack name, "-o", "json"] Nothing
  pure $ case r of
    Left e -> Left (classify e)
    Right out -> do
      v <- decodeJson out
      either (Left . KubeFailed) Right (parseHpaObject v)

-- | All HPAs in a namespace, plus a message for each item that could not be parsed.
listHpas :: Kube -> Text -> IO (Either KubeErr ([HpaObject], [Text]))
listHpas k ns = do
  r <- runKubectl k ["-n", T.unpack ns, "get", hpaResource, "-o", "json"] Nothing
  pure $ case r of
    Left e -> Left (classify e)
    Right out -> parseHpaList <$> decodeJson out

-- | Replace the HPA with the given full object. The object carries its
-- @resourceVersion@, so a concurrent edit yields 'KubeConflict' instead of being overwritten.
replaceHpa :: Kube -> Text -> Value -> IO (Either KubeErr ())
replaceHpa k ns obj = do
  r <- runKubectl k ["-n", T.unpack ns, "replace", "-f", "-"] (Just (asciiJson obj))
  pure (either (Left . classify) (const (Right ())) r)

-- | @(desired, ready)@ replicas of a Deployment (@spec.replicas@, @status.readyReplicas@).
getDeploymentReadiness :: Kube -> Text -> Text -> IO (Either KubeErr (Int, Int))
getDeploymentReadiness k ns dep = do
  r <- runKubectl k ["-n", T.unpack ns, "get", "deployment", T.unpack dep, "-o", "json"] Nothing
  pure $ case r of
    Left e -> Left (classify e)
    Right out -> do
      v <- decodeJson out
      pure (intAt ["spec", "replicas"] v, intAt ["status", "readyReplicas"] v)
  where
    intAt path v = case foldl step (Just v) path of
      Just (Number n) -> truncate n
      _ -> 0
    step (Just (Object o)) key = KM.lookup (fromTextKey key) o
    step _ _ = Nothing
    fromTextKey = K.fromText

getVirtualService :: Kube -> Text -> Text -> IO (Either KubeErr Value)
getVirtualService k ns vs = do
  r <- runKubectl k ["-n", T.unpack ns, "get", "virtualservice", T.unpack vs, "-o", "json"] Nothing
  pure $ case r of
    Left e -> Left (classify e)
    Right out -> decodeJson out

-- | Kubernetes events whose involved object is an HPA, as raw items.
listHpaEvents :: Kube -> Text -> IO (Either KubeErr [Value])
listHpaEvents k ns = do
  r <-
    runKubectl
      k
      ["-n", T.unpack ns, "get", "events", "--field-selector", "involvedObject.kind=HorizontalPodAutoscaler", "-o", "json"]
      Nothing
  pure $ case r of
    Left e -> Left (classify e)
    Right out -> do
      v <- decodeJson out
      pure $ case v of
        Object o | Just (Array items) <- KM.lookup "items" o -> V.toList items
        _ -> []
