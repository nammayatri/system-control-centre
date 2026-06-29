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
import Products.Autopilot.Mobile.Queries.Tracker (listIncomingMobileVersions, parseMobileTargetState)
import Products.Autopilot.Mobile.StoreSync (refreshStoreStatusOne)
import Products.Autopilot.Mobile.Lifecycle.Phase (Display (..), ReleasePhase (..), displayStatus, variantSlug)
import Products.Autopilot.Mobile.Types (MobileBuildContext (..), MobileBuildTargetState (..), isDebugBuildType)
import Products.Autopilot.Mobile.Types.Storage (AppCatalog, AppCatalogT (..), StoreStatus, StoreStatusT (..))
import Products.Autopilot.Types.Storage.Schema (ReleaseTrackerRow, ReleaseTrackerT (..))
import Products.Autopilot.RuntimeConfig (getMobileBuildType, getStoreRefreshCooldownSeconds)

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
    , displayLabel :: Maybe Text
    -- ^ Canonical backend displayStatus for the production/incoming lifecycle cell,
    -- so the monitor and the release list render the same badge. Nothing for the
    -- testing tracks (they badge by track) and non-lifecycle cells.
    , displayVariant :: Maybe Text
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
    , -- | The PROD-INCOMING version (in review / approved-held / rejected), if any —
      -- sourced from release_tracker so it shows even after leaving the internal track.
      incoming :: Maybe TrackCellResp
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
    , staleThresholdSeconds :: Int
    -- ^ The single freshness threshold (= the backend refresh cooldown). The UI
    -- uses it to decide when to auto-refresh on open + warn that data is stale, so
    -- there's one source of truth instead of a separate hardcoded client value.
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
    cooldown <- getStoreRefreshCooldownSeconds
    if isDebugBuildType buildType
        then pure (StoreMonitorResp False (Just debugUnavailableReason) [] cooldown)
        else do
            apps_ <- listAppCatalog
            statuses <- listStoreStatus
            incomings <- listIncomingMobileVersions
            pure (StoreMonitorResp True Nothing (assembleCards apps_ statuses incomings) cooldown)

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
            incomings <- listIncomingMobileVersions
            let key = (acName row, acSurface row)
                groupRows = filter (\a -> (acName a, acSurface a) == key) apps
            pure (toCard (indexStatuses statuses) (indexIncoming incomings) key groupRows)

-- ─── Assembly (pure) ───────────────────────────────────────────────

-- | Index cache rows by (app_catalog_id, track) for O(1) cell lookup.
indexStatuses :: [StoreStatus] -> Map.Map (Int32, Text) StoreStatus
indexStatuses statuses = Map.fromList [((ssAppCatalogId s, ssTrack s), s) | s <- statuses]

-- | Index the PROD-INCOMING rows by (app_group, service, env) = (name, surface,
-- platform), the catalog join key — at most one incoming per app by the slot model.
indexIncoming :: [ReleaseTrackerRow] -> Map.Map (Text, Text, Text) ReleaseTrackerRow
indexIncoming rows = Map.fromList [((rtAppGroup r, rtService r, rtEnv r), r) | r <- rows]

-- | Group catalog rows by (name, surface) — each group has up to one android +
-- one ios row — and project a card per group. Map keys give a stable A→Z order.
assembleCards :: [AppCatalog] -> [StoreStatus] -> [ReleaseTrackerRow] -> [StoreMonitorAppResp]
assembleCards apps statuses incomings =
    let idx = indexStatuses statuses
        incIdx = indexIncoming incomings
        groups = Map.toList $ Map.fromListWith (flip (++)) [((acName a, acSurface a), [a]) | a <- apps]
     in [toCard idx incIdx k rows | (k, rows) <- groups]

