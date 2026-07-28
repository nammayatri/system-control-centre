{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeApplications #-}

{- | HTTP handlers for the @app_catalog@ endpoints (list/create/patch).

Permissions: list is gated by 'AP_RELEASE_VIEW' (any operator); create
and patch require 'AP_MOBILE_APP_MANAGE' (admin).
-}
module Products.Autopilot.Mobile.Handlers.AppCatalog (
    AppCatalogEntryResp (..),
    LatestBuildResp (..),
    MobileAccessEntry (..),
    MobileAccessResp (..),
    NewAppReq (..),
    PatchAppReq (..),
    listAppsH,
    createAppH,
    patchAppH,
    mobileAccessH,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson (..))
import Core.Auth.Queries (computeEffectivePermissionsForAppGroups)
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Int (Int32)
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Proxy (Proxy (..))
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Auth (requireAppPerm, requireProductPerm)
import Products.Autopilot.Types.Permission (AutopilotPermission (..))
import Products.Types (allPermissionsText)
import Products.Autopilot.Mobile.Queries.AppCatalog
import Products.Autopilot.Mobile.Queries.StoreStatus (listStoreStatus)
import Products.Autopilot.Mobile.Types.Storage

data LatestBuildResp = LatestBuildResp
    { version :: Text
    , versionCode :: Maybe Int32
    , tagPushed :: Maybe Text
    , commitSha :: Maybe Text
    , completedAt :: UTCTime
    , track :: Maybe Text
    -- ^ store track ("production" | "internal" | "testflight") for store-sync builds
    }
    deriving (Generic, Show)

instance ToJSON LatestBuildResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON LatestBuildResp

data AppCatalogEntryResp = AppCatalogEntryResp
    { id :: Int32
    , name :: Text
    , surface :: Text
    , platform :: Text
    , githubRepo :: Text
    , workflowPath :: Text
    , packageName :: Maybe Text
    , displayLabel :: Maybe Text
    , firebaseProjectId :: Maybe Text
    , airborneAppRef :: Maybe Text
    , enabled :: Bool
    , createdAt :: UTCTime
    , latestReleaseBuild :: Maybe LatestBuildResp
    , latestDebugBuild :: Maybe LatestBuildResp
    , latestProdBuild :: Maybe LatestBuildResp
    -- ^ latest production-track build (from the @store_status@ cache); the default
    -- changelog base.
    , latestInternalBuild :: Maybe LatestBuildResp
    -- ^ latest internal-track build (Android internal testing / iOS TestFlight).
    }
    deriving (Generic, Show)

instance ToJSON AppCatalogEntryResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON AppCatalogEntryResp

data NewAppReq = NewAppReq
    { name :: Text
    , surface :: Text
    , platform :: Text
    , githubRepo :: Text
    , workflowPath :: Text
    , packageName :: Maybe Text
    , displayLabel :: Maybe Text
    , firebaseProjectId :: Maybe Text
    , enabled :: Maybe Bool
    }
    deriving (Generic, Show)

instance ToJSON NewAppReq where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON NewAppReq

data PatchAppReq = PatchAppReq
    { enabled :: Maybe Bool
    , displayLabel :: Maybe Text
    , packageName :: Maybe Text
    , firebaseProjectId :: Maybe Text
    , workflowPath :: Maybe Text
    , airborneAppRef :: Maybe Text
    -- ^ "" clears; "<org>~<app>" sets (admin backfill for store-synced apps).
    }
    deriving (Generic, Show)

instance ToJSON PatchAppReq where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON PatchAppReq

-- | One app row's effective per-app permissions (unified grant model).
data MobileAccessEntry = MobileAccessEntry
    { name :: Text
    , surface :: Text
    , platform :: Text
    , airborneAppRef :: Maybe Text
    , mobilePerms :: [Text]
    , otaPerms :: [Text]
    }
    deriving (Generic, Show)

instance ToJSON MobileAccessEntry where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON MobileAccessEntry

newtype MobileAccessResp = MobileAccessResp {apps :: [MobileAccessEntry]}
    deriving (Generic, Show)

instance ToJSON MobileAccessResp
instance FromJSON MobileAccessResp

{- | GET /mobile/access — the frontend's single source for per-app button
states. Per catalog row: effective perms from the unified autopilot grant
(\"\<name\>\/\<platform\>\") unioned with the legacy per-ref airborne-ota
grant; product-level role holders get their baseline on every row (the
fallback inside computeEffectivePermissionsForAppGroups).
-}
mobileAccessH :: AuthedPerson -> Flow MobileAccessResp
mobileAccessH ap = do
    catalog <- listAppCatalog
    let keyOf :: AppCatalog -> Text
        keyOf a = appGrantKey (acName a) (acPlatform a)
    permsFor <-
        if apIsSuperadmin ap
            then pure (\_ -> allPermissionsText "autopilot")
            else do
                uni <- computeEffectivePermissionsForAppGroups (apPersonId ap) "autopilot" (nub (map keyOf catalog))
                legacy <- computeEffectivePermissionsForAppGroups (apPersonId ap) "airborne-ota" (nub (mapMaybe acAirborneAppRef catalog))
                pure $ \a ->
                    fromMaybe [] (lookup (keyOf a) uni)
                        <> maybe [] (\r -> fromMaybe [] (lookup r legacy)) (acAirborneAppRef a)
    pure $
        MobileAccessResp
            [ MobileAccessEntry
                { name = acName a
                , surface = acSurface a
                , platform = acPlatform a
                , airborneAppRef = acAirborneAppRef a
                -- Autopilot wire names carry no prefix; OTA_* identifies the
                -- airborne family — everything else is a mobile-build perm.
                , mobilePerms = nub (filter (not . ("OTA_" `T.isPrefixOf`)) ps)
                , otaPerms = nub (filter ("OTA_" `T.isPrefixOf`) ps)
                }
            | a <- catalog
            , let ps = permsFor a
            ]

-- | Convert a 'LatestBuildRow' (from the raw SQL query) to the JSON-facing response type.
toBuildResp :: LatestBuildRow -> LatestBuildResp
toBuildResp b =
    LatestBuildResp
        { version = lbrVersion b
        , versionCode = lbrVersionCode b
        , tagPushed = lbrTagPushed b
        , commitSha = lbrCommitSha b
        , completedAt = lbrCompletedAt b
        , track = lbrStoreTrack b
        }

-- | Project a @store_status@ cell — the canonical per-track cache the App Monitor
-- reads — into a build response. The single source for the live prod/internal build,
-- shared by the create page, the monitor, and the changelog base.
toStoreStatusResp :: StoreStatus -> Maybe LatestBuildResp
toStoreStatusResp ss = do
    v <- ssVersionName ss
    pure
        LatestBuildResp
            { version = v
            , versionCode = ssVersionCode ss
            , tagPushed = Nothing
            , commitSha = Nothing
            , completedAt = ssSyncedAt ss
            , track = Just (ssTrack ss)
            }

-- | Projection from DB row to API response. The live per-track (production /
-- internal) builds come from the @store_status@ cache — the SAME source the App
-- Monitor reads — so the create page and the monitor agree by construction.
toResp :: Map.Map (Int32, Text) StoreStatus -> Map.Map (Text, Text, Text, Text) LatestBuildRow -> AppCatalog -> AppCatalogEntryResp
toResp storeMap buildMap r =
    let releaseRow = Map.lookup (acName r, acSurface r, acPlatform r, "release") buildMap
        debugRow = Map.lookup (acName r, acSurface r, acPlatform r, "debug") buildMap
        -- iOS internal distribution is TestFlight; Android uses the "internal" track.
        internalTrack = if acPlatform r == "ios" then "testflight" else "internal"
        storeBuild trk = Map.lookup (acId r, trk) storeMap >>= toStoreStatusResp
     in AppCatalogEntryResp
            { id = acId r
            , name = acName r
            , surface = acSurface r
            , platform = acPlatform r
            , githubRepo = acGithubRepo r
            , workflowPath = acWorkflowPath r
            , packageName = acPackageName r
            , displayLabel = acDisplayLabel r
            , firebaseProjectId = acFirebaseProjectId r
            , airborneAppRef = acAirborneAppRef r
            , enabled = acEnabled r
            , createdAt = acCreatedAt r
            , latestReleaseBuild = toBuildResp <$> releaseRow
            , latestDebugBuild = toBuildResp <$> debugRow
            , latestProdBuild = storeBuild "production"
            , latestInternalBuild = storeBuild internalTrack
            }

-- | Simple projection without build info (for create/patch responses).
toRespNoBuild :: AppCatalog -> AppCatalogEntryResp
toRespNoBuild r =
    AppCatalogEntryResp
        { id = acId r
        , name = acName r
        , surface = acSurface r
        , platform = acPlatform r
        , githubRepo = acGithubRepo r
        , workflowPath = acWorkflowPath r
        , packageName = acPackageName r
        , displayLabel = acDisplayLabel r
        , firebaseProjectId = acFirebaseProjectId r
        , airborneAppRef = acAirborneAppRef r
        , enabled = acEnabled r
        , createdAt = acCreatedAt r
        , latestReleaseBuild = Nothing
        , latestDebugBuild = Nothing
        , latestProdBuild = Nothing
        , latestInternalBuild = Nothing
        }

listAppsH :: AuthedPerson -> Flow [AppCatalogEntryResp]
listAppsH _ap = do
    apps <- listAppCatalog
    builds <- fetchLatestBuildsPerApp
    statuses <- listStoreStatus
    let buildMap =
            Map.fromList
                [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b, lbrBuildType b), b)
                | b <- builds
                ]
        storeMap = Map.fromList [((ssAppCatalogId s, ssTrack s), s) | s <- statuses]
    pure (map (toResp storeMap buildMap) apps)

