{- | Re-export shim so existing Autopilot imports keep working; the real
  definitions live in 'Core.Workflow.Recorded'.
-}
module Products.Autopilot.Workflow.Recorded (
    Recorded (..),
    runRecorded,
    recordedWithPersist,
)
where

import Core.Workflow.Recorded