toCard :: Map.Map (Int32, Text) StoreStatus -> Map.Map (Text, Text, Text) ReleaseTrackerRow -> (Text, Text) -> [AppCatalog] -> StoreMonitorAppResp
toCard idx incIdx (nm, sfc) rows =
    StoreMonitorAppResp
        { app = fromMaybe nm (listToMaybe (mapMaybe acDisplayLabel rows))
        , surface = sfc
        , platforms =
            PlatformsResp
                { android = toBlock idx incIdx <$> find ((== "android") . acPlatform) rows
                , ios = toBlock idx incIdx <$> find ((== "ios") . acPlatform) rows
                }
        }

toBlock :: Map.Map (Int32, Text) StoreStatus -> Map.Map (Text, Text, Text) ReleaseTrackerRow -> AppCatalog -> PlatformBlockResp
toBlock idx incIdx r =
    let cellFor trk = toCell <$> Map.lookup (acId r, trk) idx
     in PlatformBlockResp
            { appCatalogId = acId r
            , bundleId = acPackageName r
            , production = cellFor "production"
            , incoming = incomingCell <$> Map.lookup (acName r, acSurface r, acPlatform r) incIdx
            , internal = if acPlatform r == "android" then cellFor "internal" else Nothing
            , testflight = if acPlatform r == "ios" then cellFor "testflight" else Nothing
            }

-- | Project a PROD-INCOMING release_tracker row into a monitor cell. Carries the
-- review verdict so the badge reads "In review" / "Approved · held" / "Rejected".
incomingCell :: ReleaseTrackerRow -> TrackCellResp
incomingCell r =
    TrackCellResp
        { version = Just (rtNewVersion r)
        , buildCode = mbcVersionCode . mbContext =<< parseMobileTargetState (rtTargetState r)
        , status = Just "inProgress"
        , rolloutPercent = Nothing
        , reviewStatus = rtReviewStatus r
        , releaseNotes = Nothing
        , drift = False
        , syncedAt = Just (rtUpdatedAt r)
        , displayLabel = fst disp
        , displayVariant = snd disp
        }
  where
    disp = cellDisplay (Just "inProgress") (rtReviewStatus r) Nothing

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
          drift = isProd && driftsFromExpected ss
        , syncedAt = Just (ssSyncedAt ss)
        , -- Only the production cell carries the lifecycle badge; testing tracks
          -- badge by track on the FE, so leave their display Nothing.
          displayLabel = if isProd then fst disp else Nothing
        , displayVariant = if isProd then snd disp else Nothing
        }
  where
    isProd = ssTrack ss == "production"
    disp = cellDisplay (ssStatus ss) (ssReviewStatus ss) (ssRolloutPercent ss)

-- | Map an observed production/incoming store cell to a lifecycle phase, mirroring
-- the FE deriveStoreBadge precedence (review verdict before rollout; an active ramp
-- before "approved"). Nothing = no lifecycle (testing track / VALID / empty).
observedToPhase :: Maybe Text -> Maybe Text -> Maybe Double -> Maybe ReleasePhase
observedToPhase mStatus mReview mPct =
    case mReview of
        Just "rejected" -> Just (Rejected "")
        Just "in_review" -> Just InReview
        _ -> case (mStatus, mPct) of
            (Just "halted", Just p) -> Just (Halted (p / 100))
            (Just "inProgress", Just p) | p >= 1 && p < 100 -> Just (RollingOut (p / 100))
            _ -> case mReview of
                Just "approved" -> Just Approved
                _
                    | mStatus == Just "live" || mStatus == Just "completed" -> Just Live
                    | otherwise -> Nothing

-- | The observed phase rendered as (display label, variant slug), or both Nothing.
cellDisplay :: Maybe Text -> Maybe Text -> Maybe Double -> (Maybe Text, Maybe Text)
cellDisplay s r p = case observedToPhase s r p of
    Just ph -> let d = displayStatus ph in (Just (dLabel d), Just (variantSlug (dVariant d)))
    Nothing -> (Nothing, Nothing)

driftsFromExpected :: StoreStatus -> Bool
driftsFromExpected ss = case (ssVersionName ss, ssExpectedVersion ss) of
    (Just v, Just ev) -> v /= ev
    _ -> False
