{-# LANGUAGE OverloadedStrings #-}

{- | Domain types for the HPA scheduler: what a schedule changes ('HpaChange'),
when it applies ('ScheduleKind'), how a change is judged healthy
('HealthPolicy'), hard limits ('Guardrail'), and the apply ledger's state
machine ('ApplyStatus').
-}
module Products.Autopilot.Hpa.Types (
    -- * What changes
    MetricTargetChange (..),
    HpaChange (..),
    emptyChange,
    changeIsEmpty,

    -- * When
    ScheduleKind (..),
    ScheduleStatus (..),
    scheduleStatusText,
    parseScheduleStatus,

    -- * Health / limits
    CmpOp (..),
    PromCheck (..),
    HealthPolicy (..),
    defaultHealthPolicy,
    validateHealthPolicy,
    Guardrail (..),
    defaultGuardrail,

    -- * Apply ledger
    ApplyStatus (..),
    applyStatusText,
    parseApplyStatus,
    validApplyTransition,
    isTerminalApply,
    blockingStatusTexts,
    terminalStatusTexts,
    ApplyTrigger (..),
    applyTriggerText,
    parseApplyTrigger,
    ApplyStep (..),
    applyStepText,
    parseApplyStep,

    -- * Annotation keys written on managed HPAs
    annScheduleId,
    annApplyId,
    annBaseSpec,
)
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), (.!=), (.:), (.:?), (.=))
import Data.Aeson qualified as A
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime)
import Products.Autopilot.Hpa.Spec

-- ---------------------------------------------------------------------------
-- Change

-- | Replace the target of one metric entry, addressed by 'metricKey'.
data MetricTargetChange = MetricTargetChange
    { mtcKey :: Text
    , mtcTarget :: MetricTarget
    }
    deriving (Eq, Show)

instance ToJSON MetricTargetChange where
    toJSON (MetricTargetChange k t) = A.object ["key" .= k, "target" .= t]

instance FromJSON MetricTargetChange where
    parseJSON = A.withObject "MetricTargetChange" $ \o ->
        MetricTargetChange <$> o .: "key" <*> o .: "target"

{- | The fields a schedule overrides. Anything left out is not touched, and is
therefore also not restored. @chScaleUp@/@chScaleDown@ replace that whole
direction's rules block.
-}
data HpaChange = HpaChange
    { chMinReplicas :: Maybe Int
    , chMaxReplicas :: Maybe Int
    , chMetricTargets :: [MetricTargetChange]
    , chScaleUp :: Maybe ScalingRules
    , chScaleDown :: Maybe ScalingRules
    }
    deriving (Eq, Show)

emptyChange :: HpaChange
emptyChange = HpaChange Nothing Nothing [] Nothing Nothing

changeIsEmpty :: HpaChange -> Bool
changeIsEmpty = (== emptyChange)

instance ToJSON HpaChange where
    toJSON c =
        A.object $
            maybe [] (\x -> ["minReplicas" .= x]) (chMinReplicas c)
                <> maybe [] (\x -> ["maxReplicas" .= x]) (chMaxReplicas c)
                <> ["metricTargets" .= chMetricTargets c | not (null (chMetricTargets c))]
                <> maybe [] (\x -> ["scaleUp" .= x]) (chScaleUp c)
                <> maybe [] (\x -> ["scaleDown" .= x]) (chScaleDown c)

instance FromJSON HpaChange where
    parseJSON = A.withObject "HpaChange" $ \o ->
        HpaChange
            <$> o .:? "minReplicas"
            <*> o .:? "maxReplicas"
            <*> o .:? "metricTargets" .!= []
            <*> o .:? "scaleUp"
            <*> o .:? "scaleDown"

-- ---------------------------------------------------------------------------
-- Schedule timing

{- | @Once start end@: apply at @start@; restore at @end@ (@Nothing@ = permanent
change, never restored). @Weekly days startMinute durationMinutes utcOffset@:
on the given ISO weekdays (Mon=1 .. Sun=7), apply at @startMinute@ (minutes
after local midnight) for @durationMinutes@. Local time is a fixed UTC offset
in minutes (no tz database, so no DST); pick the offset that matches the intent.
-}
data ScheduleKind
    = Once UTCTime (Maybe UTCTime)
    | Weekly [Int] Int Int Int
    deriving (Eq, Show)

