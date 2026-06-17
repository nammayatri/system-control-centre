{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}

{- | App Release Monitoring HTTP handlers.

@GET  \/mobile\/store-monitor@ — the whole dashboard grid AND every modal in one
read-through-cache call: every app's live per-track store state (version, build
code, status, rollout %, review state, "What's New" notes, drift) assembled from
the @store_status@ cache joined (in Haskell) with @app_catalog@. The frontend
modal opens client-side from a loaded card — no second request.

@POST \/mobile\/store-monitor\/:id\/refresh@ — live re-poll ONE app, upsert the
cache, and return its fresh card.

Both gated by 'AP_RELEASE_VIEW' (the refresh is a read-tier action — it pulls
fresh data, it doesn't mutate a release). Every app in the catalog appears —
enabled or not — so the page shows releases for ALL apps.
-}
module Products.Autopilot.Mobile.Handlers.StoreMonitor (
    TrackCellResp (..),
    PlatformBlockResp (..),
    PlatformsResp (..),
    StoreMonitorAppResp (..),
    StoreMonitorResp (..),
    storeMonitorH,
    refreshStoreAppH,
) where

import Control.Monad.Catch (throwM)
import Core.AppError (APIError (..))
import Core.Auth.Protected (AuthedPerson)
import Core.Environment (Flow)
import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int32)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import Products.Autopilot.Mobile.Queries.AppCatalog (findAppCatalogById, listAppCatalog)
import Products.Autopilot.Mobile.Queries.StoreStatus (listStoreStatus)
import Products.Autopilot.Mobile.StoreSync (refreshStoreStatusOne)
import Products.Autopilot.Mobile.Types (isDebugBuildType)
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..), StoreStatus, StoreStatusT (..))
import Products.Autopilot.RuntimeConfig (getMobileBuildType)

-- | One track's live cell. Field names match the frontend @TrackCell@ verbatim.
data TrackCellResp = TrackCellResp
    { version :: Maybe Text
    , buildCode :: Maybe Int32
    , status :: Maybe Text
    , rolloutPercent :: Maybe Double
    , reviewStatus :: Maybe Text
    , releaseNotes :: Maybe Text
    , drift :: Bool
    , syncedAt :: Maybe UTCTime
    }
    deriving (Generic, Show)

instance ToJSON TrackCellResp
instance FromJSON TrackCellResp

-- | One platform's tracks for an app. @internal@ is Android-only, @testflight@
-- iOS-only; the off-platform one is always 'Nothing'.
data PlatformBlockResp = PlatformBlockResp
    { appCatalogId :: Int32
    , bundleId :: Maybe Text
    , production :: Maybe TrackCellResp
    , internal :: Maybe TrackCellResp
    , testflight :: Maybe TrackCellResp
    }
    deriving (Generic, Show)

instance ToJSON PlatformBlockResp
instance FromJSON PlatformBlockResp

data PlatformsResp = PlatformsResp
    { android :: Maybe PlatformBlockResp
    , ios :: Maybe PlatformBlockResp
    }
    deriving (Generic, Show)

instance ToJSON PlatformsResp
instance FromJSON PlatformsResp

-- | One dashboard card: an app (display label + surface) with its platform blocks.
data StoreMonitorAppResp = StoreMonitorAppResp
    { app :: Text
    , surface :: Text
    , platforms :: PlatformsResp
    }
    deriving (Generic, Show)

instance ToJSON StoreMonitorAppResp
instance FromJSON StoreMonitorAppResp

-- | The monitor payload + an availability flag. @available = false@ (with a
-- @reason@) tells the UI to render a notice instead of the grid — used for debug
-- deployments, which have no live production store data. Mirrors the AI
-- endpoints' @{available, reason}@ shape.
data StoreMonitorResp = StoreMonitorResp
    { available :: Bool
    , reason :: Maybe Text
    , apps :: [StoreMonitorAppResp]
    }
    deriving (Generic, Show)

instance ToJSON StoreMonitorResp
instance FromJSON StoreMonitorResp

-- | Why the monitor is hidden in a debug deployment.
debugUnavailableReason :: Text
debugUnavailableReason =
    "App Release Monitoring isn't available for debug builds — it tracks live production \
    \store releases, which a debug deployment doesn't have."

-- ─── Handlers ──────────────────────────────────────────────────────

