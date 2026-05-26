{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Queries for the @app_catalog@ table — the catalog of mobile apps
releasable through SCC. Polymorphic in MonadFlow per the codebase convention.
-}
module Products.Autopilot.Mobile.Queries.AppCatalog (
    listAppCatalog,
    listEnabledAppCatalog,
    findAppCatalogById,
    insertAppCatalog,
    updateAppCatalog,
    NewAppCatalogRow (..),
    PatchAppCatalogRow (..),
    LatestBuildRow (..),
    fetchLatestBuildsPerApp,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Int (Int32)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import Database.Beam
import Database.Beam.Postgres (Pg)
import Database.Beam.Postgres.Full (
    insertReturning,
    onConflictDefault,
    runPgInsertReturningList,
    runPgUpdateReturningList,
    updateReturning,
 )
import Database.PostgreSQL.Simple (query_)
import Products.Autopilot.Mobile.Types.Storage
import Products.Autopilot.Types.Storage.Schema (AutopilotDb (..), autopilotDb)

-- | Fields needed to INSERT a row. @id@ and @created_at@ are DB-generated.
data NewAppCatalogRow = NewAppCatalogRow
    { nacName :: Text
    , nacSurface :: Text
    , nacPlatform :: Text
    , nacGithubRepo :: Text
    , nacWorkflowPath :: Text
    , nacDebugWorkflowPath :: Maybe Text
    , nacPackageName :: Maybe Text
    , nacDisplayLabel :: Maybe Text
    , nacFirebaseProjectId :: Maybe Text
    , nacEnabled :: Maybe Bool
    -- ^ Defaults to True if Nothing.
    }

-- | Partial-update fields. Only @Just@ fields are updated.
data PatchAppCatalogRow = PatchAppCatalogRow
    { pacEnabled :: Maybe Bool
    , pacDisplayLabel :: Maybe Text
    , pacPackageName :: Maybe Text
    , pacFirebaseProjectId :: Maybe Text
    , pacWorkflowPath :: Maybe Text
    , pacDebugWorkflowPath :: Maybe Text
    }

-- | All rows.
listAppCatalog :: (MonadFlow m) => m [AppCatalog]
listAppCatalog = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select (all_ (appCatalogs autopilotDb))

-- | Only enabled rows.
listEnabledAppCatalog :: (MonadFlow m) => m [AppCatalog]
listEnabledAppCatalog = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                a <- all_ (appCatalogs autopilotDb)
                guard_ (acEnabled a ==. val_ True)
                pure a

-- | Single row by primary key.
findAppCatalogById :: (MonadFlow m) => Int32 -> m (Maybe AppCatalog)
findAppCatalogById aid = withDb $ \db -> do
    rows <-
        runDB db $
            runSelectReturningList $
                select $ do
                    a <- all_ (appCatalogs autopilotDb)
                    guard_ (acId a ==. val_ aid)
                    pure a
    pure $ case rows of
        [] -> Nothing
        (x : _) -> Just x

-- | Insert a row, returning the freshly-created row (with DB-assigned id + created_at).
insertAppCatalog :: (MonadFlow m) => NewAppCatalogRow -> m AppCatalog
insertAppCatalog NewAppCatalogRow{..} = withDb $ \db -> do
    let enabled' = fromMaybe True nacEnabled
    rows <-
        runDB db $
            runPgInsertReturningList $
                insertReturning
                    (appCatalogs autopilotDb)
                    ( insertExpressions
                        [ AppCatalog
                            { acId = default_
                            , acName = val_ nacName
                            , acSurface = val_ nacSurface
                            , acPlatform = val_ nacPlatform
                            , acGithubRepo = val_ nacGithubRepo
                            , acWorkflowPath = val_ nacWorkflowPath
                            , acDebugWorkflowPath = val_ nacDebugWorkflowPath
                            , acPackageName = val_ nacPackageName
                            , acDisplayLabel = val_ nacDisplayLabel
                            , acFirebaseProjectId = val_ nacFirebaseProjectId
                            , acEnabled = val_ enabled'
                            , acCreatedAt = default_
                            }
                        ]
                    )
                    onConflictDefault
                    (Just id)
    case rows of
        (x : _) -> pure x
        [] -> throwM $ DBError "insertAppCatalog" "INSERT ... RETURNING produced no row"

{- | Patch an existing row. Only fields that are @Just@ in the patch are updated.
Returns 'Nothing' if no row with that id exists.
-}
updateAppCatalog :: (MonadFlow m) => Int32 -> PatchAppCatalogRow -> m (Maybe AppCatalog)
updateAppCatalog aid PatchAppCatalogRow{..} = withDb $ \db ->
    runDB db go
  where
    -- Skip the UPDATE entirely if every patch field is Nothing — otherwise
    -- Beam would emit `UPDATE ... SET WHERE ...` (empty SET clause), which
    -- Postgres rejects. Just look up the current row instead.
    go =
        if isNoop
            then lookupCurrent
            else do
                rows <-
                    runPgUpdateReturningList $
                        updateReturning
                            (appCatalogs autopilotDb)
                            ( \a ->
                                mconcat $
                                    catMaybes
                                        [ fmap (\v -> acEnabled a <-. val_ v) pacEnabled
                                        , fmap (\v -> acDisplayLabel a <-. val_ (Just v)) pacDisplayLabel
                                        , fmap (\v -> acPackageName a <-. val_ (Just v)) pacPackageName
                                        , fmap (\v -> acFirebaseProjectId a <-. val_ (Just v)) pacFirebaseProjectId
                                        , fmap (\v -> acWorkflowPath a <-. val_ v) pacWorkflowPath
                                        , fmap (\v -> acDebugWorkflowPath a <-. val_ (Just v)) pacDebugWorkflowPath
                                        ]
                            )
                            (\a -> acId a ==. val_ aid)
                            id
                pure $ case rows of
                    [] -> Nothing
                    (x : _) -> Just x

    isNoop =
        case (pacEnabled, pacDisplayLabel, pacPackageName, pacFirebaseProjectId, pacWorkflowPath, pacDebugWorkflowPath) of
            (Nothing, Nothing, Nothing, Nothing, Nothing, Nothing) -> True
            _ -> False

    lookupCurrent :: Pg (Maybe AppCatalog)
    lookupCurrent = do
        rows <-
            runSelectReturningList $
                select $ do
                    a <- all_ (appCatalogs autopilotDb)
                    guard_ (acId a ==. val_ aid)
                    pure a
        pure $ case rows of
            [] -> Nothing
            (x : _) -> Just x

-- ─── Latest-build aggregation ─────────────────────────────────────

{- | Summary of the latest completed build per (app, surface, platform,
build_type). Returned by the raw SQL query in 'fetchLatestBuildsPerApp'.
-}
data LatestBuildRow = LatestBuildRow
    { lbrAppGroup :: Text
    , lbrSurface :: Text
    , lbrPlatform :: Text
    , lbrBuildType :: Text -- ^ @"debug"@ or @"release"@
    , lbrVersion :: Text
    , lbrVersionCode :: Maybe Int32
    , lbrDestination :: Maybe Text
    , lbrTagPushed :: Maybe Text
    , lbrCommitSha :: Maybe Text
    , lbrCompletedAt :: UTCTime
    }

{- | For every unique (app_group, service, env, build_type) combination
in @release_tracker@ where @category = 'MobileBuild'@ and
@status = 'COMPLETED'@, return the single most recent row.

Build type is inferred from the @destination@ field inside
@release_context.contents.mbContext@:

* Debug: destination ∈ {Firebase, TestFlight}
* Release: destination ∈ {GooglePlay, AppStore}

Uses a raw SQL query (via @withConn@) because the window function
(@ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)@) is beyond what
Beam's DSL can express cleanly.
-}
fetchLatestBuildsPerApp :: (MonadFlow m) => m [LatestBuildRow]
fetchLatestBuildsPerApp = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query_ conn
                "SELECT app_group, service, env, \
                \  CASE WHEN (release_context::jsonb -> 'contents' -> 'mbContext' ->> 'destination') IN ('Firebase', 'TestFlight') \
                \       THEN 'debug' ELSE 'release' END AS build_type, \
                \  new_version, \
                \  (release_context::jsonb -> 'contents' -> 'mbContext' ->> 'version_code')::int AS version_code, \
                \  release_context::jsonb -> 'contents' -> 'mbContext' ->> 'destination' AS destination, \
                \  release_context::jsonb -> 'contents' -> 'mbContext' ->> 'tag_pushed' AS tag_pushed, \
                \  commit_sha, \
                \  date_created \
                \FROM ( \
                \  SELECT *, ROW_NUMBER() OVER ( \
                \    PARTITION BY app_group, service, env, \
                \      CASE WHEN (release_context::jsonb -> 'contents' -> 'mbContext' ->> 'destination') IN ('Firebase', 'TestFlight') \
                \           THEN 'debug' ELSE 'release' END \
                \    ORDER BY date_created DESC \
                \  ) AS rn \
                \  FROM release_tracker \
                \  WHERE category = 'MobileBuild' AND status = 'COMPLETED' \
                \    AND release_context IS NOT NULL \
                \) sub WHERE rn = 1"
        pure (map toLatestBuildRow rows)

toLatestBuildRow :: (Text, Text, Text, Text, Text, Maybe Int32, Maybe Text, Maybe Text, Maybe Text, UTCTime) -> LatestBuildRow
toLatestBuildRow (ag, suf, plt, bt, ver, vc, dest, tag, sha, ca) =
    LatestBuildRow ag suf plt bt ver vc dest tag sha ca
