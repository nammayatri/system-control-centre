{-# LANGUAGE OverloadedStrings #-}

{- | Records WHEN an HPA's spec changes, whoever changed it.

Deliberately cheap: it writes a row only when a spec differs from the last one recorded
(a handful of rows per service per month), never a time series. Replica counts and CPU
over time come from the metrics system on demand ("Products.Autopilot.Hpa.Metrics"), and
Kubernetes scale events are read live; neither is stored here.

Runs every few minutes for services that have a schedule or a change in flight (those are
the ones whose history matters). It only reads the cluster. One pod runs it at a time (lease).
-}
module Products.Autopilot.Hpa.Observer (
    observerLoop,
    observeOnce,
    K8sEvent (..),
    parseK8sEvent,
    parseNewSize,
    parseK8sTime,
)
where

import Control.Monad (forM_, forever, when)
import Control.Monad.Catch (throwM, try)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig, logWarning)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Products.Autopilot.Hpa.Change (specHash)
import Products.Autopilot.Hpa.Kube
import Products.Autopilot.Hpa.Resolver (Resolution (..), ResolvedHpa (..), classifyHpas)
import Products.Autopilot.Hpa.Service
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Store
import Products.Autopilot.Hpa.Types (annScheduleId)
import Products.Autopilot.Hpa.Util (isAsync)
import Products.Autopilot.Hpa.Worker (supervise)
import Text.Read (readMaybe)

observerLoop :: Text -> Flow ()
observerLoop holder = supervise "observer" $ forever $ do
    cfg <- getConfig
    let cloud = cloudProvider cfg
    leader <- acquireLoopLease "observe" cloud holder 900
    when leader (observeOnce (mkKube cfg) cloud)
    liftIO (threadDelay (Seconds 300))

observeOnce :: Kube -> Text -> Flow ()
observeOnce kube cloud = do
    watched <- watchedServices cloud
    let byApp = Map.toList (Map.fromListWith (<>) [(a, [s]) | (a, s) <- watched])
    forM_ byApp $ \(app, svcs) -> do
        r <- try (observeProduct kube cloud app (nub svcs))
        case r of
            Right () -> pure ()
            Left e
                | isAsync e -> throwM e
                | otherwise -> logWarning ("[hpa] observer failed for " <> app <> ": " <> T.pack (show e))

observeProduct :: Kube -> Text -> Text -> [Text] -> Flow ()
observeProduct kube cloud app svcs = do
    ctxs <- loadServiceCtxs app svcs
    case ctxs of
        [] -> pure ()
        (c0 : _) -> do
            let ns = scNamespace c0
            hpaRes <- liftIO (listHpas kube ns)
            case hpaRes of
                Left e -> logWarning ("[hpa] observer: cannot list HPAs in " <> ns <> ": " <> kubeErrText e)
                Right (hpas, _) ->
                    forM_ ctxs $ \ctx -> do
                        let res = classifyHpas (scHost ctx) (scOtherHosts ctx) Nothing hpas
                        forM_ (map rhHpa (resHpas res)) (snapshotIfChanged cloud ctx)

-- | One row, only when the spec differs from the last recorded one.
snapshotIfChanged :: Text -> ServiceCtx -> HpaObject -> Flow ()
snapshotIfChanged cloud ctx h = do
    let hash = specHash (hoSpec h)
    previous <- lastSnapshotHash cloud (scNamespace ctx) (hoName h)
    when (previous /= Just hash) $
        insertSnapshot
            cloud
            (scAppGroup ctx)
            (scService ctx)
            (scNamespace ctx)
            (hoName h)
            (A.toJSON (hoSpec h))
            hash
            "OBSERVED"
            (lookup annScheduleId (hoAnnotations h))
            Nothing
            (hoResourceVersion h)

-- | A Kubernetes event about an HPA, as shown in the scale-events list.
data K8sEvent = K8sEvent
    { keUid :: Text
    , keHpa :: Text
    , keType :: Maybe Text
    , keReason :: Text
    , keMessage :: Text
    , keNewSize :: Maybe Int
    , keCount :: Int
    , keFirst :: UTCTime
    , keLast :: UTCTime
    }
    deriving (Eq, Show)

parseK8sEvent :: UTCTime -> Value -> Maybe K8sEvent
parseK8sEvent now (Object o) = do
    uid <- str ["metadata", "uid"]
    hpa <- str ["involvedObject", "name"]
    reason <- str ["reason"]
    let msg = fromMaybe "" (str ["message"])
        firstTs = fromMaybe now (time ["firstTimestamp"] `orElse` time ["eventTime"] `orElse` time ["metadata", "creationTimestamp"])
        lastTs = fromMaybe firstTs (time ["lastTimestamp"] `orElse` time ["eventTime"])
    pure
        K8sEvent
            { keUid = uid
            , keHpa = hpa
            , keType = str ["type"]
            , keReason = reason
            , keMessage = msg
            , keNewSize = parseNewSize msg
            , keCount = fromMaybe 1 (int ["count"])
            , keFirst = firstTs
            , keLast = lastTs
            }
  where
    orElse a b = maybe b Just a
    str path = case walk path (Object o) of Just (String t) | not (T.null t) -> Just t; _ -> Nothing
    int path = case walk path (Object o) of Just (Number n) -> Just (truncate n); _ -> Nothing
    time path = case walk path (Object o) of Just (String t) -> parseK8sTime t; _ -> Nothing
    walk [] v = Just v
    walk (k : ks) (Object m) = KM.lookup (K.fromText k) m >>= walk ks
    walk _ _ = Nothing
parseK8sEvent _ _ = Nothing

-- | The replica count in an HPA rescale message: @New size: 7; reason: ...@.
parseNewSize :: Text -> Maybe Int
parseNewSize msg = case T.breakOn "New size: " msg of
    (_, rest) | not (T.null rest) -> readMaybe (T.unpack (T.takeWhile (`elem` ['0' .. '9']) (T.drop 10 rest)))
    _ -> Nothing

-- | Kubernetes timestamps are RFC 3339 (@2026-10-19T05:00:00Z@), sometimes with micro-seconds.
parseK8sTime :: Text -> Maybe UTCTime
parseK8sTime = iso8601ParseM . T.unpack
