{-# LANGUAGE FlexibleContexts #-}

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
) where

import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow, withDb)
import Data.Int (Int32)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import Database.Beam
import Database.Beam.Postgres (Pg)
import Database.Beam.Postgres.Full (
    insertReturning,
    onConflictDefault,
    runPgInsertReturningList,
    runPgUpdateReturningList,
    updateReturning,
 )
import Products.Autopilot.Mobile.Types.Storage
import Products.Autopilot.Types.Storage.Schema (AutopilotDb (..), autopilotDb)

-- | Fields needed to INSERT a row. @id@ and @created_at@ are DB-generated.
data NewAppCatalogRow = NewAppCatalogRow
    { nacName :: Text
    , nacSurface :: Text
    , nacPlatform :: Text
    , nacGithubRepo :: Text
    , nacWorkflowPath :: Text
    , nacPackageName :: Maybe Text
    , nacDisplayLabel :: Maybe Text
    , nacEnabled :: Maybe Bool
    -- ^ Defaults to True if Nothing.
    }

-- | Partial-update fields. Only @Just@ fields are updated.
data PatchAppCatalogRow = PatchAppCatalogRow
    { pacEnabled :: Maybe Bool
    , pacDisplayLabel :: Maybe Text
    , pacPackageName :: Maybe Text
    , pacWorkflowPath :: Maybe Text
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
                            , acPackageName = val_ nacPackageName
                            , acDisplayLabel = val_ nacDisplayLabel
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
                                        , fmap (\v -> acWorkflowPath a <-. val_ v) pacWorkflowPath
                                        ]
                            )
                            (\a -> acId a ==. val_ aid)
                            id
                pure $ case rows of
                    [] -> Nothing
                    (x : _) -> Just x

    isNoop =
        case (pacEnabled, pacDisplayLabel, pacPackageName, pacWorkflowPath) of
            (Nothing, Nothing, Nothing, Nothing) -> True
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
