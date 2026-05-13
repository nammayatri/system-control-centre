{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Handler for @POST /mobile/versions/preview@.

Given a list of @app_catalog@ ids, returns the next (versionName,
versionCode) for each app by querying its @internal@ + @production@
tracks via 'fetchPlayTracks' and running 'computeNextVersion'. Per-app
errors are returned in the response (never throw); the only top-level
failure mode is missing Play Console credentials (treated as 500).

Permission: 'AP_RELEASE_CREATE' — same gate as planning a release. We
deliberately don't carve out a separate version-preview permission.
-}
module Products.Autopilot.Mobile.Handlers.Versions (
    PreviewVersionsReq (..),
    VersionPreviewItem (..),
    PreviewVersionsResp (..),
    previewVersionsH,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson)
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Queries.AppCatalog (findAppCatalogById)
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT (..))
import Products.Autopilot.Mobile.Versioning (
    PlayApiError (..),
    PlayCreds,
    computeNextVersion,
    fetchPlayTracks,
    loadPlayCreds,
 )

-- ─── Request / response types ──────────────────────────────────────

newtype PreviewVersionsReq = PreviewVersionsReq
    { appCatalogIds :: [Int32]
    }
    deriving (Generic, Show)

instance ToJSON PreviewVersionsReq
instance FromJSON PreviewVersionsReq

data VersionPreviewItem = VersionPreviewItem
    { appCatalogId :: Int32
    , nextVersionName :: Maybe Text
    , nextVersionCode :: Maybe Int32
    , source :: Maybe Text
    , err :: Maybe Text
    }
    deriving (Generic, Show)

instance ToJSON VersionPreviewItem where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON VersionPreviewItem

newtype PreviewVersionsResp = PreviewVersionsResp
    { previews :: [VersionPreviewItem]
    }
    deriving (Generic, Show)

instance ToJSON PreviewVersionsResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON PreviewVersionsResp

-- ─── Handler ───────────────────────────────────────────────────────

previewVersionsH :: AuthedPerson -> PreviewVersionsReq -> Flow PreviewVersionsResp
previewVersionsH _ap req = do
    mCreds <- loadPlayCreds
    case mCreds of
        Nothing ->
            throwM $
                InternalError
                    "play_console_service_account_json server_config is not set; cannot preview versions"
        Just creds -> do
            items <- mapM (previewOne creds) (appCatalogIds req)
            pure PreviewVersionsResp{previews = items}

{- | Per-app preview. Catches every recoverable failure into 'err' so
one bad app never poisons the whole batch.
-}
previewOne :: PlayCreds -> Int32 -> Flow VersionPreviewItem
previewOne creds aid = do
    mApp <- findAppCatalogById aid
    case mApp of
        Nothing -> pure (errorItem aid "app_not_found")
        Just app_ -> case acPackageName app_ of
            Nothing -> pure (errorItem aid "no_package_name")
            Just "" -> pure (errorItem aid "no_package_name")
            Just pkg -> do
                eTracks <- fetchPlayTracks creds pkg
                case eTracks of
                    Left e -> pure (errorItem aid (renderPlayErr e))
                    Right (internal, production) -> do
                        let (name, code) = computeNextVersion internal production
                        pure
                            VersionPreviewItem
                                { appCatalogId = aid
                                , nextVersionName = Just name
                                , nextVersionCode = Just code
                                , source = Just "play_console"
                                , err = Nothing
                                }

errorItem :: Int32 -> Text -> VersionPreviewItem
errorItem aid msg =
    VersionPreviewItem
        { appCatalogId = aid
        , nextVersionName = Nothing
        , nextVersionCode = Nothing
        , source = Nothing
        , err = Just msg
        }

renderPlayErr :: PlayApiError -> Text
renderPlayErr PlayUnauthorized = "play_unauthorized"
renderPlayErr (PlayPackageNotFound pkg) = "play_package_not_found:" <> pkg
renderPlayErr (PlayHttpError s body) =
    "play_http_error:" <> T.pack (show s) <> ":" <> body
