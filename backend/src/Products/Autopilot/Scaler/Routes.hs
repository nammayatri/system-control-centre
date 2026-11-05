{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

{- | Capacity scaler HTTP API. Mounted as a suffix of the Autopilot API next to the HPA panel's and guarded by
the same permissions, used globally (the scaler is not tied to a product): reads need @HPA_VIEW@, schedules
@HPA_SCHEDULE_EDIT@, manual apply / early restore @HPA_APPLY@, rollback / cancel / acknowledge
@HPA_ROLLBACK@, and registering targets, editing an autoscaler and guardrails @HPA_GUARDRAIL_EDIT@
(Admin only).

Only targets registered in the console (@redis_config@ / @db_config@) can be scheduled, resized or have their
autoscaler touched. Nothing a request saves can fail at apply time for a reason we could have seen:
targets, schedules and manual applies are checked against the live instance and the autoscaler's job before
they are stored.
-}
module Products.Autopilot.Scaler.Routes (
    ScalerAPI,
    scalerServer,
) where

import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Catch (throwM)
import Control.Monad.IO.Class (liftIO)
import Core.Admin.Queries (writeAuditLog)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..), Protected)
import Core.Config (Config (..))
import Core.Environment (Flow, getConfig)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Products.Autopilot.Hpa.Types (ApplyStatus (..), ApplyTrigger (..), ScheduleKind (..), ScheduleStatus (..), applyTriggerText, isTerminalApply, parseApplyStatus, scheduleStatusText)
import Products.Autopilot.Hpa.Util (decodeValue, newId)
import Products.Autopilot.Hpa.Window (activeWindow, nextWindowStart, schedulesOverlap, validateKind)
import Products.Autopilot.Scaler.Autoscaler
import Products.Autopilot.Scaler.Gcp
import Products.Autopilot.Scaler.Logic
import Products.Autopilot.Scaler.Store
import Products.Autopilot.Scaler.Types
import Products.Autopilot.Scaler.Worker (loadGuardrail)
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Servant
import Shared.API.Response (APISuccess (..))

-- ---------------------------------------------------------------------------
-- API

type ScalerAPI =
    -- Targets
    "scaler" :> Protected 'AP_HPA_VIEW :> "targets" :> QueryParam "kind" Text :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "discover" :> QueryParam "kind" Text :> QueryParam "project" Text :> QueryParam "location" Text :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> ReqBody '[JSON] TargetReq :> Post '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> ReqBody '[JSON] TargetEdit :> Put '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> Delete '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "targets" :> Capture "kind" Text :> Capture "id" Text :> Get '[JSON] Value
        -- Guardrail
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "guardrail" :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "guardrail" :> ReqBody '[JSON] Guardrail :> Put '[JSON] APISuccess
        -- The autoscaler that drives a target
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "autoscaler" :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "autoscaler" :> ReqBody '[JSON] AutoscalerEdit :> Put '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "autoscaler" :> "revert" :> ReqBody '[JSON] RevertReq :> Post '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "autoscaler" :> "pause" :> ReqBody '[JSON] NoteReq :> Post '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_GUARDRAIL_EDIT :> "targets" :> Capture "kind" Text :> Capture "id" Text :> "autoscaler" :> "resume" :> ReqBody '[JSON] NoteReq :> Post '[JSON] APISuccess
        -- Schedules
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "schedules" :> QueryParam "kind" Text :> QueryParam "target" Text :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "schedules" :> "preview" :> ReqBody '[JSON] PreviewReq :> Post '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> ReqBody '[JSON] ScheduleReq :> Post '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> ReqBody '[JSON] ScheduleReq :> Put '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> "pause" :> Post '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> "resume" :> Post '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_SCHEDULE_EDIT :> "schedules" :> Capture "id" Text :> Delete '[JSON] APISuccess
        -- Applies (the ledger)
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "applies" :> QueryParam "kind" Text :> QueryParam "target" Text :> QueryParam "status" Text :> QueryParam "limit" Int :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_VIEW :> "applies" :> Capture "id" Text :> Get '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_APPLY :> "applies" :> ReqBody '[JSON] ManualApplyReq :> Post '[JSON] Value
        :<|> "scaler" :> Protected 'AP_HPA_APPLY :> "applies" :> Capture "id" Text :> "restore" :> Post '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_ROLLBACK :> "applies" :> Capture "id" Text :> "rollback" :> Post '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_ROLLBACK :> "applies" :> Capture "id" Text :> "cancel" :> Post '[JSON] APISuccess
        :<|> "scaler" :> Protected 'AP_HPA_ROLLBACK :> "applies" :> Capture "id" Text :> "acknowledge" :> Post '[JSON] APISuccess

