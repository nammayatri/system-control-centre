{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

{- | HTTP handlers for the @app_catalog@ endpoints (list/create/patch).

Permissions: list is gated by 'AP_RELEASE_VIEW' (any operator); create
and patch require 'AP_MOBILE_APP_MANAGE' (admin).
-}
module Products.Autopilot.Mobile.Handlers.AppCatalog (
    AppCatalogEntryResp (..),
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
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Queries.AppCatalog
import Products.Autopilot.Mobile.Types.Storage

data AppCatalogEntryResp = AppCatalogEntryResp
    { id :: Int32
    , name :: Text
    , surface :: Text
    , platform :: Text
    , githubRepo :: Text
    , workflowPath :: Text
    , packageName :: Maybe Text
    , displayLabel :: Maybe Text
    , enabled :: Bool
    , createdAt :: UTCTime
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
    , workflowPath :: Maybe Text
    }
    deriving (Generic, Show)

instance ToJSON PatchAppReq where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON PatchAppReq

toResp :: AppCatalog -> AppCatalogEntryResp
toResp r =
    AppCatalogEntryResp
        { id = acId r
        , name = acName r
        , surface = acSurface r
        , platform = acPlatform r
        , githubRepo = acGithubRepo r
        , workflowPath = acWorkflowPath r
        , packageName = acPackageName r
        , displayLabel = acDisplayLabel r
        , enabled = acEnabled r
        , createdAt = acCreatedAt r
        }

listAppsH :: AuthedPerson -> Flow [AppCatalogEntryResp]
listAppsH _ap = map toResp <$> listAppCatalog

createAppH :: AuthedPerson -> NewAppReq -> Flow AppCatalogEntryResp
createAppH _ap NewAppReq{name = n, surface = s, platform = p, githubRepo = g, workflowPath = w, packageName = pkg, displayLabel = d, enabled = e} =
    let row =
            NewAppCatalogRow
                { nacName = n
                , nacSurface = s
                , nacPlatform = p
                , nacGithubRepo = g
                , nacWorkflowPath = w
                , nacPackageName = pkg
                , nacDisplayLabel = d
                , nacEnabled = e
                }
     in toResp <$> insertAppCatalog row

patchAppH :: AuthedPerson -> Int32 -> PatchAppReq -> Flow AppCatalogEntryResp
patchAppH _ap aid PatchAppReq{enabled = e, displayLabel = d, packageName = pkg, workflowPath = w} = do
    let patch =
            PatchAppCatalogRow
                { pacEnabled = e
                , pacDisplayLabel = d
                , pacPackageName = pkg
                , pacWorkflowPath = w
                }
    mResult <- updateAppCatalog aid patch
    case mResult of
        Just r -> pure (toResp r)
        Nothing -> throwM $ NotFound "app_catalog row not found"
