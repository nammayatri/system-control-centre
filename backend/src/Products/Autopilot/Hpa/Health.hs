{-# LANGUAGE OverloadedStrings #-}

{- | Is a just-changed HPA healthy? Pure assessment + judgement, plus the
Prometheus query used by optional 'PromCheck's.

A scale-up legitimately has unready pods for a while, so an issue only becomes
a breach once it has persisted for the policy's grace period. The worker keeps
the "unhealthy since" timestamp in the ledger row, so a restart neither forgets
nor resets it.
-}
module Products.Autopilot.Hpa.Health (
    HealthInputs (..),
    HealthReport (..),
    Verdict (..),
    assessHealth,
    judge,
    substitutePromQuery,
    parsePromScalar,
    queryPromScalar,
    runPromChecks,
    safeK8sName,
)
where

import Core.Config (Config (..))
import Core.Http.Client (HttpReq (..), HttpResponse (..), defaultReq, httpRaw)
import Core.Types.Time (Seconds (..))
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Char (isAsciiLower, isDigit)
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (UTCTime, diffUTCTime)
import Data.Vector qualified as V
import Network.HTTP.Types.URI (urlEncode)
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Types

data HealthInputs = HealthInputs
    { hiHpa :: HpaObject
    , hiReadiness :: Maybe (Int, Int)
    -- ^ @(desired, ready)@ of the scale-target Deployment, if it could be read.
    , hiProm :: [(PromCheck, Either Text Double)]
    }

data HealthReport = HealthReport
    { hrIssues :: [Text]
    -- ^ Things that count against the change.
    , hrNotes :: [Text]
    -- ^ Things we could not check; never a breach on their own.
    }
    deriving (Eq, Show)

assessHealth :: HealthPolicy -> HealthInputs -> HealthReport
assessHealth pol hi = HealthReport (inactive <> unavailable <> promIssues) (readinessNote <> promNotes)
  where
    conds = hstConditions (hoStatus (hiHpa hi))
    inactive =
        [ "HPA reports ScalingActive=False" <> maybe "" (" (" <>) (fmap (<> ")") (describe c))
        | hpRollbackOnScalingInactive pol
        , c <- conds
        , hcType c == "ScalingActive"
        , hcStatus c == "False"
        ]
    describe c = case (hcReason c, hcMessage c) of
        (Just r, Just m) -> Just (r <> ": " <> m)
        (Just r, Nothing) -> Just r
        (Nothing, Just m) -> Just m
        _ -> Nothing
    unavailable = case hiReadiness hi of
        Just (desired, ready)
            | desired > 0
            , (desired - ready) * 100 > hpMaxUnavailablePct pol * desired ->
                [ T.pack (show (desired - ready))
                    <> " of "
                    <> T.pack (show desired)
                    <> " pods not ready (limit "
                    <> T.pack (show (hpMaxUnavailablePct pol))
                    <> "%)"
                ]
        _ -> []
    readinessNote = ["pod readiness unavailable" | hiReadiness hi == Nothing]
    promIssues =
        [ pcName c <> " = " <> T.pack (show v) <> (if pcOp c == OpGt then " > " else " < ") <> T.pack (show (pcThreshold c))
        | (c, Right v) <- hiProm hi
        , breaches c v
        ]
    promNotes = [pcName c <> ": " <> e | (c, Left e) <- hiProm hi]
    breaches c v = case pcOp c of
        OpGt -> v > pcThreshold c
        OpLt -> v < pcThreshold c

data Verdict = VerdictOk | VerdictWatching | VerdictBreach
    deriving (Eq, Show)

{- | Turn a report into a verdict, given the time the change first looked unhealthy.
Returns the (possibly new, possibly cleared) unhealthy-since timestamp to persist.
-}
judge :: HealthPolicy -> UTCTime -> Maybe UTCTime -> HealthReport -> (Verdict, Maybe UTCTime)
judge pol now since report
    | null (hrIssues report) = (VerdictOk, Nothing)
    | fromIntegral (hpGraceSeconds pol) <= diffUTCTime now start = (VerdictBreach, Just start)
    | otherwise = (VerdictWatching, Just start)
  where
    start = fromMaybe now since

-- ---------------------------------------------------------------------------
-- Prometheus

-- | A Kubernetes object name: lowercase alphanumerics, @-@ and @.@.
safeK8sName :: Text -> Bool
safeK8sName t = not (T.null t) && T.length t <= 253 && T.all ok t
  where
    ok c = isAsciiLower c || isDigit c || c == '-' || c == '.'

{- | Fill @{{namespace}}@, @{{service}}@ and @{{deployment}}@. Values are checked to be
plain k8s names first, so a crafted name cannot rewrite the query.
-}
substitutePromQuery :: Text -> Text -> Text -> Text -> Either Text Text
substitutePromQuery ns svc dep q
    | not (all safeK8sName [ns, svc, dep]) = Left "refusing to build a query from an unusual resource name"
    | otherwise =
        Right (T.replace "{{deployment}}" dep (T.replace "{{service}}" svc (T.replace "{{namespace}}" ns q)))

-- | The first sample of an instant-query response as a number.
parsePromScalar :: Value -> Either Text Double
parsePromScalar (Object o) = case KM.lookup "status" o of
    Just (String "error") -> Left "prometheus returned an error"
    _ -> case KM.lookup "data" o of
        Just (Object d) -> case KM.lookup "result" d of
            Just (Array rs) | Just (Object r) <- firstOf rs -> case KM.lookup "value" r of
                Just (Array vs) | [_, v] <- V.toList vs -> num v
                _ -> Left "unexpected sample shape"
            Just (Array _) -> Left "no data"
            _ -> Left "unexpected result shape"
        _ -> Left "response had no data"
  where
    firstOf rs = if V.null rs then Nothing else Just (V.head rs)
    -- NaN and infinities parse as numbers but must never be compared against a threshold.
    num (String s) = case reads (T.unpack s) of
        [(x, "")] -> finite s x
        _ -> Left ("not a number: " <> s)
    num (Number n) = finite (T.pack (show n)) (toRealFloat n)
    num _ = Left "not a number"
    finite raw x
        | isNaN x = Left "value is NaN"
        | isInfinite x = Left ("value is not finite: " <> raw)
        | otherwise = Right x
parsePromScalar _ = Left "response was not an object"

queryPromScalar :: String -> Text -> IO (Either Text Double)
queryPromScalar promUrl query = do
    let url = T.pack promUrl <> "/api/v1/query?query=" <> TE.decodeUtf8 (urlEncode True (TE.encodeUtf8 query))
        req = (defaultReq url) {reqTimeout = Seconds 10, reqRetries = 0, reqLogTag = "hpa-prom"}
    r <- httpRaw req
    pure $ case r of
        Left e -> Left ("prometheus unreachable: " <> T.pack (take 120 (show e)))
        Right HttpResponse {respStatus = s, respBody = b}
            | s >= 400 -> Left ("prometheus HTTP " <> T.pack (show s))
            | otherwise -> maybe (Left "prometheus returned invalid JSON") parsePromScalar (A.decode b)

-- | Evaluate every check; with no Prometheus configured they are reported as notes, not failures.
runPromChecks :: Config -> Text -> Text -> Text -> [PromCheck] -> IO [(PromCheck, Either Text Double)]
runPromChecks cfg ns svc dep checks = mapM one checks
  where
    one c
        | null (prometheusUrl cfg) = pure (c, Left "PROMETHEUS_URL is not configured")
        | otherwise = case substitutePromQuery ns svc dep (pcQuery c) of
            Left e -> pure (c, Left e)
            Right q -> (,) c <$> queryPromScalar (prometheusUrl cfg) q
