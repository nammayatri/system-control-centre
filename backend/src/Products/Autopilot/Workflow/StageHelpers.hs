{-# LANGUAGE OverloadedStrings #-}

{- | Autopilot-specific bridge from legacy 'StateFlow' bodies to 'Stage'.

Lives in @Products.Autopilot.Workflow@ because it's parameterised over
Autopilot's 'ReleaseWFStatus' / 'ReleaseState' — other products will build
their own equivalent over their own status types.
-}
module Products.Autopilot.Workflow.StageHelpers (
    mkLegacyStateFlowStage,
)
where

import Core.Workflow.Engine (liftStateFlow)
import Core.Workflow.Stage (Stage (..), StageOutcome (..), mkStage)
import Data.Text (Text)
import Products.Autopilot.Types.Release (ReleaseTracker (..))
import Products.Autopilot.Types.Workflow (ReleaseWFStatus)
import Products.Autopilot.Workflow.Types (ReleaseState (..), StateFlow)

{- | Build a 'Stage' from a legacy 'StateFlow' body. Skip-check and advance
use @releaseWFStatus >= targetStatus@; the body runs via 'liftStateFlow'
and is expected to throw on failure (no 'StageAbort' path).
-}
mkLegacyStateFlowStage :: Text -> ReleaseWFStatus -> StateFlow () -> Stage ReleaseState
mkLegacyStateFlowStage name targetStatus action =
    (mkStage name (liftStateFlow action >> pure StageSuccess))
        { stageGuard = \rs -> releaseWFStatus (releaseTracker rs) >= targetStatus
        , stageOnAdvance = \rs ->
            let rt = releaseTracker rs
             in rs{releaseTracker = rt{releaseWFStatus = targetStatus}}
        }
