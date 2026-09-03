{-# LANGUAGE OverloadedStrings #-}

{- | Storage for QA automation config + triggered runs (@qa_automation_config@,
@qa_automation_run@).

Every query is cloud-scoped through 'withCloudDb', same as
"Products.Autopilot.Queries.ReleaseWebhook" — a config on the GCP instance
must not fire from the AWS one.
-}
module Products.Autopilot.Queries.QaAutomation (
    findConfigForAppGroup,
    upsertConfig,
    insertRun,
    updateRunResult,
    findRunsForRelease,
    findRunByRunId,
)
where

import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow)
import Data.Aeson (FromJSON, ToJSON, Value, decode, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Database.Beam
import GHC.Int (Int32)
import Products.Autopilot.Queries.ReleaseTracker (withCloudDb)
import Products.Autopilot.Types.QaAutomation
import Products.Autopilot.Types.Storage.Schema

-- Row <-> domain

decodeJsonList :: (FromJSON a) => Maybe Text -> [a]
decodeJsonList Nothing = []
decodeJsonList (Just t) = fromMaybe [] (decode (LBS.fromStrict (TE.encodeUtf8 t)))

encodeJsonList :: (ToJSON a) => [a] -> Text
encodeJsonList xs = TE.decodeUtf8 (LBS.toStrict (encode xs))

decodeJsonValue :: Maybe Text -> Maybe Value
decodeJsonValue Nothing = Nothing
decodeJsonValue (Just t) = decode (LBS.fromStrict (TE.encodeUtf8 t))

encodeJsonValue :: Value -> Text
encodeJsonValue v = TE.decodeUtf8 (LBS.toStrict (encode v))

configFromRow :: QaAutomationConfigRow -> QaAutomationConfig
configFromRow r =
    QaAutomationConfig
        { qcId = qacId r
        , qcAppGroup = qacAppGroup r
        , qcEnabled = qacEnabled r
        , qcOnSuccess = qacOnSuccess r
        , qcTestDashboardUrl = qacTestDashboardUrl r
        , qcWebhookToken = qacWebhookToken r
        , qcFlows = decodeJsonList (Just (qacFlows r))
        , qcEnvFile = qacEnvFile r
        , qcConcurrency = qacConcurrency r
        }

runFromRow :: QaAutomationRunRow -> QaAutomationRun
runFromRow r =
    QaAutomationRun
        { qrId = qarId r
        , qrRunId = qarRunId r
        , qrReleaseId = qarReleaseId r
        , qrAppGroup = qarAppGroup r
        , qrReleaseVersion = qarReleaseVersion r
        , qrStatus = qarStatus r
        , qrTriggerSource = qarTriggerSource r
        , qrTestDashboardUrl = qarTestDashboardUrl r
        , qrPassed = qarPassed r
        , qrFailed = qarFailed r
        , qrDetail = decodeJsonValue (qarDetail r)
        , qrCreatedAt = qarCreatedAt r
        , qrUpdatedAt = qarUpdatedAt r
        }

-- Reads

findConfigForAppGroup :: (MonadFlow m) => Text -> m (Maybe QaAutomationConfig)
findConfigForAppGroup grp = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    c <- all_ (qaAutomationConfigs autopilotDb)
                    guard_ (qacCloudType c ==. val_ cloud)
                    guard_ (qacAppGroup c ==. val_ grp)
                    pure c
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just (configFromRow x)

-- | Newest first — what the results tab lists.
findRunsForRelease :: (MonadFlow m) => Text -> m [QaAutomationRun]
findRunsForRelease rid = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\r -> desc_ (qarCreatedAt r)) $ do
                        r <- all_ (qaAutomationRuns autopilotDb)
                        guard_ (qarCloudType r ==. val_ cloud)
                        guard_ (qarReleaseId r ==. val_ rid)
                        pure r
    pure (map runFromRow rows)

findRunByRunId :: (MonadFlow m) => Text -> m (Maybe QaAutomationRun)
findRunByRunId runId = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    r <- all_ (qaAutomationRuns autopilotDb)
                    guard_ (qarCloudType r ==. val_ cloud)
                    guard_ (qarRunId r ==. val_ runId)
                    pure r
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just (runFromRow x)

-- Writes

