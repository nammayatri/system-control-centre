{-# LANGUAGE OverloadedStrings #-}

{- | Fleet activity feed (docs\/design\/fleet-activity-mockup-v1.html): one
merged, newest-first stream of every mobile operation across the fleet —
release workflow events, OTA bundle pushes, and proxied airborne mutations.

Three sources, one UNION:
  * @release_events@ (BUSINESS rows of MobileBuild trackers; noisy machine
    labels excluded) joined to @release_tracker@ for app\/platform\/version.
    Actor comes from the payload when the writer recorded one.
  * @ota_push@ — one entry per push at its latest state change.
  * @airborne_events@ — RAMP\/CONCLUDE\/DISCARD\/CREATE with real actors.

Category\/sentence mapping lives in the frontend; this endpoint returns raw
labels. Cursor paging: pass @before@ (the @at@ of the last row) for the next
page — client-side category filters keep working because the cursor is the
scan position, not a filtered offset.
-}
module Products.Autopilot.Mobile.Handlers.Activity (
    ActivityResp (..),
    ActivityRow (..),
    fleetActivityH,
) where

import Core.Auth.Protected (AuthedPerson)
import Core.DB.Connection (withConn)
import Core.Environment (Flow, withDb)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple ((:.) (..), query)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import GHC.Generics (Generic)

data ActivityRow = ActivityRow
    { avId :: Text
    , avAt :: UTCTime
    , avActor :: Maybe Text
    , avSource :: Text
    -- ^ release | ota_push | airborne
    , avAction :: Text
    , avApp :: Maybe Text
    , avPlatform :: Maybe Text
    , avVersion :: Maybe Text
    , avReleaseId :: Maybe Text
    , avGroupId :: Maybe Text
    , avDetail :: Maybe Value
    }
    deriving (Generic, Show)

instance FromRow ActivityRow where
    fromRow =
        ActivityRow
            <$> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field
            <*> field

instance ToJSON ActivityRow where
    toJSON r =
        object
            [ "id" .= avId r
            , "at" .= avAt r
            , "actor" .= avActor r
            , "source" .= avSource r
            , "action" .= avAction r
            , "app" .= avApp r
            , "platform" .= avPlatform r
            , "version" .= avVersion r
            , "releaseId" .= avReleaseId r
            , "groupId" .= avGroupId r
            , "detail" .= avDetail r
            ]

data ActivityResp = ActivityResp
    { arRows :: [ActivityRow]
    , arNextBefore :: Maybe UTCTime
    -- ^ cursor for the next page; Nothing = end of the window
    }
    deriving (Generic, Show)

instance ToJSON ActivityResp where
    toJSON r = object ["rows" .= arRows r, "nextBefore" .= arNextBefore r]

fleetActivityH ::
    AuthedPerson ->
    Maybe Int ->
    -- ^ days window (default 7, clamped 1..90)
    Maybe Text ->
    -- ^ app filter (matches app name, ILIKE)
    Maybe Text ->
    -- ^ actor filter (exact email)
    Maybe Text ->
    -- ^ free-text search (action / app / version)
    Maybe UTCTime ->
    -- ^ cursor: only rows strictly before this instant
    Maybe Int ->
    -- ^ page size (default 50, clamped 1..200)
    Flow ActivityResp
fleetActivityH _ap mDays mApp mActor mQ mBefore mLimit = do
    let days = max 1 (min 90 (fromMaybe 7 mDays))
        lim = max 1 (min 200 (fromMaybe 50 mLimit))
    rows <-
        withDb $ \db -> withConn db $ \conn ->
            query
                conn
                "SELECT * FROM ( \
                  \  SELECT 're-' || re.re_id::text AS aid, re.re_created_at AS at, \
                  \         COALESCE(re.re_payload->>'actor', re.re_payload->>'by', \
                  \                  re.re_payload->>'requested_by', re.re_payload->>'approved_by', \
                  \                  re.re_payload->>'email') AS actor, \
                  \         'release'::text AS source, re.re_label AS action, \
                  \         rt.app_group AS app, rt.env AS platform, rt.new_version AS version, \
                  \         re.re_release_id AS release_id, rt.release_group_id AS group_id, \
                  \         re.re_payload AS detail \
                  \  FROM release_events re \
                  \  JOIN release_tracker rt ON rt.id = re.re_release_id \
                  \  WHERE rt.category = 'MobileBuild' AND re.re_category = 'BUSINESS' \
                  \    AND re.re_label NOT IN ('MATRIX_JOB_UPDATED','RUNNER_PICKED','SNAPSHOT', \
                  \        'STATUS_UPDATED','DECISION_RESULT','DECISION_NOTIFIED','DECISION_ENGINE', \
                  \        'SYNC_REQUEST','SYNC_SKIPPED','STORE_SYNC','MONITORING_PODS_NOT_READY','NOTIFICATION') \
                  \  UNION ALL \
                       \  SELECT 'op-' || op.id::text, op.updated_at, op.dispatched_by, 'ota_push', \
                       \         'OTA_PUSH_' || op.status, op.app_name, op.platform, op.final_version, \
                       \         NULL, op.mobile_release_group_id, \
                       \         jsonb_build_object('bump', op.requested_bump, 'error', op.error, \
                       \                            'runId', op.external_run_id, 'packageVersion', op.package_version, \
                       \                            'sourceRef', op.source_ref) \
                       \  FROM ota_push op \
                       \  UNION ALL \
                       \  SELECT 'ae-' || ae.id::text, ae.created_at, ae.actor, 'airborne', \
                       \         'OTA_' || ae.action, ae.airborne_app, NULL, NULL, NULL, NULL, \
                       \         jsonb_build_object('endpoint', ae.endpoint, 'request', ae.request, \
                       \                            'status', ae.upstream_status) \
                       \  FROM airborne_events ae \
                       \) t \
                       \WHERE t.at >= now() - (?::text || ' days')::interval \
                       \  AND (?::timestamptz IS NULL OR t.at < ?) \
                       \  AND (?::text IS NULL OR t.app ILIKE '%' || ? || '%') \
                       \  AND (?::text IS NULL OR t.actor = ?) \
                       \  AND (?::text IS NULL OR t.action ILIKE '%' || ? || '%' \
                       \       OR t.app ILIKE '%' || ? || '%' OR COALESCE(t.version,'') ILIKE '%' || ? || '%') \
                       \ORDER BY t.at DESC, t.aid DESC \
                       \LIMIT ?"
                ( (show days, mBefore, mBefore, mApp, mApp)
                    :. (mActor, mActor, mQ, mQ, mQ, mQ)
                    :. [lim]
                )
    let nextBefore
            | length rows < lim = Nothing
            | otherwise = avAt <$> listToMaybe (reverse rows)
    pure ActivityResp{arRows = rows, arNextBefore = nextBefore}
