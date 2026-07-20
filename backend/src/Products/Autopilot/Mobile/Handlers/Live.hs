{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Handler for @GET /releases/live@ — returns the currently-live state of
backend services and mobile builds: the latest @COMPLETED@ release row
per @(app_group, service, env)@ tuple, split into @backend@ and
@mobile@ arrays.

The optional @?category=@ query parameter narrows the response:

  * @Nothing@ or @"all"@ — both arrays populated.
  * @"backend"@ — only backend rows; @mobile = []@.
  * @"mobile"@  — only mobile rows;  @backend = []@.

We deduplicate per @(app_group, service, env)@ in Haskell after
fetching all completed rows ordered by @end_time DESC@. This avoids
needing @SELECT DISTINCT ON@ in Beam, and the row volume here (one
COMPLETED per release) is small enough that the in-memory pass is
trivial.
-}
module Products.Autopilot.Mobile.Handlers.Live (
    LiveBackendRow (..),
    LiveMobileRow (..),
    LiveReleasesResp (..),
    liveReleasesH,
) where

import Core.Auth.Protected (AuthedPerson)
import Core.DB.Connection (runDB)
import Core.Environment (Flow, withDb)
import Data.Aeson (FromJSON (..), Options (..), ToJSON (..), defaultOptions, genericToJSON)
import qualified Data.Aeson as Aeson
import Data.Int (Int32)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime)
import Database.Beam
import Products.Autopilot.Mobile.Types (MobileBuildContext (..), MobileBuildTargetState (..))
import Products.Autopilot.Queries.ReleaseTracker (visibleToCloud, withCloudDb)
import Products.Autopilot.Types.Storage.Schema
import Products.Autopilot.Types.Target (TargetState (..))

-- ---------------------------------------------------------------------------
-- Response types
-- ---------------------------------------------------------------------------

data LiveBackendRow = LiveBackendRow
    { appGroup :: Text
    , service :: Text
    , env :: Text
    , liveVersion :: Text
    , rolloutState :: Maybe Text
    , updatedAt :: UTCTime
    }
    deriving (Generic, Show)

instance ToJSON LiveBackendRow where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON LiveBackendRow

data LiveMobileRow = LiveMobileRow
    { app :: Text
    , surface :: Text
    , platform :: Text
    , liveVersion :: Text
    , versionCode :: Maybe Int32
    , tagPushed :: Maybe Text
    , releasedAt :: UTCTime
    }
    deriving (Generic, Show)

instance ToJSON LiveMobileRow where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON LiveMobileRow

data LiveReleasesResp = LiveReleasesResp
    { backend :: [LiveBackendRow]
    , mobile :: [LiveMobileRow]
    }
    deriving (Generic, Show)

instance ToJSON LiveReleasesResp where
    toJSON = genericToJSON defaultOptions{omitNothingFields = True}
instance FromJSON LiveReleasesResp

-- ---------------------------------------------------------------------------
-- Handler
-- ---------------------------------------------------------------------------

backendCategories :: [Text]
backendCategories = ["BackendService", "BackendScheduler", "BackendConfig"]

mobileCategory :: Text
mobileCategory = "MobileBuild"

liveReleasesH :: AuthedPerson -> Maybe Text -> Flow LiveReleasesResp
liveReleasesH _ap mCategory = do
    let wantBackend = case mCategory of
            Just "mobile" -> False
            _ -> True
        wantMobile = case mCategory of
            Just "backend" -> False
            _ -> True
    backendRows <-
        if wantBackend
            then fetchBackendLive
            else pure []
    mobileRows <-
        if wantMobile
            then fetchMobileLive
            else pure []
    pure LiveReleasesResp{backend = backendRows, mobile = mobileRows}

-- ---------------------------------------------------------------------------
-- Backend fetch + dedup
-- ---------------------------------------------------------------------------