instance ToJSON ScheduleKind where
    toJSON (Once s e) =
        A.object (["kind" .= ("ONCE" :: Text), "startAt" .= s] <> maybe [] (\x -> ["endAt" .= x]) e)
    toJSON (Weekly d sm dur off) =
        A.object
            [ "kind" .= ("WEEKLY" :: Text)
            , "days" .= d
            , "startTime" .= (pad2 (sm `div` 60) <> ":" <> pad2 (sm `mod` 60))
            , "durationMinutes" .= dur
            , "utcOffsetMinutes" .= off
            ]
      where
        pad2 n = T.justifyRight 2 '0' (T.pack (show n))

instance FromJSON ScheduleKind where
    parseJSON = A.withObject "ScheduleKind" $ \o -> do
        k <- o .: "kind"
        case (k :: Text) of
            "ONCE" -> Once <$> o .: "startAt" <*> o .:? "endAt"
            "WEEKLY" -> do
                days <- o .: "days"
                st <- o .: "startTime"
                dur <- o .: "durationMinutes"
                off <- o .:? "utcOffsetMinutes" .!= 0
                sm <- either fail pure (parseHHMM st)
                pure (Weekly days sm dur off)
            other -> fail ("unknown schedule kind: " <> T.unpack other)

parseHHMM :: Text -> Either String Int
parseHHMM t = case T.splitOn ":" t of
    [h, m]
        | T.all (`elem` ['0' .. '9']) h
        , T.all (`elem` ['0' .. '9']) m
        , not (T.null h)
        , not (T.null m)
        , T.length m == 2
        , let hh = read (T.unpack h) :: Int
        , let mm = read (T.unpack m) :: Int
        , hh <= 23
        , mm <= 59 ->
            Right (hh * 60 + mm)
    _ -> Left ("startTime must be HH:MM (00:00-23:59), got: " <> T.unpack t)

data ScheduleStatus = SchedActive | SchedPaused | SchedExpired
    deriving (Eq, Show)

scheduleStatusText :: ScheduleStatus -> Text
scheduleStatusText SchedActive = "ACTIVE"
scheduleStatusText SchedPaused = "PAUSED"
scheduleStatusText SchedExpired = "EXPIRED"

parseScheduleStatus :: Text -> Maybe ScheduleStatus
parseScheduleStatus "ACTIVE" = Just SchedActive
parseScheduleStatus "PAUSED" = Just SchedPaused
parseScheduleStatus "EXPIRED" = Just SchedExpired
parseScheduleStatus _ = Nothing

instance ToJSON ScheduleStatus where
    toJSON = String . scheduleStatusText

-- ---------------------------------------------------------------------------
-- Health policy

data CmpOp = OpGt | OpLt
    deriving (Eq, Show)

instance ToJSON CmpOp where
    toJSON OpGt = "GT"
    toJSON OpLt = "LT"

instance FromJSON CmpOp where
    parseJSON = A.withText "CmpOp" $ \t -> case t of
        "GT" -> pure OpGt
        "LT" -> pure OpLt
        other -> fail ("unknown comparison: " <> T.unpack other)

{- | An optional Prometheus instant query evaluated during the observation
window; the check FAILS when @value <op> threshold@ holds. The query may use
@{{namespace}}@, @{{service}}@ and @{{deployment}}@.
-}
data PromCheck = PromCheck
    { pcName :: Text
    , pcQuery :: Text
    , pcOp :: CmpOp
    , pcThreshold :: Double
    }
    deriving (Eq, Show)

instance ToJSON PromCheck where
    toJSON c = A.object ["name" .= pcName c, "query" .= pcQuery c, "op" .= pcOp c, "threshold" .= pcThreshold c]

instance FromJSON PromCheck where
    parseJSON = A.withObject "PromCheck" $ \o ->
        PromCheck <$> o .: "name" <*> o .: "query" <*> o .: "op" <*> o .: "threshold"