scalerServer :: ServerT ScalerAPI Flow
scalerServer =
    listTargetsH
        :<|> discoverH
        :<|> addTargetH
        :<|> editTargetH
        :<|> deleteTargetH
        :<|> targetDetailH
        :<|> getGuardrailH
        :<|> putGuardrailH
        :<|> getAutoscalerH
        :<|> editAutoscalerH
        :<|> revertAutoscalerH
        :<|> pauseAutoscalerH
        :<|> resumeAutoscalerH
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

data TargetReq = TargetReq
    { trKind :: TargetKind
    , trName :: Text
    , trProject :: Text
    , trLocation :: Text
    , trCluster :: Maybe Text
    , trResource :: Text
    , trJob :: Maybe Text
    , trJobLocation :: Maybe Text
    }

instance FromJSON TargetReq where
    parseJSON = A.withObject "TargetReq" $ \o ->
        TargetReq
            <$> o .: "kind"
            <*> o .: "name"
            <*> o .: "project"
            <*> o .: "location"
            <*> o .:? "cluster"
            <*> o .: "resource"
            <*> o .:? "autoscalerJob"
            <*> o .:? "autoscalerLocation"

data TargetEdit = TargetEdit
    { teName :: Text
    , teJob :: Maybe Text
    , teJobLocation :: Maybe Text
    }

instance FromJSON TargetEdit where
    parseJSON = A.withObject "TargetEdit" $ \o ->
        TargetEdit <$> o .: "name" <*> o .:? "autoscalerJob" <*> o .:? "autoscalerLocation"

data AutoscalerEdit = AutoscalerEdit
    { aeSet :: [(Text, Value)]
    , aeRules :: Maybe Value
    , aeExpected :: Text
    , aeNote :: Text
    }

instance FromJSON AutoscalerEdit where
    parseJSON = A.withObject "AutoscalerEdit" $ \o -> do
        s <- o .:? "set" .!= (KM.empty :: A.Object)
        AutoscalerEdit [(K.toText k, v) | (k, v) <- KM.toList s]
            <$> o .:? "rules"
            <*> o .: "expectedData"
            <*> o .:? "note" .!= ""

data RevertReq = RevertReq {rvHistoryId :: Int, rvExpected :: Text}

instance FromJSON RevertReq where
    parseJSON = A.withObject "RevertReq" $ \o -> RevertReq <$> o .: "historyId" <*> o .: "expectedData"

newtype NoteReq = NoteReq Text

instance FromJSON NoteReq where
    parseJSON = A.withObject "NoteReq" $ \o -> NoteReq <$> o .:? "note" .!= ""

data ScheduleReq = ScheduleReq
    { sqKind :: TargetKind
    , sqTargetId :: Text
    , sqName :: Text
    , sqTiming :: ScheduleKind
    , sqChange :: ScaleChange
    }

instance FromJSON ScheduleReq where
    parseJSON = A.withObject "ScheduleReq" $ \o ->
        ScheduleReq <$> o .: "targetKind" <*> o .: "targetId" <*> o .: "name" <*> o .: "timing" <*> o .: "change"

data PreviewReq = PreviewReq
    { pqKind :: TargetKind
    , pqTargetId :: Text
    , pqChange :: ScaleChange
    , pqTiming :: Maybe ScheduleKind
    , pqExcludeScheduleId :: Maybe Text
    -- ^ the schedule being edited, so it is not reported as overlapping itself
    }

instance FromJSON PreviewReq where
    parseJSON = A.withObject "PreviewReq" $ \o ->
        PreviewReq <$> o .: "targetKind" <*> o .: "targetId" <*> o .: "change" <*> o .:? "timing" <*> o .:? "excludeScheduleId"

data ManualApplyReq = ManualApplyReq
    { maKind :: TargetKind
    , maTargetId :: Text
    , maChange :: ScaleChange
    , maEndAt :: Maybe UTCTime
    }

instance FromJSON ManualApplyReq where
    parseJSON = A.withObject "ManualApplyReq" $ \o ->
        ManualApplyReq <$> o .: "targetKind" <*> o .: "targetId" <*> o .: "change" <*> o .:? "endAt"

-- ---------------------------------------------------------------------------
-- Helpers

bad :: Text -> Flow a
bad = throwM . BadRequest

cloudOf :: Flow Text
cloudOf = cloudProvider <$> getConfig

gcp :: Gcp
gcp = mkGcp

audit :: AuthedPerson -> Text -> Text -> Text -> Value -> Flow ()
audit ap action entity eid details = writeAuditLog (apPersonId ap) action (Just entity) (Just eid) (Just details)

