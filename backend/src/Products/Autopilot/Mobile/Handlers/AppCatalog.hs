{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

{- | HTTP handlers for the @app_catalog@ endpoints (list/create/patch).

Permissions: list is gated by 'AP_RELEASE_VIEW' (any operator); create
and patch require 'AP_MOBILE_APP_MANAGE' (admin).
-}
module Products.Autopilot.Mobile.Handlers.AppCatalog (
    AppCatalogEntryResp (..),
    LatestBuildResp (..),
    NewAppReq (..),
    PatchAppReq (..),
    listAppsH,
    createAppH,
    patchAppH,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson)
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Queries.AppCatalog
import Products.Autopilot.Mobile.Types.Storage

data LatestBuildResp = LatestBuildResp
    { version :: Text
    , versionCode :: Maybe Int32
    , destination :: Maybe Text
    , tagPushed :: Maybe Text
    , commitSha :: Maybe Text
    , completedAt :: UTCTime
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
    , debugWorkflowPath :: Maybe Text
    , packageName :: Maybe Text
    , displayLabel :: Maybe Text
    , firebaseProjectId :: Maybe Text
    , enabled :: Bool
    , createdAt :: UTCTime
    , latestReleaseBuild :: Maybe LatestBuildResp
    , latestDebugBuild :: Maybe LatestBuildResp
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
    , debugWorkflowPath :: Maybe Text
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
    , debugWorkflowPath :: Maybe Text
    }
    deriving (Generic, Show)

instance ToJSON PatchAppReq where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON PatchAppReq

-- | Convert a 'LatestBuildRow' (from the raw SQL query) to the JSON-facing response type.
toBuildResp :: LatestBuildRow -> LatestBuildResp
toBuildResp b =
    LatestBuildResp
        { version = lbrVersion b
        , versionCode = lbrVersionCode b
        , destination = lbrDestination b
        , tagPushed = lbrTagPushed b
        , commitSha = lbrCommitSha b
        , completedAt = lbrCompletedAt b
        }

-- | Build-map-aware projection from DB row to API response.
toResp :: Map.Map (Text, Text, Text, Text) LatestBuildResp -> AppCatalog -> AppCatalogEntryResp
toResp buildMap r =
    AppCatalogEntryResp
        { id = acId r
        , name = acName r
        , surface = acSurface r
        , platform = acPlatform r
        , githubRepo = acGithubRepo r
        , workflowPath = acWorkflowPath r
        , debugWorkflowPath = acDebugWorkflowPath r
        , packageName = acPackageName r
        , displayLabel = acDisplayLabel r
        , firebaseProjectId = acFirebaseProjectId r
        , enabled = acEnabled r
        , createdAt = acCreatedAt r
        , latestReleaseBuild = Map.lookup (acName r, acSurface r, acPlatform r, "release") buildMap
        , latestDebugBuild = Map.lookup (acName r, acSurface r, acPlatform r, "debug") buildMap
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
        , debugWorkflowPath = acDebugWorkflowPath r
        , packageName = acPackageName r
        , displayLabel = acDisplayLabel r
        , firebaseProjectId = acFirebaseProjectId r
        , enabled = acEnabled r
        , createdAt = acCreatedAt r
        , latestReleaseBuild = Nothing
        , latestDebugBuild = Nothing
        }

listAppsH :: AuthedPerson -> Flow [AppCatalogEntryResp]
listAppsH _ap = do
    apps <- listAppCatalog
    builds <- fetchLatestBuildsPerApp
    let buildMap = Map.fromList
            [ ((lbrAppGroup b, lbrSurface b, lbrPlatform b, lbrBuildType b), toBuildResp b)
            | b <- builds
            ]
    pure (map (toResp buildMap) apps)

createAppH :: AuthedPerson -> NewAppReq -> Flow AppCatalogEntryResp
createAppH _ap NewAppReq{name = n, surface = s, platform = p, githubRepo = g, workflowPath = w, debugWorkflowPath = dw, packageName = pkg, displayLabel = d, firebaseProjectId = fbp, enabled = e} =
    let row =
            NewAppCatalogRow
                { nacName = n
                , nacSurface = s
                , nacPlatform = p
                , nacGithubRepo = g
                , nacWorkflowPath = w
                , nacDebugWorkflowPath = dw
                , nacPackageName = pkg
                , nacDisplayLabel = d
                , nacFirebaseProjectId = fbp
                , nacEnabled = e
                }
     in toRespNoBuild <$> insertAppCatalog row

patchAppH :: AuthedPerson -> Int32 -> PatchAppReq -> Flow AppCatalogEntryResp
patchAppH _ap aid PatchAppReq{enabled = e, displayLabel = d, packageName = pkg, firebaseProjectId = fbp, workflowPath = w, debugWorkflowPath = dw} = do
    let patch =
            PatchAppCatalogRow
                { pacEnabled = e
                , pacDisplayLabel = d
                , pacPackageName = pkg
                , pacFirebaseProjectId = fbp
                , pacWorkflowPath = w
                , pacDebugWorkflowPath = dw
                }
    mResult <- updateAppCatalog aid patch
    case mResult of
        Just r -> pure (toRespNoBuild r)
        Nothing -> throwM $ NotFound "app_catalog row not found"
