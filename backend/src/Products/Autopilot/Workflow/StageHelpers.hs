{-# LANGUAGE OverloadedStrings #-}

{- | Autopilot-specific stage construction helpers.

These helpers bridge the legacy 'StateFlow' workflow bodies and the new
product-agnostic 'Stage' / 'WorkflowSpec' machinery in 'Core.Workflow.*'.
They preserve the exact semantics of the old @|>>@ operator (defined in
'Workflow.Helpers.cprV2') so per-category specs can wrap existing
@validatePreconditions@ / @prepareK8sResources@ / etc. functions without
rewriting the bodies.

== Why this lives in 'Products.Autopilot.Workflow' rather than 'Core.Workflow' ==

The helper is parameterised over 'ReleaseWFStatus' and reads
@releaseWFStatus . releaseTracker@ from 'ReleaseState' — both of which
are autopilot-specific (a future product like @FrontendRelease@ would have
its own status enum and its own state record). Different products will
build their own @mkLegacyStateFlowStage@-style helpers parameterised over
their own status types.
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

{- | Build a 'Stage' from an existing legacy 'StateFlow' body.

Preserves the exact semantics of the old @|>>@ operator from
'Workflow.Helpers.cprV2':

* @stageGuard@ uses @releaseWFStatus rs >= targetStatus@ — matches the
  existing @stateCheckFuncV2@ in 'Workflow.Helpers'.
* @stageOnAdvance@ updates @releaseWFStatus@ to @targetStatus@ — matches
  the @modify@ block in @cprV2@.
* @stageExec@ runs the legacy 'StateFlow' body via 'liftStateFlow' and
  returns 'StageSuccess' (legacy bodies throw on failure rather than
  returning 'StageAbort').
* All other 'Stage' fields ('stagePreCheck', 'stageOnError',
  'stageAcquireLocks') are defaulted by 'mkStage'.

Stages built via this helper behave __identically__ to the old @|>>@ —
same skip-on-resume semantics, same persistence after each step, same
@wf_status@ advance — but they are now __values__ that the
'Core.Workflow.Engine' walks through the canonical six-step lifecycle.
-}
mkLegacyStateFlowStage :: Text -> ReleaseWFStatus -> StateFlow () -> Stage ReleaseState
mkLegacyStateFlowStage name targetStatus action =
    (mkStage name (liftStateFlow action >> pure StageSuccess))
        { stageGuard = \rs -> releaseWFStatus (releaseTracker rs) >= targetStatus
        , stageOnAdvance = \rs ->
            let rt = releaseTracker rs
             in rs{releaseTracker = rt{releaseWFStatus = targetStatus}}
        }
