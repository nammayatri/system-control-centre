{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Products.Autopilot.ApiLatencyReport
  ( postApiLatencyReport,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad.IO.Class (liftIO)
import Core.Config (Config (..))
import Core.Environment (Flow)
import Core.Http.Client (HttpReq (..), HttpResponse (..), defaultReq, httpRaw)
import Core.Logging (logErrorG, logInfoG)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (toList)
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Products.Autopilot.Notifications (notifyFixedChannelAlert, notifyGenericThreadMessage)
import Products.Autopilot.RuntimeConfig
  ( getApiLatencyReportSreChannel,
    getApiLatencyReportSreMinCalls,
    getApiLatencyReportSreThresholdPct,
    getApiLatencyReportTopDeltaCount,
    getApiLatencyReportTopVolumeCount,
    getApiLatencyReportWindowMinutes,
    isApiLatencyReportEnabledForAppGroupService,
  )
import Products.Autopilot.Types.Release (ReleaseTracker (appGroup, releaseId, service, startTime))
import Products.Autopilot.Types.Target.Kubernetes (K8sReleaseContext (..))

data HandlerStat = HandlerStat
  { hsHandler :: Text,
    hsOldMs :: Maybe Double,
    hsNewMs :: Double,
    hsNewCount :: Double,
    hsDeltaPct :: Maybe Double
  }

rowsPerMessage :: Int
rowsPerMessage = 25

postApiLatencyReport :: Config -> ReleaseTracker -> K8sReleaseContext -> Flow ()
postApiLatencyReport cfg rt ctx = do
  enabled <- isApiLatencyReportEnabledForAppGroupService (appGroup rt) (service rt)
  if not enabled || null (prometheusUrl cfg)
    then pure ()
    else do
      windowMins <- getApiLatencyReportWindowMinutes
      topVolumeN <- getApiLatencyReportTopVolumeCount
      topDeltaN <- getApiLatencyReportTopDeltaCount
      result <-
        liftIO
          ( try (buildReport cfg ctx (startTime rt) windowMins) ::
              IO (Either SomeException (Maybe [HandlerStat]))
          )
      case result of
        Left e -> liftIO $ logErrorG $ "[API_LATENCY_REPORT] failed: " <> T.pack (show e)
        Right Nothing -> liftIO $ logInfoG "[API_LATENCY_REPORT] no data, skipping"
        Right (Just stats) -> do
          let header = reportHeader rt ctx
          mapM_ (notifyGenericThreadMessage rt) (formatReport header stats topVolumeN topDeltaN)
          postSreAlertIfBreaking rt ctx stats

reportHeader :: ReleaseTracker -> K8sReleaseContext -> Text
reportHeader rt ctx =
  appGroup rt
    <> " | "
    <> service rt
    <> " ("
    <> releaseId rt
    <> ") — "
    <> oldVersion ctx
    <> " \8594 "
    <> newVersion ctx

postSreAlertIfBreaking :: ReleaseTracker -> K8sReleaseContext -> [HandlerStat] -> Flow ()
postSreAlertIfBreaking rt ctx stats = do
  sreChannel <- getApiLatencyReportSreChannel
  thresholdPct <- getApiLatencyReportSreThresholdPct
  minCalls <- getApiLatencyReportSreMinCalls
  let breaking =
        sortBy
          (comparing (Down . absDelta))
          [ s
            | s <- stats,
              hsNewCount s >= fromIntegral minCalls,
              maybe False (\d -> abs d >= fromIntegral thresholdPct) (hsDeltaPct s)
          ]
  case breaking of
    [] -> pure ()
    _ ->
      notifyFixedChannelAlert
        sreChannel
        ( "\128680 Breaking API latency shift — "
            <> reportHeader rt ctx
            <> ":\n```"
            <> T.intercalate "\n" (map formatRow breaking)
            <> "```"
        )

buildReport :: Config -> K8sReleaseContext -> Maybe UTCTime -> Int -> IO (Maybe [HandlerStat])
buildReport cfg ctx mStartTime windowMins = do
  let promUrl = prometheusUrl cfg
      svc = serviceName ctx
      oldVer = oldVersion ctx
      newVer = newVersion ctx
  if null promUrl || T.null oldVer || T.null newVer || oldVer == newVer
    then pure Nothing
    else do
      oldAvg <- queryVectorAt promUrl (avgLatencyQuery svc oldVer windowMins) mStartTime
      newAvg <- queryVectorAt promUrl (avgLatencyQuery svc newVer windowMins) Nothing
      newCnt <- queryVectorAt promUrl (countQuery svc newVer windowMins) Nothing
      if null newAvg
        then pure Nothing
        else pure (Just (mergeStats oldAvg newAvg newCnt))

mergeStats :: [(Text, Double)] -> [(Text, Double)] -> [(Text, Double)] -> [HandlerStat]
mergeStats oldAvg newAvg newCnt =
  [ HandlerStat
      { hsHandler = h,
        hsOldMs = mOld,
        hsNewMs = newMs,
        hsNewCount = maybe 0 id (lookup h newCnt),
        hsDeltaPct = case mOld of
          Just oldMs | oldMs > 0 -> Just ((newMs - oldMs) / oldMs * 100)
          _ -> Nothing
      }
    | (h, newMs) <- newAvg,
      let mOld = lookup h oldAvg
  ]

avgLatencyQuery :: Text -> Text -> Int -> Text
avgLatencyQuery svc ver windowMins =
  "1000 * (sum by (handler) (increase(http_request_duration_seconds_sum{service=~\""
    <> svc
    <> "\", version=\""
    <> ver
    <> "\"}["
    <> win
    <> "]))) / (sum by (handler) (increase(http_request_duration_seconds_count{service=~\""
    <> svc
    <> "\", version=\""
    <> ver
    <> "\"}["
    <> win
    <> "])))"
  where
    win = T.pack (show windowMins) <> "m"

countQuery :: Text -> Text -> Int -> Text
countQuery svc ver windowMins =
  "sum by (handler) (increase(http_request_duration_seconds_count{service=~\""
    <> svc
    <> "\", version=\""
    <> ver
    <> "\"}["
    <> T.pack (show windowMins)
    <> "m]))"

queryVectorAt :: String -> Text -> Maybe UTCTime -> IO [(Text, Double)]
queryVectorAt promUrl query mTime = do
  let timeParam = case mTime of
        Nothing -> ""
        Just t -> "&time=" <> T.pack (show (round (utcTimeToPOSIXSeconds t) :: Integer))
      url = T.pack promUrl <> "/api/v1/query?query=" <> query <> timeParam
      req = (defaultReq url) {reqTimeout = Seconds 15, reqRetries = 0, reqLogTag = "prometheus-latency-report"}
  result <- httpRaw req
  case result of
    Right HttpResponse {respStatus = s, respBody = b}
      | s < 400 -> pure (parsePromVector (TE.decodeUtf8 (LBS.toStrict b)))
    Right HttpResponse {respStatus = s} -> do
      logErrorG $ "[API_LATENCY_REPORT] Prometheus query failed (HTTP " <> T.pack (show s) <> ")"
      pure []
    Left e -> do
      logErrorG $ "[API_LATENCY_REPORT] Prometheus query failed: " <> T.pack (show e)
      pure []

parsePromVector :: Text -> [(Text, Double)]
parsePromVector raw =
  case A.decodeStrict' (TE.encodeUtf8 raw) :: Maybe Value of
    Just (Object obj) ->
      case KM.lookup (K.fromText "data") obj of
        Just (Object dataObj) ->
          case KM.lookup (K.fromText "result") dataObj of
            Just (Array results) -> concatMap parseResult (toList results)
            _ -> []
        _ -> []
    _ -> []
  where
    parseResult (Object r) =
      case (KM.lookup (K.fromText "metric") r, KM.lookup (K.fromText "value") r) of
        (Just (Object m), Just (Array v)) ->
          case (KM.lookup (K.fromText "handler") m, toList v) of
            (Just (String h), [_, String valStr]) | valStr /= "NaN" ->
              case reads (T.unpack valStr) of
                [(d, "")] -> [(h, d)]
                _ -> []
            _ -> []
        _ -> []
    parseResult _ = []

absDelta :: HandlerStat -> Double
absDelta s = maybe 0 abs (hsDeltaPct s)

formatRow :: HandlerStat -> Text
formatRow s =
  hsHandler s
    <> " — old="
    <> fmtMs (hsOldMs s)
    <> "ms new="
    <> fmtMs (Just (hsNewMs s))
    <> "ms Δ="
    <> fmtDelta (hsDeltaPct s)
    <> " calls="
    <> T.pack (show (round (hsNewCount s) :: Integer))
  where
    fmtMs Nothing = "n/a"
    fmtMs (Just v) = T.pack (show (round v :: Integer))
    fmtDelta Nothing = "n/a (no old-version baseline)"
    fmtDelta (Just d) = (if d >= 0 then "+" else "") <> T.pack (show (roundTo1 d)) <> "%"
    roundTo1 x = fromIntegral (round (x * 10) :: Integer) / 10 :: Double

formatReport :: Text -> [HandlerStat] -> Int -> Int -> [Text]
formatReport header stats topVolumeN topDeltaN =
  let byDelta = take topDeltaN (sortBy (comparing (Down . absDelta)) stats)
      byVolume = take topVolumeN (sortBy (comparing (Down . hsNewCount)) stats)
      deltaMsg =
        "*API latency — "
          <> header
          <> "*\nTop "
          <> T.pack (show (length byDelta))
          <> " %-change (all endpoints):\n```"
          <> T.intercalate "\n" (map formatRow byDelta)
          <> "```"
      volumeMsgs =
        [ "*API latency — "
            <> header
            <> "*\nTop by call volume ("
            <> T.pack (show (i + 1))
            <> "-"
            <> T.pack (show (min (length byVolume) (i + rowsPerMessage)))
            <> " of "
            <> T.pack (show (length byVolume))
            <> "):\n```"
            <> T.intercalate "\n" (map formatRow chunk)
            <> "```"
          | (i, chunk) <- zip [0, rowsPerMessage ..] (chunksOf rowsPerMessage byVolume)
        ]
   in deltaMsg : volumeMsgs
  where
    chunksOf _ [] = []
    chunksOf n xs = take n xs : chunksOf n (drop n xs)
