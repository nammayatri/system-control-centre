{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Queries for the @app_catalog@ table — the catalog of mobile apps
releasable through SCC. Polymorphic in MonadFlow per the codebase convention.
-}
module Products.Autopilot.Mobile.Queries.AppCatalog (
    listAppCatalog,
    listEnabledAppCatalog,
    findAppCatalogById,
    findAppCatalogByIds,
    insertAppCatalog,
    updateAppCatalog,
    NewAppCatalogRow (..),
    PatchAppCatalogRow (..),
    LatestBuildRow (..),
    fetchLatestBuildsPerApp,
    fetchLatestBuildsForApp,
    storeTrackOf,
    TrackSnapshot (..),
    tracksOf,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, mapMaybe)
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
import Database.PostgreSQL.Simple (query, query_)
import Products.Autopilot.Mobile.Queries.Tracker (parseMobileTargetState)
import Products.Autopilot.Queries.ReleaseTracker (parseJsonTextMaybe)
import Products.Autopilot.Mobile.Types (MobileBuildContext (..), MobileBuildTargetState (..))
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

{- | Batch lookup by id. Used by the mobile create handler to validate every
requested @appCatalogId@ in one round-trip before inserting any release row
(see 'Handlers.Release.createMobileReleasesH'). Returns only the rows that
exist; the caller diffs against the requested ids to report unknown ones.
-}
findAppCatalogByIds :: (MonadFlow m) => [Int32] -> m [AppCatalog]
findAppCatalogByIds [] = pure []
findAppCatalogByIds aids = withDb $ \db ->
    runDB db $
        runSelectReturningList $
            select $ do
                a <- all_ (appCatalogs autopilotDb)
                guard_ (acId a `in_` map val_ aids)
                pure a

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
                                        ]
                            )
                            (\a -> acId a ==. val_ aid)
                            id
                pure $ case rows of
                    [] -> Nothing
                    (x : _) -> Just x

    isNoop =
        case (pacEnabled, pacDisplayLabel, pacPackageName, pacFirebaseProjectId, pacWorkflowPath) of
            (Nothing, Nothing, Nothing, Nothing, Nothing) -> True
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
    , lbrBuildType :: Text
    -- ^ @"debug"@ or @"release"@
    , lbrVersion :: Text
    , lbrVersionCode :: Maybe Int32
    , lbrTagPushed :: Maybe Text
    , lbrCommitSha :: Maybe Text
    , lbrCompletedAt :: UTCTime
    , lbrStoreTrack :: Maybe Text
    -- ^ store track from @metadata.store_track@ ("production" | "internal" |
    -- "testflight"), set on store-sync rows; 'Nothing' for SCC-built rows.
    , lbrTracks :: Map.Map Text TrackSnapshot
    -- ^ per-track latest-build snapshots from @metadata.tracks@ ("production" /
    -- "internal"), recorded by store-sync so the create page can show — and diff
    -- against — both tracks. Empty for SCC-built rows / rows synced before this.
    }

-- | Tolerant extractor for @metadata.store_track@ (skips absent/malformed metadata).
newtype StoreTrackMeta = StoreTrackMeta (Maybe Text)

instance FromJSON StoreTrackMeta where
    parseJSON = withObject "StoreTrackMeta" $ \o -> StoreTrackMeta <$> o .:? "store_track"

storeTrackOf :: Maybe Text -> Maybe Text
storeTrackOf mMeta = (parseJsonTextMaybe mMeta :: Maybe StoreTrackMeta) >>= \(StoreTrackMeta t) -> t

{- | One store track's latest-build snapshot, written by store-sync into
@metadata.tracks.{production,internal}@. Carries enough to label the build (the
version + code) and to use it as a changelog base (the git @tag@). 'tsTag' may be
'Nothing' when the build code is unknown (e.g. the live iOS App Store version),
in which case it can label the track but not seed a commit diff.
-}
data TrackSnapshot = TrackSnapshot
    { tsVersion :: Text
    , tsCode :: Maybe Int32
    , tsTag :: Maybe Text
    }
    deriving (Show, Eq)

instance ToJSON TrackSnapshot where
    toJSON ts = object ["version" .= tsVersion ts, "code" .= tsCode ts, "tag" .= tsTag ts]

instance FromJSON TrackSnapshot where
    parseJSON = withObject "TrackSnapshot" $ \o ->
        TrackSnapshot <$> o .: "version" <*> o .:? "code" <*> o .:? "tag"

-- | Tolerant extractor for the @metadata.tracks@ map (empty when absent/malformed).
newtype TracksMeta = TracksMeta (Map.Map Text TrackSnapshot)

instance FromJSON TracksMeta where
    parseJSON = withObject "TracksMeta" $ \o -> TracksMeta . fromMaybe Map.empty <$> o .:? "tracks"

