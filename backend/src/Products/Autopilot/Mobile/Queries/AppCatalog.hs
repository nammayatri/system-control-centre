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
    derivedStoreTag,
    normalizeAppSegment,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (DBError (..))
import Core.DB.Connection (runDB, withConn)
import Core.Environment (MonadFlow, withDb)
import Data.Aeson (FromJSON (..), withObject, (.:?))
import Data.Char (isAlphaNum)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
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
import Products.Autopilot.Mobile.Types (MobileBuildContext (..), MobileBuildTargetState (..))
import Products.Autopilot.Mobile.Types.Storage
import Products.Autopilot.Queries.ReleaseTracker (parseJsonTextMaybe)
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
                            , acStoreAccount = val_ Nothing
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
    -- "testflight"), set on store-sync rows; 'Nothing' for SCC-built rows. Its
    -- presence marks a store-sync snapshot row (the dedup tiebreaker).
    }

-- | Tolerant extractor for @metadata.store_track@ (skips absent/malformed metadata).
newtype StoreTrackMeta = StoreTrackMeta (Maybe Text)

instance FromJSON StoreTrackMeta where
    parseJSON = withObject "StoreTrackMeta" $ \o -> StoreTrackMeta <$> o .:? "store_track"

storeTrackOf :: Maybe Text -> Maybe Text
storeTrackOf mMeta = (parseJsonTextMaybe mMeta :: Maybe StoreTrackMeta) >>= \(StoreTrackMeta t) -> t

{- | One store track's latest build as a changelog base: the version + code and
the derived git @tag@ to diff against. Built on demand from the @store_status@
cache ('Products.Autopilot.Mobile.Queries.StoreStatus.findStoreTracksForApp') by
the resolver in @Handlers.Release@. 'tsTag' is 'Nothing' when the build code is
unknown (e.g. the live iOS App Store version) — then it labels the track but can't
seed a commit diff.
-}
data TrackSnapshot = TrackSnapshot
    { tsVersion :: Text
    , tsCode :: Maybe Int32
    , tsTag :: Maybe Text
    }
    deriving (Show, Eq)

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
                \WHERE category = 'MobileBuild' AND status IN ('COMPLETED', 'INPROGRESS') \
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
                \WHERE category = 'MobileBuild' AND status IN ('COMPLETED', 'INPROGRESS') \
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
        isStoreSync = isJust . lbrStoreTrack
        -- newest-first input. Keep the newest row per key, BUT prefer the store-sync
        -- snapshot row (marked by store_track): a version can be INPROGRESS (in review /
        -- rolling) while still being the snapshot that anchors the app's store builds, so
        -- a newer trackless pure-external-review row must not displace it. fromListWith
        -- calls (f incoming existing); `existing` is newest-so-far, `incoming` oldest-last.
        preferStoreSync incoming existing
            | isStoreSync existing = existing
            | isStoreSync incoming = incoming
            | otherwise = existing
        latest = Map.fromListWith preferStoreSync [(keyOf r, r) | r <- parsed]
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
            }

{- | The git tag for a store build, matching the CI tag scheme
(see Workflow.execConfirmTag):
  consumer: {normalize(app)}/prod/{platform}/v{version}+{code}
  provider: {acName}-v{version}-{code}
'Nothing' when there's no build code (then the build has no changelog baseline).
Pure in @(app, version, code)@, so store-sync and the changelog-base resolver
derive the same tag from one definition.
-}
derivedStoreTag :: AppCatalog -> Text -> Maybe Int32 -> Maybe Text
derivedStoreTag ac version mCode = case mCode of
    Just code
        | acSurface ac == "driver" ->
            Just (acName ac <> "-v" <> version <> "-" <> T.pack (show code))
        | otherwise ->
            Just (normalizeAppSegment (acName ac) <> "/prod/" <> acPlatform ac <> "/v" <> version <> "+" <> T.pack (show code))
    Nothing -> Nothing

-- | Lowercase, non-alphanumerics → dashes, runs collapsed — the app segment of a
-- consumer store tag.
normalizeAppSegment :: Text -> Text
normalizeAppSegment = collapseDashes . T.map step . T.toLower
  where
    step c
        | isAlphaNum c = c
        | otherwise = '-'
    collapseDashes :: Text -> Text
    collapseDashes t =
        T.dropWhile (== '-') $
            T.dropWhileEnd (== '-') $
                T.intercalate "-" $
                    filter (not . T.null) (T.splitOn "-" t)
