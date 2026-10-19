{-# LANGUAGE OverloadedStrings #-}

{- | Read-only background sampler behind the performance panel.

For every watched service (explicitly watched, with a schedule, or with an apply
in flight) it records, once a minute: replicas and utilisation per HPA, a
snapshot whenever the HPA's spec changes (whoever changed it), and the
Kubernetes scale events. It writes nothing to the cluster, so it is safe to run
everywhere; one pod runs it at a time (lease), and a dead leader's lease expires.
-}
module Products.Autopilot.Hpa.Observer (
    observerLoop,
    observeOnce,
    currentUtilization,
    parseNewSize,
    parseK8sTime,
)
where

import Control.Monad (forM_, forever, when)
import Control.Monad.Catch (throwM, try)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig, logInfo, logWarning)
import Core.Types.Time (Seconds (..), threadDelay)
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Vector qualified as V
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

-- | How long samples and scale events are kept.
retentionDays :: Int
retentionDays = 7

observerLoop :: Text -> Flow ()
observerLoop holder = do
    ticks <- liftIO (newIORef (0 :: Int))
    supervise "observer" $ forever $ do
        cfg <- getConfig
        let cloud = cloudProvider cfg
        leader <- acquireLoopLease "observe" cloud holder 150
        when leader $ do
            observeOnce (mkKube cfg) cloud
            n <- liftIO (readIORef ticks)
            -- roughly hourly
            if n >= 60
                then do
                    liftIO (writeIORef ticks 0)
                    deleted <- pruneObserverData cloud retentionDays
                    when (deleted > 0) (logInfo ("[hpa] pruned " <> T.pack (show deleted) <> " old observer rows"))
                else liftIO (modifyIORef' ticks (+ 1))
        liftIO (threadDelay (Seconds 60))

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
                Right (hpas, _) -> do
                    now <- liftIO getCurrentTime
                    evRes <- liftIO (listHpaEvents kube ns)
                    let events = either (const []) id evRes
                    forM_ ctxs $ \ctx -> do
                        let res = classifyHpas (scHost ctx) (scOtherHosts ctx) Nothing hpas
                            mine = map rhHpa (resHpas res)
                            names = map hoName mine
                        forM_ mine (observeHpa cloud ctx now)
                        forM_ events (storeEvent cloud ctx names now)

observeHpa :: Text -> ServiceCtx -> UTCTime -> HpaObject -> Flow ()
observeHpa cloud ctx now h = do
    let spec = hoSpec h
        st = hoStatus h
    insertSample
        SampleRow
            { smCloud = cloud
            , smAppGroup = scAppGroup ctx
            , smService = scService ctx
            , smNamespace = scNamespace ctx
            , smHpaName = hoName h
            , smTs = now
            , smMin = hsMinReplicas spec
            , smMax = hsMaxReplicas spec
            , smCurrent = hstCurrentReplicas st
            , smDesired = hstDesiredReplicas st
            , smCpuPct = currentUtilization "cpu" (hstCurrentMetrics st)
            , smMemPct = currentUtilization "memory" (hstCurrentMetrics st)
            , smMetrics = hstCurrentMetrics st
            }
    let hash = specHash spec
    previous <- lastSnapshotHash cloud (scNamespace ctx) (hoName h)
    when (previous /= Just hash) $
        insertSnapshot
            cloud
            (scAppGroup ctx)
            (scService ctx)
            (scNamespace ctx)
            (hoName h)
            (A.toJSON spec)
            hash
            "OBSERVED"
            (lookup annScheduleId (hoAnnotations h))
            Nothing
            (hoResourceVersion h)

storeEvent :: Text -> ServiceCtx -> [Text] -> UTCTime -> Value -> Flow ()
storeEvent cloud ctx names now ev = case ev of
    Object o
        | Just uid <- str ["metadata", "uid"] o
        , Just hpa <- str ["involvedObject", "name"] o
        , hpa `elem` names
        , Just reason <- str ["reason"] o -> do
            let msg = fromMaybe "" (str ["message"] o)
                typ = str ["type"] o
                cnt = fromMaybe 1 (intAt ["count"] o)
                firstTs = fromMaybe now (timeAt ["firstTimestamp"] o `orElse` timeAt ["eventTime"] o `orElse` timeAt ["metadata", "creationTimestamp"] o)
                lastTs = fromMaybe firstTs (timeAt ["lastTimestamp"] o `orElse` timeAt ["eventTime"] o)
            upsertScaleEvent cloud (scAppGroup ctx) (scService ctx) (scNamespace ctx) hpa uid typ reason msg (parseNewSize msg) cnt firstTs lastTs
    _ -> pure ()
  where
    orElse a b = maybe b Just a
    str path o = case walk path (Object o) of Just (String t) | not (T.null t) -> Just t; _ -> Nothing
    intAt path o = case walk path (Object o) of Just (Number n) -> Just (truncate n); _ -> Nothing
    timeAt path o = case walk path (Object o) of Just (String t) -> parseK8sTime t; _ -> Nothing
    walk [] v = Just v
    walk (k : ks) (Object o) = KM.lookup (fromText' k) o >>= walk ks
    walk _ _ = Nothing
    fromText' = K.fromText

{- | The measured average utilisation (percent of request) of a resource from
@status.currentMetrics@; @Nothing@ when the HPA reports an absolute value instead.
-}
currentUtilization :: Text -> Value -> Maybe Double
currentUtilization name (Array ms) = case mapMaybe pick (V.toList ms) of
    (x : _) -> Just x
    [] -> Nothing
  where
    pick (Object m)
        | Just (String "Resource") <- KM.lookup "type" m
        , Just (Object r) <- KM.lookup "resource" m
        , Just (String n) <- KM.lookup "name" r
        , n == name
        , Just (Object cur) <- KM.lookup "current" r
        , Just (Number u) <- KM.lookup "averageUtilization" cur =
            Just (toRealFloat u)
    pick _ = Nothing
currentUtilization _ _ = Nothing

-- | The replica count in an HPA rescale message: @New size: 7; reason: ...@.
parseNewSize :: Text -> Maybe Int
parseNewSize msg = case T.breakOn "New size: " msg of
    (_, rest) | not (T.null rest) -> readMaybe (T.unpack (T.takeWhile (`elem` ['0' .. '9']) (T.drop 10 rest)))
    _ -> Nothing

-- | Kubernetes timestamps are RFC 3339 (@2026-10-19T05:00:00Z@), sometimes with micro-seconds.
parseK8sTime :: Text -> Maybe UTCTime
parseK8sTime = iso8601ParseM . T.unpack
