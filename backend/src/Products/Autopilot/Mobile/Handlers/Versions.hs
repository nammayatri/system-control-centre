{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

{- | Handler for @POST /mobile/versions/preview@.

Given a list of @app_catalog@ ids, returns the next version for each
app. The response shape **differs per platform**:

* Android rows return @next_version_name@ + @next_version_code@
  (two fields; matches Play / @fastlane-android.yaml@ inputs).
* iOS rows return @next_version_number@ (single field; matches Apple /
  @fastlane.yaml@ inputs — build number is computed inside the workflow).

Per-app errors land in the @err@ field; the only top-level failure
mode is one of the platform clients being completely misconfigured.
Each row's resolution uses 'Mobile.Versioning.resolveNextVersion', so
adding more platforms later means extending the dispatcher in one
place rather than touching this handler.

Permission: 'AP_RELEASE_CREATE' — same gate as planning a release. We
deliberately don't carve out a separate version-preview permission.
-}
module Products.Autopilot.Mobile.Handlers.Versions (
    PreviewVersionsReq (..),
    VersionPreviewItem (..),
    PreviewVersionsResp (..),
    previewVersionsH,
) where

import Control.Monad.IO.Class (liftIO)
import Core.Auth.Protected (AuthedPerson)
import Core.Environment (Flow)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericToJSON)
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Queries.AppCatalog (findAppCatalogById)
import Products.Autopilot.Mobile.Types.Storage (AppCatalogT (..))
import Products.Autopilot.RuntimeConfig (isVersionPreviewEnabled)
import Products.Autopilot.Mobile.Versioning (
    VersionResolution (..),
    loadAscCreds,
    mintAscToken,
    resolveNextVersionWithToken,
 )

-- ─── Request / response types ──────────────────────────────────────

newtype PreviewVersionsReq = PreviewVersionsReq
    { appCatalogIds :: [Int32]
    }
    deriving (Generic, Show)

instance ToJSON PreviewVersionsReq
instance FromJSON PreviewVersionsReq

-- | Per-app response row.
--
-- Discriminated by which fields are set:
--
-- * Android success: @nextVersionName@ + @nextVersionCode@ + @source = "play_console"@.
-- * iOS success: @nextVersionNumber@ + @source = "app_store_connect"@.
-- * Error: @err@ holds the stable tag from the dispatcher.
--
-- Unrelated fields are omitted from JSON via 'omitNothingFields'.
data VersionPreviewItem = VersionPreviewItem
    { appCatalogId :: Int32
    , nextVersionName :: Maybe Text
    , nextVersionCode :: Maybe Int32
    , nextVersionNumber :: Maybe Text
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
    enabled <- isVersionPreviewEnabled
    if not enabled
        then pure PreviewVersionsResp{previews = []}
        else do
            mAscToken <- mintAscTokenOnce
            items <- mapM (previewOne mAscToken) (appCatalogIds req)
            pure PreviewVersionsResp{previews = items}

mintAscTokenOnce :: Flow (Maybe Text)
mintAscTokenOnce = do
    mCreds <- loadAscCreds
    case mCreds of
        Nothing -> pure Nothing
        Just creds -> do
            eToken <- liftIO (mintAscToken creds)
            case eToken of
                Left _ -> pure Nothing
                Right token -> pure (Just token)

{- | Per-app preview. Catches every recoverable failure into 'err' so
one bad app never poisons the whole batch. Uses a shared ASC token for
all iOS apps to avoid Apple rejecting duplicate JWTs minted in the
same second.
-}
previewOne :: Maybe Text -> Int32 -> Flow VersionPreviewItem
previewOne mAscToken aid = do
    mApp <- findAppCatalogById aid
    case mApp of
        Nothing -> pure (errorItem aid "app_not_found")
        Just app_ -> case acPackageName app_ of
            Nothing -> pure (errorItem aid "no_package_name")
            Just "" -> pure (errorItem aid "no_package_name")
            Just pkg -> do
                res <- resolveNextVersionWithToken mAscToken (acPlatform app_) pkg
                pure $ case res of
                    Left e -> errorItem aid e
                    Right (AndroidVersion name code) ->
                        VersionPreviewItem
                            { appCatalogId = aid
                            , nextVersionName = Just name
                            , nextVersionCode = Just code
                            , nextVersionNumber = Nothing
                            , source = Just "play_console"
                            , err = Nothing
                            }
                    Right (IosVersion number) ->
                        VersionPreviewItem
                            { appCatalogId = aid
                            , nextVersionName = Nothing
                            , nextVersionCode = Nothing
                            , nextVersionNumber = Just number
                            , source = Just "app_store_connect"
                            , err = Nothing
                            }

errorItem :: Int32 -> Text -> VersionPreviewItem
errorItem aid msg =
    VersionPreviewItem
        { appCatalogId = aid
        , nextVersionName = Nothing
        , nextVersionCode = Nothing
        , nextVersionNumber = Nothing
        , source = Nothing
        , err = Just msg
        }