kindOr400 :: Text -> Flow TargetKind
kindOr400 k = maybe (bad ("unknown target kind '" <> k <> "' (use REDIS or DB)")) pure (parseTargetKind k)

targetOr404 :: TargetKind -> Text -> Flow Target
targetOr404 kind tid = do
    cloud <- cloudOf
    getTarget cloud kind tid >>= maybe (throwM (NotFound "Target not found")) pure

-- | Read the target from Google Cloud and check it is what it was registered as.
liveState :: Target -> Flow InstanceState
liveState tg = do
    r <- liftIO (gcpGetState gcp tg)
    case r of
        Left (GcpNotFound m) -> throwM (NotFound ("not found in Google Cloud: " <> m))
        Left e -> throwM (InternalError ("cannot read the instance: " <> gcpErrText e))
        Right st
            | modeKind (isMode st) /= tgKind tg -> bad "that instance is not the kind of target it was registered as"
            | otherwise -> pure st

nonTerminal :: ApplyRow -> Bool
nonTerminal a = maybe True (not . isTerminalApply) (parseApplyStatus (arStatus a))

windowJson :: UTCTime -> ScheduleRow -> Value
windowJson now s = case decodeValue (srTiming s) of
    Left (e :: Text) -> A.object ["error" .= e]
    Right k ->
        A.object
            [ "windowOpen" .= isJust (activeWindow k now)
            , "nextStart" .= nextWindowStart k now
            ]

scheduleWithWindow :: UTCTime -> ScheduleRow -> Value
scheduleWithWindow now s = case toJSON s of
    Object o -> Object (KM.insert "window" (windowJson now s) o)
    v -> v

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ---------------------------------------------------------------------------
-- Targets

listTargetsH :: AuthedPerson -> Maybe Text -> Flow Value
listTargetsH _ mKind = do
    kind <- traverse kindOr400 mKind
    cloud <- cloudOf
    targets <- listTargets cloud kind
    schedules <- listSchedules cloud kind Nothing
    applies <- listApplies cloud kind Nothing Nothing 300
    now <- liftIO getCurrentTime
    rows <- forM targets $ \t -> do
        live <- liftIO (gcpGetState gcp t)
        let mine = [s | s <- schedules, srTargetKind s == targetKindText (tgKind t), srTargetId s == tgId t]
            active = [s | s <- mine, srStatus s == "ACTIVE"]
            inflight = [a | a <- applies, arTargetKind a == targetKindText (tgKind t), arTargetId a == tgId t, nonTerminal a]
        pure $
            A.object
                [ "target" .= t
                , "state" .= either (const Null) toJSON live
                , "cloudError" .= either (Just . gcpErrText) (const Nothing) live
                , "schedules" .= length mine
                , "activeSchedules" .= length active
                , "windowOpen" .= or [isJust (activeWindow k now) | s <- active, Right k <- [decodeValue (srTiming s)]]
                , "inflight" .= [A.object ["id" .= arId a, "status" .= arStatus a] | a <- inflight]
                ]
    pure (A.object ["targets" .= rows])

discoverH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Flow Value
discoverH _ mKind mProject mLocation = do
    kind <- maybe (bad "kind is required (REDIS or DB)") kindOr400 mKind
    let project = T.strip (fromMaybe "" mProject)
        location = T.strip (fromMaybe "" mLocation)
    when (T.null project || T.null location) (bad "project and location are required")
    unless (safeSegment project && safeSegment location) (bad "project and location may only contain letters, digits, '-' and '_'")
    cloud <- cloudOf
    found <- liftIO (gcpDiscover gcp kind project location)
    registered <- listTargets cloud (Just kind)
    case found of
        Left e -> pure (A.object ["error" .= gcpErrText e, "items" .= ([] :: [Value])])
        Right ds ->
            pure $
                A.object
                    [ "items"
                        .= [ A.object
                                [ "cluster" .= dsParent d
                                , "resource" .= dsResource d
                                , "state" .= dsState d
                                , "registered" .= any (\t -> tgResource t == dsResource d && tgParent t == dsParent d && tgProject t == project && tgLocation t == location) registered
                                ]
                           | d <- ds
                           ]
                    ]

-- | Names that go into URLs and resource paths.
checkSegments :: Target -> Flow ()
checkSegments t = do
    let required = [("project", tgProject t), ("location", tgLocation t), ("resource", tgResource t)] <> [("cluster", c) | Just c <- [tgParent t]]
    forM_ required $ \(label, v) ->
        unless (safeSegment v) (bad (label <> " may only contain letters, digits, '-' and '_'"))
    when (tgKind t == KindDb && tgParent t == Nothing) (bad "a database target needs its AlloyDB cluster")
    forM_ (tgJob t) $ \j -> unless (safeSegment j) (bad "autoscalerJob may only contain letters, digits, '-' and '_'")
    forM_ (tgJobLocation t) $ \l -> unless (safeSegment l) (bad "autoscalerLocation may only contain letters, digits, '-' and '_'")
    let n = T.strip (tgName t)
    when (T.null n || T.length n > 100) (bad "name must be 1..100 characters")

