{- | Re-export shim for the shared 'Core.Workflow.Recorded' module.

The Recorded monad lives in 'Core.Workflow.Recorded' so every product
(Autopilot, future products) can reuse the same checkpointed workflow
engine. This module exists only to keep existing Autopilot imports
working without a codebase-wide rename.
-}
module Products.Autopilot.Workflow.Recorded (
    Recorded (..),
    runRecorded,
    recordedWithPersist,
)
where

import Core.Workflow.Recorded