tracksOf :: Maybe Text -> Map.Map Text TrackSnapshot
tracksOf mMeta = case (parseJsonTextMaybe mMeta :: Maybe TracksMeta) of
    Just (TracksMeta m) -> m
    Nothing -> Map.empty

{- | For every unique (app_group, service, env, build_type) combination
in @release_tracker@ where @category = 'MobileBuild'@ and
@status = 'COMPLETED'@, return the single most recent row.

Build type, version code, and pushed tag come from the parsed
@MobileBuildContext@ (the @mbContext@ inside @release_context@). Parsing
is done in Haskell via the domain 'parseMobileTargetState' /
'MobileBuildContext' 'FromJSON' decoder — the single source of truth for
the JSON shape, including the legacy @destination@→@build_type@ fallback
(@Firebase@/@TestFlight@ → @"debug"@). Doing the decode here rather than
in SQL keeps that classification in one place and avoids a DB-side JSON
cast that would abort the whole query on a single malformed row.

SQL pulls the COMPLETED MobileBuild rows newest-first; Haskell drops any
row whose context won't parse (so a corrupt row can't mask the latest
*valid* build), then keeps the first (newest) row seen per
(app, surface, platform, build_type). Mobile-release volume is low, so
in-memory grouping is cheap; @idx_rt_status@ + @idx_rt_created_at@ back
the scan.
-}
fetchLatestBuildsPerApp :: (MonadFlow m) => m [LatestBuildRow]
fetchLatestBuildsPerApp = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query_
                conn
                "SELECT app_group, service, env, new_version, commit_sha, \
                \  date_created, release_context, metadata \
                \FROM release_tracker \
                \WHERE category = 'MobileBuild' AND status = 'COMPLETED' \
                \  AND release_context IS NOT NULL \
                \ORDER BY date_created DESC"
        pure (latestBuildsFromRows rows)

{- | Scoped variant: the latest completed build per build_type for a SINGLE
@(app_group, surface, platform)@. Used by revert and changelog-preview, which
need only one app's builds — filtering in SQL avoids the full-table scan
'fetchLatestBuildsPerApp' does (which only @listAppsH@ genuinely needs).
-}
fetchLatestBuildsForApp :: (MonadFlow m) => Text -> Text -> Text -> m [LatestBuildRow]
fetchLatestBuildsForApp appGroup surface platform = withDb $ \db ->
    withConn db $ \conn -> do
        rows <-
            query
                conn
                "SELECT app_group, service, env, new_version, commit_sha, \
                \  date_created, release_context, metadata \
                \FROM release_tracker \
                \WHERE category = 'MobileBuild' AND status = 'COMPLETED' \
                \  AND release_context IS NOT NULL \
                \  AND app_group = ? AND service = ? AND env = ? \
                \ORDER BY date_created DESC"
                (appGroup, surface, platform)
        pure (latestBuildsFromRows rows)

{- | Shared reducer for both latest-build queries: parse each raw row (dropping
unparseable ones, per B2) and keep the newest per
(app, surface, platform, build_type). Input must be newest-first.
-}
latestBuildsFromRows :: [(Text, Text, Text, Text, Maybe Text, UTCTime, Text, Maybe Text)] -> [LatestBuildRow]
latestBuildsFromRows rows =
    let parsed = mapMaybe toLatestBuildRow rows
        keyOf r = (lbrAppGroup r, lbrSurface r, lbrPlatform r, lbrBuildType r)
        -- newest-first input ⇒ keep the first row seen per key (the existing
        -- value in the map), so insertWith returns the existing one.
        latest = Map.fromListWith (\_incoming existing -> existing) [(keyOf r, r) | r <- parsed]
     in Map.elems latest

{- | Parse one raw row into a 'LatestBuildRow'. Returns 'Nothing' when the
@release_context@ can't be decoded to a 'MobileBuildTargetState' — such rows
are skipped rather than blanking the result.
-}
toLatestBuildRow :: (Text, Text, Text, Text, Maybe Text, UTCTime, Text, Maybe Text) -> Maybe LatestBuildRow
toLatestBuildRow (ag, suf, plt, ver, sha, ca, ctxText, mMeta) = do
    mbts <- parseMobileTargetState (Just ctxText)
    let ctx = mbContext mbts
    pure
        LatestBuildRow
            { lbrAppGroup = ag
            , lbrSurface = suf
            , lbrPlatform = plt
            , lbrBuildType = mbcBuildType ctx
            , lbrVersion = ver
            , lbrVersionCode = mbcVersionCode ctx
            , lbrTagPushed = mbcTagPushed ctx
            , lbrCommitSha = sha
            , lbrCompletedAt = ca
            , lbrStoreTrack = storeTrackOf mMeta
            , lbrTracks = tracksOf mMeta
            }