-- | Creating catalog rows is fleet-level: product-level grant only, the
-- per-app deployment fallback must not qualify.
createAppH :: AuthedPerson -> NewAppReq -> Flow AppCatalogEntryResp
createAppH ap NewAppReq{name = n, surface = s, platform = p, githubRepo = g, workflowPath = w, packageName = pkg, displayLabel = d, firebaseProjectId = fbp, enabled = e} = do
    requireProductPerm (Proxy @'AP_MOBILE_APP_MANAGE) ap
    let row =
            NewAppCatalogRow
                { nacName = n
                , nacSurface = s
                , nacPlatform = p
                , nacGithubRepo = g
                , nacWorkflowPath = w
                , nacPackageName = pkg
                , nacDisplayLabel = d
                , nacFirebaseProjectId = fbp
                , nacEnabled = e
                }
    toRespNoBuild <$> insertAppCatalog row

-- | Editing a catalog row (enable/disable, OTA ref, workflow…) is per-app:
-- an Admin grant on that row's "<name>/<platform>" key (or product-level).
patchAppH :: AuthedPerson -> Int32 -> PatchAppReq -> Flow AppCatalogEntryResp
patchAppH ap aid PatchAppReq{enabled = e, displayLabel = d, packageName = pkg, firebaseProjectId = fbp, workflowPath = w, airborneAppRef = ref} = do
    target <- findAppCatalogById aid >>= maybe (throwM $ NotFound "app_catalog row not found") pure
    requireAppPerm (Proxy @'AP_MOBILE_APP_MANAGE) ap (acName target) (acPlatform target)
    let patch =
            PatchAppCatalogRow
                { pacEnabled = e
                , pacDisplayLabel = d
                , pacPackageName = pkg
                , pacFirebaseProjectId = fbp
                , pacWorkflowPath = w
                , pacAirborneAppRef = ref
                }
    mResult <- updateAppCatalog aid patch
    case mResult of
        Just r -> pure (toRespNoBuild r)
        Nothing -> throwM $ NotFound "app_catalog row not found"