-- | Config is edited as a whole (no partial-update API planned yet) — insert
-- if absent for this @(appGroup, cloudType)@, else overwrite every editable
-- column. @uq_qa_automation_config@ makes the two branches race-safe enough
-- for a low-traffic admin action; a genuine race just picks a winner.
upsertConfig :: (MonadFlow m) => QaAutomationConfig -> m ()
upsertConfig cfg = withCloudDb $ \cloud db -> do
    now <- getCurrentTime
    existing <-
        runDB db $
            runSelectReturningList $
                select $ do
                    c <- all_ (qaAutomationConfigs autopilotDb)
                    guard_ (qacCloudType c ==. val_ cloud)
                    guard_ (qacAppGroup c ==. val_ (qcAppGroup cfg))
                    pure c
    case existing of
        [] ->
            runDB db $
                runInsert $
                    insert (qaAutomationConfigs autopilotDb) $
                        insertExpressions
                            [ QaAutomationConfigT
                                { qacId = default_
                                , qacAppGroup = val_ (qcAppGroup cfg)
                                , qacCloudType = val_ cloud
                                , qacEnabled = val_ (qcEnabled cfg)
                                , qacOnSuccess = val_ (qcOnSuccess cfg)
                                , qacTestDashboardUrl = val_ (qcTestDashboardUrl cfg)
                                , qacWebhookToken = val_ (qcWebhookToken cfg)
                                , qacFlows = val_ (encodeJsonList (qcFlows cfg))
                                , qacEnvFile = val_ (qcEnvFile cfg)
                                , qacConcurrency = val_ (qcConcurrency cfg)
                                , qacCreatedAt = val_ now
                                , qacUpdatedAt = val_ now
                                }
                            ]
        (row : _) ->
            runDB db $
                runUpdate $
                    update
                        (qaAutomationConfigs autopilotDb)
                        ( \c ->
                            mconcat
                                [ qacEnabled c <-. val_ (qcEnabled cfg)
                                , qacOnSuccess c <-. val_ (qcOnSuccess cfg)
                                , qacTestDashboardUrl c <-. val_ (qcTestDashboardUrl cfg)
                                , qacWebhookToken c <-. val_ (qcWebhookToken cfg)
                                , qacFlows c <-. val_ (encodeJsonList (qcFlows cfg))
                                , qacEnvFile c <-. val_ (qcEnvFile cfg)
                                , qacConcurrency c <-. val_ (qcConcurrency cfg)
                                , qacUpdatedAt c <-. val_ now
                                ]
                        )
                        (\c -> qacId c ==. val_ (qacId row))

-- | One row per triggered run. @qrRunId@ from the dashboard's response is the
-- join key for 'updateRunResult'.
insertRun ::
    (MonadFlow m) =>
    -- | run id (from the dashboard)
    Text ->
    -- | release id
    Text ->
    -- | app group
    Text ->
    -- | release version
    Maybe Text ->
    -- | trigger source: "MANUAL" | "AUTO"
    Text ->
    -- | test dashboard deep link
    Text ->
    m ()
insertRun runId releaseId grp version triggerSource dashboardUrl = withCloudDb $ \cloud db -> do
    now <- getCurrentTime
    runDB db $
        runInsert $
            insert (qaAutomationRuns autopilotDb) $
                insertExpressions
                    [ QaAutomationRunT
                        { qarId = default_
                        , qarRunId = val_ runId
                        , qarReleaseId = val_ releaseId
                        , qarAppGroup = val_ grp
                        , qarCloudType = val_ cloud
                        , qarReleaseVersion = val_ version
                        , qarStatus = val_ "RUNNING"
                        , qarTriggerSource = val_ triggerSource
                        , qarTestDashboardUrl = val_ (Just dashboardUrl)
                        , qarPassed = val_ Nothing
                        , qarFailed = val_ Nothing
                        , qarDetail = val_ Nothing
                        , qarCreatedAt = val_ now
                        , qarUpdatedAt = val_ now
                        }
                    ]

-- | Called after polling the dashboard for a run's current state
-- ('Products.Autopilot.QaAutomation.refreshRunStatus').
updateRunResult :: (MonadFlow m) => Text -> Text -> Maybe Int32 -> Maybe Int32 -> Maybe Value -> m ()
updateRunResult runId newStatus passed failed detail = withCloudDb $ \cloud db -> do
    now <- getCurrentTime
    runDB db $
        runUpdate $
            update
                (qaAutomationRuns autopilotDb)
                ( \r ->
                    mconcat
                        [ qarStatus r <-. val_ newStatus
                        , qarPassed r <-. val_ passed
                        , qarFailed r <-. val_ failed
                        , qarDetail r <-. val_ (encodeJsonValue <$> detail)
                        , qarUpdatedAt r <-. val_ now
                        ]
                )
                (\r -> qarRunId r ==. val_ runId &&. qarCloudType r ==. val_ cloud)