{- | If an autoscaler job is configured, it must be readable and have an entry for this target, so the editor and
the scale-in hold cannot fail later for a reason we could have seen.
-}
checkJob :: Target -> Flow ()
checkJob t = forM_ (tgJob t) $ \_ -> do
    r <- liftIO (gcpGetJob gcp t)
    case r of
        Left e -> bad ("cannot read the autoscaler job: " <> gcpErrText e)
        Right j -> case decodeJobData (sjData j) >>= entryFor (autoscalerKeys t) of
            Left e -> bad ("the autoscaler job does not manage this target: " <> e)
            Right _ -> pure ()

normalise :: Target -> Target
normalise t =
    t
        { tgName = T.strip (tgName t)
        , tgJob = blankToNothing (tgJob t)
        , tgJobLocation = blankToNothing (tgJobLocation t)
        }
  where
    blankToNothing m = case fmap T.strip m of
        Just s | not (T.null s) -> Just s
        _ -> Nothing

addTargetH :: AuthedPerson -> TargetReq -> Flow Value
addTargetH ap req = do
    tid <- newId
    let t =
            normalise
                Target
                    { tgId = tid
                    , tgKind = trKind req
                    , tgName = trName req
                    , tgProject = T.strip (trProject req)
                    , tgLocation = T.strip (trLocation req)
                    , tgParent = if trKind req == KindDb then fmap T.strip (trCluster req) else Nothing
                    , tgResource = T.strip (trResource req)
                    , tgJob = trJob req
                    , tgJobLocation = trJobLocation req
                    }
    checkSegments t
    st <- liveState t
    checkJob t
    cloud <- cloudOf
    ok <- insertTarget cloud t (apEmail ap)
    unless ok (throwM (Conflict "this instance is already registered"))
    audit ap "SCALER_TARGET_ADD" "scaler_target" tid (toJSON t)
    pure (A.object ["id" .= tid, "state" .= st])

editTargetH :: AuthedPerson -> Text -> Text -> TargetEdit -> Flow APISuccess
editTargetH ap kindT tid req = do
    kind <- kindOr400 kindT
    existing <- targetOr404 kind tid
    let t = normalise existing {tgName = teName req, tgJob = teJob req, tgJobLocation = teJobLocation req}
    checkSegments t
    checkJob t
    cloud <- cloudOf
    ok <- updateTarget cloud t
    unless ok (throwM (NotFound "Target not found"))
    audit ap "SCALER_TARGET_EDIT" "scaler_target" tid (toJSON t)
    pure Success

deleteTargetH :: AuthedPerson -> Text -> Text -> Flow APISuccess
deleteTargetH ap kindT tid = do
    kind <- kindOr400 kindT
    t <- targetOr404 kind tid
    cloud <- cloudOf
    n <- targetInUse cloud kind tid
    when (n > 0) (throwM (Conflict ("this target still has " <> tshow n <> " schedule(s) or in-flight change(s); delete or finish them first")))
    _ <- deleteTarget cloud kind tid
    audit ap "SCALER_TARGET_DELETE" "scaler_target" tid (toJSON t)
    pure Success

targetDetailH :: AuthedPerson -> Text -> Text -> Flow Value
targetDetailH _ kindT tid = do
    kind <- kindOr400 kindT
    t <- targetOr404 kind tid
    cloud <- cloudOf
    live <- liftIO (gcpGetState gcp t)
    g <- loadGuardrail cloud kind tid
    schedules <- listSchedules cloud (Just kind) (Just tid)
    applies <- listApplies cloud (Just kind) (Just tid) Nothing 50
    events <- listEventsForTarget cloud kind tid 50
    now <- liftIO getCurrentTime
    rows <- forM schedules $ \s -> do
        mine <- appliesForSchedule cloud (srId s)
        pure $ case scheduleWithWindow now s of
            Object o -> Object (KM.insert "applies" (toJSON (take 20 mine)) o)
            v -> v
    autoscaler <- autoscalerSummary cloud t
    pure $
        A.object
            [ "target" .= t
            , "state" .= either (const Null) toJSON live
            , "cloudError" .= either (Just . gcpErrText) (const Nothing) live
            , "guardrail" .= g
            , "schedules" .= rows
            , "applies" .= applies
            , "events" .= events
            , "autoscaler" .= autoscaler
            ]

