{-# LANGUAGE OverloadedStrings #-}

{- | Storage for outbound release webhooks (@release_webhook@).

Every query is cloud-scoped through 'withCloudDb', exactly like
"Products.Autopilot.Queries.ProductService" — a webhook configured on the GCP
instance must not fire from the AWS one.
-}
module Products.Autopilot.Queries.ReleaseWebhook (
    listWebhooks,
    findWebhookById,
    findWebhookByName,
    listWebhooksForRelease,
    insertWebhook,
    updateWebhook,
    deleteWebhook,
)
where

import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow)
import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Database.Beam
import GHC.Int (Int32)
import Products.Autopilot.Queries.ReleaseTracker (withCloudDb)
import Products.Autopilot.Types.Storage.Schema
import Products.Autopilot.Types.Webhook

-- Row <-> domain

-- | JSON-in-TEXT columns decode leniently: a hand-edited or legacy value that
-- no longer parses degrades to "no headers", never to a failed dispatch.
decodeJsonList :: (FromJSON a) => Maybe Text -> [a]
decodeJsonList Nothing = []
decodeJsonList (Just t) = fromMaybe [] (decode (LBS.fromStrict (TE.encodeUtf8 t)))

encodeJsonList :: (ToJSON a) => [a] -> Maybe Text
encodeJsonList [] = Nothing
encodeJsonList xs = Just (TE.decodeUtf8 (LBS.toStrict (encode xs)))

-- | An unrecognised @method@ in the DB falls back to POST rather than dropping
-- the hook — the config API validates on write, so this is only a safety net.
fromRow :: ReleaseWebhookRow -> ReleaseWebhook
fromRow r =
    ReleaseWebhook
        { whId = rwId r
        , whAppGroup = rwAppGroup r
        , whServices = decodeJsonList (rwServices r)
        , whName = rwName r
        , whEnabled = rwEnabled r
        , whOnSuccess = rwOnSuccess r
        , whOnFailure = rwOnFailure r
        , whMethod = fromMaybe WH_POST (textToWebhookMethod (rwMethod r))
        , whUrl = rwUrl r
        , whHeaders = decodeJsonList (rwHeaders r)
        , whQueryParams = decodeJsonList (rwQueryParams r)
        , whBody = rwBody r
        , whTimeoutSeconds = rwTimeoutSeconds r
        , whRetries = rwRetries r
        }

-- Reads

-- | All webhooks, optionally narrowed to one app group, in a stable
-- (group, name) order so the config list does not reshuffle between loads.
listWebhooks :: (MonadFlow m) => Maybe Text -> m [ReleaseWebhook]
listWebhooks mAppGroup = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (\w -> (asc_ (rwAppGroup w), asc_ (rwName w))) $ do
                        w <- all_ (releaseWebhooks autopilotDb)
                        guard_ (rwCloudType w ==. val_ cloud)
                        case mAppGroup of
                            Just g -> guard_ (rwAppGroup w ==. val_ g)
                            Nothing -> pure ()
                        pure w
    pure (map fromRow rows)

findWebhookById :: (MonadFlow m) => Int32 -> m (Maybe ReleaseWebhook)
findWebhookById wid = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    w <- all_ (releaseWebhooks autopilotDb)
                    guard_ (rwCloudType w ==. val_ cloud)
                    guard_ (rwId w ==. val_ wid)
                    pure w
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just (fromRow x)

-- | Lookup along 'uq_release_webhook', so the API can answer a name collision
-- with a 400 rather than an escaped unique violation.
findWebhookByName :: (MonadFlow m) => Text -> Text -> m (Maybe ReleaseWebhook)
findWebhookByName grp name = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    w <- all_ (releaseWebhooks autopilotDb)
                    guard_ (rwCloudType w ==. val_ cloud)
                    guard_ (rwAppGroup w ==. val_ grp)
                    guard_ (rwName w ==. val_ name)
                    pure w
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just (fromRow x)

{- | Every enabled hook that applies to @(appGroup, service)@: the ones whose
service set is empty (= whole group) plus the ones that name this service.

The set lives in a JSON column, so SQL narrows to the app group and the match
happens here — a group has a handful of hooks, not thousands.
-}
listWebhooksForRelease :: (MonadFlow m) => Text -> Text -> m [ReleaseWebhook]
listWebhooksForRelease grp svc = do
    hooks <- listEnabledWebhooksForGroup grp
    pure (filter covers hooks)
  where
    covers wh = null (whServices wh) || svc `elem` whServices wh