fetchBackendLive :: Flow [LiveBackendRow]
fetchBackendLive = do
    rows <- withCloudDb $ \cloud db ->
        runDB db $
            runSelectReturningList $
                select $
                    -- ORDER BY last_updated DESC so the first row per
                    -- (app_group, service, env) in the dedup pass is the
                    -- most-recently-COMPLETED release. For COMPLETED rows
                    -- last_updated is set at completion, which matches the
                    -- ordering we'd get from end_time but is non-null.
                    orderBy_ (desc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (visibleToCloud cloud rt)
                        guard_ (rtStatus rt ==. val_ "COMPLETED")
                        guard_ (rtCategory rt `in_` map val_ backendCategories)
                        pure rt
    pure (dedupBackend rows)

dedupBackend :: [ReleaseTrackerRow] -> [LiveBackendRow]
dedupBackend = go Map.empty
  where
    go :: Map.Map (Text, Text, Text) LiveBackendRow -> [ReleaseTrackerRow] -> [LiveBackendRow]
    go acc [] = Map.elems acc
    go acc (rt : rest) =
        let key = (rtAppGroup rt, rtService rt, rtEnv rt)
            row =
                LiveBackendRow
                    { appGroup = rtAppGroup rt
                    , service = rtService rt
                    , env = rtEnv rt
                    , liveVersion = rtNewVersion rt
                    , -- Beam doesn't surface a per-row rollout snapshot field
                      -- in release_tracker (it lives in release_context for K8s
                      -- and isn't useful for the live view yet). Leave Nothing
                      -- for now; future work can decode K8sState here.
                      rolloutState = Nothing
                    , updatedAt = fromMaybe (rtUpdatedAt rt) (rtEndTime rt)
                    }
         in -- Map.insertWith keeps the existing (newer) entry on collision,
            -- so the first occurrence per key wins. Rows arrive end_time DESC.
            go (Map.insertWith (\_new old -> old) key row acc) rest

-- ---------------------------------------------------------------------------
-- Mobile fetch + dedup
-- ---------------------------------------------------------------------------

fetchMobileLive :: Flow [LiveMobileRow]
fetchMobileLive = do
    rows <- withDb $ \db ->
        runDB db $
            runSelectReturningList $
                select $
                    orderBy_ (desc_ . rtUpdatedAt) $ do
                        rt <- all_ (releaseTrackers autopilotDb)
                        guard_ (rtStatus rt ==. val_ "COMPLETED")
                        guard_ (rtCategory rt ==. val_ mobileCategory)
                        pure rt
    pure (dedupMobile rows)

dedupMobile :: [ReleaseTrackerRow] -> [LiveMobileRow]
dedupMobile = go Map.empty
  where
    go :: Map.Map (Text, Text, Text) LiveMobileRow -> [ReleaseTrackerRow] -> [LiveMobileRow]
    go acc [] = Map.elems acc
    go acc (rt : rest) =
        let key = (rtAppGroup rt, rtService rt, rtEnv rt)
            row = toMobileRow rt
         in go (Map.insertWith (\_new old -> old) key row acc) rest

toMobileRow :: ReleaseTrackerRow -> LiveMobileRow
toMobileRow rt =
    let mCtx = decodeMobileContext (rtTargetState rt)
     in LiveMobileRow
            { app = rtAppGroup rt
            , surface = rtService rt
            , platform = rtEnv rt
            , liveVersion = rtNewVersion rt
            , versionCode = mCtx >>= mbcVersionCode
            , tagPushed = mCtx >>= mbcTagPushed
            , releasedAt = fromMaybe (rtUpdatedAt rt) (rtEndTime rt)
            }

{- | Best-effort decode of the @release_context@ JSON text into a
'MobileBuildContext'. Returns 'Nothing' if the column is NULL, not
valid JSON, or not a 'MobileBuildState' variant.
-}
decodeMobileContext :: Maybe Text -> Maybe MobileBuildContext
decodeMobileContext Nothing = Nothing
decodeMobileContext (Just t) =
    case Aeson.eitherDecodeStrict (TE.encodeUtf8 t) of
        Right (MobileBuildState mbts) -> Just (mbContext mbts)
        _ -> Nothing