-- | A short look at the autoscaler for the target page; the full editor has its own endpoint.
autoscalerSummary :: Text -> Target -> Flow Value
autoscalerSummary cloud t = case tgJob t of
    Nothing -> pure (A.object ["configured" .= False])
    Just _ -> do
        r <- readAutoscaler gcp cloud t
        pure $ case r of
            Left e -> A.object ["configured" .= True, "ok" .= False, "error" .= editErrText e]
            Right v -> A.object ["configured" .= True, "ok" .= True, "state" .= avState v, "heldBy" .= avHeldBy v]

-- ---------------------------------------------------------------------------
-- Guardrail

getGuardrailH :: AuthedPerson -> Text -> Text -> Flow Value
getGuardrailH _ kindT tid = do
    kind <- kindOr400 kindT
    _ <- targetOr404 kind tid
    cloud <- cloudOf
    toJSON <$> loadGuardrail cloud kind tid

putGuardrailH :: AuthedPerson -> Text -> Text -> Guardrail -> Flow APISuccess
putGuardrailH ap kindT tid g = do
    kind <- kindOr400 kindT
    _ <- targetOr404 kind tid
    let cap = if kind == KindDb then unitsHardCap ModeReadPool else unitsHardCap ModeCluster
        issues =
            [ "maxUnits must be 1.." <> tshow cap | Just n <- [grMaxUnits g], n < 1 || n > cap ]
                <> [ "maxReplicas must be 0.." <> tshow maxReplicasHardCap | Just n <- [grMaxReplicas g], n < 0 || n > maxReplicasHardCap ]
                <> [ "maxStep must be >= 1" | Just n <- [grMaxStep g], n < 1 ]
    unless (null issues) (bad (T.intercalate "; " issues))
    cloud <- cloudOf
    putGuardrailRow cloud kind tid (toJSON g) (apEmail ap)
    audit ap "SCALER_GUARDRAIL_UPDATE" "scaler_guardrail" tid (toJSON g)
    pure Success

-- ---------------------------------------------------------------------------
-- The autoscaler that drives a target

editErrToApi :: EditErr -> Flow a
editErrToApi (EditBad ms) = bad (T.intercalate "; " ms)
editErrToApi (EditConflict m) = throwM (Conflict m)
editErrToApi (EditNotFound m) = throwM (NotFound m)
editErrToApi (EditCloud m) = throwM (InternalError m)

getAutoscalerH :: AuthedPerson -> Text -> Text -> Flow Value
getAutoscalerH _ kindT tid = do
    kind <- kindOr400 kindT
    t <- targetOr404 kind tid
    cloud <- cloudOf
    r <- readAutoscaler gcp cloud t
    history <- listAutoscalerHistory cloud kind tid 30
    case r of
        Left e -> pure (A.object ["ok" .= False, "error" .= editErrText e, "history" .= history])
        Right v ->
            pure $
                A.object
                    [ "ok" .= True
                    , "job" .= avJob v
                    , "jobLocation" .= avJobLocation v
                    , "state" .= avState v
                    , "schedule" .= avSchedule v
                    , "data" .= avData v
                    , "entry" .= avEntry v
                    , "editable" .= [A.object ["key" .= k, "kind" .= keyKindJson kk] | (k, kk) <- avEditable v]
                    , "heldBy" .= avHeldBy v
                    , "history" .= history
                    ]

keyKindJson :: KeyKind -> Value
keyKindJson (KInt lo hi) = A.object ["type" .= ("int" :: Text), "min" .= lo, "max" .= hi]
keyKindJson (KEnum opts) = A.object ["type" .= ("enum" :: Text), "options" .= opts]

editAutoscalerH :: AuthedPerson -> Text -> Text -> AutoscalerEdit -> Flow Value
editAutoscalerH ap kindT tid req = do
    kind <- kindOr400 kindT
    t <- targetOr404 kind tid
    cloud <- cloudOf
    r <- editAutoscaler gcp cloud t (apEmail ap) "EDIT" (EditReq (aeSet req) (aeRules req)) (aeExpected req) (aeNote req)
    case r of
        Left e -> editErrToApi e
        Right after -> do
            audit ap "SCALER_AUTOSCALER_EDIT" "scaler_target" tid (A.object ["keys" .= map fst (aeSet req), "rules" .= isJust (aeRules req), "note" .= aeNote req])
            pure (A.object ["entry" .= after])

revertAutoscalerH :: AuthedPerson -> Text -> Text -> RevertReq -> Flow Value
revertAutoscalerH ap kindT tid req = do
    kind <- kindOr400 kindT
    t <- targetOr404 kind tid
    cloud <- cloudOf
    r <- revertAutoscaler gcp cloud t (apEmail ap) (rvHistoryId req) (rvExpected req)
    case r of
        Left e -> editErrToApi e
        Right after -> do
            audit ap "SCALER_AUTOSCALER_REVERT" "scaler_target" tid (A.object ["historyId" .= rvHistoryId req])
            pure (A.object ["entry" .= after])