data HealthPolicy = HealthPolicy
    { hpAutoRollback :: Bool
    -- ^ Roll back automatically on a failed health check (otherwise only flag it).
    , hpObserveSeconds :: Int
    -- ^ How long to watch after the change before calling it good. 0 = don't observe.
    , hpMaxUnavailablePct :: Int
    -- ^ Breach when more than this % of desired pods are not ready ...
    , hpGraceSeconds :: Int
    -- ^ ... continuously for this long (scale-ups legitimately have unready pods).
    , hpRollbackOnScalingInactive :: Bool
    -- ^ Breach when the HPA reports ScalingActive=False (cannot read its metrics).
    , hpPromChecks :: [PromCheck]
    }
    deriving (Eq, Show)

defaultHealthPolicy :: HealthPolicy
defaultHealthPolicy = HealthPolicy True 300 50 180 True []

instance ToJSON HealthPolicy where
    toJSON p =
        A.object
            [ "autoRollback" .= hpAutoRollback p
            , "observeSeconds" .= hpObserveSeconds p
            , "maxUnavailablePct" .= hpMaxUnavailablePct p
            , "graceSeconds" .= hpGraceSeconds p
            , "rollbackOnScalingInactive" .= hpRollbackOnScalingInactive p
            , "promChecks" .= hpPromChecks p
            ]

-- | Every field is optional; missing ones take the default.
instance FromJSON HealthPolicy where
    parseJSON = A.withObject "HealthPolicy" $ \o ->
        HealthPolicy
            <$> o .:? "autoRollback" .!= hpAutoRollback d
            <*> o .:? "observeSeconds" .!= hpObserveSeconds d
            <*> o .:? "maxUnavailablePct" .!= hpMaxUnavailablePct d
            <*> o .:? "graceSeconds" .!= hpGraceSeconds d
            <*> o .:? "rollbackOnScalingInactive" .!= hpRollbackOnScalingInactive d
            <*> o .:? "promChecks" .!= []
      where
        d = defaultHealthPolicy

validateHealthPolicy :: HealthPolicy -> [Text]
validateHealthPolicy p =
    [ "observeSeconds must be 0..7200" | hpObserveSeconds p < 0 || hpObserveSeconds p > 7200 ]
        <> [ "maxUnavailablePct must be 1..100" | hpMaxUnavailablePct p < 1 || hpMaxUnavailablePct p > 100 ]
        <> [ "graceSeconds must be 0..7200" | hpGraceSeconds p < 0 || hpGraceSeconds p > 7200 ]
        <> concatMap promIssues (hpPromChecks p)
  where
    promIssues c =
        [ "promCheck name must not be empty" | T.null (T.strip (pcName c)) ]
            <> [ "promCheck '" <> pcName c <> "': query must not be empty" | T.null (T.strip (pcQuery c)) ]
            <> [ "promCheck '" <> pcName c <> "': query too long" | T.length (pcQuery c) > 2000 ]

-- ---------------------------------------------------------------------------
-- Guardrails

data Guardrail = Guardrail
    { grMaxReplicasCap :: Maybe Int
    , grMinReplicasFloor :: Maybe Int
    , grMaxStepPct :: Maybe Int
    -- ^ Largest allowed change of min or max replicas, as % of its current value.
    , grFrozen :: Bool
    , grFrozenReason :: Maybe Text
    }
    deriving (Eq, Show)

defaultGuardrail :: Guardrail
defaultGuardrail = Guardrail Nothing Nothing Nothing False Nothing

instance ToJSON Guardrail where
    toJSON g =
        A.object
            [ "maxReplicasCap" .= grMaxReplicasCap g
            , "minReplicasFloor" .= grMinReplicasFloor g
            , "maxStepPct" .= grMaxStepPct g
            , "frozen" .= grFrozen g
            , "frozenReason" .= grFrozenReason g
            ]

instance FromJSON Guardrail where
    parseJSON = A.withObject "Guardrail" $ \o ->
        Guardrail
            <$> o .:? "maxReplicasCap"
            <*> o .:? "minReplicasFloor"
            <*> o .:? "maxStepPct"
            <*> o .:? "frozen" .!= False
            <*> o .:? "frozenReason"

-- ---------------------------------------------------------------------------
-- Apply ledger