-- | The whole grid + modal data in one cache read. A debug deployment has no
-- production store data, so it short-circuits to @available = false@ (no DB read,
-- no store calls) and the UI shows a notice.
storeMonitorH :: AuthedPerson -> Flow StoreMonitorResp
storeMonitorH _ap = do
    buildType <- getMobileBuildType
    if isDebugBuildType buildType
        then pure (StoreMonitorResp False (Just debugUnavailableReason) [])
        else do
            apps_ <- listAppCatalog
            statuses <- listStoreStatus
            pure (StoreMonitorResp True Nothing (assembleCards apps_ statuses))

-- | Live re-poll one app, then return its fresh card. 404 on an unknown id. In a
-- debug deployment it re-polls nothing and reads no @store_status@ (the table may
-- not even be migrated there) — returns an empty card.
refreshStoreAppH :: AuthedPerson -> Int32 -> Flow StoreMonitorAppResp
refreshStoreAppH _ap aid = do
    mRow <- findAppCatalogById aid
    case mRow of
        Nothing -> throwM $ NotFound "app_catalog row not found"
        Just row -> do
            buildType <- getMobileBuildType
            -- Debug: no store data, and store_status may be unmigrated — skip both
            -- the live re-poll and the table read entirely.
            statuses <-
                if isDebugBuildType buildType
                    then pure []
                    else refreshStoreStatusOne row >> listStoreStatus
            apps <- listAppCatalog
            let key = (acName row, acSurface row)
                groupRows = filter (\a -> (acName a, acSurface a) == key) apps
            pure (toCard (indexStatuses statuses) key groupRows)

-- ─── Assembly (pure) ───────────────────────────────────────────────

-- | Index cache rows by (app_catalog_id, track) for O(1) cell lookup.
indexStatuses :: [StoreStatus] -> Map.Map (Int32, Text) StoreStatus
indexStatuses statuses = Map.fromList [((ssAppCatalogId s, ssTrack s), s) | s <- statuses]

-- | Group catalog rows by (name, surface) — each group has up to one android +
-- one ios row — and project a card per group. Map keys give a stable A→Z order.
assembleCards :: [AppCatalog] -> [StoreStatus] -> [StoreMonitorAppResp]
assembleCards apps statuses =
    let idx = indexStatuses statuses
        groups = Map.toList $ Map.fromListWith (flip (++)) [((acName a, acSurface a), [a]) | a <- apps]
     in [toCard idx k rows | (k, rows) <- groups]

toCard :: Map.Map (Int32, Text) StoreStatus -> (Text, Text) -> [AppCatalog] -> StoreMonitorAppResp
toCard idx (nm, sfc) rows =
    StoreMonitorAppResp
        { app = fromMaybe nm (listToMaybe (mapMaybe acDisplayLabel rows))
        , surface = sfc
        , platforms =
            PlatformsResp
                { android = toBlock idx <$> find ((== "android") . acPlatform) rows
                , ios = toBlock idx <$> find ((== "ios") . acPlatform) rows
                }
        }

toBlock :: Map.Map (Int32, Text) StoreStatus -> AppCatalog -> PlatformBlockResp
toBlock idx r =
    let cellFor trk = toCell <$> Map.lookup (acId r, trk) idx
     in PlatformBlockResp
            { appCatalogId = acId r
            , bundleId = acPackageName r
            , production = cellFor "production"
            , internal = if acPlatform r == "android" then cellFor "internal" else Nothing
            , testflight = if acPlatform r == "ios" then cellFor "testflight" else Nothing
            }

toCell :: StoreStatus -> TrackCellResp
toCell ss =
    TrackCellResp
        { version = ssVersionName ss
        , buildCode = ssVersionCode ss
        , status = ssStatus ss
        , rolloutPercent = ssRolloutPercent ss
        , reviewStatus = ssReviewStatus ss
        , releaseNotes = ssReleaseNotes ss
        , -- Drift = the live PRODUCTION version differs from the last SCC-shipped
          -- one (an out-of-band release). Other tracks never flag drift.
          drift = ssTrack ss == "production" && driftsFromExpected ss
        , syncedAt = Just (ssSyncedAt ss)
        }

driftsFromExpected :: StoreStatus -> Bool
driftsFromExpected ss = case (ssVersionName ss, ssExpectedVersion ss) of
    (Just v, Just ev) -> v /= ev
    _ -> False