listEnabledWebhooksForGroup :: (MonadFlow m) => Text -> m [ReleaseWebhook]
listEnabledWebhooksForGroup grp = withCloudDb $ \cloud db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    w <- all_ (releaseWebhooks autopilotDb)
                    guard_ (rwCloudType w ==. val_ cloud)
                    guard_ (rwAppGroup w ==. val_ grp)
                    guard_ (rwEnabled w ==. val_ True)
                    pure w
    pure (map fromRow rows)

-- Writes

insertWebhook :: (MonadFlow m) => UpsertWebhookReq -> WebhookMethod -> m ()
insertWebhook req meth = withCloudDb $ \cloud db -> do
    now <- getCurrentTime
    runDB db $
        runInsert $
            insert (releaseWebhooks autopilotDb) $
                insertExpressions
                    [ ReleaseWebhookT
                        { rwId = default_
                        , rwAppGroup = val_ (uwAppGroup req)
                        , rwServices = val_ (encodeJsonList (fromMaybe [] (uwServices req)))
                        , rwCloudType = val_ cloud
                        , rwName = val_ (uwName req)
                        , rwEnabled = val_ (fromMaybe True (uwEnabled req))
                        , rwOnSuccess = val_ (fromMaybe True (uwOnSuccess req))
                        , rwOnFailure = val_ (fromMaybe True (uwOnFailure req))
                        , rwMethod = val_ (webhookMethodToText meth)
                        , rwUrl = val_ (uwUrl req)
                        , rwHeaders = val_ (encodeJsonList (fromMaybe [] (uwHeaders req)))
                        , rwQueryParams = val_ (encodeJsonList (fromMaybe [] (uwQueryParams req)))
                        , rwBody = val_ (uwBody req)
                        , rwTimeoutSeconds = val_ (uwTimeoutSeconds req)
                        , rwRetries = val_ (uwRetries req)
                        , rwCreatedAt = val_ now
                        , rwUpdatedAt = val_ now
                        }
                    ]

-- | Full replace of the editable columns. @app_group@ is not updatable — the
-- handler rejects a payload whose group differs from the stored row, so a
-- webhook can never silently migrate out from under its RBAC scope.
updateWebhook :: (MonadFlow m) => Int32 -> UpsertWebhookReq -> WebhookMethod -> m ()
updateWebhook wid req meth = withCloudDb $ \cloud db -> do
    now <- getCurrentTime
    runDB db $
        runUpdate $
            update
                (releaseWebhooks autopilotDb)
                ( \w ->
                    mconcat
                        [ rwServices w <-. val_ (encodeJsonList (fromMaybe [] (uwServices req)))
                        , rwName w <-. val_ (uwName req)
                        , rwEnabled w <-. val_ (fromMaybe True (uwEnabled req))
                        , rwOnSuccess w <-. val_ (fromMaybe True (uwOnSuccess req))
                        , rwOnFailure w <-. val_ (fromMaybe True (uwOnFailure req))
                        , rwMethod w <-. val_ (webhookMethodToText meth)
                        , rwUrl w <-. val_ (uwUrl req)
                        , rwHeaders w <-. val_ (encodeJsonList (fromMaybe [] (uwHeaders req)))
                        , rwQueryParams w <-. val_ (encodeJsonList (fromMaybe [] (uwQueryParams req)))
                        , rwBody w <-. val_ (uwBody req)
                        , rwTimeoutSeconds w <-. val_ (uwTimeoutSeconds req)
                        , rwRetries w <-. val_ (uwRetries req)
                        , rwUpdatedAt w <-. val_ now
                        ]
                )
                (\w -> rwId w ==. val_ wid &&. rwCloudType w ==. val_ cloud)

deleteWebhook :: (MonadFlow m) => Int32 -> m ()
deleteWebhook wid = withCloudDb $ \cloud db ->
    runDB db $
        runDelete $
            delete
                (releaseWebhooks autopilotDb)
                (\w -> rwId w ==. val_ wid &&. rwCloudType w ==. val_ cloud)