{- | Lifecycle of one application of a change to one HPA. The text forms are
written to the DB and referenced by the partial unique index in the
migration; keep 'blockingStatusTexts' in sync with it.
-}
data ApplyStatus
    = Pending
    | Applying
    | Observing
    | -- | Change is live and held; waiting for the window to end.
      Applied
    | Restoring
    | Restored
    | RollingBack
    | RolledBack
    | Failed
    | -- | Retries exhausted or state unrecoverable; a human must look.
      NeedsAttention
    | Skipped
    deriving (Eq, Show, Enum, Bounded)

applyStatusText :: ApplyStatus -> Text
applyStatusText s = case s of
    Pending -> "PENDING"
    Applying -> "APPLYING"
    Observing -> "OBSERVING"
    Applied -> "APPLIED"
    Restoring -> "RESTORING"
    Restored -> "RESTORED"
    RollingBack -> "ROLLING_BACK"
    RolledBack -> "ROLLED_BACK"
    Failed -> "FAILED"
    NeedsAttention -> "NEEDS_ATTENTION"
    Skipped -> "SKIPPED"

parseApplyStatus :: Text -> Maybe ApplyStatus
parseApplyStatus t = lookup t [(applyStatusText s, s) | s <- [minBound .. maxBound]]

instance ToJSON ApplyStatus where
    toJSON = String . applyStatusText

isTerminalApply :: ApplyStatus -> Bool
isTerminalApply s = s `elem` [Restored, RolledBack, Failed, Skipped]

-- | Statuses that still occupy the single in-flight slot of an HPA.
blockingStatusTexts :: [Text]
blockingStatusTexts = [applyStatusText s | s <- [minBound .. maxBound], not (isTerminalApply s)]

terminalStatusTexts :: [Text]
terminalStatusTexts = [applyStatusText s | s <- [minBound .. maxBound], isTerminalApply s]

validApplyTransition :: ApplyStatus -> ApplyStatus -> Bool
validApplyTransition from to = to `elem` allowed from
  where
    allowed Pending = [Applying, Skipped, Failed, NeedsAttention]
    allowed Applying = [Observing, Applied, RollingBack, Failed, NeedsAttention, Skipped]
    allowed Observing = [Applied, RollingBack, Restoring, NeedsAttention]
    allowed Applied = [Restoring, RollingBack, NeedsAttention]
    allowed Restoring = [Restored, NeedsAttention]
    allowed RollingBack = [RolledBack, NeedsAttention]
    allowed NeedsAttention = [Failed, Restoring, RollingBack]
    allowed Restored = []
    allowed RolledBack = []
    allowed Failed = []
    allowed Skipped = []

data ApplyTrigger = TrigScheduled | TrigManual
    deriving (Eq, Show)

applyTriggerText :: ApplyTrigger -> Text
applyTriggerText TrigScheduled = "SCHEDULED"
applyTriggerText TrigManual = "MANUAL"

parseApplyTrigger :: Text -> Maybe ApplyTrigger
parseApplyTrigger "SCHEDULED" = Just TrigScheduled
parseApplyTrigger "MANUAL" = Just TrigManual
parseApplyTrigger _ = Nothing

instance ToJSON ApplyTrigger where
    toJSON = String . applyTriggerText

{- | Where a worker got to. Written BEFORE and AFTER each side effect so a
successor that picks the row up after a crash knows what may have happened.
-}
data ApplyStep = StepPrecheck | StepSnapshot | StepPatch | StepVerify | StepObserve | StepRestore | StepRollback
    deriving (Eq, Show, Enum, Bounded)

applyStepText :: ApplyStep -> Text
applyStepText s = case s of
    StepPrecheck -> "PRECHECK"
    StepSnapshot -> "SNAPSHOT"
    StepPatch -> "PATCH"
    StepVerify -> "VERIFY"
    StepObserve -> "OBSERVE"
    StepRestore -> "RESTORE"
    StepRollback -> "ROLLBACK"

parseApplyStep :: Text -> Maybe ApplyStep
parseApplyStep t = lookup t [(applyStepText s, s) | s <- [minBound .. maxBound]]

-- ---------------------------------------------------------------------------

annScheduleId, annApplyId, annBaseSpec :: Text
annScheduleId = "sc.juspay.in/hpa-schedule-id"
annApplyId = "sc.juspay.in/hpa-apply-id"
annBaseSpec = "sc.juspay.in/hpa-base-spec"
