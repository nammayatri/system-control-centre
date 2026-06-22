{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Slot-supersession rules for the version-keyed mobile release model
-- (migration 0034). Both rules transition the OTHER production-track versions of an
-- app to HISTORY when a new version takes a slot, so the live + incoming slots each
-- hold exactly one version. Pure DB transitions; callers log the returned ids.
--
--   * Rule A — 'supersedePreviousLive': when a version starts rolling out, the
--     previously-live version (a different version still rolling / halted) freezes
--     at its last % and becomes @rollout_status = 'superseded'@ history.
--   * Rule B — 'retireOlderIncoming': when a version enters the incoming slot
--     (review / approved / rejected), any OTHER incoming version drops to history.
module Products.Autopilot.Mobile.Queries.Supersession
  ( supersedePreviousLive,
    retireOlderIncoming,
  )
where

import Control.Monad (forM_)
import Core.DB.Connection (runDB)
import Core.Environment (MonadFlow, withDb)
import Data.Text (Text)
import Database.Beam
import Database.Beam.Postgres (Postgres)
import Products.Autopilot.Types.Storage.Schema
  ( AutopilotDb (..),
    ReleaseTrackerT (..),
    autopilotDb,
  )

-- | Scope shared by both rules: another production-track MobileBuild row of the
-- SAME app for a DIFFERENT version than the one taking the slot.
otherProductionVersion ::
  Text -> Text -> Text -> Text -> Text -> ReleaseTrackerT (QExpr Postgres s) -> QExpr Postgres s Bool
otherProductionVersion appGroup surface platform newVersion excludeRid rt =
  rtAppGroup rt ==. val_ appGroup
    &&. rtService rt ==. val_ surface
    &&. rtEnv rt ==. val_ platform
    &&. rtCategory rt ==. val_ "MobileBuild"
    &&. rtStoreTrack rt ==. val_ (Just "production")
    &&. rtId rt /=. val_ excludeRid
    &&. rtNewVersion rt /=. val_ newVersion

-- | Rule A. Freeze the previous live version (different version, still rolling out /
-- halted below 100%) at its last percent and mark it @superseded@ → HISTORY. A
-- version already at completed/100% is left alone (it drops to history by version
-- order on its own). Returns the affected release ids for the caller to log.
supersedePreviousLive ::
  (MonadFlow m) => Text -> Text -> Text -> Text -> Text -> m [Text]
supersedePreviousLive appGroup surface platform newVersion excludeRid = withDb $ \db -> do
  ids <-
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (otherProductionVersion appGroup surface platform newVersion excludeRid rt)
          guard_
            ( rtRolloutStatus rt ==. val_ (Just "rolling_out")
                ||. rtRolloutStatus rt ==. val_ (Just "halted")
            )
          pure (rtId rt)
  forM_ ids $ \i ->
    runDB db $
      runUpdate $
        update
          (releaseTrackers autopilotDb)
          ( \rt ->
              mconcat
                [ rtStatus rt <-. val_ "COMPLETED",
                  -- keep rollout_percent frozen at its last value for the badge
                  rtRolloutStatus rt <-. val_ (Just "superseded")
                ]
          )
          (\rt -> rtId rt ==. val_ i)
  pure ids

-- | Rule B. Drop any OTHER incoming version (review_status set, not yet rolling) to
-- HISTORY when a newer version takes the incoming slot. Keeps review_status so the
-- history row still reads its last review state. Returns the affected ids.
retireOlderIncoming ::
  (MonadFlow m) => Text -> Text -> Text -> Text -> Text -> m [Text]
retireOlderIncoming appGroup surface platform newVersion excludeRid = withDb $ \db -> do
  ids <-
    runDB db $
      runSelectReturningList $
        select $ do
          rt <- all_ (releaseTrackers autopilotDb)
          guard_ (otherProductionVersion appGroup surface platform newVersion excludeRid rt)
          guard_ (not_ (isNothing_ (rtReviewStatus rt))) -- has a review state (incoming)
          guard_ (isNothing_ (rtRolloutStatus rt)) -- but not yet rolling out
          pure (rtId rt)
  forM_ ids $ \i ->
    runDB db $
      runUpdate $
        update
          (releaseTrackers autopilotDb)
          (\rt -> rtStatus rt <-. val_ "COMPLETED")
          (\rt -> rtId rt ==. val_ i)
  pure ids