pauseAutoscalerH, resumeAutoscalerH :: AuthedPerson -> Text -> Text -> NoteReq -> Flow APISuccess
pauseAutoscalerH ap kindT tid (NoteReq note) = setPaused ap kindT tid True note
resumeAutoscalerH ap kindT tid (NoteReq note) = setPaused ap kindT tid False note

setPaused :: AuthedPerson -> Text -> Text -> Bool -> Text -> Flow APISuccess
setPaused ap kindT tid paused note = do
    kind <- kindOr400 kindT
    t <- targetOr404 kind tid
    cloud <- cloudOf
    r <- setAutoscalerPaused gcp cloud t (apEmail ap) paused note
    case r of
        Left e -> editErrToApi e
        Right () -> do
            audit ap (if paused then "SCALER_AUTOSCALER_PAUSE" else "SCALER_AUTOSCALER_RESUME") "scaler_target" tid (A.object ["note" .= note])
            pure Success

-- ---------------------------------------------------------------------------
-- Schedules

listSchedulesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Flow Value
listSchedulesH _ mKind mTarget = do
    kind <- traverse kindOr400 mKind
    cloud <- cloudOf
    now <- liftIO getCurrentTime
    schedules <- listSchedules cloud kind mTarget
    rows <- forM schedules $ \s -> do
        applies <- appliesForSchedule cloud (srId s)
        pure $ case scheduleWithWindow now s of
            Object o -> Object (KM.insert "applies" (toJSON (take 20 applies)) o)
            v -> v
    pure (A.object ["schedules" .= rows])

{- | Everything a schedule or manual apply must satisfy, against the live target and its autoscaler job. Throws
the first problem as a 400 so nothing unusable is stored.
-}
checkChange :: Target -> ScaleChange -> Flow InstanceState
checkChange t change = do
    st <- liveState t
    let structural = validateChange (isMode st) change
    unless (null structural) (bad (T.intercalate "; " structural))
    when (scBlockScaleIn change) $ do
        when (tgJob t == Nothing) (bad "this target has no autoscaler job, so its scale-in cannot be blocked (set one on the target first)")
        checkJob t
    cloud <- cloudOf
    g <- loadGuardrail cloud (tgKind t) (tgId t)
    -- A freeze is a pause on applying, not a reason to refuse saving a schedule.
    case planCapacity g {grFrozen = False} st change of
        Left issues -> bad (T.intercalate "; " issues)
        Right _ -> pure st

validateScheduleReq :: Target -> Maybe Text -> Text -> ScheduleKind -> ScaleChange -> Flow ()
validateScheduleReq t excludeId name timing change = do
    let n = T.strip name
    when (T.null n || T.length n > 100) (bad "name must be 1..100 characters")
    let structural = validateKind timing
    unless (null structural) (bad (T.intercalate "; " structural))
    now <- liftIO getCurrentTime
    case timing of
        Once _ (Just end) | end <= now -> bad "endAt is in the past"
        _ -> pure ()
    _ <- checkChange t change
    cloud <- cloudOf
    others <- schedulesForTarget cloud (tgKind t) (tgId t)
    forM_ [o | o <- others, Just (srId o) /= excludeId] $ \o ->
        case decodeValue (srTiming o) of
            Right ok
                | schedulesOverlap now 14 timing ok ->
                    throwM (Conflict ("overlaps the windows of schedule '" <> srName o <> "'; one target can hold one change at a time"))
            _ -> pure ()

previewH :: AuthedPerson -> PreviewReq -> Flow Value
previewH _ req = do
    t <- targetOr404 (pqKind req) (pqTargetId req)
    cloud <- cloudOf
    st <- liveState t
    g <- loadGuardrail cloud (tgKind t) (tgId t)
    let change = pqChange req
        structural = validateChange (isMode st) change
        verdict = planCapacity g st change
    autoscaler <-
        if scBlockScaleIn change
            then
                if tgJob t == Nothing
                    then pure (A.object ["ok" .= False, "error" .= ("this target has no autoscaler job configured" :: Text)])
                    else do
                        r <- liftIO (gcpGetJob gcp t)
                        pure $ case r of
                            Left e -> A.object ["ok" .= False, "error" .= gcpErrText e]
                            Right job -> case decodeJobData (sjData job) >>= readMinimum (autoscalerKeys t) of
                                Left e -> A.object ["ok" .= False, "error" .= e]
                                Right n -> A.object ["ok" .= True, "minimum" .= n, "wouldPin" .= maybe False (n <) (scUnits change), "jobState" .= sjState job]
            else pure Null
    overlapping <- case pqTiming req of
        Nothing -> pure []
        Just timing -> do
            now <- liftIO getCurrentTime
            others <- schedulesForTarget cloud (tgKind t) (tgId t)
            pure [srName o | o <- others, Just (srId o) /= pqExcludeScheduleId req, Right ok <- [decodeValue (srTiming o)], schedulesOverlap now 14 timing ok]
    pure $
        A.object
            [ "state" .= st
            , "valid" .= null structural
            , "issues" .= structural
            , "plan" .= planJson (isMode st) verdict
            , "refusedBecause" .= either id (const []) verdict
            , "autoscaler" .= autoscaler
            , "overlaps" .= overlapping
            ]

