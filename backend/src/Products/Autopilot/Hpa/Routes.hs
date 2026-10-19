{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

{- | HPA panel HTTP API. Mounted as a suffix of 'CoreAPI' by
"Products.Autopilot.Routes", like the Mobile and ReleaseBot sub-APIs, so RBAC,
logging and middleware stay on the one Servant tree.

Reads (@HPA_VIEW@) show live HPAs, replica/utilisation history, scale events,
spec history with diffs, schedules and the apply ledger. Writes are split so
access can be granted narrowly: schedules (@HPA_SCHEDULE_EDIT@), manual
apply / early restore (@HPA_APPLY@), rollback / cancel / acknowledge
(@HPA_ROLLBACK@) and guardrails (@HPA_GUARDRAIL_EDIT@, withheld from Manager).
Every endpoint also checks the permission against the product (app group) being
touched, so a grant can be scoped to one app group.

Nothing a request saves can fail at apply time for a reason we could have seen:
schedules and manual applies are previewed against the live HPAs first.
-}
module Products.Autopilot.Hpa.Routes (
    HpaAPI,
    hpaServer,
) where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.AppError (APIError (..))
import Core.Admin.Queries (writeAuditLog)
import Core.Auth.Protected (AuthedPerson (..), Protected, requireDeploymentPermission)
import Core.Auth.Permission (KnownPermission)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (find)
import Data.Maybe (fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Products.Autopilot.Hpa.Change (jsonDiff)
import Products.Autopilot.Hpa.Kube (Kube, getVirtualService, kubeErrText, listHpas, mkKube)
import Products.Autopilot.Hpa.Preview
import Products.Autopilot.Hpa.Resolver
import Products.Autopilot.Hpa.Service
import Products.Autopilot.Hpa.Spec
import Products.Autopilot.Hpa.Store
import Products.Autopilot.Hpa.Types
import Products.Autopilot.Hpa.Util (decodeValue, newId)
import Products.Autopilot.Hpa.Window
import Products.Autopilot.Queries.ProductService (
    findProductByName,
    getProductNamespace,
    getProductVsName,
    getServiceHost,
    listReleaseConfigByProduct,
 )
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Autopilot.Types.Storage.Schema qualified as S
import Servant
import Shared.API.Response (APISuccess (..))

-- ---------------------------------------------------------------------------
-- API

type HpaAPI =
    -- Reads
    "hpa" :> Protected 'AP_HPA_VIEW :> "overview" :> Capture "product" Text :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "service" :> Capture "product" Text :> Capture "service" Text :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "service" :> Capture "product" Text :> Capture "service" Text :> "series" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "service" :> Capture "product" Text :> Capture "service" Text :> "scale-events" :> QueryParam "from" Text :> QueryParam "to" Text :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "service" :> Capture "product" Text :> Capture "service" Text :> "history" :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "service" :> Capture "product" Text :> Capture "service" Text :> "events" :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "service" :> Capture "product" Text :> Capture "service" Text :> "guardrail" :> Get '[JSON] Value
        -- Guardrail / watch
        :<|> "hpa" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "service" :> Capture "product" Text :> Capture "service" Text :> "guardrail" :> ReqBody '[JSON] Guardrail :> Put '[JSON] APISuccess
        :<|> "hpa" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "service" :> Capture "product" Text :> Capture "service" Text :> "watch" :> ReqBody '[JSON] WatchReq :> Put '[JSON] APISuccess
        -- Schedules
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "schedules" :> QueryParam "product" Text :> QueryParam "service" Text :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "schedules" :> "preview" :> ReqBody '[JSON] PreviewReq :> Post '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> ReqBody '[JSON] ScheduleReq :> Post '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> ReqBody '[JSON] ScheduleReq :> Put '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> "pause" :> Post '[JSON] APISuccess
        :<|> "hpa" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> "resume" :> Post '[JSON] APISuccess
        :<|> "hpa" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> Delete '[JSON] APISuccess
        -- Applies (the ledger)
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "applies" :> QueryParam "product" Text :> QueryParam "service" Text :> QueryParam "status" Text :> QueryParam "limit" Int :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_VIEW :> "applies" :> Capture "id" Text :> Get '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_APPLY :> "applies" :> ReqBody '[JSON] ManualApplyReq :> Post '[JSON] Value
        :<|> "hpa" :> Protected 'AP_HPA_APPLY :> "applies" :> Capture "id" Text :> "restore" :> Post '[JSON] APISuccess
        :<|> "hpa" :> Protected 'AP_HPA_ROLLBACK :> "applies" :> Capture "id" Text :> "rollback" :> Post '[JSON] APISuccess
        :<|> "hpa" :> Protected 'AP_HPA_ROLLBACK :> "applies" :> Capture "id" Text :> "cancel" :> Post '[JSON] APISuccess
        :<|> "hpa" :> Protected 'AP_HPA_ROLLBACK :> "applies" :> Capture "id" Text :> "acknowledge" :> Post '[JSON] APISuccess

hpaServer :: ServerT HpaAPI Flow
hpaServer =
    overviewH
        :<|> serviceH
        :<|> seriesH
        :<|> scaleEventsH
        :<|> historyH
        :<|> eventsH
        :<|> getGuardrailH
        :<|> putGuardrailH
        :<|> watchH
        :<|> listSchedulesH
        :<|> previewH
        :<|> createScheduleH
        :<|> updateScheduleH
        :<|> pauseScheduleH
        :<|> resumeScheduleH
        :<|> deleteScheduleH
        :<|> listAppliesH
        :<|> getApplyH
        :<|> manualApplyH
        :<|> restoreApplyH
        :<|> rollbackApplyH
        :<|> cancelApplyH
        :<|> acknowledgeApplyH

-- ---------------------------------------------------------------------------
-- Request bodies

data WatchReq = WatchReq Bool

instance FromJSON WatchReq where
    parseJSON = A.withObject "WatchReq" $ \o -> WatchReq <$> o .: "watched"

data ScheduleReq = ScheduleReq
    { sqProduct :: Text
    , sqService :: Text
    , sqName :: Text
    , sqKind :: ScheduleKind
    , sqChange :: HpaChange
    , sqPolicy :: Maybe HealthPolicy
    }

instance FromJSON ScheduleReq where
    parseJSON = A.withObject "ScheduleReq" $ \o ->
        ScheduleReq
            <$> o .:? "product" .!= ""
            <*> o .:? "service" .!= ""
            <*> o .: "name"
            <*> o .: "kind"
            <*> o .: "change"
            <*> o .:? "healthPolicy"

data PreviewReq = PreviewReq
    { pqProduct :: Text
    , pqService :: Text
    , pqHpa :: Maybe Text
    , pqChange :: HpaChange
    , pqKind :: Maybe ScheduleKind
    }

instance FromJSON PreviewReq where
    parseJSON = A.withObject "PreviewReq" $ \o ->
        PreviewReq <$> o .: "product" <*> o .: "service" <*> o .:? "hpa" <*> o .: "change" <*> o .:? "kind"

data ManualApplyReq = ManualApplyReq
    { maProduct :: Text
    , maService :: Text
    , maHpa :: Maybe Text
    , maChange :: HpaChange
    , maPolicy :: Maybe HealthPolicy
    , maEndAt :: Maybe UTCTime
    }

instance FromJSON ManualApplyReq where
    parseJSON = A.withObject "ManualApplyReq" $ \o ->
        ManualApplyReq
            <$> o .: "product"
            <*> o .: "service"
            <*> o .:? "hpa"
            <*> o .: "change"
            <*> o .:? "healthPolicy"
            <*> o .:? "endAt"

-- ---------------------------------------------------------------------------
-- Helpers

bad :: Text -> Flow a
bad = throwM . BadRequest

cloudOf :: Flow Text
cloudOf = cloudProvider <$> getConfig

kubeOf :: Flow Kube
kubeOf = mkKube <$> getConfig

-- | Check the permission against the product (app group) being touched, so a grant can be scoped to one.
need :: (KnownPermission p) => Proxy (p :: AutopilotPermission) -> AuthedPerson -> Text -> Flow ()
need = requireDeploymentPermission

audit :: AuthedPerson -> Text -> Text -> Text -> Value -> Flow ()
audit ap action entity eid details = writeAuditLog (apPersonId ap) action (Just entity) (Just eid) (Just details)

ctxOr404 :: Text -> Text -> Flow ServiceCtx
ctxOr404 app svc = loadServiceCtx app svc >>= maybe (throwM (NotFound ("Service not found: " <> app <> "/" <> svc))) pure

parseTime :: Text -> Maybe UTCTime
parseTime = iso8601ParseM . T.unpack

-- | @from@/@to@ default to the last six hours.
timeRange :: Maybe Text -> Maybe Text -> Flow (UTCTime, UTCTime)
timeRange mFrom mTo = do
    now <- liftIO getCurrentTime
    to <- case mTo of
        Nothing -> pure now
        Just t -> maybe (bad ("invalid 'to' time: " <> t)) pure (parseTime t)
    from <- case mFrom of
        Nothing -> pure (addUTCTime (-6 * 3600) to)
        Just t -> maybe (bad ("invalid 'from' time: " <> t)) pure (parseTime t)
    when (from >= to) (bad "'from' must be before 'to'")
    when (diffUTCTime to from > 8 * 86400) (bad "the range may be at most 8 days")
    pure (from, to)

windowJson :: Window -> Value
windowJson w = A.object ["start" .= wStart w, "end" .= wEnd w]

-- | Window state of a schedule right now, for the UI.
scheduleTiming :: UTCTime -> ScheduleRow -> Value
scheduleTiming now s = case decodeValue (srKind s) of
    Left e -> A.object ["error" .= e]
    Right k ->
        A.object
            [ "windowOpen" .= isJust (activeWindow k now)
            , "currentWindow" .= fmap windowJson (activeWindow k now)
            , "nextStart" .= nextWindowStart k now
            ]

scheduleWithTiming :: UTCTime -> ScheduleRow -> Value
scheduleWithTiming now s = case toJSON s of
    Object o -> Object (KM.insert "timing" (scheduleTiming now s) o)
    v -> v

nonTerminal :: ApplyRow -> Bool
nonTerminal a = maybe True (not . isTerminalApply) (parseApplyStatus (arStatus a))

-- ---------------------------------------------------------------------------
-- Reads

overviewH :: AuthedPerson -> Text -> Flow Value
overviewH ap app = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    pCfg <- findProductByName app >>= maybe (throwM (NotFound ("Product not found: " <> app))) pure
    cloud <- cloudOf
    kube <- kubeOf
    services <- listReleaseConfigByProduct app
    let ns = getProductNamespace pCfg
        vsName = getProductVsName pCfg
        hosts = [h | s <- services, Just h <- [getServiceHost s]]
    hpaRes <- liftIO (listHpas kube ns)
    vsRes <- if T.null vsName then pure Nothing else Just <$> liftIO (getVirtualService kube ns vsName)
    schedules <- listSchedules cloud (Just app) Nothing
    applies <- listApplies cloud (Just app) Nothing Nothing 500
    watched <- listWatched cloud app
    guards <- listGuardrails cloud app
    now <- liftIO getCurrentTime
    let (hpas, clusterErr) = case hpaRes of
            Right (hs, _) -> (hs, Nothing)
            Left e -> ([], Just (kubeErrText e))
        weightsFor host = case vsRes of
            Just (Right vs) -> Just (subsetWeightsFromVs host vs)
            _ -> Nothing
        row svcRow = case (S.dcService svcRow, getServiceHost svcRow) of
            (Just svcName, mHost) ->
                let host = fromMaybe svcName mHost
                    res = classifyHpas host hosts (weightsFor host) hpas
                    serving = servingTargets res
                    mine = [s | s <- schedules, srService s == svcName]
                    active = [s | s <- mine, srStatus s == "ACTIVE"]
                    kinds = [k | s <- active, Right k <- [decodeValue (srKind s)]]
                    inflight = [a | a <- applies, arService a == svcName, nonTerminal a]
                    frozen = maybe False grFrozen (lookup svcName guards >>= either (const Nothing) Just . decodeValue)
                 in Just $
                        A.object
                            [ "service" .= svcName
                            , "host" .= host
                            , "hpaCount" .= length (resHpas res)
                            , "serving" .= map servingSummary serving
                            , "reason" .= resReason res
                            , "warnings" .= resWarnings res
                            , "schedules" .= length mine
                            , "activeSchedules" .= length active
                            , "windowOpen" .= any (isJust . (`activeWindow` now)) kinds
                            , "nextWindowStart" .= minimumMaybe (mapMaybe (`nextWindowStart` now) kinds)
                            , "inflight" .= [A.object ["id" .= arId a, "status" .= arStatus a, "hpaName" .= arHpaName a] | a <- inflight]
                            , "watched" .= (svcName `elem` watched)
                            , "frozen" .= frozen
                            ]
            _ -> Nothing
    pure $
        A.object
            [ "product" .= app
            , "namespace" .= ns
            , "clusterError" .= clusterErr
            , "services" .= mapMaybe row services
            ]
  where
    minimumMaybe [] = Nothing
    minimumMaybe xs = Just (minimum xs)

servingSummary :: ResolvedHpa -> Value
servingSummary r =
    let h = rhHpa r
        sp = hoSpec h
        st = hoStatus h
     in A.object
            [ "name" .= hoName h
            , "version" .= rhVersion r
            , "role" .= rhRole r
            , "minReplicas" .= hsMinReplicas sp
            , "maxReplicas" .= hsMaxReplicas sp
            , "currentReplicas" .= hstCurrentReplicas st
            , "desiredReplicas" .= hstDesiredReplicas st
            , "metrics" .= map describeMetric (hsMetrics sp)
            , "editable" .= (rhEditableReason r == Nothing)
            , "notEditableReason" .= rhEditableReason r
            ]

serviceH :: AuthedPerson -> Text -> Text -> Flow Value
serviceH ap app svc = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    ctx <- ctxOr404 app svc
    cloud <- cloudOf
    kube <- kubeOf
    res <- liftIO (resolveServiceHpasWith kube (scNamespace ctx) (scVsName ctx) (scHost ctx) (scOtherHosts ctx))
    resolution <- either (throwM . BadRequest) pure res
    g <- loadGuardrail cloud app svc
    schedules <- listSchedules cloud (Just app) (Just svc)
    applies <- listApplies cloud (Just app) (Just svc) Nothing 30
    watched <- listWatched cloud app
    now <- liftIO getCurrentTime
    pure $
        A.object
            [ "product" .= app
            , "service" .= svc
            , "host" .= scHost ctx
            , "namespace" .= scNamespace ctx
            , "baseline" .= A.object ["minReplicas" .= scBaselineMin ctx, "maxReplicas" .= scBaselineMax ctx]
            , "resolution" .= resolution
            , "guardrail" .= g
            , "schedules" .= map (scheduleWithTiming now) schedules
            , "applies" .= applies
            , "watched" .= (svc `elem` watched)
            ]

-- | Bucket the series so a long range stays a few hundred points.
bucketFor :: UTCTime -> UTCTime -> Int
bucketFor from to = max 60 (((truncate (realToFrac (diffUTCTime to from) :: Double) `div` 360) `div` 60) * 60)

seriesH :: AuthedPerson -> Text -> Text -> Maybe Text -> Maybe Text -> Flow Value
seriesH ap app svc mFrom mTo = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    (from, to) <- timeRange mFrom mTo
    let bucket = bucketFor from to
    points <- samplesFor cloud app svc from to bucket
    latest <- latestSampleTime cloud app svc
    pure (A.object ["from" .= from, "to" .= to, "bucketSeconds" .= bucket, "latestSample" .= latest, "points" .= points])

scaleEventsH :: AuthedPerson -> Text -> Text -> Maybe Text -> Maybe Text -> Flow Value
scaleEventsH ap app svc mFrom mTo = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    (from, to) <- timeRange mFrom mTo
    evs <- scaleEventsFor cloud app svc from to 500
    pure (A.object ["from" .= from, "to" .= to, "events" .= evs])

{- | Spec history per HPA, newest first, each with the diff from the previous snapshot
of the same HPA: how the configuration changed, and who (schedule, manual apply, or
someone else) was responsible.
-}
historyH :: AuthedPerson -> Text -> Text -> Flow Value
historyH ap app svc = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    snaps <- snapshotsFor cloud app svc 100
    let hpaOf v = case v of Object o | Just (String n) <- KM.lookup "hpaName" o -> n; _ -> ""
        specOf v = case v of Object o -> fromMaybe Null (KM.lookup "spec" o); _ -> Null
        withDiff (i, v) =
            let older = find ((== hpaOf v) . hpaOf) (drop (i + 1) snaps)
                d = maybe [] (\o -> jsonDiff (specOf o) (specOf v)) older
             in case v of
                    Object o -> Object (KM.insert "diff" (toJSON d) (KM.insert "previousSnapshot" (maybe Null (fromMaybe Null . field "id") older) o))
                    x -> x
        field k (Object o) = KM.lookup (K.fromText k) o
        field _ _ = Nothing
    pure (A.object ["snapshots" .= map withDiff (zip [0 ..] snaps)])

eventsH :: AuthedPerson -> Text -> Text -> Flow Value
eventsH ap app svc = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    evs <- listEventsForService cloud app svc 200
    pure (A.object ["events" .= evs])

getGuardrailH :: AuthedPerson -> Text -> Text -> Flow Value
getGuardrailH ap app svc = do
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    toJSON <$> loadGuardrail cloud app svc

-- ---------------------------------------------------------------------------
-- Guardrail / watch

putGuardrailH :: AuthedPerson -> Text -> Text -> Guardrail -> Flow APISuccess
putGuardrailH ap app svc g = do
    need (Proxy :: Proxy 'AP_HPA_GUARDRAIL_EDIT) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    let issues =
            [ "maxReplicasCap must be >= 1" | Just c <- [grMaxReplicasCap g], c < 1 ]
                <> [ "minReplicasFloor must be >= 1" | Just f <- [grMinReplicasFloor g], f < 1 ]
                <> [ "minReplicasFloor must not exceed maxReplicasCap" | Just f <- [grMinReplicasFloor g], Just c <- [grMaxReplicasCap g], f > c ]
                <> [ "maxStepPct must be 1..1000" | Just p <- [grMaxStepPct g], p < 1 || p > 1000 ]
    unless (null issues) (bad (T.intercalate "; " issues))
    putGuardrailRow cloud app svc (toJSON g) (apEmail ap)
    audit ap "HPA_GUARDRAIL_UPDATE" "hpa_guardrail" (app <> "/" <> svc) (toJSON g)
    pure Success

watchH :: AuthedPerson -> Text -> Text -> WatchReq -> Flow APISuccess
watchH ap app svc (WatchReq on) = do
    need (Proxy :: Proxy 'AP_HPA_SCHEDULE_EDIT) ap app
    _ <- ctxOr404 app svc
    cloud <- cloudOf
    if on then addWatch cloud app svc (apEmail ap) else removeWatch cloud app svc
    pure Success

-- ---------------------------------------------------------------------------
-- Schedules

listSchedulesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow Value
listSchedulesH ap mApp mSvc = do
    app <- maybe (bad "the 'product' query parameter is required") pure mApp
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    cloud <- cloudOf
    now <- liftIO getCurrentTime
    schedules <- listSchedules cloud (Just app) mSvc
    rows <- forM schedules $ \s -> do
        applies <- appliesForSchedule cloud (srId s)
        pure $ case scheduleWithTiming now s of
            Object o -> Object (KM.insert "applies" (toJSON (take 20 applies)) o)
            v -> v
    pure (A.object ["schedules" .= rows])

-- | Dry-run a change (and optionally a timing) without saving anything.
previewH :: AuthedPerson -> PreviewReq -> Flow Value
previewH ap req = do
    let app = pqProduct req
        svc = pqService req
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    ctx <- ctxOr404 app svc
    cloud <- cloudOf
    kube <- kubeOf
    g <- loadGuardrail cloud app svc
    when (changeIsEmpty (pqChange req)) (bad "the change is empty")
    r <- liftIO (previewChange kube ctx g (pqChange req) (pqHpa req))
    (resolution, targets) <- either bad pure r
    now <- liftIO getCurrentTime
    others <- listSchedules cloud (Just app) (Just svc)
    let timing = case pqKind req of
            Nothing -> Null
            Just k ->
                A.object
                    [ "problems" .= validateKind k
                    , "windowOpenNow" .= isJust (activeWindow k now)
                    , "nextStarts" .= take 5 (iterate' k now)
                    , "overlaps" .= [srName o | o <- others, srStatus o /= "EXPIRED", Right ok <- [decodeValue (srKind o)], schedulesOverlap now 14 k ok]
                    ]
    pure
        ( A.object
            [ "targets" .= targets
            , "blocking" .= blockingProblems targets
            , "warnings" .= resWarnings resolution
            , "reason" .= resReason resolution
            , "timing" .= timing
            ]
        )
  where
    iterate' k t = case nextWindowStart k t of
        Nothing -> []
        Just s -> s : iterate' k s

-- | Common validation for create/update. Returns the effective policy.
validateScheduleReq :: AuthedPerson -> Text -> Text -> Maybe Text -> ScheduleReq -> Flow HealthPolicy
validateScheduleReq _ app svc excludeId req = do
    let name = T.strip (sqName req)
        policy = fromMaybe defaultHealthPolicy (sqPolicy req)
    when (T.null name || T.length name > 100) (bad "name must be 1..100 characters")
    let structural = validateKind (sqKind req) <> validateHealthPolicy policy
    unless (null structural) (bad (T.intercalate "; " structural))
    when (changeIsEmpty (sqChange req)) (bad "the change is empty")
    now <- liftIO getCurrentTime
    case sqKind req of
        Once _ (Just end) | end <= now -> bad "endAt is in the past"
        _ -> pure ()
    ctx <- ctxOr404 app svc
    cloud <- cloudOf
    kube <- kubeOf
    g <- loadGuardrail cloud app svc
    r <- liftIO (previewChange kube ctx g (sqChange req) Nothing)
    case r of
        Left e -> bad ("cannot validate against the live HPA: " <> e)
        Right (_, targets) -> do
            let problems = blockingProblems targets
            unless (null problems) (bad (T.intercalate "; " problems))
            -- Editing a schedule whose change is currently live would always look like a no-op.
            when (excludeId == Nothing && all tpNoop targets) (bad "no effect: every serving HPA already has these values")
    others <- listSchedules cloud (Just app) (Just svc)
    forM_ [o | o <- others, Just (srId o) /= excludeId, srStatus o /= "EXPIRED"] $ \o ->
        case decodeValue (srKind o) of
            Right ok
                | schedulesOverlap now 14 (sqKind req) ok ->
                    throwM (Conflict ("overlaps the windows of schedule '" <> srName o <> "'; one service can hold one change at a time"))
            _ -> pure ()
    pure policy

createScheduleH :: AuthedPerson -> ScheduleReq -> Flow Value
createScheduleH ap req = do
    let app = sqProduct req
        svc = sqService req
    when (T.null app || T.null svc) (bad "product and service are required")
    need (Proxy :: Proxy 'AP_HPA_SCHEDULE_EDIT) ap app
    policy <- validateScheduleReq ap app svc Nothing req
    cloud <- cloudOf
    sid <- newId
    insertSchedule cloud sid app svc (T.strip (sqName req)) (toJSON (sqKind req)) (toJSON (sqChange req)) (toJSON policy) (apEmail ap)
    audit ap "HPA_SCHEDULE_CREATE" "hpa_schedule" sid (A.object ["product" .= app, "service" .= svc, "name" .= sqName req, "change" .= sqChange req])
    pure (A.object ["id" .= sid])

updateScheduleH :: AuthedPerson -> Text -> ScheduleReq -> Flow Value
updateScheduleH ap sid req = do
    cloud <- cloudOf
    existing <- getSchedule cloud sid >>= maybe (throwM (NotFound "Schedule not found")) pure
    let app = srAppGroup existing
        svc = srService existing
    need (Proxy :: Proxy 'AP_HPA_SCHEDULE_EDIT) ap app
    policy <- validateScheduleReq ap app svc (Just sid) req
    ok <- updateSchedule cloud sid (T.strip (sqName req)) (toJSON (sqKind req)) (toJSON (sqChange req)) (toJSON policy)
    unless ok (throwM (NotFound "Schedule not found"))
    audit ap "HPA_SCHEDULE_UPDATE" "hpa_schedule" sid (A.object ["name" .= sqName req, "change" .= sqChange req])
    pure (A.object ["id" .= sid])

pauseScheduleH :: AuthedPerson -> Text -> Flow APISuccess
pauseScheduleH ap sid = setStatus ap sid "ACTIVE" "PAUSED" "HPA_SCHEDULE_PAUSE"

resumeScheduleH :: AuthedPerson -> Text -> Flow APISuccess
resumeScheduleH ap sid = setStatus ap sid "PAUSED" "ACTIVE" "HPA_SCHEDULE_RESUME"

setStatus :: AuthedPerson -> Text -> Text -> Text -> Text -> Flow APISuccess
setStatus ap sid from to action = do
    cloud <- cloudOf
    s <- getSchedule cloud sid >>= maybe (throwM (NotFound "Schedule not found")) pure
    need (Proxy :: Proxy 'AP_HPA_SCHEDULE_EDIT) ap (srAppGroup s)
    when (srStatus s /= from) (throwM (Conflict ("schedule is " <> srStatus s <> ", not " <> from)))
    _ <- setScheduleStatus cloud sid to
    audit ap action "hpa_schedule" sid (A.object ["name" .= srName s])
    pure Success

{- | Deleting a schedule never strands a change: applies that have not started are cancelled,
and ones that are holding a change are sent to restore at once.
-}
deleteScheduleH :: AuthedPerson -> Text -> Flow APISuccess
deleteScheduleH ap sid = do
    cloud <- cloudOf
    s <- getSchedule cloud sid >>= maybe (throwM (NotFound "Schedule not found")) pure
    need (Proxy :: Proxy 'AP_HPA_SCHEDULE_EDIT) ap (srAppGroup s)
    _ <- deleteSchedule cloud sid
    applies <- appliesForSchedule cloud sid
    forM_ (filter nonTerminal applies) $ \a -> do
        let why = Just "the schedule was deleted"
        _ <- forceTransition (arId a) cloud [Pending] Skipped why
        _ <- forceTransition (arId a) cloud [Applied, Observing] Restoring why
        -- Mid-apply (the worker may have just claimed it): undo whatever it has done so far.
        _ <- forceTransition (arId a) cloud [Applying] RollingBack why
        addEvent cloud (Just (arId a)) (Just sid) (arAppGroup a) (arService a) "schedule_deleted" ("schedule deleted by " <> apEmail ap) Null
    audit ap "HPA_SCHEDULE_DELETE" "hpa_schedule" sid (A.object ["name" .= srName s])
    pure Success

-- ---------------------------------------------------------------------------
-- Applies

listAppliesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Int -> Flow Value
listAppliesH ap mApp mSvc mStatus mLimit = do
    app <- maybe (bad "the 'product' query parameter is required") pure mApp
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap app
    cloud <- cloudOf
    when (maybe False (\s -> parseApplyStatus s == Nothing) mStatus) (bad "unknown status")
    rows <- listApplies cloud (Just app) mSvc mStatus (max 1 (min 500 (fromMaybe 100 mLimit)))
    pure (A.object ["applies" .= rows])

getApplyH :: AuthedPerson -> Text -> Flow Value
getApplyH ap aid = do
    cloud <- cloudOf
    row <- getApply cloud aid >>= maybe (throwM (NotFound "Apply not found")) pure
    need (Proxy :: Proxy 'AP_HPA_VIEW) ap (arAppGroup row)
    evs <- listEventsForApply cloud aid
    pure (A.object ["apply" .= row, "events" .= evs])

manualApplyH :: AuthedPerson -> ManualApplyReq -> Flow Value
manualApplyH ap req = do
    let app = maProduct req
        svc = maService req
    need (Proxy :: Proxy 'AP_HPA_APPLY) ap app
    ctx <- ctxOr404 app svc
    cloud <- cloudOf
    kube <- kubeOf
    now <- liftIO getCurrentTime
    let policy = fromMaybe defaultHealthPolicy (maPolicy req)
        policyIssues = validateHealthPolicy policy
    unless (null policyIssues) (bad (T.intercalate "; " policyIssues))
    when (changeIsEmpty (maChange req)) (bad "the change is empty")
    case maEndAt req of
        Just e | e <= now -> bad "endAt is in the past"
        _ -> pure ()
    g <- loadGuardrail cloud app svc
    r <- liftIO (previewChange kube ctx g (maChange req) (maHpa req))
    (_, targets) <- either bad pure r
    let problems = blockingProblems targets
    unless (null problems) (bad (T.intercalate "; " problems))
    when (all tpNoop targets) (bad "no effect: the HPA already has these values")
    busy <- inflightAppliesForService cloud app svc
    let busyNames = [arHpaName a | a <- busy, arHpaName a `elem` map tpHpa targets]
    unless (null busyNames) $
        throwM (Conflict ("already has an in-flight change: " <> T.intercalate ", " busyNames <> "; restore or cancel it first"))
    inserted <- liftIO (newIORef ([] :: [Text]))
    ids <- forM [t | t <- targets, not (tpNoop t)] $ \t -> do
        aid <- newId
        ok <-
            insertApply
                ApplyNew
                    { anId = aid
                    , anCloud = cloud
                    , anScheduleId = Nothing
                    , anTrigger = applyTriggerText TrigManual
                    , anAppGroup = app
                    , anService = svc
                    , anNamespace = scNamespace ctx
                    , anHpaName = tpHpa t
                    , anChange = toJSON (maChange req)
                    , anPolicy = toJSON policy
                    , anWindowStart = Nothing
                    , anWindowEnd = maEndAt req
                    , anCreatedBy = apEmail ap
                    }
        unless ok $ do
            -- A concurrent apply won the slot for this HPA: withdraw the ones already queued so the
            -- request either happens completely or not at all.
            queued <- liftIO (readIORef inserted)
            forM_ queued $ \q -> forceTransition q cloud [Pending] Skipped (Just "withdrawn: the request could not be applied to every HPA")
            throwM (Conflict (tpHpa t <> " already has an in-flight change; nothing was applied"))
        liftIO (modifyIORef' inserted (aid :))
        addEvent cloud (Just aid) Nothing app svc "manual_apply" ("requested by " <> apEmail ap) (A.object ["change" .= maChange req, "endAt" .= maEndAt req])
        pure aid
    audit ap "HPA_MANUAL_APPLY" "hpa_apply" (T.intercalate "," ids) (A.object ["product" .= app, "service" .= svc, "change" .= maChange req])
    pure (A.object ["applyIds" .= ids])

-- | Shared shape of the lifecycle actions: load, authorise against the row's product, compare-and-set, record.
lifecycle :: (KnownPermission p) => Proxy (p :: AutopilotPermission) -> AuthedPerson -> Text -> [ApplyStatus] -> ApplyStatus -> Text -> Text -> Flow APISuccess
lifecycle perm ap aid froms to reason action = do
    cloud <- cloudOf
    row <- getApply cloud aid >>= maybe (throwM (NotFound "Apply not found")) pure
    need perm ap (arAppGroup row)
    ok <- forceTransition aid cloud froms to (Just (reason <> " by " <> apEmail ap))
    unless ok $
        throwM (Conflict ("cannot " <> action <> " an apply that is " <> arStatus row))
    addEvent cloud (Just aid) (arScheduleId row) (arAppGroup row) (arService row) (T.toLower action) (reason <> " by " <> apEmail ap) Null
    audit ap ("HPA_" <> T.toUpper action) "hpa_apply" aid (A.object ["hpa" .= arHpaName row])
    pure Success

restoreApplyH :: AuthedPerson -> Text -> Flow APISuccess
restoreApplyH ap aid = lifecycle (Proxy :: Proxy 'AP_HPA_APPLY) ap aid [Applied, Observing, NeedsAttention] Restoring "restore requested" "RESTORE"

rollbackApplyH :: AuthedPerson -> Text -> Flow APISuccess
rollbackApplyH ap aid = lifecycle (Proxy :: Proxy 'AP_HPA_ROLLBACK) ap aid [Applying, Observing, Applied, NeedsAttention] RollingBack "manual rollback" "ROLLBACK"

cancelApplyH :: AuthedPerson -> Text -> Flow APISuccess
cancelApplyH ap aid = lifecycle (Proxy :: Proxy 'AP_HPA_ROLLBACK) ap aid [Pending] Skipped "cancelled" "CANCEL"

acknowledgeApplyH :: AuthedPerson -> Text -> Flow APISuccess
acknowledgeApplyH ap aid = lifecycle (Proxy :: Proxy 'AP_HPA_ROLLBACK) ap aid [NeedsAttention] Failed "acknowledged" "ACKNOWLEDGE"