planJson :: InstanceMode -> Either [Text] CapacityPlan -> Value
planJson mode (Right p) = A.object ["units" .= cpUnits p, "replicas" .= cpReplicas p, "noop" .= planIsNoop p, "summary" .= describePlan mode p]
planJson _ (Left _) = Null

createScheduleH :: AuthedPerson -> ScheduleReq -> Flow Value
createScheduleH ap req = do
    t <- targetOr404 (sqKind req) (sqTargetId req)
    validateScheduleReq t Nothing (sqName req) (sqTiming req) (sqChange req)
    cloud <- cloudOf
    sid <- newId
    insertSchedule cloud sid (tgKind t) (tgId t) (T.strip (sqName req)) (toJSON (sqTiming req)) (toJSON (sqChange req)) (apEmail ap)
    audit ap "SCALER_SCHEDULE_CREATE" "scaler_schedule" sid (A.object ["target" .= tgName t, "name" .= sqName req, "change" .= sqChange req])
    pure (A.object ["id" .= sid])

updateScheduleH :: AuthedPerson -> Text -> ScheduleReq -> Flow Value
updateScheduleH ap sid req = do
    cloud <- cloudOf
    existing <- getSchedule cloud sid >>= maybe (throwM (NotFound "Schedule not found")) pure
    kind <- kindOr400 (srTargetKind existing)
    -- The target of a schedule is fixed; edit the window and the change only.
    t <- targetOr404 kind (srTargetId existing)
    validateScheduleReq t (Just sid) (sqName req) (sqTiming req) (sqChange req)
    ok <- updateSchedule cloud sid (T.strip (sqName req)) (toJSON (sqTiming req)) (toJSON (sqChange req))
    unless ok (throwM (NotFound "Schedule not found"))
    audit ap "SCALER_SCHEDULE_UPDATE" "scaler_schedule" sid (A.object ["name" .= sqName req, "change" .= sqChange req])
    pure (A.object ["id" .= sid])

setStatus :: AuthedPerson -> Text -> ScheduleStatus -> ScheduleStatus -> Text -> Flow APISuccess
setStatus ap sid from to action = do
    cloud <- cloudOf
    s <- getSchedule cloud sid >>= maybe (throwM (NotFound "Schedule not found")) pure
    when (srStatus s /= scheduleStatusText from) (throwM (Conflict ("schedule is " <> srStatus s <> ", not " <> scheduleStatusText from)))
    _ <- setScheduleStatus cloud sid (scheduleStatusText to)
    audit ap action "scaler_schedule" sid (A.object ["name" .= srName s])
    pure Success

pauseScheduleH :: AuthedPerson -> Text -> Flow APISuccess
pauseScheduleH ap sid = setStatus ap sid SchedActive SchedPaused "SCALER_SCHEDULE_PAUSE"

resumeScheduleH :: AuthedPerson -> Text -> Flow APISuccess
resumeScheduleH ap sid = setStatus ap sid SchedPaused SchedActive "SCALER_SCHEDULE_RESUME"

{- | Deleting a schedule never strands a change: applies that have not started are cancelled, and ones that are
holding a change are sent to restore at once.
-}
deleteScheduleH :: AuthedPerson -> Text -> Flow APISuccess
deleteScheduleH ap sid = do
    cloud <- cloudOf
    s <- getSchedule cloud sid >>= maybe (throwM (NotFound "Schedule not found")) pure
    kind <- kindOr400 (srTargetKind s)
    _ <- deleteSchedule cloud sid
    applies <- appliesForSchedule cloud sid
    forM_ (filter nonTerminal applies) $ \a -> do
        let why = Just "the schedule was deleted"
        _ <- forceTransition (arId a) cloud [Pending] Skipped why
        _ <- forceTransition (arId a) cloud [Applied, Observing] Restoring why
        -- Mid-apply (the worker may have just claimed it): undo whatever it has done so far.
        _ <- forceTransition (arId a) cloud [Applying] RollingBack why
        addEvent cloud (Just (arId a)) (Just sid) kind (arTargetId a) "schedule_deleted" ("schedule deleted by " <> apEmail ap) Null
    audit ap "SCALER_SCHEDULE_DELETE" "scaler_schedule" sid (A.object ["name" .= srName s])
    pure Success

-- ---------------------------------------------------------------------------
-- Applies

listAppliesH :: AuthedPerson -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Int -> Flow Value
listAppliesH _ mKind mTarget mStatus mLimit = do
    kind <- traverse kindOr400 mKind
    cloud <- cloudOf
    when (maybe False (\st -> parseApplyStatus st == Nothing) mStatus) (bad "unknown status")
    rows <- listApplies cloud kind mTarget mStatus (max 1 (min 500 (fromMaybe 100 mLimit)))
    pure (A.object ["applies" .= rows])

getApplyH :: AuthedPerson -> Text -> Flow Value
getApplyH _ aid = do
    cloud <- cloudOf
    row <- getApply cloud aid >>= maybe (throwM (NotFound "Apply not found")) pure
    evs <- listEventsForApply cloud aid
    pure (A.object ["apply" .= row, "events" .= evs])

manualApplyH :: AuthedPerson -> ManualApplyReq -> Flow Value
manualApplyH ap req = do
    t <- targetOr404 (maKind req) (maTargetId req)
    now <- liftIO getCurrentTime
    case maEndAt req of
        Just end | end <= now -> bad "endAt is in the past"
        _ -> pure ()
    _ <- checkChange t (maChange req)
    cloud <- cloudOf
    inflight <- inflightApplies cloud (tgKind t) (tgId t)
    unless (null inflight) (throwM (Conflict "this target already has a change in flight"))
    aid <- newId
    ok <-
        insertApply
            ApplyNew
                { anId = aid
                , anCloud = cloud
                , anScheduleId = Nothing
                , anTrigger = applyTriggerText TrigManual
                , anKind = tgKind t
                , anTargetId = tgId t
                , anChange = toJSON (maChange req)
                , anWindowStart = Nothing
                , anWindowEnd = maEndAt req
                , anCreatedBy = apEmail ap
                }
    unless ok (throwM (Conflict "this target already has a change in flight"))
    addEvent cloud (Just aid) Nothing (tgKind t) (tgId t) "manual" ("manual apply requested by " <> apEmail ap) (A.object ["change" .= maChange req])
    audit ap "SCALER_APPLY" "scaler_apply" aid (A.object ["target" .= tgName t, "change" .= maChange req])
    pure (A.object ["id" .= aid])

lifecycle :: AuthedPerson -> Text -> [ApplyStatus] -> ApplyStatus -> Text -> Text -> Flow APISuccess
lifecycle ap aid froms to reason action = do
    cloud <- cloudOf
    row <- getApply cloud aid >>= maybe (throwM (NotFound "Apply not found")) pure
    kind <- kindOr400 (arTargetKind row)
    ok <- forceTransition aid cloud froms to (Just (reason <> " by " <> apEmail ap))
    unless ok $
        throwM (Conflict ("cannot " <> action <> " an apply that is " <> arStatus row))
    addEvent cloud (Just aid) (arScheduleId row) kind (arTargetId row) (T.toLower action) (reason <> " by " <> apEmail ap) Null
    audit ap ("SCALER_" <> T.toUpper action) "scaler_apply" aid (A.object ["target" .= arTargetId row])
    pure Success

restoreApplyH :: AuthedPerson -> Text -> Flow APISuccess
restoreApplyH ap aid = lifecycle ap aid [Applied, Observing, NeedsAttention] Restoring "restore requested" "RESTORE"

rollbackApplyH :: AuthedPerson -> Text -> Flow APISuccess
rollbackApplyH ap aid = lifecycle ap aid [Applying, Observing, Applied, NeedsAttention] RollingBack "manual rollback" "ROLLBACK"

cancelApplyH :: AuthedPerson -> Text -> Flow APISuccess
cancelApplyH ap aid = lifecycle ap aid [Pending] Skipped "cancelled" "CANCEL"

{- | Acknowledging a parked apply gives it up: it goes through ROLLING_BACK, which puts the autoscaler's minimum
back (a no-op if nothing was pinned) and keeps any capacity already added. It never leaves a pin behind.
-}
acknowledgeApplyH :: AuthedPerson -> Text -> Flow APISuccess
acknowledgeApplyH ap aid = lifecycle ap aid [NeedsAttention] RollingBack "acknowledged" "ACKNOWLEDGE"
